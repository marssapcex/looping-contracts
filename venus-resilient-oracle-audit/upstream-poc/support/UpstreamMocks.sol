// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import { ResilientOracle } from "../../deployed-source/contracts/ResilientOracle.sol";
import { OracleInterface } from "../../deployed-source/contracts/interfaces/OracleInterface.sol";
import { ICappedOracle } from "../../deployed-source/contracts/interfaces/ICappedOracle.sol";

contract UpstreamAccessManager {
    mapping(bytes32 => bool) public denied;

    function setDenied(string calldata signature, bool value) external {
        denied[keccak256(bytes(signature))] = value;
    }

    function isAllowedToCall(address, string calldata signature) external view returns (bool) {
        return !denied[keccak256(bytes(signature))];
    }
}

contract UpstreamMutableOracle is OracleInterface, ICappedOracle {
    mapping(address => uint256) public prices;
    mapping(address => uint256) public lastUpdated;
    uint256 public snapshotCalls;
    uint256 public snapshotPrice;
    address public snapshotAsset;
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

    function setRevertOnRead(bool value) external {
        revertOnRead = value;
    }

    function setSnapshotAsset(address asset) external {
        snapshotAsset = asset;
    }

    function setSnapshotBehavior(bool revert_, bool setPrice_, uint256 price_) external {
        revertOnSnapshot = revert_;
        setPriceOnSnapshot = setPrice_;
        snapshotPrice = price_;
    }

    function getPrice(address asset) external view override returns (uint256) {
        require(!revertOnRead, "oracle read failed");
        return prices[asset];
    }

    function updateSnapshot() external override {
        ++snapshotCalls;
        require(!revertOnSnapshot, "snapshot failed");
        if (setPriceOnSnapshot) {
            prices[snapshotAsset] = snapshotPrice;
            lastUpdated[snapshotAsset] = block.timestamp;
        }
    }
}

contract UpstreamDelegateProxy {
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

contract UpstreamSameTransactionConsumer {
    ResilientOracle public immutable oracle;
    UpstreamMutableOracle public immutable main;

    constructor(ResilientOracle oracle_, UpstreamMutableOracle main_) {
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

    function cacheThenReplaceConfig(address asset, ResilientOracle.TokenConfig memory config) external returns (uint256) {
        oracle.updateAssetPrice(asset);
        oracle.setTokenConfig(config);
        return oracle.getPrice(asset);
    }
}
