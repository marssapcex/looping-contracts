// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { Test } from "forge-std/Test.sol";
import { ResilientOracle } from "../deployed-source/contracts/ResilientOracle.sol";
import { BoundValidator } from "../deployed-source/contracts/oracles/BoundValidator.sol";
import {
    UpstreamAccessManager,
    UpstreamMutableOracle,
    UpstreamDelegateProxy,
    UpstreamSameTransactionConsumer
} from "./support/UpstreamMocks.sol";

contract UpstreamResilientOracleTest is Test {
    address internal constant ASSET = address(0xA55E7);
    address internal constant ASSET_B = address(0xB);

    UpstreamAccessManager internal acm;
    UpstreamMutableOracle internal main;
    UpstreamMutableOracle internal pivot;
    UpstreamMutableOracle internal fallbackOracle;
    BoundValidator internal validator;
    ResilientOracle internal oracle;

    function setUp() public {
        acm = new UpstreamAccessManager();
        main = new UpstreamMutableOracle(18);
        pivot = new UpstreamMutableOracle(18);
        fallbackOracle = new UpstreamMutableOracle(18);

        BoundValidator validatorImplementation = new BoundValidator();
        UpstreamDelegateProxy validatorProxy = new UpstreamDelegateProxy(
            address(validatorImplementation),
            abi.encodeCall(BoundValidator.initialize, (address(acm)))
        );
        validator = BoundValidator(address(validatorProxy));
        ResilientOracle implementation = new ResilientOracle(address(0), address(0), validator);
        UpstreamDelegateProxy proxy = new UpstreamDelegateProxy(
            address(implementation),
            abi.encodeCall(ResilientOracle.initialize, (address(acm)))
        );
        oracle = ResilientOracle(address(proxy));

        main.setPrice(ASSET, 100);
        pivot.setPrice(ASSET, 100);
        fallbackOracle.setPrice(ASSET, 100);
        _setBounds(0.9e18, 1.1e18);
        _configure(ASSET, address(main), address(0), address(0), true, false, false, true);
    }

    function _setBounds(uint256 lower, uint256 upper) internal {
        validator.setValidateConfig(
            BoundValidator.ValidateConfig({ asset: ASSET, upperBoundRatio: upper, lowerBoundRatio: lower })
        );
    }

    function _configure(
        address asset,
        address main_,
        address pivot_,
        address fallback_,
        bool mainEnabled,
        bool pivotEnabled,
        bool fallbackEnabled,
        bool caching
    ) internal {
        bool[3] memory flags;
        flags[0] = mainEnabled;
        flags[1] = pivotEnabled;
        flags[2] = fallbackEnabled;
        oracle.setTokenConfig(
            ResilientOracle.TokenConfig({
                asset: asset,
                oracles: [main_, pivot_, fallback_],
                enableFlagsForOracles: flags,
                cachingEnabled: caching
            })
        );
    }

    function test_mainAcceptedOnlyWhenPivotIsActuallyUnconfiguredOrDisabled() public {
        main.setPrice(ASSET, 123);
        assertEq(oracle.getPrice(ASSET), 123);
        _configure(ASSET, address(main), address(pivot), address(0), true, false, false, true);
        main.setPrice(ASSET, 456);
        assertEq(oracle.getPrice(ASSET), 456);
    }

    function test_enabledPivotReturningZeroDoesNotFailOpenToMain() public {
        _configure(ASSET, address(main), address(pivot), address(0), true, true, false, true);
        pivot.setPrice(ASSET, 0);
        main.setPrice(ASSET, 999);
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(ASSET);
    }

    function test_enabledPivotRevertDoesNotFailOpenToMain() public {
        _configure(ASSET, address(main), address(pivot), address(0), true, true, false, true);
        pivot.setRevertOnRead(true);
        main.setPrice(ASSET, 999);
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(ASSET);
    }

    function test_pivotInvalidUsesFinalMainFallbackComparison() public {
        _configure(ASSET, address(main), address(pivot), address(fallbackOracle), true, true, true, true);
        pivot.setPrice(ASSET, 0);
        main.setPrice(ASSET, 100);
        fallbackOracle.setPrice(ASSET, 105);
        assertEq(oracle.getPrice(ASSET), 100);

        main.setPrice(ASSET, 200);
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(ASSET);
    }

    function test_fallbackCannotStandaloneWithoutPivotOrMain() public {
        _configure(ASSET, address(main), address(0), address(fallbackOracle), true, false, true, true);
        main.setPrice(ASSET, 0);
        fallbackOracle.setPrice(ASSET, 100);
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(ASSET);

        _configure(ASSET, address(main), address(0), address(fallbackOracle), false, false, true, true);
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(ASSET);
    }

    function test_validPivotRejectsMainAndAcceptsFallback() public {
        _configure(ASSET, address(main), address(pivot), address(fallbackOracle), true, true, true, true);
        main.setPrice(ASSET, 200);
        pivot.setPrice(ASSET, 100);
        fallbackOracle.setPrice(ASSET, 110);
        assertEq(oracle.getPrice(ASSET), 110);
    }

    function test_correlatedMainAndPivotDefeatsCrossCheck() public {
        _configure(ASSET, address(main), address(main), address(0), true, true, false, true);
        main.setPrice(ASSET, 200);
        assertEq(oracle.getPrice(ASSET), 200);
    }

    function test_governanceConfiguredWideBoundsAcceptTwoXDeviation() public {
        _setBounds(0.4e18, 1.6e18);
        _configure(ASSET, address(main), address(pivot), address(0), true, true, false, true);
        main.setPrice(ASSET, 200);
        pivot.setPrice(ASSET, 100);
        assertEq(oracle.getPrice(ASSET), 200);
    }

    function test_boundConfigurationIsAccessControlled() public {
        acm.setDenied("setValidateConfig(ValidateConfig)", true);
        vm.expectRevert();
        _setBounds(0.1e18, 10e18);
    }

    function test_missingBoundConfigFailsClosedWithEnabledPivot() public {
        UpstreamDelegateProxy validatorProxy = new UpstreamDelegateProxy(
            address(new BoundValidator()),
            abi.encodeCall(BoundValidator.initialize, (address(acm)))
        );
        ResilientOracle implementation = new ResilientOracle(address(0), address(0), BoundValidator(address(validatorProxy)));
        UpstreamDelegateProxy proxy = new UpstreamDelegateProxy(
            address(implementation),
            abi.encodeCall(ResilientOracle.initialize, (address(acm)))
        );
        ResilientOracle fresh = ResilientOracle(address(proxy));
        bool[3] memory flags;
        flags[0] = true;
        flags[1] = true;
        fresh.setTokenConfig(
            ResilientOracle.TokenConfig({
                asset: ASSET,
                oracles: [address(main), address(pivot), address(0)],
                enableFlagsForOracles: flags,
                cachingEnabled: false
            })
        );
        vm.expectRevert();
        fresh.getPrice(ASSET);
    }

    function test_sameTransactionFirstValidPriceWins() public {
        UpstreamSameTransactionConsumer consumer = new UpstreamSameTransactionConsumer(oracle, main);
        (uint256 first, uint256 live, uint256 second) = consumer.cacheMutateAndRead(ASSET, 200);
        assertEq(first, 100);
        assertEq(live, 200);
        assertEq(second, 100);
    }

    function test_assetSpecificCaching() public {
        main.setPrice(ASSET_B, 300);
        _configure(ASSET_B, address(main), address(0), address(0), true, false, false, false);
        oracle.updateAssetPrice(ASSET);
        oracle.updateAssetPrice(ASSET_B);
        main.setPrice(ASSET, 200);
        main.setPrice(ASSET_B, 400);
        assertEq(oracle.getPrice(ASSET), 100);
        assertEq(oracle.getPrice(ASSET_B), 400);
    }

    function test_configurationReplacementDoesNotClearTransientPrice() public {
        UpstreamSameTransactionConsumer consumer = new UpstreamSameTransactionConsumer(oracle, main);
        bool[3] memory flags;
        ResilientOracle.TokenConfig memory disabled = ResilientOracle.TokenConfig({
            asset: ASSET,
            oracles: [address(main), address(0), address(0)],
            enableFlagsForOracles: flags,
            cachingEnabled: false
        });
        assertEq(consumer.cacheThenReplaceConfig(ASSET, disabled), 100);
    }

    function test_existingCacheSkipsLaterSnapshot() public {
        main.setSnapshotAsset(ASSET);
        oracle.updateAssetPrice(ASSET);
        main.setSnapshotBehavior(false, true, 120);
        oracle.updateAssetPrice(ASSET);
        assertEq(main.snapshotCalls(), 1);
        assertEq(main.getPrice(ASSET), 100);
        assertEq(oracle.getPrice(ASSET), 100);
    }

    function test_snapshotFailureIsSwallowedAndPriceStillCaches() public {
        main.setSnapshotBehavior(true, false, 0);
        oracle.updateAssetPrice(ASSET);
        assertEq(main.snapshotCalls(), 0);
        main.setPrice(ASSET, 200);
        assertEq(oracle.getPrice(ASSET), 100);
    }

    function test_cachingDisabledUpdateDoesNotValidatePrice() public {
        _configure(ASSET, address(main), address(0), address(0), true, false, false, false);
        main.setPrice(ASSET, 0);
        oracle.updateAssetPrice(ASSET);
        vm.expectRevert("invalid resilient oracle price");
        oracle.getPrice(ASSET);
    }

    function test_pauseBlocksReadsButNotUpdateOrSnapshot() public {
        oracle.pause();
        vm.expectRevert("resilient oracle is paused");
        oracle.getPrice(ASSET);
        oracle.updateAssetPrice(ASSET);
        assertEq(main.snapshotCalls(), 1);
        main.setPrice(ASSET, 200);
        vm.expectRevert("resilient oracle is paused");
        oracle.getPrice(ASSET);
        oracle.unpause();
        assertEq(oracle.getPrice(ASSET), 100);
    }

    function test_stalenessAndDecimalsRemainSourceResponsibilities() public {
        main.setStalePrice(ASSET, 1_000_000, 1);
        assertEq(main.lastUpdated(ASSET), 1);
        assertEq(oracle.getPrice(ASSET), 1_000_000);
    }
}
