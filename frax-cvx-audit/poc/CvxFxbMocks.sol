// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

// Zero-debt/zero-collateral lender used only for the paused ERC4626 accounting
// campaign. No leverage result is claimed from this mock.
contract MockFraxLendZero {
    function userBorrowShares(address) external pure returns (uint256) { return 0; }
    function userCollateralBalance(address) external pure returns (uint256) { return 0; }
}

interface MockTokenLike {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

// Deterministic 1:1 FRAX/sFRAX vault for exercising leverage call paths. It is
// intentionally not a yield or mainnet sFRAX model.
contract MockSfraxVault {
    address public immutable frax;
    address public immutable sfrax;
    constructor(address _frax, address _sfrax) { frax = _frax; sfrax = _sfrax; }
    function previewDeposit(uint256 assets) external pure returns (uint256) { return assets; }
    function deposit(uint256 assets, address receiver) external returns (uint256) {
        require(MockTokenLike(frax).transferFrom(msg.sender, address(this), assets), "frax in");
        MockTokenLike(sfrax).mint(receiver, assets);
        return assets;
    }
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        require(MockTokenLike(sfrax).transferFrom(owner, address(this), shares), "sfrax in");
        require(MockTokenLike(frax).transfer(receiver, shares), "frax out");
        return shares;
    }
    function maxWithdraw(address owner) external view returns (uint256) {
        return MockTokenLike(sfrax).balanceOf(owner);
    }
}

contract MockDualOracle {
    uint256 public rate = 1e18;
    function setRate(uint256 _rate) external { rate = _rate; }
    function getPrices() external view returns (bool, bool, uint256) { return (false, false, rate); }
}

// Single-position lender with 1:1 debt shares and unrestricted FRAX liquidity.
// It enforces real token/collateral/debt transitions but does not model interest,
// liquidations, external borrowers, or mainnet liquidity constraints.
contract MockFraxLendLevered {
    struct VaultAccount { uint128 amount; uint128 shares; }
    struct CurrentRateInfo {
        uint32 lastBlock; uint32 feeToProtocolRate; uint64 lastTimestamp;
        uint64 ratePerSec; uint64 fullUtilizationRate;
    }
    struct ExchangeRateInfo {
        address oracle; uint32 maxOracleDeviation; uint184 lastTimestamp;
        uint256 lowExchangeRate; uint256 highExchangeRate;
    }
    address public immutable collateralContract;
    address public immutable frax;
    address public immutable oracle;
    uint256 public collateral;
    uint256 public debtShares;
    constructor(address _fxb, address _frax, address _oracle) {
        collateralContract = _fxb; frax = _frax; oracle = _oracle;
    }
    function userCollateralBalance(address user) external view returns (uint256) {
        return user == msg.sender || user != address(0) ? collateral : 0;
    }
    function userBorrowShares(address user) external view returns (uint256) {
        return user == msg.sender || user != address(0) ? debtShares : 0;
    }
    function maxLTV() external pure returns (uint256) { return 98000; }
    function toBorrowAmount(uint256 shares, bool, bool) external pure returns (uint256) { return shares; }
    function totalBorrow() external view returns (uint256, uint256) { return (debtShares, debtShares); }
    function totalAsset() external pure returns (uint256, uint256) { return (1e30, 1e30); }
    function totalAssets() external pure returns (uint256) { return 1e30; }
    function exchangeRateInfo() external view returns (ExchangeRateInfo memory info) {
        uint256 rate = MockDualOracle(oracle).rate();
        info = ExchangeRateInfo(oracle, 0, 0, rate, rate);
    }
    function updateExchangeRate() external view returns (bool, uint256, uint256) {
        uint256 rate = MockDualOracle(oracle).rate();
        return (true, rate, rate);
    }
    function previewAddInterest() external view returns (
        uint256, uint256, uint256, CurrentRateInfo memory,
        VaultAccount memory, VaultAccount memory
    ) {
        return (0, 0, 0, CurrentRateInfo(0, 0, 0, 0, 0),
            VaultAccount(1e30, 1e30), VaultAccount(uint128(debtShares), uint128(debtShares)));
    }
    function addCollateral(uint256 amount, address) external {
        require(MockTokenLike(collateralContract).transferFrom(msg.sender, address(this), amount), "fxb in");
        collateral += amount;
    }
    function removeCollateral(uint256 amount, address receiver) external {
        require(debtShares == 0, "debt outstanding");
        require(amount <= collateral, "collateral");
        collateral -= amount;
        require(MockTokenLike(collateralContract).transfer(receiver, amount), "fxb out");
    }
    function borrowAsset(uint256 amount, uint256 collateralAmount, address receiver) external returns (uint256) {
        if (collateralAmount > 0) {
            require(MockTokenLike(collateralContract).transferFrom(msg.sender, address(this), collateralAmount), "fxb in");
            collateral += collateralAmount;
        }
        debtShares += amount;
        MockTokenLike(frax).mint(receiver, amount);
        return amount;
    }
    function repayAsset(uint256 shares, address borrower) external returns (uint256) {
        require(shares <= debtShares, "debt shares");
        require(MockTokenLike(frax).transferFrom(borrower, address(this), shares), "frax repay");
        debtShares -= shares;
        return shares;
    }
}

contract MockFeeRegistry {
    uint256 public totalFees;
    uint256 public cvxIncentive;
    uint256 public platformIncentive;
    function setFees(uint256 total, uint256 cvx, uint256 platform) external {
        totalFees = total;
        cvxIncentive = cvx;
        platformIncentive = platform;
    }
}

contract MockLockStaker {
    function increaseAmount(uint256) external pure returns (bool) { return true; }
    function increaseTime(uint256) external pure returns (bool) { return true; }
}

contract MockRewardSink {
    mapping(address => uint256) public notified;
    function notifyRewardAmount(address token, uint256 amount) external {
        notified[token] += amount;
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amount)
        );
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");
    }
}
