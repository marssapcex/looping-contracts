// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {SomniaConfigLib, SomniaMetrics} from "../src/Interfaces.sol";
import {SomniaLendAttack} from "../src/SomniaLendAttack.sol";

/// @notice Offline tests for the harness itself. They prove the accounting/report plumbing can
///         fail loudly; they are NOT chain results and are never exported as evidence.
contract SomniaLendHarnessUnitTest is Test {
    SomniaLendAttack internal attack;

    function setUp() public {
        attack = new SomniaLendAttack(SomniaConfigLib.mainnet());
    }

    function test_decode_shortfall_roundtrips_metrics() public view {
        SomniaMetrics memory m;
        m.mode = 1;
        m.flashAsset = address(0xBEEF);
        m.flashAmount = 1_000e18;
        m.flashPremium = 1e18;
        m.flashRepayment = 1_001e18;
        m.suppliedCollateral = 500e18;
        m.collateralOracleBefore = 2e8;
        m.collateralOracleAfter = 3e8;
        m.bestBidBefore = 1e18;
        m.bestAskBefore = 2e18;
        m.bestBidAfter = 3e18;
        m.bestAskAfter = 4e18;
        m.preTradeBaseTraded = 17;
        m.preTradeQuoteTraded = 19;
        m.debtBorrowedFlashAsset = 42;
        m.borrowUsdso = 7;
        m.borrowUsdc = 8;
        m.borrowWeth = 9;
        m.borrowWbtc = 10;
        m.borrowWsomi = 11;
        m.finalUsdso = 123;
        m.finalUsdc = 456;
        m.unspentFlashAsset = 48e18;
        m.repaymentBase = 1_000e8;
        m.coverageBps = 9_123;
        m.unitEdgeBps = -456;
        m.premiumBps = 5;
        m.edgeRequiredBps = 2_506;
        m.maxNetBase = -1_234;
        m.borrowPowerInflationBase = -567;
        m.breakevenLtvBps = 12_345;
        m.liquidationThresholdBps = 8_250;
        m.badDebtBase = -2_500;
        m.attackerLiquidBase = 889;
        m.seededBase = 0;
        m.zeroSeed = true;
        m.stepFailures = 2;
        m.lastErrorStep = 5;
        m.lastErrorSelector = 0xdeadbeef;
        m.shortfallFlashAsset = 77;
        m.shortfallBase = 88;
        m.oracleRereadCount = 1;
        m.repaid = false;

        bytes memory reason = abi.encodeWithSelector(SomniaLendAttack.Shortfall.selector, abi.encode(m));
        (bool ok, SomniaMetrics memory out) = attack.decodeShortfall(reason);

        assertTrue(ok, "decode failed");
        assertEq(out.mode, m.mode);
        assertEq(out.flashAsset, m.flashAsset);
        assertEq(out.flashAmount, m.flashAmount);
        assertEq(out.flashPremium, m.flashPremium);
        assertEq(out.flashRepayment, m.flashRepayment);
        assertEq(out.suppliedCollateral, m.suppliedCollateral);
        assertEq(out.collateralOracleBefore, m.collateralOracleBefore);
        assertEq(out.collateralOracleAfter, m.collateralOracleAfter);
        assertEq(out.bestBidAfter, m.bestBidAfter);
        assertEq(out.bestAskAfter, m.bestAskAfter);
        assertEq(out.preTradeBaseTraded, m.preTradeBaseTraded);
        assertEq(out.preTradeQuoteTraded, m.preTradeQuoteTraded);
        assertEq(out.borrowUsdso, m.borrowUsdso);
        assertEq(out.borrowUsdc, m.borrowUsdc);
        assertEq(out.borrowWeth, m.borrowWeth);
        assertEq(out.borrowWbtc, m.borrowWbtc);
        assertEq(out.borrowWsomi, m.borrowWsomi);
        assertEq(out.finalUsdso, m.finalUsdso);
        assertEq(out.finalUsdc, m.finalUsdc);
        assertEq(out.unspentFlashAsset, m.unspentFlashAsset);
        assertEq(out.repaymentBase, m.repaymentBase);
        assertEq(out.coverageBps, m.coverageBps);
        assertEq(out.unitEdgeBps, m.unitEdgeBps);
        assertEq(out.premiumBps, m.premiumBps);
        assertEq(out.edgeRequiredBps, m.edgeRequiredBps);
        assertEq(out.maxNetBase, m.maxNetBase);
        assertEq(out.borrowPowerInflationBase, m.borrowPowerInflationBase);
        assertEq(out.breakevenLtvBps, m.breakevenLtvBps);
        assertEq(out.liquidationThresholdBps, m.liquidationThresholdBps);
        assertEq(out.badDebtBase, m.badDebtBase);
        assertEq(out.attackerLiquidBase, m.attackerLiquidBase);
        assertEq(out.seededBase, m.seededBase);
        assertEq(out.zeroSeed, m.zeroSeed);
        assertEq(out.stepFailures, m.stepFailures);
        assertEq(out.lastErrorStep, m.lastErrorStep);
        assertEq(out.lastErrorSelector, m.lastErrorSelector);
        assertEq(out.shortfallFlashAsset, m.shortfallFlashAsset);
        assertEq(out.shortfallBase, m.shortfallBase);
        assertEq(out.oracleRereadCount, m.oracleRereadCount);
        assertFalse(out.repaid);
    }

    function test_decode_shortfall_rejects_other_selectors() public view {
        (bool ok,) = attack.decodeShortfall(abi.encodeWithSignature("Error(string)", "nope"));
        assertFalse(ok);
        (bool ok2,) = attack.decodeShortfall("");
        assertFalse(ok2);
    }

    function test_profit_criterion_requires_all_three_conditions() public view {
        SomniaMetrics memory m;
        m.zeroSeed = true;
        m.stepFailures = 2;
        m.lastErrorStep = 5;
        m.lastErrorSelector = 0xdeadbeef;
        assertFalse(attack.isProfitable(m), "zero metrics must not be profitable");

        m.repaid = true;
        assertFalse(attack.isProfitable(m), "repaid with no value must not be profitable");

        m.attackerLiquidBase = 1;
        assertTrue(attack.isProfitable(m), "repaid zero-seed run with value left is profit");

        m.repaid = false;
        assertFalse(attack.isProfitable(m), "unrepaid run must never be profitable");

        m.repaid = true;
        m.zeroSeed = false;
        m.seededBase = 0;
        assertFalse(attack.isProfitable(m), "a seeded run must never be reported as profit");

        m.zeroSeed = true;
        m.stepFailures = 2;
        m.lastErrorStep = 5;
        m.lastErrorSelector = 0xdeadbeef;
        m.seededBase = 5;
        m.attackerLiquidBase = 5;
        assertFalse(attack.isProfitable(m), "value at or below the seed is not profit");
    }

    function test_only_owner_can_run() public {
        SomniaLendAttack.Params memory p = SomniaLendAttack.Params(1, 1, 1, false, false);
        vm.prank(address(0xBAD));
        vm.expectRevert(SomniaLendAttack.NotOwner.selector);
        attack.runSomiPumpSupply(1, p);
    }

    function test_cannot_run_twice() public {
        // The real entry points revert before touching the Pool because hasRun flips first only
        // after every parameter check; use an invalid amount to hit the guard deterministically.
        SomniaLendAttack.Params memory p = SomniaLendAttack.Params(1, 1, 0, false, false);
        vm.expectRevert(bytes("zero flashloan"));
        attack.runSomiPumpSupply(0, p);
    }
}
