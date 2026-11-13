// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { LoanVaultDeposits } from "./LoanVaultDeposits.sol";
import { VaultAccountingLib } from "./VaultAccountingLib.sol";
import { WithdrawalQueueLibrary } from "./WithdrawalQueueLibrary.sol";
import { ILoanVault } from "./interfaces/ILoanVault.sol";

/// @title LoanVaultWithdrawals
/// @author Axcess Protocol
/// @notice ERC-7540-style async redemptions (request -> fund -> claim), wind-down recovery and fee sweep.
abstract contract LoanVaultWithdrawals is LoanVaultDeposits {
    using WithdrawalQueueLibrary for WithdrawalQueueLibrary.WithdrawalQueue;

    // ============ Storage ============
    bytes32 private constant LOAN_VAULT_WITHDRAWALS_STORAGE_SLOT =
        0x0f22b21bc2cca331f000138790d008f6fde42ad89895b8069425c37e5784e600;

    /// @custom:storage-location erc7201:com.axcess.loanvault.withdrawals.storage
    struct LoanVaultWithdrawalsStorage {
        // Per-controller FIFO of redemption requests; their shares sit in escrow until funded.
        mapping(address => WithdrawalQueueLibrary.WithdrawalQueue) userWithdrawalQueue;
        address feeRecipient;
        // Assets reserved per epoch, written once at funding; one assets-per-share for the whole epoch.
        mapping(uint256 => uint256) epochFundedAssets;
        // Every epoch <= this is fully funded. Monotone.
        uint256 fundedThroughEpoch;
        // Wind-down recovery drawn per lender. Address keying is safe: transfers stop at termination.
        mapping(address => uint256) claimedRecovery;
        // Wind-down: lenders whose escrowed shares were returned.
        mapping(address => bool) escrowReturned;
    }

    function _getWithdrawalsStorage() internal pure returns (LoanVaultWithdrawalsStorage storage s) {
        bytes32 slot = LOAN_VAULT_WITHDRAWALS_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    // ============ Liquidity Helpers ============

    /// @dev Cash to hold back: funded pot plus matured unfunded liability. Stored state; accrue first.
    function _requiredVaultBalance() internal view returns (uint256) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        return ds.reservedAssets + _maturedLiability(ds.maturedRedeemShares, ds.totalAssets, totalSupply());
    }

    /// @dev Held cash above `_requiredVaultBalance`; the fee-sweep ceiling, so it does not net out `accruedFees`.
    function _freeLiquidity() internal view returns (uint256) {
        uint256 held = _heldAssetsUsdc();
        uint256 reserved = _requiredVaultBalance();
        return held > reserved ? held - reserved : 0;
    }

    /// @dev Free liquidity less `accruedFees`, so the borrower cannot draw the cash backing the fee.
    function _borrowableLiquidity() internal view returns (uint256) {
        uint256 free = _freeLiquidity();
        uint256 fees = _getDepositsStorage().accruedFees;
        return free > fees ? free - fees : 0;
    }

    /// @dev Projected twin of `_borrowableLiquidity`, so views never advertise more than `borrow()` allows.
    function _freeLiquidityProjected() internal view returns (uint256) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        (uint256 projAssets, uint256 projFees, uint256 projMaturedShares) = _projectedPoolNow();
        uint256 reserved =
            ds.reservedAssets + _maturedLiability(projMaturedShares, projAssets, totalSupply()) + projFees;
        uint256 held = _heldAssetsUsdc();
        return held > reserved ? held - reserved : 0;
    }

    // ============ Redeem requests ============

    /// @notice Escrows the caller's `shares` for redemption at a future epoch boundary.
    /// @return requestId The claimable epoch
    function requestRedeem(uint256 shares) external whenWithdrawalsNotPaused nonReentrant returns (uint256 requestId) {
        if (shares == 0) revert ZeroShares();

        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        // Checked before the registry so a revoked caller on a terminated vault gets VaultTerminated.
        if (ds.terminatedAt != 0) revert VaultTerminated();
        _accrueInterest();

        _requireApprovedLender(msg.sender);
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        uint256 claimableEpoch =
            VaultAccountingLib.getWithdrawalTiming(ds.genesisTimestamp, ds.epochDuration, ds.withdrawalNotice);

        ds.scheduledWithdrawalShares[claimableEpoch] += shares;
        _enqueueRequest(_getWithdrawalsStorage(), msg.sender, shares, claimableEpoch);

        // `canTransfer` admits shares into escrow only while this flag is set.
        escrowInFlight = true;
        _transfer(msg.sender, address(this), shares);
        escrowInFlight = false;

        _refreshDelinquency();
        emit RedeemRequest(msg.sender, msg.sender, claimableEpoch, msg.sender, shares);
        return claimableEpoch;
    }

    /// @notice Unfunded shares `controller` has queued for `requestId` (the claimable epoch).
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares) {
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();
        WithdrawalQueueLibrary.WithdrawalQueue storage queue = ws.userWithdrawalQueue[controller];
        uint256 fundedThrough = ws.fundedThroughEpoch;

        for (uint128 idx = queue._head(); idx < queue._tail(); ++idx) {
            ILoanVault.WithdrawalRequest memory request = queue._peek(idx);
            if (request.claimableEpoch == requestId && request.claimableEpoch > fundedThrough) {
                shares += request.shares;
            }
        }
    }

    /// @notice Shares `controller` can claim now via `redeem`; 0 whenever `redeem` would revert.
    function claimableRedeemRequest(uint256, address controller) external view returns (uint256 shares) {
        if (_redeemBlocked(controller)) return 0;
        (, shares) = _previewClaim(controller);
    }

    /// @dev True when `redeem()` would fail its guards: paused (unless terminated) or not approved.
    function _redeemBlocked(address owner) internal view returns (bool) {
        if (withdrawalsPaused() && _getDepositsStorage().terminatedAt == 0) return true;
        return !_isApprovedLender(owner);
    }

    /// @dev Claimable assets and shares for `controller`; must match `_redeem`'s walk exactly.
    function _previewClaim(address controller) internal view returns (uint256 netAssets, uint256 totalShares) {
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        WithdrawalQueueLibrary.WithdrawalQueue storage queue = ws.userWithdrawalQueue[controller];
        uint256 fundedThrough = ws.fundedThroughEpoch;

        for (uint128 idx = queue._head(); idx < queue._tail(); ++idx) {
            ILoanVault.WithdrawalRequest memory request = queue._peek(idx);
            // Queue epochs are non-decreasing, so the funded requests form a prefix.
            if (request.claimableEpoch > fundedThrough) break;
            netAssets += _payoutFor(ws, ds, request.claimableEpoch, request.shares);
            totalShares += request.shares;
        }
    }

    /// @dev Pro-rata cut of the epoch's funded assets, rounded down; claim order is irrelevant.
    function _payoutFor(
        LoanVaultWithdrawalsStorage storage ws,
        LoanVaultDepositsStorage storage ds,
        uint256 epoch,
        uint256 shares
    )
        private
        view
        returns (uint256)
    {
        uint256 epochShares = ds.scheduledWithdrawalShares[epoch];
        if (epochShares == 0) return 0;
        return Math.mulDiv(shares, ws.epochFundedAssets[epoch], epochShares);
    }

    // ============ Funding ============

    /// @notice Funds every matured redemption at one price, burning the shares and reserving the cash.
    function fundRedemptions() external nonReentrant {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        _accrueInterest();
        if (ds.terminatedAt != 0) revert VaultTerminated();

        uint256 shares = ds.maturedRedeemShares;
        if (shares == 0) revert NothingMatured();

        uint256 supplyBefore = totalSupply();
        uint256 need = _maturedLiability(shares, ds.totalAssets, supplyBefore);
        if (_cashForClaims(ds) < need) revert InsufficientFunds();

        _fundRedemptions(ds, shares, need, supplyBefore);
    }

    /// @dev `repay()` hook: funds matured redemptions if the cash covers them, else skips silently.
    function _fundMaturedIfCovered(LoanVaultDepositsStorage storage ds) internal {
        if (ds.terminatedAt != 0) return;
        uint256 shares = ds.maturedRedeemShares;
        if (shares == 0) return;
        uint256 supplyBefore = totalSupply();
        uint256 need = _maturedLiability(shares, ds.totalAssets, supplyBefore);
        if (_cashForClaims(ds) < need) return;
        _fundRedemptions(ds, shares, need, supplyBefore);
    }

    /// @dev Callers accrue and check the preconditions first.
    function _fundRedemptions(
        LoanVaultDepositsStorage storage ds,
        uint256 shares,
        uint256 need,
        uint256 supplyBefore
    )
        private
    {
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();
        // Split `need` pro-rata by shares; rounding dust goes to the last epoch so the parts sum to `need`.
        uint256 currentEp = VaultAccountingLib.currentEpoch(ds.genesisTimestamp, ds.epochDuration);
        uint256 allocated;
        uint256 lastEpochWithShares;
        for (uint256 e = ws.fundedThroughEpoch + 1; e <= currentEp; ++e) {
            uint256 epochShares = ds.scheduledWithdrawalShares[e];
            if (epochShares == 0) continue;
            uint256 alloc = Math.mulDiv(epochShares, need, shares);
            ws.epochFundedAssets[e] = alloc;
            allocated += alloc;
            lastEpochWithShares = e;
        }
        if (lastEpochWithShares != 0 && allocated < need) {
            ws.epochFundedAssets[lastEpochWithShares] += need - allocated;
        }
        ws.fundedThroughEpoch = currentEp;

        _burn(address(this), shares);
        ds.totalAssets = ds.totalAssets > need ? ds.totalAssets - need : 0;
        _resetBasePeriod(ds);
        ds.reservedAssets += need;
        ds.maturedRedeemShares = 0;
        // `reservedAssets` moved with no transfer; re-stamp or the watermark stays stale-high by `need`.
        _stampCashWatermark();

        _refreshDelinquency();
        emit RedemptionsFunded(currentEp, shares, need);
    }

    // ============ Claims ============

    /// @notice Claims all of the caller's funded requests; their shares were burned at funding.
    function redeem() external nonReentrant returns (uint256 assets) {
        return _redeem(msg.sender);
    }

    /// @notice `redeem()` paying `receiver`; the claimant is still `msg.sender`.
    function redeem(address receiver) external nonReentrant returns (uint256 assets) {
        return _redeem(receiver);
    }

    function _redeem(address receiver) private returns (uint256 assets) {
        _requirePayee(receiver);
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();
        if (ds.terminatedAt == 0) _requireWithdrawalsNotPaused();
        _requireApprovedLender(msg.sender);
        _accrueInterest();

        WithdrawalQueueLibrary.WithdrawalQueue storage queue = ws.userWithdrawalQueue[msg.sender];
        if (queue._isEmpty()) revert NoPendingWithdrawal();

        uint256 fundedThrough = ws.fundedThroughEpoch;
        uint256 totalShares;
        while (!queue._isEmpty()) {
            ILoanVault.WithdrawalRequest memory request = queue._peek(queue._head());
            if (request.claimableEpoch > fundedThrough) break;
            assets += _payoutFor(ws, ds, request.claimableEpoch, request.shares);
            totalShares += request.shares;
            queue._dequeueFront();
        }
        if (totalShares == 0) revert NotYetClaimable();

        // `held` and `reservedAssets` drop together, so a claim cannot move `_cashForClaims`.
        ds.reservedAssets -= assets;
        // `_payUsdc` re-stamps the watermark; the zero-payout path must stamp it too.
        if (assets != 0) _payUsdc(receiver, assets);
        else _stampCashWatermark();

        _refreshDelinquency();
        emit Withdraw(msg.sender, receiver, msg.sender, assets, totalShares);
    }

    /// @dev Rejects the zero address and the vault itself.
    function _requirePayee(address receiver) private view {
        if (receiver == address(0)) revert ReceiverCannotBeZeroAddress();
        if (receiver == address(this)) revert InvalidReceiver();
    }

    // ============ Wind-down recovery ============

    /// @notice Claims the caller's pro-rata share of wind-down recovery once the accrual cutoff has passed.
    function claimRecovery() external nonReentrant returns (uint256 pay) {
        return _claimRecovery(msg.sender);
    }

    /// @notice `claimRecovery()` paying `receiver`; the entitlement stays keyed on `msg.sender`.
    function claimRecovery(address receiver) external nonReentrant returns (uint256 pay) {
        return _claimRecovery(receiver);
    }

    function _claimRecovery(address receiver) private returns (uint256 pay) {
        _requirePayee(receiver);
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();

        if (ds.terminatedAt == 0) revert VaultNotTerminated();
        _accrueInterest();
        if (block.timestamp < _accrualCutoff(ds)) revert NotYetClaimable();
        _requireApprovedLender(msg.sender);

        _snapshotResolution(ds);
        _returnEscrowedShares(ds, ws, msg.sender);

        uint256 units = balanceOf(msg.sender);
        if (units == 0) revert NothingToClaim();

        uint256 pool = _cashForClaims(ds) + ds.totalRecoveryPaid;
        if (pool > ds.frozenAssets) pool = ds.frozenAssets;

        uint256 entitled = Math.mulDiv(units, pool, ds.resolutionShares);
        uint256 drawn = ws.claimedRecovery[msg.sender];
        if (entitled <= drawn) revert NothingToClaim();
        pay = entitled - drawn;

        ws.claimedRecovery[msg.sender] = entitled;
        ds.totalRecoveryPaid += pay;
        _payUsdc(receiver, pay);

        emit RecoveryClaimed(msg.sender, pay, pool);
    }

    /// @dev Freezes share supply and book value on the first claim past the accrual cutoff.
    function _snapshotResolution(LoanVaultDepositsStorage storage ds) private {
        if (ds.resolutionShares != 0) return;
        uint256 supply = totalSupply();
        if (supply == 0) revert NothingToClaim();
        ds.resolutionShares = supply;
        ds.frozenAssets = ds.totalAssets;
        emit WindDownSnapshot(supply, ds.totalAssets);
    }

    /// @dev Returns a lender's unfunded escrowed shares (once) and drops those queue entries.
    function _returnEscrowedShares(
        LoanVaultDepositsStorage storage ds,
        LoanVaultWithdrawalsStorage storage ws,
        address lender
    )
        private
    {
        if (ws.escrowReturned[lender]) return;

        WithdrawalQueueLibrary.WithdrawalQueue storage queue = ws.userWithdrawalQueue[lender];
        uint256 fundedThrough = ws.fundedThroughEpoch;
        // Capped at the cutoff epoch: accrual never matures anything past it.
        uint256 currentEp = VaultAccountingLib.currentEpoch(ds.genesisTimestamp, ds.epochDuration);
        uint256 cutoff = _accrualCutoff(ds);
        if (cutoff != type(uint256).max) {
            uint256 cutoffEp = VaultAccountingLib.epochAtTimestamp(cutoff, ds.genesisTimestamp, ds.epochDuration);
            if (currentEp > cutoffEp) currentEp = cutoffEp;
        }
        uint256 owed;
        uint256 maturedOwed;
        // Walk from the tail: funded requests form a prefix, so the unfunded escrow is the suffix.
        while (!queue._isEmpty()) {
            ILoanVault.WithdrawalRequest memory request = queue._peek(queue._tail() - 1);
            // Funded requests stay claimable via redeem().
            if (request.claimableEpoch <= fundedThrough) break;
            owed += request.shares;
            // Only matured epochs were counted in `maturedRedeemShares`.
            if (request.claimableEpoch <= currentEp) maturedOwed += request.shares;
            // Unschedule so a later boundary cannot re-mature these shares.
            ds.scheduledWithdrawalShares[request.claimableEpoch] -= request.shares;
            queue._dequeueBack();
        }
        if (owed == 0) return;

        // Latched only once shares move, so an empty walk can be retried.
        ws.escrowReturned[lender] = true;
        ds.maturedRedeemShares = ds.maturedRedeemShares > maturedOwed ? ds.maturedRedeemShares - maturedOwed : 0;
        _transfer(address(this), lender, owed);
        emit EscrowReturned(lender, owed);
    }

    // ============ Fees ============

    /// @notice Sweeps accrued protocol fees to `feeRecipient`.
    function collectFees() external onlyVaultManager nonReentrant {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        _accrueInterest();

        uint256 amount = ds.accruedFees;
        if (amount == 0) revert ZeroAmount();
        address recipient = _getWithdrawalsStorage().feeRecipient;
        if (recipient == address(0)) revert FeeRecipientCannotBeZeroAddress();
        if (amount > _feeSweepable(ds)) revert InsufficientFunds();

        ds.accruedFees = 0;
        _payUsdc(recipient, amount);
        _refreshDelinquency();
        emit FeeCollected(recipient, amount);
    }

    /// @notice Post-cutoff, pays the borrower any cash above the outstanding lender book and accrued fee.
    function sweepResidual() external onlyVaultManager nonReentrant returns (uint256 swept) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        if (ds.terminatedAt == 0) revert VaultNotTerminated();
        _accrueInterest();
        if (block.timestamp < _accrualCutoff(ds)) revert NotYetClaimable();

        uint256 free = _feeSweepable(ds); // cash above the outstanding lender book
        swept = free > ds.accruedFees ? free - ds.accruedFees : 0;
        if (swept == 0) revert ZeroAmount();

        _payUsdc(ds.borrower, swept);
        emit ResidualSwept(ds.borrower, swept);
    }

    /// @dev Cash the fee may draw: free liquidity while live; once terminated, cash above all lender claims.
    function _feeSweepable(LoanVaultDepositsStorage storage ds) private view returns (uint256) {
        if (ds.terminatedAt == 0) return _freeLiquidity();

        // The lender book is final only at the accrual cutoff; sweeping earlier could jump ahead of it.
        if (block.timestamp < _accrualCutoff(ds)) return 0;

        // Lenders are owed the frozen book (or the pool, before the snapshot) less recovery paid.
        uint256 lenderBook = ds.resolutionShares != 0 ? ds.frozenAssets : ds.totalAssets;
        uint256 outstanding = lenderBook > ds.totalRecoveryPaid ? lenderBook - ds.totalRecoveryPaid : 0;

        uint256 cash = _cashForClaims(ds); // already nets out the funded-but-unclaimed pot
        return cash > outstanding ? cash - outstanding : 0;
    }

    /// @notice Sets the fee recipient; reverts on the zero address.
    function setFeeRecipient(address newRecipient) external onlyVaultManager {
        if (newRecipient == address(0)) revert FeeRecipientCannotBeZeroAddress();
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();
        address old = ws.feeRecipient;
        ws.feeRecipient = newRecipient;
        emit FeeRecipientUpdated(old, newRecipient);
    }

    /// @notice Accrued protocol fees awaiting `collectFees()`, projected to now.
    function accruedFees() external view returns (uint256) {
        (, uint256 projFees,) = _projectedPoolNow();
        return projFees;
    }

    /// @notice Every epoch at or below this has been funded in full.
    function fundedThroughEpoch() external view returns (uint256) {
        return _getWithdrawalsStorage().fundedThroughEpoch;
    }

    /// @notice Extra cash `fundRedemptions()` needs to succeed now (0 if covered or terminated).
    function redemptionFundingShortfall() external view returns (uint256) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        if (ds.terminatedAt != 0) return 0;

        (uint256 projAssets,, uint256 projMatured) = _projectedPoolNow();
        if (projMatured == 0) return 0;

        uint256 need = _maturedLiability(projMatured, projAssets, totalSupply());
        uint256 cash = _cashForClaims(ds);
        return need > cash ? need - cash : 0;
    }

    /// @notice Wind-down recovery already drawn by `lender`.
    function claimedRecovery(address lender) external view returns (uint256) {
        return _getWithdrawalsStorage().claimedRecovery[lender];
    }

    /// @notice Wind-down share count and frozen book; both 0 until the first `claimRecovery()`.
    function resolutionSnapshot() external view returns (uint256 shares, uint256 frozenBook) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        return (ds.resolutionShares, ds.frozenAssets);
    }

    // ============ Internal helpers ============

    /// @dev Appends, or merges into the back entry on the same epoch; queue epochs stay non-decreasing.
    function _enqueueRequest(
        LoanVaultWithdrawalsStorage storage ws,
        address controller,
        uint256 shares,
        uint256 claimableEpoch
    )
        internal
    {
        WithdrawalQueueLibrary.WithdrawalQueue storage queue = ws.userWithdrawalQueue[controller];

        if (!queue._isEmpty()) {
            ILoanVault.WithdrawalRequest storage lastRequest = queue._backMut();
            if (lastRequest.claimableEpoch == claimableEpoch) {
                lastRequest.shares += shares;
                return;
            }
        }
        queue._enqueue(ILoanVault.WithdrawalRequest({ shares: shares, claimableEpoch: claimableEpoch }));
    }

    function _initializeWithdrawalsStorage(ConstructorParams calldata _params) internal {
        LoanVaultWithdrawalsStorage storage s = _getWithdrawalsStorage();
        s.feeRecipient = _params.feeRecipient;
    }
}
