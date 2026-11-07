// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { ResilientOracle } from "../contracts/ResilientOracle.sol";
import {
    AllowAllAccessManager,
    MutableOracle,
    ConfigurableBoundValidator,
    DelegateProxy,
    SameTransactionConsumer
} from "./support/AuditMocks.sol";

contract ResilientOracleBranchesTest is Test {
    address internal constant ASSET = address(0xA55E7);

    AllowAllAccessManager internal acm;
    MutableOracle internal main;
    MutableOracle internal pivot;
    MutableOracle internal fallbackOracle;
    ConfigurableBoundValidator internal validator;
    ResilientOracle internal oracle;
    ResilientOracle internal implementation;

    function setUp() public {
        acm = new AllowAllAccessManager();
        main = new MutableOracle(18);
        pivot = new MutableOracle(18);
        fallbackOracle = new MutableOracle(18);
        validator = new ConfigurableBoundValidator();
        implementation = new ResilientOracle();
        DelegateProxy proxy = new DelegateProxy(
            address(implementation),
            abi.encodeCall(ResilientOracle.initialize, (address(acm), validator, true))
        );
        oracle = ResilientOracle(address(proxy));
        main.setPrice(ASSET, 100);
        pivot.setPrice(ASSET, 100);
        fallbackOracle.setPrice(ASSET, 100);
        _configure(address(main), address(0), address(0), true, false, false);
    }

    function _configure(
        address main_,
        address pivot_,
        address fallback_,
        bool mainEnabled,
        bool pivotEnabled,
        bool fallbackEnabled
    ) internal {
        bool[3] memory flags;
        flags[0] = mainEnabled;
        flags[1] = pivotEnabled;
        flags[2] = fallbackEnabled;
        oracle.setTokenConfig(
            ResilientOracle.TokenConfig({ asset: ASSET, oracles: [main_, pivot_, fallback_], enableFlagsForOracles: flags })
        );
    }

    function _relativeValidator() internal {
        validator.setMode(ConfigurableBoundValidator.Mode.RELATIVE_BPS, 9_000, 11_000);
    }

    function test_mainAcceptedWithoutPivotEvenWhenValidatorRejectsEverything() public {
        main.setPrice(ASSET, 123);
        assertEq(oracle.getPrice(ASSET), 123);
        oracle.updateAssetPrice(ASSET);
        assertEq(oracle.getPrice(ASSET), 123);
    }

    function test_mainAcceptedWhenPivotIsConfiguredButDisabled() public {
        _configure(address(main), address(pivot), address(0), true, false, false);
        main.setPrice(ASSET, 999);
        assertEq(oracle.getPrice(ASSET), 999);
    }

    function test_mainAcceptedWhenPivotRevertsOrReturnsZero() public {
        _configure(address(main), address(pivot), address(0), true, true, false);
        pivot.setRevertOnRead(true);
        main.setPrice(ASSET, 777);
        assertEq(oracle.getPrice(ASSET), 777);

        pivot.setRevertOnRead(false);
        pivot.setPrice(ASSET, 0);
        main.setPrice(ASSET, 888);
        assertEq(oracle.getPrice(ASSET), 888);
    }

    function testFuzz_noPivotAcceptsAnyNonzeroMainPrice(uint256 price) public {
        vm.assume(price != 0);
        main.setPrice(ASSET, price);
        assertEq(oracle.getPrice(ASSET), price);
    }

    function test_relativeBoundsRejectMainAndUseValidFallback() public {
        _relativeValidator();
        _configure(address(main), address(pivot), address(fallbackOracle), true, true, true);
        main.setPrice(ASSET, 200);
        pivot.setPrice(ASSET, 100);
        fallbackOracle.setPrice(ASSET, 110);
        assertEq(oracle.getPrice(ASSET), 110);
    }

    function test_relativeBoundsRejectMainWithoutFallbackAndRevert() public {
        _relativeValidator();
        _configure(address(main), address(pivot), address(0), true, true, false);
        main.setPrice(ASSET, 200);
        pivot.setPrice(ASSET, 100);
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(ASSET);
        vm.expectRevert("invalid resilient oracle price");
        oracle.updateAssetPrice(ASSET);
    }

    function test_invalidFallbackAlsoReverts() public {
        _relativeValidator();
        _configure(address(main), address(pivot), address(fallbackOracle), true, true, true);
        main.setPrice(ASSET, 200);
        pivot.setPrice(ASSET, 100);
        fallbackOracle.setPrice(ASSET, 130);
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(ASSET);
    }

    function test_validatorRevertFailsClosedWhenPivotExists() public {
        _configure(address(main), address(pivot), address(fallbackOracle), true, true, true);
        validator.setRevert(true);
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(ASSET);
    }

    function test_disabledMainUsesFallbackValidatedAgainstPivot() public {
        _relativeValidator();
        _configure(address(main), address(pivot), address(fallbackOracle), false, true, true);
        fallbackOracle.setPrice(ASSET, 110);
        assertEq(oracle.getPrice(ASSET), 110);
        fallbackOracle.setPrice(ASSET, 130);
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(ASSET);
    }

    function test_brokenPivotLeavesFallbackUnboundedToo() public {
        _configure(address(main), address(pivot), address(fallbackOracle), false, true, true);
        pivot.setPrice(ASSET, 0);
        fallbackOracle.setPrice(ASSET, 999_999);
        assertEq(oracle.getPrice(ASSET), 999_999);
    }

    function test_zeroMainFallsBackButZeroFallbackCannotBeFinalPrice() public {
        _relativeValidator();
        _configure(address(main), address(pivot), address(fallbackOracle), true, true, true);
        main.setPrice(ASSET, 0);
        fallbackOracle.setPrice(ASSET, 110);
        assertEq(oracle.getPrice(ASSET), 110);
        fallbackOracle.setPrice(ASSET, 0);
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(ASSET);
    }

    function test_unconfiguredAssetAndZeroPricesRevert() public {
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(address(0xDEAD));
        main.setPrice(ASSET, 0);
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(ASSET);
        vm.expectRevert("invalid resilient oracle price");
        oracle.updateAssetPrice(ASSET);
    }

    function test_correlatedOracleRolesDefeatIndependentCrossCheck() public {
        _relativeValidator();
        _configure(address(main), address(main), address(main), true, true, true);
        main.setPrice(ASSET, 200);
        assertEq(oracle.getPrice(ASSET), 200);
    }

    function test_independentPivotRejectsCorrelatedManipulationControl() public {
        _relativeValidator();
        _configure(address(main), address(pivot), address(fallbackOracle), true, true, true);
        main.setPrice(ASSET, 200);
        pivot.setPrice(ASSET, 100);
        fallbackOracle.setPrice(ASSET, 130);
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(ASSET);
    }

    function test_stalenessAndDecimalsAreDelegatedToSource() public {
        main.setStalePrice(ASSET, 1_000_000, 1);
        assertEq(main.lastUpdated(ASSET), 1);
        assertEq(main.decimals(), 18);
        assertEq(oracle.getPrice(ASSET), 1_000_000);
    }

    function test_sameTransactionFirstValidPriceWins() public {
        SameTransactionConsumer consumer = new SameTransactionConsumer(oracle, main);
        (uint256 first, uint256 live, uint256 second) = consumer.cacheMutateAndRead(ASSET, 200);
        assertEq(first, 100);
        assertEq(live, 200);
        assertEq(second, 100);
    }

    function testFuzz_sameTransactionCacheIgnoresAnyLaterSourcePrice(uint256 newPrice) public {
        SameTransactionConsumer consumer = new SameTransactionConsumer(oracle, main);
        (, uint256 live, uint256 second) = consumer.cacheMutateAndRead(ASSET, newPrice);
        assertEq(live, newPrice);
        assertEq(second, 100);
    }

    function test_cachingDisabledReadsLaterSourcePrice() public {
        oracle.setCachingEnabled(false);
        oracle.updateAssetPrice(ASSET);
        main.setPrice(ASSET, 200);
        assertEq(oracle.getPrice(ASSET), 200);
    }

    function test_disablingCachingDoesNotClearExistingTransientPrice() public {
        SameTransactionConsumer consumer = new SameTransactionConsumer(oracle, main);
        assertEq(consumer.cacheThenDisableCaching(ASSET, 200), 100);
    }

    function test_disablingMainDoesNotClearExistingTransientPrice() public {
        SameTransactionConsumer consumer = new SameTransactionConsumer(oracle, main);
        assertEq(consumer.cacheThenDisableMain(ASSET), 100);
    }

    function test_cacheIsContractScoped() public {
        oracle.updateAssetPrice(ASSET);
        main.setPrice(ASSET, 200);

        DelegateProxy secondProxy = new DelegateProxy(
            address(implementation),
            abi.encodeCall(ResilientOracle.initialize, (address(acm), validator, true))
        );
        ResilientOracle second = ResilientOracle(address(secondProxy));
        bool[3] memory flags;
        flags[0] = true;
        second.setTokenConfig(
            ResilientOracle.TokenConfig({
                asset: ASSET,
                oracles: [address(main), address(0), address(0)],
                enableFlagsForOracles: flags
            })
        );
        assertEq(oracle.getPrice(ASSET), 100);
        assertEq(second.getPrice(ASSET), 200);
    }

    function test_pauseBlocksReadsButPermissionlessUpdateStillSnapshotsAndCaches() public {
        SameTransactionConsumer consumer = new SameTransactionConsumer(oracle, main);
        assertEq(consumer.pauseCacheMutateAndUnpause(ASSET, 200), 100);
        assertEq(main.snapshotCalls(), 1);
    }

    function test_publicGettersRevertWhilePaused() public {
        oracle.pause();
        vm.expectRevert("Pausable: paused");
        oracle.getPrice(ASSET);
        vm.expectRevert("Pausable: paused");
        oracle.getUnderlyingPrice(ASSET);
        oracle.updateSnapshot(ASSET);
        assertEq(main.snapshotCalls(), 1);
    }

    function test_snapshotFailureIsSilentlyIgnored() public {
        main.setSnapshotBehavior(true, false, 0);
        oracle.updateAssetPrice(ASSET);
        // The increment is rolled back with the mock's revert; no error escapes the oracle.
        assertEq(main.snapshotCalls(), 0);
        assertEq(oracle.getPrice(ASSET), 100);
    }

    function test_snapshotRunsOnlyOnUpdateInTestableReconstruction() public {
        main.setSnapshotAsset(ASSET);
        main.setSnapshotBehavior(false, true, 120);
        assertEq(oracle.getPrice(ASSET), 100);
        oracle.updateAssetPrice(ASSET);
        assertEq(main.getPrice(ASSET), 120);
        assertEq(oracle.getPrice(ASSET), 120);
    }

    function test_cachedPriceSkipsLaterSnapshotAndSurvives() public {
        main.setSnapshotAsset(ASSET);
        oracle.updateAssetPrice(ASSET);
        main.setSnapshotBehavior(false, true, 120);
        oracle.updateAssetPrice(ASSET);
        assertEq(main.snapshotCalls(), 1);
        assertEq(main.getPrice(ASSET), 100);
        assertEq(oracle.getPrice(ASSET), 100);
    }

    function test_aclBlocksThresholdAndCacheConfiguration() public {
        acm.setDenied("setBoundValidator(address)", true);
        acm.setDenied("setCachingEnabled(bool)", true);
        vm.expectRevert();
        oracle.setBoundValidator(validator);
        vm.expectRevert();
        oracle.setCachingEnabled(false);
    }

    function test_batchConfigurationNeedsOracleSelfPermission() public {
        acm.setDenied("setTokenConfig(TokenConfig)", true);
        ResilientOracle.TokenConfig[] memory configs = new ResilientOracle.TokenConfig[](1);
        bool[3] memory flags;
        flags[0] = true;
        configs[0] = ResilientOracle.TokenConfig({
            asset: ASSET,
            oracles: [address(main), address(0), address(0)],
            enableFlagsForOracles: flags
        });
        vm.expectRevert();
        oracle.setTokenConfigs(configs);
    }

    function test_implementationCannotBeInitialized() public {
        vm.expectRevert("Initializable: contract is already initialized");
        implementation.initialize(address(acm), validator, true);
    }
}
