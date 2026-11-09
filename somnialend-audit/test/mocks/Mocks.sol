// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DexMath, IDreamDexSpotPool, ReserveData} from "../../src/Interfaces.sol";

/// @notice Minimal test doubles for the SomniaLend + dreamDEX surface used by the attack contract.
///         They exist so the attack's call sequence can be rehearsed locally with no RPC. They are
///         NOT models of Somnia and their numbers are never reported as chain results.

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev WETH9-shaped wrapper, matching WSOMI's deployed behaviour.
contract MockWrappedNative {
    string public name = "Wrapped SOMI";
    string public symbol = "WSOMI";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad, "balance");
        balanceOf[msg.sender] -= wad;
        totalSupply -= wad;
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "native send");
        emit Withdrawal(msg.sender, wad);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Chainlink/DIA-shaped feed: `latestRoundData` and `latestAnswer` both answered.
contract MockFeed {
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;

    constructor(int256 initialAnswer, uint256 initialUpdatedAt) {
        answer = initialAnswer;
        updatedAt = initialUpdatedAt;
        roundId = 1;
    }

    function set(int256 newAnswer, uint256 newUpdatedAt) external {
        answer = newAnswer;
        updatedAt = newUpdatedAt;
        roundId += 1;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt - 60, updatedAt, roundId);
    }

    function latestAnswer() external view returns (int256) {
        return answer;
    }
}

/// @dev Aave-V3-shaped oracle: 8-decimal base currency, per-asset source with a fallback.
contract MockOracle {
    uint256 public constant BASE_CURRENCY_UNIT = 1e8;
    address public constant BASE_CURRENCY = address(0);
    address public fallbackOracle;

    mapping(address => address) public sourceOf;
    mapping(address => uint256) internal directPrice;

    function setSource(address asset, address feed) external {
        sourceOf[asset] = feed;
    }

    function setPrice(address asset, uint256 price) external {
        directPrice[asset] = price;
    }

    function getSourceOfAsset(address asset) external view returns (address) {
        return sourceOf[asset];
    }

    function getFallbackOracle() external view returns (address) {
        return fallbackOracle;
    }

    function getAssetPrice(address asset) public view returns (uint256) {
        address feed = sourceOf[asset];
        if (feed != address(0)) {
            return uint256(MockFeed(feed).latestAnswer());
        }
        return directPrice[asset];
    }
}

/// @dev Aave-V3-shaped lending pool with one reserve per asset, linear interest-free accounting.
contract MockLendPool {
    uint256 public constant FLASHLOAN_PREMIUM_TOTAL = 5; // 5 bps, matches Aave V3 default
    address public immutable oracle;

    struct Reserve {
        uint256 ltv;
        uint256 liquidationThreshold;
        bool active;
        bool frozen;
        bool borrowingEnabled;
        uint256 cash;
    }

    mapping(address => Reserve) public reserves;
    address[] public assetList;

    mapping(address => mapping(address => uint256)) public supplied; // user => asset => amount
    mapping(address => mapping(address => uint256)) public borrowedAmount; // user => asset => amount

    constructor(address oracle_) {
        oracle = oracle_;
    }

    function addReserve(address asset, uint256 ltv, uint256 threshold, bool borrowEnabled) external {
        reserves[asset] = Reserve(ltv, threshold, true, false, borrowEnabled, 0);
        assetList.push(asset);
    }

    function fund(address asset, uint256 amount) external {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        reserves[asset].cash += amount;
    }

    function getReservesList() external view returns (address[] memory) {
        return assetList;
    }

    function getConfiguration(address asset) external view returns (uint256 data) {
        Reserve storage r = reserves[asset];
        data = (r.ltv & 0xffff) | ((r.liquidationThreshold & 0xffff) << 16);
        if (r.active) data |= uint256(1) << 56;
        if (r.frozen) data |= uint256(1) << 57;
        if (r.borrowingEnabled) data |= uint256(1) << 58;
    }

    function getReserveData(address asset) external view returns (ReserveData memory r) {
        require(reserves[asset].active, "reserve");
        r.aTokenAddress = address(this); // pool holds the cash, like the aToken does on-chain
        r.configuration.data = this.getConfiguration(asset);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        supplied[onBehalfOf][asset] += amount;
        reserves[asset].cash += amount;
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        Reserve storage r = reserves[asset];
        require(r.active && r.borrowingEnabled && !r.frozen, "borrow disabled");
        (,, uint256 available,,,) = this.getUserAccountData(msg.sender);
        uint256 price = MockOracle(oracle).getAssetPrice(asset);
        uint256 need = (amount * price) / (10 ** MockERC20(asset).decimals());
        require(need <= available, "borrow too much");
        require(r.cash >= amount, "insufficient cash");
        r.cash -= amount;
        borrowedAmount[onBehalfOf][asset] += amount;
        MockERC20(asset).transfer(msg.sender, amount);
    }

    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata params, uint16)
        external
    {
        uint256 premium = (amount * FLASHLOAN_PREMIUM_TOTAL) / 10_000;
        require(reserves[asset].cash >= amount, "flash cash");
        reserves[asset].cash -= amount;
        MockERC20(asset).transfer(receiver, amount);

        bool ok = IFlashLoanSimpleReceiver(receiver).executeOperation(
            asset, amount, premium, msg.sender, params
        );
        require(ok, "callback failed");

        MockERC20(asset).transferFrom(receiver, address(this), amount + premium);
        reserves[asset].cash += amount + premium;
    }

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
        )
    {
        uint256 weightedThreshold;
        uint256 weightedLtv;
        for (uint256 i; i < assetList.length; ++i) {
            address asset = assetList[i];
            uint256 price = MockOracle(oracle).getAssetPrice(asset);
            uint256 dec = 10 ** MockERC20(asset).decimals();

            uint256 collateral = (supplied[user][asset] * price) / dec;
            totalCollateralBase += collateral;
            weightedThreshold += (collateral * reserves[asset].liquidationThreshold);
            // Aave weights the LTV by each collateral's contribution, not by a single reserve.
            weightedLtv += (collateral * reserves[asset].ltv);

            totalDebtBase += (borrowedAmount[user][asset] * price) / dec;
        }

        if (totalCollateralBase > 0) {
            currentLiquidationThreshold = weightedThreshold / totalCollateralBase;
            ltv = weightedLtv / totalCollateralBase;
            uint256 maxBorrow = (totalCollateralBase * ltv) / 10_000;
            availableBorrowsBase = maxBorrow > totalDebtBase ? maxBorrow - totalDebtBase : 0;
            healthFactor = totalDebtBase == 0
                ? type(uint256).max
                : ((totalCollateralBase * currentLiquidationThreshold) / 10_000) * 1e18 / totalDebtBase;
        }
    }
}

interface IFlashLoanSimpleReceiver {
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool);
}

/// @dev dreamDEX-shaped CLOB: one aggregated level per side, fee taken from the input token,
///      `placeOrder` is payable so native SOMI can be the base asset.
contract MockSpotPool is IDreamDexSpotPool {
    address public baseToken;
    address public quoteToken;
    uint256 public tickSize;
    uint256 public minQuantity;
    uint256 public lotSize;
    uint256 public takerFeeBpsTimes1k; // bps * 1k, matching the real ABI

    uint256 public bidPrice;
    uint256 public bidSize;
    uint256 public askPrice;
    uint256 public askSize;

    uint128 internal nextOrderId = 1;

    constructor(address base, address quote, uint256 tick, uint256 minQty, uint256 lot, uint256 takerFee) {
        baseToken = base;
        quoteToken = quote;
        tickSize = tick;
        minQuantity = minQty;
        lotSize = lot;
        takerFeeBpsTimes1k = takerFee;
    }

    function setBook(uint256 bidP, uint256 bidQ, uint256 askP, uint256 askQ) external {
        bidPrice = bidP;
        bidSize = bidQ;
        askPrice = askP;
        askSize = askQ;
    }

    function getPoolParams()
        external
        view
        returns (address, address, uint256, uint256, uint256, uint256, uint256)
    {
        return (baseToken, quoteToken, 0, takerFeeBpsTimes1k, tickSize, minQuantity, lotSize);
    }

    function getBookLevels(bool isBid, uint64) external view returns (BookLevel[] memory levels) {
        uint256 price = isBid ? bidPrice : askPrice;
        uint256 size = isBid ? bidSize : askSize;
        if (price == 0 || size == 0) return new BookLevel[](0);
        levels = new BookLevel[](1);
        levels[0] = BookLevel(price, size);
    }

    function _feeOnInput(uint256 amount) internal view returns (uint256) {
        return (amount * (takerFeeBpsTimes1k / 1000)) / 10_000;
    }

    function _decimals(address token) internal view returns (uint8) {
        // Native SOMI has no contract, so `decimals()` reverts on the sentinel. It is 18dp.
        if (token == NATIVE_SENTINEL || token == address(0)) return 18;
        return MockERC20(token).decimals();
    }

    function _baseDec() internal view returns (uint8) {
        return _decimals(baseToken);
    }

    function _quoteDec() internal view returns (uint8) {
        return _decimals(quoteToken);
    }

    function getAutoPullRequirement(address, bool isBid, uint256 price, uint256 quantity, uint96)
        external
        view
        returns (address, uint256, uint256)
    {
        if (isBid) {
            uint256 cost = DexMath.quoteForBase(price, quantity, _baseDec(), _quoteDec());
            cost += _feeOnInput(cost);
            return (quoteToken, cost, 0);
        }
        return (baseToken, quantity, 0);
    }

    function placeOrder(
        bool isBid,
        uint64,
        uint256 price,
        uint256 quantity,
        uint64,
        uint8,
        uint8,
        address,
        uint96
    ) external payable returns (bool, uint128) {
        require(quantity > 0, "quantity");

        if (isBid) {
            require(askPrice > 0 && price >= askPrice, "would not cross");
            require(askSize >= quantity, "book too thin");
            // Settle at the real ask, not at the taker's limit: `required` from
            // getAutoPullRequirement is an upper bound, the fill is what actually clears.
            uint256 cost = DexMath.quoteForBase(askPrice, quantity, _baseDec(), _quoteDec());
            cost += _feeOnInput(cost);
            require(msg.value >= 0, "noop");
            _collectInputUpTo(quoteToken, cost);
            askSize -= quantity;
            if (askSize == 0) askPrice = 0;
            _sendOutput(baseToken, quantity);
        } else {
            require(bidPrice > 0 && price <= bidPrice, "would not cross");
            require(bidSize >= quantity, "book too thin");
            uint256 proceeds = DexMath.quoteForBase(bidPrice, quantity, _baseDec(), _quoteDec());
            proceeds -= _feeOnInput(proceeds);
            _collectInputUpTo(baseToken, quantity);
            bidSize -= quantity;
            if (bidSize == 0) bidPrice = 0;
            _sendOutput(quoteToken, proceeds);
        }
        return (true, nextOrderId++);
    }

    function _collectInputUpTo(address token, uint256 amount) internal {
        if (token == NATIVE_SENTINEL) {
            require(msg.value >= amount, "native input");
        } else if (token == address(0)) {
            require(msg.value >= amount, "native input");
        } else {
            require(MockERC20(token).transferFrom(msg.sender, address(this), amount), "input pull");
        }
    }

    function _sendOutput(address token, uint256 amount) internal {
        if (token == NATIVE_SENTINEL || token == address(0)) {
            (bool ok,) = msg.sender.call{value: amount}("");
            require(ok, "native out");
        } else {
            require(MockERC20(token).transfer(msg.sender, amount), "output send");
        }
    }

    receive() external payable {}

    function getWithdrawableBalance(address, address) external pure returns (uint256) {
        return 0;
    }

    function withdraw(address, uint256) external {}

    address public constant NATIVE_SENTINEL = 0x28f34DeFd2b4CB48d9eE6d89f2Be4Bc601694c00;
}
