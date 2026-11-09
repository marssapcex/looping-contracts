// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface IWrappedNative {
    function deposit() external payable;
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
}
