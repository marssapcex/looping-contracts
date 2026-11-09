// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Economics} from "../src/Economics.sol";

/// @notice Arithmetic self-checks for the feasibility model. These pin the break-even algebra so
///         a fork report can quote the formula instead of re-deriving it in prose. No chain state.
contract EconomicsTest is Test {
    uint256 internal constant BPS = 10_000;

    function test_coverage_exact_breakeven() public pure {
        assertEq(Economics.coverageBps(1_000e8, 1_000e8), BPS);
        assertEq(Economics.coverageBps(950e8, 1_000e8), 9_500);
        assertEq(Economics.coverageBps(1_100e8, 1_000e8), 11_000);
        assertEq(Economics.coverageBps(1, 0), 0);
    }

    function test_edge_required_matches_definition() public pure {
        // LTV 80%, premium 0.05% -> need 25.06% of "free" value.
        assertEq(Economics.edgeRequiredBps(8_000, 5), 2_506);
        // LTV 50% -> 100.1%.
        assertEq(Economics.edgeRequiredBps(5_000, 5), 10_010);
        // No LTV -> impossible.
        assertEq(Economics.edgeRequiredBps(0, 5), type(uint256).max);
    }

    function test_breakeven_ltv_is_inverse_of_edge_required() public pure {
        uint256 premium = 5;
        for (uint256 ltv = 1_000; ltv <= 9_500; ltv += 500) {
            uint256 edge = Economics.edgeRequiredBps(ltv, premium);
            // Feeding that exact edge back must return the same LTV (within rounding).
            uint256 back = Economics.breakevenLtvBps(int256(edge), premium);
            assertApproxEqAbs(back, ltv, 1, "breakeven ltv mismatch");
        }
    }

    function test_breakeven_ltv_returns_max_when_fill_is_not_better_than_free() public pure {
        assertEq(Economics.breakevenLtvBps(-int256(BPS), 5), type(uint256).max);
        assertEq(Economics.breakevenLtvBps(-int256(BPS) - 1, 5), type(uint256).max);
    }

    function test_net_base_sign() public pure {
        assertEq(Economics.netBase(1_000e8, 900e8), 100e8);
        assertEq(Economics.netBase(800e8, 900e8), -100e8);
        assertEq(Economics.netBase(900e8, 900e8), 0);
    }

    function test_known_mango_shape_numbers() public pure {
        // Illustrative only: a reserve at 80% LTV with a 5 bp flash premium needs a 2506 bp gap
        // between what the attacker pays and what the protocol thinks the collateral is worth.
        uint256 required = Economics.edgeRequiredBps(8_000, 5);
        console2.log("edge required (bps) for LTV 80% / premium 5bps", required);

        // If the attacker actually captures 3000 bp of that gap, coverage is above 10000.
        uint256 collateralValue = 1_300e8; // paid 1000e8, protocol values 1300e8
        uint256 borrowPower = Economics.borrowPower(collateralValue, 8_000);
        uint256 coverage = Economics.coverageBps(borrowPower, 1_000e8 + 0.5e8);
        console2.log("coverage (bps) for a 3000 bp gap", coverage);
        assertGt(coverage, BPS, "3000 bp gap should clear an 80% LTV");

        // And at 2000 bp gap it must not.
        uint256 borrowPowerLow = Economics.borrowPower(1_200e8, 8_000);
        assertLt(Economics.coverageBps(borrowPowerLow, 1_000e8 + 0.5e8), BPS);
    }
}
