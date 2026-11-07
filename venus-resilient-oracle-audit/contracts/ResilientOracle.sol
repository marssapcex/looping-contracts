// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.25;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import { Transient } from "./lib/Transient.sol";
import { VBep20Interface } from "./interfaces/VBep20Interface.sol";
import { BoundValidatorInterface, ResilientOracleInterface, OracleInterface } from "./interfaces/OracleInterface.sol";
import { ICappedOracle } from "./interfaces/ICappedOracle.sol";
import { AccessControlledV8 } from "@venusprotocol/governance-contracts/contracts/Governance/AccessControlledV8.sol";

contract ResilientOracle is ResilientOracleInterface, Initializable, Ownable2StepUpgradeable, AccessControlledV8, PausableUpgradeable {
    using Transient for *;

    enum OracleRole {
        MAIN,
        PIVOT,
        FALLBACK
    }

    bytes32 private constant _CACHE_SLOT = keccak256("venus.oracles.ResilientOracle.priceCache");

    uint256 public constant INVALID_PRICE = 0;

    event TokenConfigAdded(
        address indexed asset,
        address indexed mainOracle,
        address indexed pivotOracle,
        address fallbackOracle
    );
    event OracleSet(address indexed asset, address indexed oracle, OracleRole indexed role);
    event OracleEnabled(address indexed asset, OracleRole indexed role, bool indexed enabled);
    event SnapshotUpdated(address asset, uint256 oldPrice, uint256 newPrice, uint256 oldTimestamp, uint256 newTimestamp);

    struct TokenConfig {
        address asset;
        address[3] oracles;
        bool[3] enableFlagsForOracles;
    }

    bool public cachingEnabled;

    mapping(address => TokenConfig) private tokenConfigs;

    BoundValidatorInterface public boundValidator;

    constructor() {
        _disableInitializers();
    }

    function initialize(address accessControlManager_, BoundValidatorInterface boundValidator_, bool cachingEnabled_) external initializer {
        require(address(boundValidator_) != address(0), "invalid bound validator address");
        __Ownable2Step_init();
        __AccessControlled_init_unchained(accessControlManager_);
        boundValidator = boundValidator_;
        cachingEnabled = cachingEnabled_;
    }

    function pause() external {
        _checkAccessAllowed("pause()");
        _pause();
    }

    function unpause() external {
        _checkAccessAllowed("unpause()");
        _unpause();
    }

    function setTokenConfig(TokenConfig memory tokenConfig) external {
        _checkAccessAllowed("setTokenConfig(TokenConfig)");
        require(tokenConfig.asset != address(0), "asset can't be zero");
        require(tokenConfig.oracles[0] != address(0), "main oracle can't be zero");
        setOracle(tokenConfig.asset, tokenConfig.oracles[0], OracleRole.MAIN);

        if (tokenConfig.oracles[1] != address(0)) {
            setOracle(tokenConfig.asset, tokenConfig.oracles[1], OracleRole.PIVOT);
        } else {
            address pivotOracle = tokenConfigs[tokenConfig.asset].oracles[1];
            if (pivotOracle != address(0)) {
                setOracle(tokenConfig.asset, address(0), OracleRole.PIVOT);
            }
        }

        if (tokenConfig.oracles[2] != address(0)) {
            setOracle(tokenConfig.asset, tokenConfig.oracles[2], OracleRole.FALLBACK);
        } else {
            address fallbackOracle = tokenConfigs[tokenConfig.asset].oracles[2];
            if (fallbackOracle != address(0)) {
                setOracle(tokenConfig.asset, address(0), OracleRole.FALLBACK);
            }
        }

        for (uint256 i = 0; i < 3; ++i) {
            tokenConfigs[tokenConfig.asset].enableFlagsForOracles[i] = tokenConfig.enableFlagsForOracles[i];
        }
        tokenConfigs[tokenConfig.asset].asset = tokenConfig.asset;
        emit TokenConfigAdded(tokenConfig.asset, tokenConfig.oracles[0], tokenConfig.oracles[1], tokenConfig.oracles[2]);
    }

    function setTokenConfigs(TokenConfig[] memory tokenConfigs_) external {
        _checkAccessAllowed("setTokenConfigs(TokenConfig[])");
        uint256 numTokenConfigs = tokenConfigs_.length;
        for (uint256 i; i < numTokenConfigs; ) {
            this.setTokenConfig(tokenConfigs_[i]);
            unchecked {
                ++i;
            }
        }
    }

    function setOracle(address asset, address oracle, OracleRole role) public {
        _checkAccessAllowed("setOracle(address,address,uint8)");
        require(asset != address(0), "asset can't be zero");
        uint256 roleIndex = uint256(role);
        require(roleIndex < 3, "invalid oracle role");
        require(oracle != address(0) || roleIndex != 0, "can't set zero address to main oracle");
        tokenConfigs[asset].oracles[roleIndex] = oracle;
        emit OracleSet(asset, oracle, role);
    }

    function enableOracle(address asset, OracleRole role, bool enable) external {
        _checkAccessAllowed("enableOracle(address,uint8,bool)");
        require(asset != address(0), "asset can't be zero");
        uint256 roleIndex = uint256(role);
        require(roleIndex < 3, "invalid oracle role");
        tokenConfigs[asset].enableFlagsForOracles[roleIndex] = enable;
        emit OracleEnabled(asset, role, enable);
    }

    function setBoundValidator(BoundValidatorInterface newBoundValidator) external {
        _checkAccessAllowed("setBoundValidator(address)");
        require(address(newBoundValidator) != address(0), "invalid bound validator address");
        boundValidator = newBoundValidator;
    }

    function setCachingEnabled(bool enable) external {
        _checkAccessAllowed("setCachingEnabled(bool)");
        cachingEnabled = enable;
    }

    function updatePrice(address vToken) external override {
        address asset = VBep20Interface(vToken).underlying();
        updateAssetPrice(asset);
    }

    function updateAssetPrice(address asset) public override {
        uint256 cachedPrice = _CACHE_SLOT.readCachedPrice(asset);
        if (cachedPrice == 0) {
            updateSnapshot(asset);
            uint256 price = _getPrice(asset);
            if (cachingEnabled) {
                _CACHE_SLOT.cachePrice(asset, price);
            }
        }
    }

    function getPrice(address asset) public view override whenNotPaused returns (uint256) {
        uint256 cachedPrice = _CACHE_SLOT.readCachedPrice(asset);
        if (cachedPrice == 0) {
            return _getPrice(asset);
        }
        return cachedPrice;
    }

    function getUnderlyingPrice(address vToken) external view override whenNotPaused returns (uint256) {
        address asset = VBep20Interface(vToken).underlying();
        return getPrice(asset);
    }

    function getTokenConfig(address asset) external view returns (TokenConfig memory) {
        return tokenConfigs[asset];
    }

    function updateSnapshot(address asset) public {
        if (tokenConfigs[asset].oracles[0] != address(0)) {
            try ICappedOracle(tokenConfigs[asset].oracles[0]).updateSnapshot() {} catch {}
        }
    }

    function _getPrice(address asset) internal view returns (uint256) {
        uint256 pivotPrice = INVALID_PRICE;

        address pivotOracle = tokenConfigs[asset].oracles[uint256(OracleRole.PIVOT)];
        if (pivotOracle != address(0) && tokenConfigs[asset].enableFlagsForOracles[uint256(OracleRole.PIVOT)]) {
            try OracleInterface(pivotOracle).getPrice(asset) returns (uint256 pricePivot) {
                pivotPrice = pricePivot;
            } catch {}
        }

        (uint256 price, bool validated) = _getMainOraclePrice(asset, pivotPrice != INVALID_PRICE, pivotPrice);
        if (!validated) {
            price = INVALID_PRICE;
        }

        if (price == INVALID_PRICE && tokenConfigs[asset].enableFlagsForOracles[uint256(OracleRole.FALLBACK)]) {
            price = _getFallbackOraclePrice(asset, pivotPrice);
        }

        require(price != INVALID_PRICE, "invalid resilient oracle price");
        return price;
    }

    function _getMainOraclePrice(
        address asset,
        bool pivotEnabled,
        uint256 pivotPrice
    ) internal view returns (uint256 mainOraclePrice, bool validated) {
        if (tokenConfigs[asset].enableFlagsForOracles[uint256(OracleRole.MAIN)]) {
            try OracleInterface(tokenConfigs[asset].oracles[uint256(OracleRole.MAIN)]).getPrice(asset) returns (uint256 returnedPrice) {
                mainOraclePrice = returnedPrice;
                if (!pivotEnabled) {
                    validated = true;
                    return (mainOraclePrice, validated);
                }
            } catch {
                return (INVALID_PRICE, false);
            }
        } else {
            return (INVALID_PRICE, false);
        }

        if (tokenConfigs[asset].enableFlagsForOracles[uint256(OracleRole.FALLBACK)] && mainOraclePrice == INVALID_PRICE) {
            return (INVALID_PRICE, false);
        }

        try
            boundValidator.validatePriceWithAnchorPrice(asset, mainOraclePrice, pivotPrice)
        returns (bool validateMainPrice) {
            validated = validateMainPrice;
            return (mainOraclePrice, validated);
        } catch {
            return (INVALID_PRICE, false);
        }
    }

    function _getFallbackOraclePrice(address asset, uint256 pivotPrice) internal view returns (uint256 fallbackPrice) {
        address fallbackOracle = tokenConfigs[asset].oracles[uint256(OracleRole.FALLBACK)];
        try OracleInterface(fallbackOracle).getPrice(asset) returns (uint256 priceFallback) {
            fallbackPrice = priceFallback;
        } catch {
            return INVALID_PRICE;
        }

        if (pivotPrice != INVALID_PRICE) {
            try
                boundValidator.validatePriceWithAnchorPrice(asset, fallbackPrice, pivotPrice)
            returns (bool validateFallbackPrice) {
                if (!validateFallbackPrice) {
                    return INVALID_PRICE;
                }
            } catch {
                return INVALID_PRICE;
            }
        }

        return fallbackPrice;
    }
}
