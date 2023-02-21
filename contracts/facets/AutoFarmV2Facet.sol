// SPDX-License-Identifier: MIT

pragma solidity 0.8.17;

import "../AutoFarm-helpers/helpers/ERC20.sol";
import "../AutoFarm-helpers/libraries/Address.sol";
import "../AutoFarm-helpers/libraries/SafeERC20.sol";
import "../AutoFarm-helpers/libraries/EnumerableSet.sol";
import "../AutoFarm-helpers/helpers/ReentrancyGuard.sol";

import {LibDiamond} from "../libraries/LibDiamond.sol";

abstract contract AUTOToken is ERC20 {
    function mint(address _to, uint256 _amount) public virtual;
}

// For interacting with our own strategy
interface IStrategy {
    // Total want tokens managed by stratfegy
    function wantLockedTotal() external view returns (uint256);

    // Sum of all shares of users to wantLockedTotal
    function sharesTotal() external view returns (uint256);

    // Main want token compounding function
    function earn() external;

    // Transfer want tokens autoFarm -> strategy
    function deposit(uint256 _wantAmt) external returns (uint256);

    // Transfer want tokens strategy -> autoFarm
    function withdraw(uint256 _wantAmt) external returns (uint256);

    function inCaseTokensGetStuck(address _token, uint256 _amount, address _to) external;
}

contract AutoFarmV2Facet is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    modifier onlyOwner() {
        address owner_ = LibDiamond.contractOwner();
        require(msg.sender == owner_, "you are not the owner!");

        _;
    }

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    function poolLength() external view returns (uint256) {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();
        return a.poolInfo.length;
    }

    function poolInfo(uint256 pid) external view returns (LibDiamond.PoolInfo memory) {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        return a.poolInfo[pid];
    }

    function userInfo(uint256 pid, address user) external view returns (LibDiamond.UserInfo memory) {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        return a.userInfo[pid][user];
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do. (Only if want tokens are stored here.)

    function add(uint256 _allocPoint, address _want, bool _withUpdate, address _strat) public onlyOwner {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > a.startBlock ? block.number : a.startBlock;
        a.totalAllocPoint = a.totalAllocPoint.add(_allocPoint);
        a.poolInfo.push(
            LibDiamond.PoolInfo({want: _want, allocPoint: _allocPoint, lastRewardBlock: lastRewardBlock, accAUTOPerShare: 0, strat: _strat})
        );
    }

    // Update the given pool's AUTO allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        if (_withUpdate) {
            massUpdatePools();
        }
        a.totalAllocPoint = a.totalAllocPoint.sub(a.poolInfo[_pid].allocPoint).add(_allocPoint);
        a.poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        if (IERC20(a.AUTOv2).totalSupply() >= a.AUTOMaxSupply) {
            return 0;
        }
        return _to.sub(_from);
    }

    // View function to see pending AUTO on frontend.
    function pendingAUTO(uint256 _pid, address _user) external view returns (uint256) {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        LibDiamond.PoolInfo storage pool = a.poolInfo[_pid];
        LibDiamond.UserInfo storage user = a.userInfo[_pid][_user];
        uint256 accAUTOPerShare = pool.accAUTOPerShare;
        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        if (block.number > pool.lastRewardBlock && sharesTotal != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 AUTOReward = multiplier.mul(a.AUTOPerBlock).mul(pool.allocPoint).div(a.totalAllocPoint);
            accAUTOPerShare = accAUTOPerShare.add(AUTOReward.mul(1e12).div(sharesTotal));
        }
        return user.shares.mul(accAUTOPerShare).div(1e12).sub(user.rewardDebt);
    }

    // View function to see staked Want tokens on frontend.
    function stakedWantTokens(uint256 _pid, address _user) external view returns (uint256) {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        LibDiamond.PoolInfo storage pool = a.poolInfo[_pid];
        LibDiamond.UserInfo storage user = a.userInfo[_pid][_user];

        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        uint256 wantLockedTotal = IStrategy(a.poolInfo[_pid].strat).wantLockedTotal();
        if (sharesTotal == 0) {
            return 0;
        }
        return user.shares.mul(wantLockedTotal).div(sharesTotal);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        uint256 length = a.poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        LibDiamond.PoolInfo storage pool = a.poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        if (sharesTotal == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        if (multiplier <= 0) {
            return;
        }
        uint256 AUTOReward = multiplier.mul(a.AUTOPerBlock).mul(pool.allocPoint).div(a.totalAllocPoint);

        AUTOToken(a.AUTOv2).mint(LibDiamond.contractOwner(), AUTOReward.mul(a.ownerAUTOReward).div(1000));
        AUTOToken(a.AUTOv2).mint(address(this), AUTOReward);

        pool.accAUTOPerShare = pool.accAUTOPerShare.add(AUTOReward.mul(1e12).div(sharesTotal));
        pool.lastRewardBlock = block.number;
    }

    // Want tokens moved from user -> AUTOFarm (AUTO allocation) -> Strat (compounding)
    function deposit(uint256 _pid, uint256 _wantAmt) public nonReentrant {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        updatePool(_pid);
        LibDiamond.PoolInfo storage pool = a.poolInfo[_pid];
        LibDiamond.UserInfo storage user = a.userInfo[_pid][msg.sender];

        if (user.shares > 0) {
            uint256 pending = user.shares.mul(pool.accAUTOPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeAUTOTransfer(msg.sender, pending);
            }
        }
        if (_wantAmt > 0) {
            IERC20(pool.want).safeTransferFrom(address(msg.sender), address(this), _wantAmt);

            IERC20(pool.want).safeIncreaseAllowance(pool.strat, _wantAmt);
            uint256 sharesAdded = IStrategy(a.poolInfo[_pid].strat).deposit(_wantAmt);
            user.shares = user.shares.add(sharesAdded);
        }
        user.rewardDebt = user.shares.mul(pool.accAUTOPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _wantAmt) public nonReentrant {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        updatePool(_pid);

        LibDiamond.PoolInfo storage pool = a.poolInfo[_pid];
        LibDiamond.UserInfo storage user = a.userInfo[_pid][msg.sender];

        uint256 wantLockedTotal = IStrategy(a.poolInfo[_pid].strat).wantLockedTotal();
        uint256 sharesTotal = IStrategy(a.poolInfo[_pid].strat).sharesTotal();

        require(user.shares > 0, "user.shares is 0");
        require(sharesTotal > 0, "sharesTotal is 0");

        // Withdraw pending AUTO
        uint256 pending = user.shares.mul(pool.accAUTOPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeAUTOTransfer(msg.sender, pending);
        }

        // Withdraw want tokens
        uint256 amount = user.shares.mul(wantLockedTotal).div(sharesTotal);
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {
            uint256 sharesRemoved = IStrategy(a.poolInfo[_pid].strat).withdraw(_wantAmt);

            if (sharesRemoved > user.shares) {
                user.shares = 0;
            } else {
                user.shares = user.shares.sub(sharesRemoved);
            }

            uint256 wantBal = IERC20(pool.want).balanceOf(address(this));
            if (wantBal < _wantAmt) {
                _wantAmt = wantBal;
            }
            IERC20(pool.want).safeTransfer(address(msg.sender), _wantAmt);
        }
        user.rewardDebt = user.shares.mul(pool.accAUTOPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }

    function withdrawAll(uint256 _pid) public {
        withdraw(_pid, type(uint256).max);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        LibDiamond.PoolInfo storage pool = a.poolInfo[_pid];
        LibDiamond.UserInfo storage user = a.userInfo[_pid][msg.sender];

        uint256 wantLockedTotal = IStrategy(a.poolInfo[_pid].strat).wantLockedTotal();
        uint256 sharesTotal = IStrategy(a.poolInfo[_pid].strat).sharesTotal();
        uint256 amount = user.shares.mul(wantLockedTotal).div(sharesTotal);

        IStrategy(a.poolInfo[_pid].strat).withdraw(amount);

        IERC20(pool.want).safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
        user.shares = 0;
        user.rewardDebt = 0;
    }

    // Safe AUTO transfer function, just in case if rounding error causes pool to not have enough
    function safeAUTOTransfer(address _to, uint256 _AUTOAmt) internal {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        uint256 AUTOBal = IERC20(a.AUTOv2).balanceOf(address(this));
        if (_AUTOAmt > AUTOBal) {
            IERC20(a.AUTOv2).transfer(_to, AUTOBal);
        } else {
            IERC20(a.AUTOv2).transfer(_to, _AUTOAmt);
        }
    }

    function inCaseTokensGetStuck(address _token, uint256 _amount) public onlyOwner {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();

        require(_token != a.AUTOv2, "!safe");
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }
}
