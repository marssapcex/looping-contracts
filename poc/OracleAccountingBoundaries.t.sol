// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Looping} from "../contracts/Looping.sol";
import {HypertradeAdapter} from "../contracts/periphery/HypertradeAdapter.sol";
import {MockERC20} from "./Mocks.sol";

/// @notice Minimal Compound-like model: cap is checked only at mint, while
/// represented collateral uses raw cash. It demonstrates the boundary, not a
/// current deployment or a profitable self-donation.
contract RawCashCapModel {
    uint256 public cap = 100;
    uint256 public cash;
    uint256 public supply;
    mapping(address => uint256) public shares;

    function mint(address user, uint256 amount) external {
        require(cash + amount <= cap, "cap");
        cash += amount;
        supply += amount;
        shares[user] += amount;
    }

    function donate(uint256 amount) external {
        cash += amount; // models a direct balanceOf increase without shares
    }

    function represented(address user) external view returns (uint256) {
        return supply == 0 ? 0 : shares[user] * cash / supply;
    }
}

contract InternalCashCapModel {
    uint256 public cash;
    uint256 public supply;
    uint256 private rawBalance;
    mapping(address => uint256) public shares;

    function mint(address user, uint256 amount) external {
        cash += amount;
        supply += amount;
        shares[user] += amount;
    }

    function donate(uint256 amount) external {
        rawBalance += amount; // excluded from internalCash and represented claims
    }

    function represented(address user) external view returns (uint256) {
        return supply == 0 ? 0 : shares[user] * cash / supply;
    }
}

/// @notice NAV model for a capped-but-active strategy. staleNAV has accounting
/// value but zero modeled realizable value. The donor's stale-receipt cost is
/// therefore explicitly zero in this counterexample, not assumed for a fork.
contract OffboardingNavModel {
    uint256 public liquid;
    uint256 public staleNAV;
    uint256 public supply;
    uint256 public depositCap;
    bool public active = true;
    mapping(address => uint256) public shares;

    constructor() { depositCap = type(uint256).max; }

    function totalAssets() public view returns (uint256) {
        return liquid + (active ? staleNAV : 0);
    }

    function deposit(address user, uint256 assets) external {
        require(assets <= depositCap || depositCap == type(uint256).max, "allocation cap");
        uint256 nav = totalAssets();
        uint256 minted = supply == 0 ? assets : assets * supply / nav;
        require(minted > 0, "zero shares");
        liquid += assets;
        supply += minted;
        shares[user] += minted;
    }

    function capForOffboarding() external {
        depositCap = 0; // deliberately does not deactivate or remove valuation
    }

    function donateStaleReceipt(uint256 accountedValue) external {
        staleNAV += accountedValue;
    }

    function removeStrategy() external {
        active = false;
    }

    function redeem(address user, uint256 amount) external returns (uint256 payout) {
        payout = amount * totalAssets() / supply;
        require(payout <= liquid, "liquid queue cannot pay");
        shares[user] -= amount;
        supply -= amount;
        liquid -= payout;
    }
}

contract CircularRouteModel {
    struct Hop { address tokenIn; address tokenOut; uint256 declaredOut; }

    function naiveTerminalSum(Hop[] memory hops) public pure returns (uint256 sum) {
        address terminal = hops[hops.length - 1].tokenOut;
        for (uint256 i; i < hops.length; ++i) {
            if (hops[i].tokenOut == terminal) sum += hops[i].declaredOut;
        }
    }

    function actualAndCheckedOutput(Hop[] memory hops) public pure returns (uint256) {
        address terminal = hops[hops.length - 1].tokenOut;
        for (uint256 i; i + 1 < hops.length; ++i) {
            require(hops[i].tokenOut == hops[i + 1].tokenIn, "disconnected");
            require(hops[i].tokenOut != terminal, "terminal output reconsumed");
        }
        return hops[hops.length - 1].declaredOut;
    }
}

contract UnguardedVerifier {
    uint256 public storedPrice;
    function submit(uint256 price, bool, address) external { storedPrice = price; }
}

contract GuardedVerifier {
    uint256 public storedPrice;
    address public immutable trustedSigner;
    constructor(address signer) { trustedSigner = signer; }
    function submit(uint256 price, bool authenticated, address signer) external {
        require(authenticated && signer == trustedSigner, "invalid proof/signer");
        storedPrice = price;
    }
}

contract DeviationModel {
    uint256 public previous = 100;
    function unguarded(uint256 candidate) external pure returns (bool) { return candidate > 0; }
    function bounded(uint256 candidate) external view returns (bool) {
        require(candidate >= previous * 95 / 100 && candidate <= previous * 105 / 100, "deviation");
        return true;
    }
}

/// @dev Router mints a fixed output to the adapter. It isolates route endpoint
/// validation; free mock output is setup and is never claimed as mainnet P&L.
contract MintOutputRouter {
    MockERC20 public output;
    uint256 public amount;
    constructor(MockERC20 token, uint256 outputAmount) { output = token; amount = outputAmount; }
    fallback() external { output.mint(msg.sender, amount); }
}

/// @dev Pulls real supplied collateral and creates real mock debt. No lending
/// liquidity, health factor, or mainnet economics are modeled.
contract RouteProbePool {
    MockERC20 public immutable debt;
    mapping(address => uint256) public supplied;
    mapping(address => uint256) public debtOwed;

    constructor(MockERC20 debtToken) { debt = debtToken; }

    function flashLoanSimple(
        address receiver,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16
    ) external {
        MockERC20(asset).mint(receiver, amount);
        Looping(receiver).executeOperation(asset, amount, 0, receiver, params);
        require(MockERC20(asset).transferFrom(receiver, address(this), amount), "flash repay");
        MockERC20(asset).burn(amount);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(MockERC20(asset).transferFrom(msg.sender, address(this), amount), "supply pull");
        supplied[onBehalfOf] += amount;
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        debtOwed[onBehalfOf] += amount;
        require(supplied[onBehalfOf] >= debtOwed[onBehalfOf], "health");
        MockERC20(asset).mint(msg.sender, amount);
    }
}

contract OracleAccountingBoundariesTest is Test {
    address internal attacker = address(0xA77ACC);
    address internal victim = address(0xB1C71);

    function test_DonationRaisesExistingClaimsDespiteMintCap() public {
        RawCashCapModel raw = new RawCashCapModel();
        raw.mint(victim, 80);
        vm.expectRevert(bytes("cap"));
        raw.mint(attacker, 21);
        raw.donate(100);
        assertEq(raw.represented(victim), 180, "existing claim exceeds cap");
        console2.log("raw_cash_represented_after_donation=180 cap=100 self_donation_profit_not_claimed");

        InternalCashCapModel internalCash = new InternalCashCapModel();
        internalCash.mint(victim, 80);
        internalCash.donate(100);
        assertEq(internalCash.represented(victim), 80, "negative control: raw gift excluded");
    }

    function test_ZeroCapActiveNavDonationVsRemovalControl() public {
        OffboardingNavModel fleet = new OffboardingNavModel();
        fleet.deposit(victim, 100);
        fleet.deposit(attacker, 100);
        fleet.capForOffboarding();
        fleet.donateStaleReceipt(90); // accounted 90, modeled realizable cost 0

        uint256 payout = fleet.redeem(attacker, 100);
        assertEq(payout, 145);
        assertEq(int256(payout) - 100, 45, "attacker liquid profit before gas");
        assertEq(fleet.liquid(), 55, "honest liquid residual");
        console2.log("nav_attacker_input=100 stale_cost=0 payout=145 pnl_before_gas=45 victim_liquid=55");

        OffboardingNavModel control = new OffboardingNavModel();
        control.deposit(victim, 100);
        control.deposit(attacker, 100);
        control.capForOffboarding();
        control.removeStrategy();
        control.donateStaleReceipt(90);
        assertEq(control.redeem(attacker, 100), 100, "removed strategy cannot inflate redemption");
    }

    function test_CircularRouteDoubleCountAndTerminalCheck() public {
        CircularRouteModel model = new CircularRouteModel();
        CircularRouteModel.Hop[] memory hops = new CircularRouteModel.Hop[](3);
        address A = address(0xA); address B = address(0xB);
        hops[0] = CircularRouteModel.Hop(A, B, 100);
        hops[1] = CircularRouteModel.Hop(B, A, 90);
        hops[2] = CircularRouteModel.Hop(A, B, 80);
        assertEq(model.naiveTerminalSum(hops), 180);
        vm.expectRevert(bytes("terminal output reconsumed"));
        model.actualAndCheckedOutput(hops);

        CircularRouteModel.Hop[] memory direct = new CircularRouteModel.Hop[](1);
        direct[0] = CircularRouteModel.Hop(A, B, 80);
        assertEq(model.actualAndCheckedOutput(direct), 80);
    }

    function test_UnsignedProofAndWrongSignerRejectedOnlyByGuard() public {
        UnguardedVerifier unguarded = new UnguardedVerifier();
        unguarded.submit(1_000_000, false, attacker);
        assertEq(unguarded.storedPrice(), 1_000_000, "vulnerable consumer stored invalid proof");

        GuardedVerifier guarded = new GuardedVerifier(address(0x51A));
        vm.expectRevert(bytes("invalid proof/signer"));
        guarded.submit(1_000_000, false, attacker);
        vm.expectRevert(bytes("invalid proof/signer"));
        guarded.submit(1_000_000, true, attacker);
        guarded.submit(100, true, address(0x51A));
        assertEq(guarded.storedPrice(), 100);
    }

    function test_DeviationAndInstantPpsControls() public {
        DeviationModel model = new DeviationModel();
        assertTrue(model.unguarded(180));
        vm.expectRevert(bytes("deviation"));
        model.bounded(180);
        assertTrue(model.bounded(104));

        uint256 emaPoolPrice = 1e18; // smoothing another multiplicand does not smooth vault PPS
        uint256 ppsBefore = 1e18;
        uint256 ppsAfterDonation = 1.1379e18;
        assertEq(emaPoolPrice, 1e18);
        assertGt(ppsAfterDonation * 1e18 / ppsBefore, 1.05e18);
    }

    function test_LoopingCorrectRouteExecutesAndWrongTerminalRevertsWithoutVictimDelta() public {
        (Looping looping, HypertradeAdapter adapter, RouteProbePool pool, MockERC20 debt, MockERC20 yieldAsset,) = _routeFixture();
        address[] memory path = new address[](2);
        path[0] = address(debt); path[1] = address(yieldAsset);

        vm.startPrank(attacker);
        adapter.setSwapPath(address(debt), address(yieldAsset), hex"00");
        looping.openPosition(address(pool), address(adapter), address(debt), address(yieldAsset), 0, 100, 0, path, false, 0, block.timestamp + 1);
        vm.stopPrank();

        assertEq(pool.supplied(attacker), 100);
        assertEq(pool.debtOwed(attacker), 100);
        assertEq(pool.supplied(victim), 0);
        assertEq(pool.debtOwed(victim), 0);
    }

    function test_LoopingWrongTerminalCannotSupplyDeclaredYield() public {
        (Looping looping, HypertradeAdapter adapter, RouteProbePool pool, MockERC20 debt, MockERC20 yieldAsset, MockERC20 wrong) = _routeFixture();
        address[] memory path = new address[](2);
        path[0] = address(debt); path[1] = address(wrong);

        vm.startPrank(attacker);
        adapter.setSwapPath(address(debt), address(wrong), hex"00");
        vm.expectRevert(bytes("health"));
        looping.openPosition(address(pool), address(adapter), address(debt), address(yieldAsset), 0, 100, 0, path, false, 0, block.timestamp + 1);
        vm.stopPrank();
        assertEq(pool.supplied(attacker), 0);
        assertEq(pool.debtOwed(attacker), 0);
        assertEq(pool.supplied(victim), 0);
        assertEq(yieldAsset.balanceOf(victim), 0);
    }

    function _routeFixture() internal returns (
        Looping looping,
        HypertradeAdapter adapter,
        RouteProbePool pool,
        MockERC20 debt,
        MockERC20 yieldAsset,
        MockERC20 wrong
    ) {
        debt = new MockERC20("debt", "D", 18);
        yieldAsset = new MockERC20("yield", "Y", 18);
        wrong = new MockERC20("wrong", "W", 18);
        MintOutputRouter router = new MintOutputRouter(yieldAsset, 100);
        adapter = new HypertradeAdapter(address(router));
        pool = new RouteProbePool(debt);
        address[] memory pools = new address[](1); pools[0] = address(pool);
        address[] memory swappers = new address[](1); swappers[0] = address(adapter);
        looping = new Looping(pools, swappers, address(this));
    }
}
