// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "../AutoFarm-helpers/helpers/ERC20.sol";
import "../AutoFarm-helpers/libraries/Address.sol";
import "../AutoFarm-helpers/libraries/SafeERC20.sol";
import "../AutoFarm-helpers/libraries/EnumerableSet.sol";
import "../AutoFarm-helpers/helpers/Ownable.sol";
import "../AutoFarm-helpers/interfaces/IPancakeswapFarm.sol";
import "../AutoFarm-helpers/interfaces/IPancakeRouter01.sol";
import "../AutoFarm-helpers/interfaces/IPancakeRouter02.sol";

interface IWBNB is IERC20 {
    function deposit() external payable;

    function withdraw(uint256 wad) external;
}

import "../AutoFarm-helpers/helpers/ReentrancyGuard.sol";
import "../AutoFarm-helpers/helpers/Pausable.sol";

import {LibDiamond} from "../libraries/LibDiamond.sol";

contract StratX2Facet is ReentrancyGuard, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    event SetSettings(uint256 _entranceFeeFactor, uint256 _withdrawFeeFactor, uint256 _controllerFee, uint256 _buyBackRate, uint256 _slippageFactor);

    event SetGov(address _govAddress);
    event SetOnlyGov(bool _onlyGov);
    event SetUniRouterAddress(address _uniRouterAddress);
    event SetBuyBackAddress(address _buyBackAddress);
    event SetRewardsAddress(address _rewardsAddress);

    modifier onlyAllowGov() {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        require(msg.sender == s.govAddress, "!gov");
        _;
    }

    modifier onlyOwner() {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        require(msg.sender == s.owner, "you are not the owner!");

        _;
    }

    function wantLockedTotal() external view returns (uint256) {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        return s.wantLockedTotal;
    }

    function sharesTotal() external view returns (uint256) {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        return s.sharesTotal;
    }

    // Receives new deposits from user
    function deposit(uint256 _wantAmt) public virtual onlyOwner nonReentrant whenNotPaused returns (uint256) {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        IERC20(s.wantAddress).safeTransferFrom(address(msg.sender), address(this), _wantAmt);

        uint256 sharesAdded = _wantAmt;
        if (s.wantLockedTotal > 0 && s.sharesTotal > 0) {
            sharesAdded = _wantAmt.mul(s.sharesTotal).mul(s.entranceFeeFactor).div(s.wantLockedTotal).div(s.entranceFeeFactorMax);
        }
        s.sharesTotal = s.sharesTotal.add(sharesAdded);

        if (s.isAutoComp) {
            _farm();
        } else {
            s.wantLockedTotal = s.wantLockedTotal.add(_wantAmt);
        }

        return sharesAdded;
    }

    function farm() public virtual nonReentrant {
        _farm();
    }

    function _farm() internal virtual {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        require(s.isAutoComp, "!isAutoComp");
        uint256 wantAmt = IERC20(s.wantAddress).balanceOf(address(this));
        s.wantLockedTotal = s.wantLockedTotal.add(wantAmt);
        IERC20(s.wantAddress).safeIncreaseAllowance(s.farmContractAddress, wantAmt);

        if (s.isCAKEStaking) {
            IPancakeswapFarm(s.farmContractAddress).enterStaking(wantAmt); // Just for CAKE staking, we dont use deposit()
        } else {
            IPancakeswapFarm(s.farmContractAddress).deposit(s.pid, wantAmt);
        }
    }

    function _unfarm(uint256 _wantAmt) internal virtual {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        if (s.isCAKEStaking) {
            IPancakeswapFarm(s.farmContractAddress).leaveStaking(_wantAmt); // Just for CAKE staking, we dont use withdraw()
        } else {
            IPancakeswapFarm(s.farmContractAddress).withdraw(s.pid, _wantAmt);
        }
    }

    function withdraw(uint256 _wantAmt) public virtual onlyOwner nonReentrant returns (uint256) {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        require(_wantAmt > 0, "_wantAmt <= 0");

        uint256 sharesRemoved = _wantAmt.mul(s.sharesTotal).div(s.wantLockedTotal);
        if (sharesRemoved > s.sharesTotal) {
            sharesRemoved = s.sharesTotal;
        }
        s.sharesTotal = s.sharesTotal.sub(sharesRemoved);

        if (s.withdrawFeeFactor < s.withdrawFeeFactorMax) {
            _wantAmt = _wantAmt.mul(s.withdrawFeeFactor).div(s.withdrawFeeFactorMax);
        }

        if (s.isAutoComp) {
            _unfarm(_wantAmt);
        }

        uint256 wantAmt = IERC20(s.wantAddress).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        if (s.wantLockedTotal < _wantAmt) {
            _wantAmt = s.wantLockedTotal;
        }

        s.wantLockedTotal = s.wantLockedTotal.sub(_wantAmt);

        IERC20(s.wantAddress).safeTransfer(s.autoFarmAddress, _wantAmt);

        return sharesRemoved;
    }

    // 1. Harvest farm tokens
    // 2. Converts farm tokens into want tokens
    // 3. Deposits want tokens

    function earn() public virtual nonReentrant whenNotPaused {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        require(s.isAutoComp, "!isAutoComp");
        if (s.onlyGov) {
            require(msg.sender == s.govAddress, "!gov");
        }

        // Harvest farm tokens
        _unfarm(0);

        if (s.earnedAddress == s.wbnbAddress) {
            _wrapBNB();
        }

        // Converts farm tokens into want tokens
        uint256 earnedAmt = IERC20(s.earnedAddress).balanceOf(address(this));

        earnedAmt = distributeFees(earnedAmt);
        earnedAmt = buyBack(earnedAmt);

        if (s.isCAKEStaking || s.isSameAssetDeposit) {
            s.lastEarnBlock = block.number;
            _farm();
            return;
        }

        IERC20(s.earnedAddress).safeApprove(s.uniRouterAddress, 0);
        IERC20(s.earnedAddress).safeIncreaseAllowance(s.uniRouterAddress, earnedAmt);

        if (s.earnedAddress != s.token0Address) {
            // Swap half earned to token0
            _safeSwap(s.uniRouterAddress, earnedAmt.div(2), s.slippageFactor, s.earnedToToken0Path, address(this), block.timestamp.add(600));
        }

        if (s.earnedAddress != s.token1Address) {
            // Swap half earned to token1
            _safeSwap(s.uniRouterAddress, earnedAmt.div(2), s.slippageFactor, s.earnedToToken1Path, address(this), block.timestamp.add(600));
        }

        // Get want tokens, ie. add liquidity
        uint256 token0Amt = IERC20(s.token0Address).balanceOf(address(this));
        uint256 token1Amt = IERC20(s.token1Address).balanceOf(address(this));
        if (token0Amt > 0 && token1Amt > 0) {
            IERC20(s.token0Address).safeIncreaseAllowance(s.uniRouterAddress, token0Amt);
            IERC20(s.token1Address).safeIncreaseAllowance(s.uniRouterAddress, token1Amt);
            IPancakeRouter02(s.uniRouterAddress).addLiquidity(
                s.token0Address,
                s.token1Address,
                token0Amt,
                token1Amt,
                0,
                0,
                address(this),
                block.timestamp.add(600)
            );
        }

        s.lastEarnBlock = block.number;

        _farm();
    }

    function buyBack(uint256 _earnedAmt) internal virtual returns (uint256) {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        if (s.buyBackRate <= 0) {
            return _earnedAmt;
        }

        uint256 buyBackAmt = _earnedAmt.mul(s.buyBackRate).div(s.buyBackRateMax);

        if (s.earnedAddress == s.AUTOAddress) {
            IERC20(s.earnedAddress).safeTransfer(s.buyBackAddress, buyBackAmt);
        } else {
            IERC20(s.earnedAddress).safeIncreaseAllowance(s.uniRouterAddress, buyBackAmt);

            _safeSwap(s.uniRouterAddress, buyBackAmt, s.slippageFactor, s.earnedToAUTOPath, s.buyBackAddress, block.timestamp.add(600));
        }

        return _earnedAmt.sub(buyBackAmt);
    }

    function distributeFees(uint256 _earnedAmt) internal virtual returns (uint256) {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        if (_earnedAmt > 0) {
            // Performance fee
            if (s.controllerFee > 0) {
                uint256 fee = _earnedAmt.mul(s.controllerFee).div(s.controllerFeeMax);
                IERC20(s.earnedAddress).safeTransfer(s.rewardsAddress, fee);
                _earnedAmt = _earnedAmt.sub(fee);
            }
        }

        return _earnedAmt;
    }

    function convertDustToEarned() public virtual whenNotPaused {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        require(s.isAutoComp, "!isAutoComp");
        require(!s.isCAKEStaking, "isCAKEStaking");

        // Converts dust tokens into earned tokens, which will be reinvested on the next earn().

        // Converts token0 dust (if any) to earned tokens
        uint256 token0Amt = IERC20(s.token0Address).balanceOf(address(this));
        if (s.token0Address != s.earnedAddress && token0Amt > 0) {
            IERC20(s.token0Address).safeIncreaseAllowance(s.uniRouterAddress, token0Amt);

            // Swap all dust tokens to earned tokens
            _safeSwap(s.uniRouterAddress, token0Amt, s.slippageFactor, s.token0ToEarnedPath, address(this), block.timestamp.add(600));
        }

        // Converts token1 dust (if any) to earned tokens
        uint256 token1Amt = IERC20(s.token1Address).balanceOf(address(this));
        if (s.token1Address != s.earnedAddress && token1Amt > 0) {
            IERC20(s.token1Address).safeIncreaseAllowance(s.uniRouterAddress, token1Amt);

            // Swap all dust tokens to earned tokens
            _safeSwap(s.uniRouterAddress, token1Amt, s.slippageFactor, s.token1ToEarnedPath, address(this), block.timestamp.add(600));
        }
    }

    function pause() public virtual onlyAllowGov {
        _pause();
    }

    function unpause() public virtual onlyAllowGov {
        _unpause();
    }

    function setSettings(
        uint256 _entranceFeeFactor,
        uint256 _withdrawFeeFactor,
        uint256 _controllerFee,
        uint256 _buyBackRate,
        uint256 _slippageFactor
    ) public virtual onlyAllowGov {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        require(_entranceFeeFactor >= s.entranceFeeFactorLL, "_entranceFeeFactor too low");
        require(_entranceFeeFactor <= s.entranceFeeFactorMax, "_entranceFeeFactor too high");
        s.entranceFeeFactor = _entranceFeeFactor;

        require(_withdrawFeeFactor >= s.withdrawFeeFactorLL, "_withdrawFeeFactor too low");
        require(_withdrawFeeFactor <= s.withdrawFeeFactorMax, "_withdrawFeeFactor too high");
        s.withdrawFeeFactor = _withdrawFeeFactor;

        require(_controllerFee <= s.controllerFeeUL, "_controllerFee too high");
        s.controllerFee = _controllerFee;

        require(_buyBackRate <= s.buyBackRateUL, "_buyBackRate too high");
        s.buyBackRate = _buyBackRate;

        require(_slippageFactor <= s.slippageFactorUL, "_slippageFactor too high");
        s.slippageFactor = _slippageFactor;

        emit SetSettings(_entranceFeeFactor, _withdrawFeeFactor, _controllerFee, _buyBackRate, _slippageFactor);
    }

    function setGov(address _govAddress) public virtual onlyAllowGov {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        s.govAddress = _govAddress;
        emit SetGov(_govAddress);
    }

    function setOnlyGov(bool _onlyGov) public virtual onlyAllowGov {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        s.onlyGov = _onlyGov;
        emit SetOnlyGov(_onlyGov);
    }

    function setUniRouterAddress(address _uniRouterAddress) public virtual onlyAllowGov {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        s.uniRouterAddress = _uniRouterAddress;
        emit SetUniRouterAddress(_uniRouterAddress);
    }

    function setBuyBackAddress(address _buyBackAddress) public virtual onlyAllowGov {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        s.buyBackAddress = _buyBackAddress;
        emit SetBuyBackAddress(_buyBackAddress);
    }

    function setRewardsAddress(address _rewardsAddress) public virtual onlyAllowGov {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        s.rewardsAddress = _rewardsAddress;
        emit SetRewardsAddress(_rewardsAddress);
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount, address _to) public virtual onlyAllowGov {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        require(_token != s.earnedAddress, "!safe");
        require(_token != s.wantAddress, "!safe");
        IERC20(_token).safeTransfer(_to, _amount);
    }

    function _wrapBNB() internal virtual {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();

        // BNB -> WBNB
        uint256 bnbBal = address(this).balance;
        if (bnbBal > 0) {
            IWBNB(s.wbnbAddress).deposit{value: bnbBal}(); // BNB -> WBNB
        }
    }

    function wrapBNB() public virtual onlyAllowGov {
        _wrapBNB();
    }

    function _safeSwap(
        address _uniRouterAddress,
        uint256 _amountIn,
        uint256 _slippageFactor,
        address[] memory _path,
        address _to,
        uint256 _deadline
    ) internal virtual {
        uint256[] memory amounts = IPancakeRouter02(_uniRouterAddress).getAmountsOut(_amountIn, _path);
        uint256 amountOut = amounts[amounts.length.sub(1)];

        IPancakeRouter02(_uniRouterAddress).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIn,
            amountOut.mul(_slippageFactor).div(1000),
            _path,
            _to,
            _deadline
        );
    }

    // function transferOwnership(address _newOwner) external onlyOwner {

    // }
}
