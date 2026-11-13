// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { LoanVaultWithdrawals } from "./LoanVaultWithdrawals.sol";

/// @title LoanVaultBorrower
/// @author Axcess Protocol
/// @notice Borrow/repay, deposit cap, termination and borrower reassignment.
abstract contract LoanVaultBorrower is LoanVaultWithdrawals {
    /// @dev Per-vault borrower, not a protocol role; changed only via `setBorrower`.
    modifier onlyBorrower() {
        if (msg.sender != _getDepositsStorage().borrower) revert NotBorrower();
        _;
    }

    // ============ Storage ============
    bytes32 private constant LOAN_VAULT_BORROWER_STORAGE_SLOT =
        0x533e761e997b54f715dd5c8d9d5bec07afdad8e703e42acdec4d504768865200;

    /// @custom:storage-location erc7201:com.axcess.loanvault.borrower.storage
    struct LoanVaultBorrowerStorage {
        uint256 borrowedAmount; // principal drawn via borrow() and not yet repaid
    }

    function _getBorrowerStorage() internal pure returns (LoanVaultBorrowerStorage storage s) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00300000, 1037618708528) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00300001, 0) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00300004, 0) }
        bytes32 slot = LOAN_VAULT_BORROWER_STORAGE_SLOT;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000028,slot)}
        assembly {
            s.slot := slot
        }
    }

    // ============ Borrow / Repay ============

    /// @notice Sends `amount` of free liquidity to the borrower.
    function borrow(uint256 amount) external onlyBorrower whenWithdrawalsNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00010029,0)}
        if (ds.terminatedAt != 0) revert VaultTerminated();
        _accrueInterest();
        if (_unfundedPastGrace()) revert VaultDelinquent();

        LoanVaultBorrowerStorage storage bs = _getBorrowerStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0001002a,0)}

        if (amount > _borrowableLiquidity()) revert InsufficientFunds();

        bs.borrowedAmount += amount;uint256 certora_local55 = bs.borrowedAmount;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000037,certora_local55)}
        _payUsdc(ds.borrower, amount);
        _refreshDelinquency();
        emit Borrowed(ds.borrower, amount);
    }

    /// @notice Pays up to `amount` toward `amountOwed()`; anyone may pay. Reverts if nothing is owed.
    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrueInterest(); // bill penalty up to now against the still-delinquent state
        _settleRepayment(amount);
    }

    /// @notice Sets the deposit cap, in loan-asset units.
    function setVaultCapacity(uint256 newCapacity) external onlyVaultManager nonReentrant {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0001002b,0)}
        _accrueInterest();
        uint256 oldCapacity = ds.vaultCapacity;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0000002c,oldCapacity)}
        ds.vaultCapacity = newCapacity;uint256 certora_local56 = ds.vaultCapacity;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000038,certora_local56)}
        emit CapacityUpdated(
            oldCapacity, newCapacity, ds.terminatedAt != 0 && block.timestamp >= _accrualCutoff(ds) ? 0 : ds.totalAssets
        );
    }

    /// @notice Irreversibly starts wind-down; blocks deposits, borrowing, redeem requests and funding.
    function terminate() external onlyVaultManager nonReentrant {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0001002d,0)}
        if (ds.terminatedAt != 0) revert VaultTerminated();
        _accrueInterest(); // flush the segment up to now before the wind-down clock starts
        uint256 owed = _fundingDeficit(ds.totalAssets, ds.accruedFees);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0000002e,owed)}
        // Drop any pending rate change: the remaining accrual window runs at the current rate.
        if (ds.rateActivationEpoch != 0) {
            delete ds.pendingInterestRateBps;
            delete ds.rateActivationEpoch;
        }
        ds.terminatedAt = block.timestamp;uint256 certora_local57 = ds.terminatedAt;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000039,certora_local57)} // accrual continues through _accrualCutoff, then freezes
        // A shortfall anchor survives termination (penalty bills to the cutoff); `repay()` still cures it.
        _refreshDelinquency();
        emit Terminated(ds.totalAssets, owed, block.timestamp);
    }

    /// @notice Replaces the borrower; the new one inherits the outstanding obligation.
    function setBorrower(address newBorrower) external onlyVaultManager {
        if (newBorrower == address(0)) revert BorrowerCannotBeZeroAddress();
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0001002f,0)}
        address oldBorrower = ds.borrower;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000030,oldBorrower)}
        if (newBorrower == oldBorrower) revert BorrowerUnchanged();

        ds.borrower = newBorrower;address certora_local58 = ds.borrower;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0000003a,certora_local58)}
        emit BorrowerUpdated(oldBorrower, newBorrower);
    }

    // ============ Internal Helpers ============

    /// @dev Borrower obligation: pool + `reservedAssets` + fees - (held + recovery paid), floored at 0.
    function _fundingDeficit(uint256 totalAssetsValue, uint256 feesValue) internal view returns (uint256) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00310000, 1037618708529) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00310001, 2) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00310005, 9) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00316001, feesValue) }
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00010031,0)}
        // No matured-redemption term: matured escrow stays inside `totalAssets` until funded.
        uint256 required = totalAssetsValue + ds.reservedAssets + feesValue;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000032,required)}
        // Recovery already paid discharged part of the debt (non-zero only after termination).
        uint256 held = _heldAssetsUsdc() + ds.totalRecoveryPaid;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000033,held)}
        return required > held ? required - held : 0;
    }

    /// @dev Shared by `repay()`/`repayAll()`; callers accrue first. Clamps `amount` to the deficit.
    function _settleRepayment(uint256 amount) internal {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00320000, 1037618708530) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00320001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00320005, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00326000, amount) }
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00010034,0)}
        uint256 owed = _fundingDeficit(ds.totalAssets, ds.accruedFees);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000035,owed)}
        if (owed == 0) revert ZeroAmount();
        if (amount > owed) amount = owed;
        LoanVaultBorrowerStorage storage bs = _getBorrowerStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00010036,0)}
        bs.borrowedAmount = amount >= bs.borrowedAmount ? 0 : bs.borrowedAmount - amount;uint256 certora_local59 = bs.borrowedAmount;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0000003b,certora_local59)}
        _pullUsdc(msg.sender, amount);
        _fundMaturedIfCovered(ds);
        _refreshDelinquency();
        emit Repaid(ds.borrower, msg.sender, amount);
    }
}
