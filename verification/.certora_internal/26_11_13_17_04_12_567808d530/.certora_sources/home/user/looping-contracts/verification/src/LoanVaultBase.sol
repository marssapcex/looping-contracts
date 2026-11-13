// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

// No ERC20Permit: a leaked permit signature would be a standing allowance over a lender's shares.
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { DualPausableUpgradeable } from "./DualPausableUpgradeable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ILoanVault } from "./interfaces/ILoanVault.sol";
import { IRoleManager } from "./interfaces/IRoleManager.sol";
import { IVaultLenderRegistry } from "./interfaces/IVaultLenderRegistry.sol";
import { VaultAccountingLib } from "./VaultAccountingLib.sol";

/// @title LoanVaultBase
/// @author Axcess Protocol
/// @notice Constants, config storage, the vault-manager gate and shared helpers.
/// @dev Each module keeps its state in its own ERC-7201 namespace.
abstract contract LoanVaultBase is ERC20Upgradeable, DualPausableUpgradeable, ReentrancyGuard, ILoanVault {
    // ============ Constants ============
    // *_BPS bounds are basis points (10_000 = 100% APR); durations are seconds.
    uint256 internal constant MIN_EPOCH_DURATION = 1 days;
    uint256 internal constant MAX_EPOCH_DURATION = 365 days;
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    uint256 internal constant MIN_INTEREST_RATE_BPS = 700;
    uint256 internal constant MAX_INTEREST_RATE_BPS = 10_000;
    uint256 internal constant MAX_PENALTY_RATE_BPS = 5000;
    uint256 internal constant MAX_WITHDRAWAL_GRACE_PERIOD = 7 days;

    // ============ Configurable Parameters Storage ============
    // keccak256(abi.encode(uint256(keccak256("com.axcess.loanvault.config.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VAULT_CONFIG_STORAGE_SLOT =
        0xaadcfa989575606a8f1a80e6b4de666c1e108e7b4036002d9846db4405084d00;

    /// @custom:storage-location erc7201:com.axcess.loanvault.config.storage
    struct VaultConfigStorage {
        // Annual protocol fee in bps, accrued on the same base and window as interest
        uint256 feeBps;
        // Read from the lender registry at initialization; never repointed
        IRoleManager roleManager;
    }

    /// @dev Set only during `requestRedeem`'s escrow transfer; shares may enter the vault only then.
    bool internal transient escrowInFlight;

    function _getConfigStorage() internal pure returns (VaultConfigStorage storage s) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00280000, 1037618708520) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00280001, 0) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00280004, 0) }
        bytes32 slot = VAULT_CONFIG_STORAGE_SLOT;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000024,slot)}
        assembly {
            s.slot := slot
        }
    }

    // ============ Config Getters ============

    /// @notice Annual protocol fee rate in bps, carved out of interest as it accrues.
    function feeBps() public view returns (uint256) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff000f0000, 1037618708495) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff000f0001, 0) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff000f0004, 0) }
        return _getConfigStorage().feeBps;
    }

    // ============ Initializer ============

    /// @dev Validates params and initializes config, ERC-20 metadata, RoleManager and pause state.
    function _initializeBase(ConstructorParams calldata _params) internal {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00290000, 1037618708521) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00290001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00290005, 4) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00296200, _params) }
        _validateInitParams(_params);
        _initializeConfig(_params);

        __ERC20_init(_params.name, _params.symbol);
        _getConfigStorage().roleManager = IVaultLenderRegistry(_params.lenderRegistry).roleManager();
        __DualPausable_init();
    }

    function _initializeConfig(ConstructorParams calldata _params) private {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002b0000, 1037618708523) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002b0001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002b0005, 4) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002b6200, _params) }
        VaultConfigStorage storage cs = _getConfigStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00010025,0)}
        cs.feeBps = _params.feeBps;uint256 certora_local39 = cs.feeBps;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000027,certora_local39)}
    }

    function _validateInitParams(ConstructorParams calldata _params) private pure {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002c0000, 1037618708524) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002c0001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002c0005, 4) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002c6200, _params) }
        if (_params.asset == address(0)) revert AssetCannotBeZeroAddress();
        if (_params.lenderRegistry == address(0)) revert LenderRegistryCannotBeZeroAddress();
        if (_params.borrower == address(0)) {
            revert BorrowerCannotBeZeroAddress();
        }
        if (_params.feeRecipient == address(0)) {
            revert FeeRecipientCannotBeZeroAddress();
        }
        if (_params.interestRateBps > MAX_INTEREST_RATE_BPS) {
            revert InterestRateExceedsMax();
        }
        if (_params.interestRateBps < MIN_INTEREST_RATE_BPS) {
            revert InterestRateBelowMin();
        }
        // The fee is carved out of interest, so the lender's net rate must stay positive.
        if (_params.feeBps >= _params.interestRateBps) revert InvalidFeeBps();
        if (_params.initialCapacity == 0) revert InitialCapacityCannotBeZero();
        if (_params.penaltyRateBps > MAX_PENALTY_RATE_BPS) revert PenaltyRateExceedsMax();
        if (_params.withdrawalGracePeriod > MAX_WITHDRAWAL_GRACE_PERIOD) revert GracePeriodExceedsMax();
        // A minimum above the cap would make every deposit revert.
        if (_params.minimumDepositAmount > _params.initialCapacity) revert InvalidDepositAmount();
    }

    // ============ Config Setters (onlyVaultManager) ============

    /// @dev Reads the role from the RoleManager on every call, so a revocation applies immediately.
    modifier onlyVaultManager() {
        _requireVaultManager();
        _;
    }

    function _requireVaultManager() internal view virtual {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002a0000, 1037618708522) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002a0001, 0) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002a0004, 0) }
        if (!_getConfigStorage().roleManager.isVaultManager(msg.sender)) revert NotVaultManager();
    }

    /// @dev Exclusive upper bound for `feeBps`: the lower of the current and any scheduled rate.
    function _feeCeilingRateBps() internal view virtual returns (uint256);

    // ============ Shared Helpers ============

    /// @dev ERC-4626 virtual-share offset; 0 means shares mirror the asset's decimals.
    function _decimalsOffset() internal pure returns (uint8) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002d0000, 1037618708525) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002d0001, 0) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002d0004, 0) }
        return 0;
    }

    /// @dev Best-effort `decimals()` read; returns 18 if the call fails or the value exceeds uint8.
    function _tryGetAssetDecimals(IERC20 asset_) internal view returns (uint8) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002e0000, 1037618708526) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002e0001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002e0005, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff002e6000, asset_) }
        (bool success, bytes memory returnData) =
            address(asset_).staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00010026,0)}

        if (success && returnData.length >= 32) {
            uint256 returnedDecimals = abi.decode(returnData, (uint256));
            if (returnedDecimals <= type(uint8).max) {
                // forge-lint: disable-next-line(unsafe-typecast) -- bounds-checked above
                return uint8(returnedDecimals);
            }
        }
        return 18;
    }
}
