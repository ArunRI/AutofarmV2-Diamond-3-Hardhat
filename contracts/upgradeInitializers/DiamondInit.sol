// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
*
* Implementation of a diamond.
/******************************************************************************/

import {LibDiamond} from "../libraries/LibDiamond.sol";
import {IDiamondLoupe} from "../interfaces/IDiamondLoupe.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
import {IERC173} from "../interfaces/IERC173.sol";
import {IERC165} from "../interfaces/IERC165.sol";

// It is expected that this contract is customized if you want to deploy your diamond
// with data from a deployment script. Use the init function to initialize state variables
// of your diamond. Add parameters to the init function if you need to.

contract DiamondInit {
    function autofarmV2Init(address _autoV2) external {
        LibDiamond.AutoFarmV2Storage storage a = LibDiamond.autoFarmV2Storage();
        a.AUTOv2 = _autoV2;
        a.burnAddress = 0x000000000000000000000000000000000000dEaD;
        a.ownerAUTOReward = 138; // 12%
        a.AUTOMaxSupply = 80000e18;
        a.AUTOPerBlock = 8000000000000000; // auto tokens created per block
        a.startBlock = 3888888;
        a.totalAllocPoint = 0;
    }

    function stratX2Init(address _autoFarmAdress, address _wantToken) external {
        LibDiamond.StratX2Storage storage s = LibDiamond.stratX2Storage();
        s.owner = _autoFarmAdress;
        s.autoFarmAddress = _autoFarmAdress;
        s.wantAddress = _wantToken;
        s.onlyGov = true;
        s.lastEarnBlock = 0;
        s.wantLockedTotal = 0;
        s.sharesTotal = 0;
        s.controllerFee = 0; // 70;
        s.controllerFeeMax = 10000; // 100 = 1%
        s.controllerFeeUL = 300;
        s.buyBackRate = 0; // 250;
        s.buyBackRateMax = 10000; // 100 = 1%
        s.buyBackRateUL = 800;
        s.buyBackAddress = 0x000000000000000000000000000000000000dEaD;
        s.rewardsAddress;
        s.entranceFeeFactor = 9990; // < 0.1% entrance fee - goes to pool + prevents front-running
        s.entranceFeeFactorMax = 10000;
        s.entranceFeeFactorLL = 9950; // 0.5% is the max entrance fee settable. LL = lowerlimit
        s.withdrawFeeFactor = 10000; // 0.1% withdraw fee - goes to pool
        s.withdrawFeeFactorMax = 10000;
        s.withdrawFeeFactorLL = 9950; // 0.5% is the max entrance fee settable. LL = lowerlimit
        s.slippageFactor = 950; // 5% default slippage tolerance
        s.slippageFactorUL = 995;
    }

    // You can add parameters to this function in order to pass in
    // data to set your own state variables
    function init() external {
        // adding ERC165 data
        LibDiamond.DiamondStorage storage ds = LibDiamond.diamondStorage();
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IERC173).interfaceId] = true;

        // add your own state variables
        // EIP-2535 specifies that the `diamondCut` function takes two optional
        // arguments: address _init and bytes calldata _calldata
        // These arguments are used to execute an arbitrary function using delegatecall
        // in order to set state variables in the diamond during deployment or an upgrade
        // More info here: https://eips.ethereum.org/EIPS/eip-2535#diamond-interface
    }
}
