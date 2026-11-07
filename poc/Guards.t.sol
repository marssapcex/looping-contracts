// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Looping} from "../contracts/Looping.sol";
import {StrategyManager} from "../contracts/StrategyManager.sol";
import {StrategyManagerFactory} from "../contracts/StrategyManagerFactory.sol";
import {HypertradeAdapter} from "../contracts/periphery/HypertradeAdapter.sol";
import {MockERC20, MockNoOpRouter, MockPool} from "./Mocks.sol";

contract GuardsTest is Test {
    address internal attacker = address(0xA77ACC);
    address internal victim = address(0xB1C71);
    address internal owner = address(0x0B3E);

    MockERC20 internal debt;
    MockERC20 internal yieldAsset;
    MockPool internal pool;
    Looping internal looping;

    function setUp() public {
        debt = new MockERC20("debt", "D", 18);
        yieldAsset = new MockERC20("yield", "Y", 18);
        pool = new MockPool();
        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        address[] memory swappers = new address[](0);
        looping = new Looping(pools, swappers, owner);
    }

    function test_CallbackFromNonPoolRevertsWithoutDeltas() public {
        bytes memory params = _params(2, victim);
        uint256 attackerDebtBefore = debt.balanceOf(attacker);
        vm.expectRevert(bytes("msg.sender != pool"));
        vm.prank(attacker);
        looping.executeOperation(address(debt), 0, 0, address(looping), params);
        assertEq(debt.balanceOf(attacker), attackerDebtBefore);
    }

    function test_CallbackWithWrongInitiatorRevertsWithoutVictimDelta() public {
        bytes memory params = _params(2, victim);
        vm.expectRevert(bytes("initiator != address(this)"));
        pool.callExecuteOperation(looping, address(debt), 0, 0, attacker, params);
        assertEq(debt.balanceOf(victim), 0);
        assertEq(yieldAsset.balanceOf(victim), 0);
    }

    function test_OpenAndCloseEncodeCallerNotVictim() public {
        address[] memory path = new address[](0);
        vm.startPrank(attacker);
        looping.openPosition(
            address(pool), address(0), address(debt), address(yieldAsset),
            0, 0, 0, path, false, 0, block.timestamp + 1
        );
        assertEq(pool.lastUser(), attacker, "open user");

        looping.closePosition(
            address(pool), address(0), address(debt), address(yieldAsset),
            0, 0, path, 0, block.timestamp + 1
        );
        vm.stopPrank();
        assertEq(pool.lastUser(), attacker, "close user");
        assertEq(debt.balanceOf(victim), 0);
        assertEq(yieldAsset.balanceOf(victim), 0);
        console2.log("cross_user_close_delta_victim_debt=0 delta_victim_yield=0");
    }

    function test_StrategyManagerPermissionlessSinksRevert() public {
        StrategyManager manager = new StrategyManager(
            owner, address(pool), address(yieldAsset), address(debt)
        );
        StrategyManager.Call[] memory calls = new StrategyManager.Call[](0);
        address[] memory tokens = new address[](0);

        vm.startPrank(attacker);
        vm.expectRevert();
        manager.executeCall(address(0), 0, hex"", true);
        vm.expectRevert();
        manager.executeMultiCall(calls);
        vm.expectRevert(bytes("only owner or self"));
        manager.cleanOutTokens(tokens);
        vm.expectRevert(bytes("only owner or self"));
        manager.withdrawAllFromPool(tokens);
        vm.stopPrank();

        assertEq(address(manager).balance, 0);
        assertEq(debt.balanceOf(attacker), 0);
    }

    function test_FactoryAssignsStrategyToActualCaller() public {
        StrategyManagerFactory factory = new StrategyManagerFactory();
        vm.prank(attacker);
        factory.createStrategyManager(address(pool), address(yieldAsset), address(debt));
        address managerAddress = factory.getUserStrategyManager(
            attacker, address(pool), address(yieldAsset), address(debt)
        );
        assertEq(StrategyManager(managerAddress).owner(), attacker);
        assertEq(
            factory.getUserStrategyManager(victim, address(pool), address(yieldAsset), address(debt)),
            address(0)
        );
    }

    function test_TransientRouteDoesNotCrossBlocks() public {
        MockNoOpRouter router = new MockNoOpRouter();
        HypertradeAdapter adapter = new HypertradeAdapter(address(router));
        adapter.setSwapPath(address(debt), address(yieldAsset), hex"00");
        // Foundry executes test-contract calls in one test transaction, so
        // rolling the block exercises the explicit storedBlock == block.number
        // freshness check. Separate-transaction clearing is checked on anvil.
        vm.roll(block.number + 1);

        address[] memory path = new address[](2);
        path[0] = address(debt);
        path[1] = address(yieldAsset);
        vm.expectRevert(bytes("HypertradeAdapter: path not set in this block"));
        adapter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            0, 0, path, attacker, address(0), block.timestamp + 1
        );
        assertEq(yieldAsset.balanceOf(attacker), 0);
    }

    function test_UnknownSelectorCannotCallLoopingSink() public {
        (bool ok,) = address(looping).call(hex"deadbeef");
        assertFalse(ok);
    }

    function _params(uint8 action, address user) internal view returns (bytes memory) {
        address[] memory path = new address[](0);
        return abi.encode(action, address(yieldAsset), address(0), path, 0, 0, user, 0, block.timestamp + 1);
    }
}
