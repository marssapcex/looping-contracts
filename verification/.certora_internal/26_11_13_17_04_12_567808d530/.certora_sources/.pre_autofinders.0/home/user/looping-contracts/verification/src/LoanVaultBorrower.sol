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

    function _getBorrowerStorage() internal pure returns (LoanVaultBorrowerStorage storage s) {
        bytes32 slot = LOAN_VAULT_BORROWER_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    // ============ Borrow / Repay ============

    /// @notice Sends `amount` of free liquidity to the borrower.
    function borrow(uint256 amount) external onlyBorrower whenWithdrawalsNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        if (ds.terminatedAt != 0) revert VaultTerminated();
        _accrueInterest();
        if (_unfundedPastGrace()) revert VaultDelinquent();

        LoanVaultBorrowerStorage storage bs = _getBorrowerStorage();

        if (amount > _borrowableLiquidity()) revert InsufficientFunds();

        bs.borrowedAmount += amount;
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
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        _accrueInterest();
        uint256 oldCapacity = ds.vaultCapacity;
        ds.vaultCapacity = newCapacity;
        emit CapacityUpdated(
            oldCapacity, newCapacity, ds.terminatedAt != 0 && block.timestamp >= _accrualCutoff(ds) ? 0 : ds.totalAssets
        );
    }

    /// @notice Irreversibly starts wind-down; blocks deposits, borrowing, redeem requests and funding.
    function terminate() external onlyVaultManager nonReentrant {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        if (ds.terminatedAt != 0) revert VaultTerminated();
        _accrueInterest(); // flush the segment up to now before the wind-down clock starts
        uint256 owed = _fundingDeficit(ds.totalAssets, ds.accruedFees);
        // Drop any pending rate change: the remaining accrual window runs at the current rate.
        if (ds.rateActivationEpoch != 0) {
            delete ds.pendingInterestRateBps;
            delete ds.rateActivationEpoch;
        }
        ds.terminatedAt = block.timestamp; // accrual continues through _accrualCutoff, then freezes
        // A shortfall anchor survives termination (penalty bills to the cutoff); `repay()` still cures it.
        _refreshDelinquency();
        emit Terminated(ds.totalAssets, owed, block.timestamp);
    }

    /// @notice Replaces the borrower; the new one inherits the outstanding obligation.
    function setBorrower(address newBorrower) external onlyVaultManager {
        if (newBorrower == address(0)) revert BorrowerCannotBeZeroAddress();
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        address oldBorrower = ds.borrower;
        if (newBorrower == oldBorrower) revert BorrowerUnchanged();

        ds.borrower = newBorrower;
        emit BorrowerUpdated(oldBorrower, newBorrower);
    }

    // ============ Internal Helpers ============

    /// @dev Borrower obligation: pool + `reservedAssets` + fees - (held + recovery paid), floored at 0.
    function _fundingDeficit(uint256 totalAssetsValue, uint256 feesValue) internal view returns (uint256) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        // No matured-redemption term: matured escrow stays inside `totalAssets` until funded.
        uint256 required = totalAssetsValue + ds.reservedAssets + feesValue;
        // Recovery already paid discharged part of the debt (non-zero only after termination).
        uint256 held = _heldAssetsUsdc() + ds.totalRecoveryPaid;
        return required > held ? required - held : 0;
    }

    /// @dev Shared by `repay()`/`repayAll()`; callers accrue first. Clamps `amount` to the deficit.
    function _settleRepayment(uint256 amount) internal {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        uint256 owed = _fundingDeficit(ds.totalAssets, ds.accruedFees);
        if (owed == 0) revert ZeroAmount();
        if (amount > owed) amount = owed;
        LoanVaultBorrowerStorage storage bs = _getBorrowerStorage();
        bs.borrowedAmount = amount >= bs.borrowedAmount ? 0 : bs.borrowedAmount - amount;
        _pullUsdc(msg.sender, amount);
        _fundMaturedIfCovered(ds);
        _refreshDelinquency();
        emit Repaid(ds.borrower, msg.sender, amount);
    }
}
