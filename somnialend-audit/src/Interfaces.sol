// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Every external address the harness touches, in one place.
struct SomniaConfig {
    address pool;
    address oracle;
    address wsomi;
    address usdc;
    address weth;
    address usdso;
    address wbtc;
    address somiUsdso;
    address usdcUsdso;
    address wethUsdso;
    address wbtcUsdso;
}

/// @notice The exact deployed Somnia mainnet (chain 5031) configuration. Verified from the
///         explorer and from `somnia-chain/dreamdex-bot-kit`; the DEX proxy reader decodes to
///         0x55790554C0d6914edb90F8d05B2f0bBc85605026.
library SomniaConfigLib {
    function mainnet() internal pure returns (SomniaConfig memory c) {
        c.pool = 0xEC6758e6324c167DB39B6908036240460a2b0168;
        c.oracle = 0x9b7B5d69a08071ce74C2f3D655038E3b782eAaFc;
        c.wsomi = 0x046EDe9564A72571df6F5e44d0405360c0f4dCab;
        c.usdc = 0x28BEc7E30E6faee657a03e19Bf1128AaD7632A00;
        c.weth = 0x936Ab8C674bcb567CD5dEB85D8A216494704E9D8;
        c.usdso = 0x00000022dA000002656c64D9eA6011ea952D008A;
        c.wbtc = 0xC5098b3cA516784323872F17235fa074E167D3D2;
        c.somiUsdso = 0x035De7403eac6872787779CCA7CCF1b4CDb61379;
        c.usdcUsdso = 0x47fD2f18426f67106DBaC82F6d21D446c5F2120b;
        c.wethUsdso = 0xa936da11B57b50A344e1293AAaE5232885ea2bDE;
        c.wbtcUsdso = 0x25bfF6B7B5E2243424F38E75de7ab03C0522a5EA;
    }
}

/// @dev Shared, flat metric record so the test harness can decode it from a revert payload.
struct SomniaMetrics {
    uint8 mode;
    address flashAsset;
    uint256 flashAmount;
    uint256 flashPremium;
    uint256 flashRepayment;
    uint256 suppliedCollateral;
    uint256 collateralDecimals;
    uint256 ltvBps;
    uint256 collateralOracleBefore;
    uint256 collateralOracleAfter;
    int256 collateralFeedAnswerBefore;
    int256 collateralFeedAnswerAfter;
    uint256 collateralFeedUpdatedAtBefore;
    uint256 collateralFeedUpdatedAtAfter;
    uint256 debtOracleBefore;
    uint256 debtOracleAfter;
    uint256 bestBidBefore;
    uint256 bestAskBefore;
    uint256 bestBidAfter;
    uint256 bestAskAfter;
    uint256 preTradeBaseTraded;
    uint256 preTradeQuoteTraded;
    uint256 preTradeExecPrice;
    uint256 baselineBorrowPowerBase;
    int256 borrowPowerInflationBase;
    uint256 postSupplyAvailableBorrowsBase;
    uint256 debtBorrowedFlashAsset;
    uint256 borrowUsdso;
    uint256 borrowUsdc;
    uint256 borrowWeth;
    uint256 borrowWbtc;
    uint256 borrowWsomi;
    uint256 exitBaseSold;
    uint256 exitQuoteProceeds;
    uint256 exitExecPrice;
    uint256 totalCollateralBase;
    uint256 totalDebtBase;
    uint256 healthFactor;
    uint256 debtIfCollateralZeroBase;
    int256 badDebtBase;
    uint256 attackerLiquidBase;
    uint256 seededBase;
    uint256 stepFailures;
    bytes4 lastErrorSelector;
    uint16 lastErrorStep;
    bool zeroSeed;
    uint256 finalUsdso;
    uint256 finalUsdc;
    uint256 finalWeth;
    uint256 finalWbtc;
    uint256 finalNative;
    uint256 finalWsomi;
    uint256 unspentFlashAsset;
    uint256 repaymentBase;
    uint256 coverageBps;
    int256 unitEdgeBps;
    uint256 premiumBps;
    uint256 edgeRequiredBps;
    int256 maxNetBase;
    uint256 breakevenLtvBps;
    uint256 liquidationThresholdBps;
    uint256 shortfallFlashAsset;
    uint256 shortfallBase;
    uint256 oracleRereadCount;
    bool repaid;
}

/// @notice Step identifiers carried in `SomniaMetrics.lastErrorStep` so a failed fork run names
///         the exact leg that broke instead of reporting a bare revert.
library Step {
    uint16 internal constant NONE = 0;
    uint16 internal constant ATOKEN_LOOKUP = 1;
    uint16 internal constant RESERVE_CONFIG = 2;
    uint16 internal constant ACCOUNT_DATA = 3;
    uint16 internal constant ORACLE_PRICE = 4;
    uint16 internal constant BORROW = 5;
    uint16 internal constant EXIT_ORDER = 6;
    uint16 internal constant SUPPLY = 7;
    uint16 internal constant NODE_LIMIT = 8;
}

/// @notice Decimal-aware CLOB price helper.
///         dreamDEX quotes `price` as quote-per-base scaled by 1e18 in *token units*, while
///         `quantity` is in the base token's smallest unit. Converting between the two needs both
///         decimals, which is exactly where a mixed-decimal market (USDC.e/USDso: 6/18) goes
///         wrong if the code assumes 18 everywhere.
library DexMath {
    /// @return quoteRaw amount of the quote token, in its own smallest unit
    function quoteForBase(uint256 price, uint256 baseRaw, uint8 baseDec, uint8 quoteDec)
        internal
        pure
        returns (uint256)
    {
        return (price * baseRaw * (10 ** quoteDec)) / (1e18 * (10 ** baseDec));
    }

    /// @return baseRaw amount of the base token, in its own smallest unit
    function baseForQuote(uint256 price, uint256 quoteRaw, uint8 baseDec, uint8 quoteDec)
        internal
        pure
        returns (uint256)
    {
        if (price == 0) return 0;
        return (quoteRaw * 1e18 * (10 ** baseDec)) / (price * (10 ** quoteDec));
    }
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface IWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

struct ReserveConfigurationMap {
    uint256 data;
}

struct ReserveData {
    ReserveConfigurationMap configuration;
    uint128 liquidityIndex;
    uint128 currentLiquidityRate;
    uint128 currentVariableBorrowRate;
    uint128 currentStableBorrowRate;
    uint40 lastUpdateTimestamp;
    uint16 id;
    address aTokenAddress;
    address stableDebtTokenAddress;
    address variableDebtTokenAddress;
    address interestRateStrategyAddress;
    uint128 accruedToTreasury;
    uint128 unbacked;
    uint128 isolationModeTotalDebt;
}

interface ISomniaLendPool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;

    function getReservesList() external view returns (address[] memory);
    function getReserveData(address asset) external view returns (ReserveData memory);
    function getConfiguration(address asset) external view returns (ReserveConfigurationMap memory);
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
    function getSourceOfAsset(address asset) external view returns (address);
    function getFallbackOracle() external view returns (address);
    function BASE_CURRENCY() external view returns (address);
    function BASE_CURRENCY_UNIT() external view returns (uint256);
}

interface IDreamDexSpotPool {
    struct BookLevel {
        uint256 price;
        uint256 quantity;
    }

    function getPoolParams()
        external
        view
        returns (
            address baseToken,
            address quoteToken,
            uint256 makerFeeBpsTimes1k,
            uint256 takerFeeBpsTimes1k,
            uint256 tickSize,
            uint256 minQuantity,
            uint256 lotSize
        );

    function getBookLevels(bool isBid, uint64 numLevels) external view returns (BookLevel[] memory);

    function getAutoPullRequirement(
        address owner,
        bool isBid,
        uint256 price,
        uint256 quantity,
        uint96 builderFeeBpsTimes1k
    ) external view returns (address inputToken, uint256 requiredAmount, uint256 delta);

    function placeOrder(
        bool isBid,
        uint64 userData,
        uint256 price,
        uint256 quantity,
        uint64 expireTimestampNs,
        uint8 orderType,
        uint8 selfMatchingOption,
        address builder,
        uint96 builderFeeBpsTimes1k
    ) external payable returns (bool success, uint128 orderId);

    function getWithdrawableBalance(address owner, address token) external view returns (uint256);
    function withdraw(address token, uint256 amount) external;
}
