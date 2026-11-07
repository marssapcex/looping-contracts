// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { ResilientOracle } from "../../contracts/ResilientOracle.sol";
import { OracleInterface, BoundValidatorInterface } from "../../contracts/interfaces/OracleInterface.sol";
import { ICappedOracle } from "../../contracts/interfaces/ICappedOracle.sol";

contract AllowAllAccessManager {
    mapping(bytes32 => bool) public denied;

    function setDenied(string calldata signature, bool value) external {
        denied[keccak256(bytes(signature))] = value;
    }

    function isAllowedToCall(address, string calldata signature) external view returns (bool) {
        return !denied[keccak256(bytes(signature))];
    }
}

contract MutableOracle is OracleInterface, ICappedOracle {
    mapping(address => uint256) public prices;
    mapping(address => uint256) public lastUpdated;
    uint256 public snapshotCalls;
    uint256 public snapshotPrice;
    bool public revertOnRead;
    bool public revertOnSnapshot;
    bool public setPriceOnSnapshot;
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
        lastUpdated[asset] = block.timestamp;
    }

    function setStalePrice(address asset, uint256 price, uint256 timestamp) external {
        prices[asset] = price;
        lastUpdated[asset] = timestamp;
    }

    function setSnapshotBehavior(bool revert_, bool setPrice_, uint256 price_) external {
        revertOnSnapshot = revert_;
        setPriceOnSnapshot = setPrice_;
        snapshotPrice = price_;
    }

    function setRevertOnRead(bool value) external {
        revertOnRead = value;
    }

    function getPrice(address asset) external view override returns (uint256) {
        require(!revertOnRead, "oracle read failed");
        return prices[asset];
    }

    function updateSnapshot() external override {
        ++snapshotCalls;
        require(!revertOnSnapshot, "snapshot failed");
        if (setPriceOnSnapshot) {
            // Asset is irrelevant to this branch mock; tests use one asset per oracle.
            // The test calls setSnapshotAsset before enabling this behavior.
            prices[snapshotAsset] = snapshotPrice;
            lastUpdated[snapshotAsset] = block.timestamp;
        }
    }

    address public snapshotAsset;

    function setSnapshotAsset(address asset) external {
        snapshotAsset = asset;
    }
}

contract ConfigurableBoundValidator is BoundValidatorInterface {
    enum Mode {
        ACCEPT_ALL,
        REJECT_ALL,
        ABSOLUTE,
        RELATIVE_BPS
    }

    Mode public mode;
    uint256 public lower;
    uint256 public upper;
    bool public revertOnValidation;

    constructor() {
        mode = Mode.REJECT_ALL;
    }

    function setMode(Mode mode_, uint256 lower_, uint256 upper_) external {
        mode = mode_;
        lower = lower_;
        upper = upper_;
    }

    function setRevert(bool value) external {
        revertOnValidation = value;
    }

    function validatePriceWithAnchorPrice(
        address,
        uint256 reporterPrice,
        uint256 anchorPrice
    ) external view override returns (bool) {
        require(!revertOnValidation, "validator failed");
        if (mode == Mode.ACCEPT_ALL) return true;
        if (mode == Mode.REJECT_ALL) return false;
        if (mode == Mode.ABSOLUTE) return reporterPrice >= lower && reporterPrice <= upper;
        if (anchorPrice == 0) return false;
        uint256 ratio = (reporterPrice * 10_000) / anchorPrice;
        return ratio >= lower && ratio <= upper;
    }
}

contract DelegateProxy {
    address public immutable implementation;

    constructor(address implementation_, bytes memory initData) {
        implementation = implementation_;
        (bool ok, bytes memory result) = implementation_.delegatecall(initData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    fallback() external payable {
        address target = implementation;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract SameTransactionConsumer {
    ResilientOracle public immutable oracle;
    MutableOracle public immutable main;

    constructor(ResilientOracle oracle_, MutableOracle main_) {
        oracle = oracle_;
        main = main_;
    }

    function cacheMutateAndRead(address asset, uint256 newPrice) external returns (uint256 first, uint256 live, uint256 second) {
        oracle.updateAssetPrice(asset);
        first = oracle.getPrice(asset);
        main.setPrice(asset, newPrice);
        live = main.getPrice(asset);
        second = oracle.getPrice(asset);
    }

    function cacheThenDisableMain(address asset) external returns (uint256) {
        oracle.updateAssetPrice(asset);
        oracle.enableOracle(asset, ResilientOracle.OracleRole.MAIN, false);
        return oracle.getPrice(asset);
    }

    function cacheThenDisableCaching(address asset, uint256 newPrice) external returns (uint256) {
        oracle.updateAssetPrice(asset);
        oracle.setCachingEnabled(false);
        main.setPrice(asset, newPrice);
        return oracle.getPrice(asset);
    }

    function pauseCacheMutateAndUnpause(address asset, uint256 newPrice) external returns (uint256) {
        oracle.pause();
        oracle.updateAssetPrice(asset);
        main.setPrice(asset, newPrice);
        oracle.unpause();
        return oracle.getPrice(asset);
    }
}
