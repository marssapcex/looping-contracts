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

    function _getWithdrawalsStorage() internal pure returns (LoanVaultWithdrawalsStorage storage s) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00520000, 1037618708562) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00520001, 0) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00520004, 0) }
        bytes32 slot = LOAN_VAULT_WITHDRAWALS_STORAGE_SLOT;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000a9,slot)}
        assembly {
            s.slot := slot
        }
    }

    // ============ Liquidity Helpers ============

    /// @dev Cash to hold back: funded pot plus matured unfunded liability. Stored state; accrue first.
    function _requiredVaultBalance() internal view returns (uint256) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00530000, 1037618708563) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00530001, 0) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00530004, 0) }
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100aa,0)}
        return ds.reservedAssets + _maturedLiability(ds.maturedRedeemShares, ds.totalAssets, totalSupply());
    }

    /// @dev Held cash above `_requiredVaultBalance`; the fee-sweep ceiling, so it does not net out `accruedFees`.
    function _freeLiquidity() internal view returns (uint256) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00550000, 1037618708565) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00550001, 0) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00550004, 0) }
        uint256 held = _heldAssetsUsdc();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000ab,held)}
        uint256 reserved = _requiredVaultBalance();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000ac,reserved)}
        return held > reserved ? held - reserved : 0;
    }

    /// @dev Free liquidity less `accruedFees`, so the borrower cannot draw the cash backing the fee.
    function _borrowableLiquidity() internal view returns (uint256) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00560000, 1037618708566) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00560001, 0) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00560004, 0) }
        uint256 free = _freeLiquidity();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000ad,free)}
        uint256 fees = _getDepositsStorage().accruedFees;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000ae,fees)}
        return free > fees ? free - fees : 0;
    }

    /// @dev Projected twin of `_borrowableLiquidity`, so views never advertise more than `borrow()` allows.
    function _freeLiquidityProjected() internal view returns (uint256) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00540000, 1037618708564) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00540001, 0) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00540004, 0) }
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100af,0)}
        (uint256 projAssets, uint256 projFees, uint256 projMaturedShares) = _projectedPoolNow();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100b0,0)}
        uint256 reserved =
            ds.reservedAssets + _maturedLiability(projMaturedShares, projAssets, totalSupply()) + projFees;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000b1,reserved)}
        uint256 held = _heldAssetsUsdc();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000b2,held)}
        return held > reserved ? held - reserved : 0;
    }

    // ============ Redeem requests ============

    /// @notice Escrows the caller's `shares` for redemption at a future epoch boundary.
    /// @return requestId The claimable epoch
    function requestRedeem(uint256 shares) external whenWithdrawalsNotPaused nonReentrant returns (uint256 requestId) {
        if (shares == 0) revert ZeroShares();

        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100b3,0)}
        // Checked before the registry so a revoked caller on a terminated vault gets VaultTerminated.
        if (ds.terminatedAt != 0) revert VaultTerminated();
        _accrueInterest();

        _requireApprovedLender(msg.sender);
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        uint256 claimableEpoch =
            VaultAccountingLib.getWithdrawalTiming(ds.genesisTimestamp, ds.epochDuration, ds.withdrawalNotice);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000b4,claimableEpoch)}

        ds.scheduledWithdrawalShares[claimableEpoch] += shares;uint256 certora_local236 = ds.scheduledWithdrawalShares[claimableEpoch];assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000ec,certora_local236)}
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
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100b5,0)}
        WithdrawalQueueLibrary.WithdrawalQueue storage queue = ws.userWithdrawalQueue[controller];assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100b6,0)}
        uint256 fundedThrough = ws.fundedThroughEpoch;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000b7,fundedThrough)}

        for (uint128 idx = queue._head(); idx < queue._tail(); ++idx) {
            ILoanVault.WithdrawalRequest memory request = queue._peek(idx);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100fe,0)}
            if (request.claimableEpoch == requestId && request.claimableEpoch > fundedThrough) {
                shares += request.shares;
            }
        }
    }

    /// @notice Shares `controller` can claim now via `redeem`; 0 whenever `redeem` would revert.
    function claimableRedeemRequest(uint256, address controller) external view returns (uint256 shares) {
        if (_redeemBlocked(controller)) return 0;
        (, shares) = _previewClaim(controller);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000200ed,0)}
    }

    /// @dev True when `redeem()` would fail its guards: paused (unless terminated) or not approved.
    function _redeemBlocked(address owner) internal view returns (bool) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00570000, 1037618708567) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00570001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00570005, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00576000, owner) }
        if (withdrawalsPaused() && _getDepositsStorage().terminatedAt == 0) return true;
        return !_isApprovedLender(owner);
    }

    /// @dev Claimable assets and shares for `controller`; must match `_redeem`'s walk exactly.
    function _previewClaim(address controller) internal view returns (uint256 netAssets, uint256 totalShares) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00580000, 1037618708568) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00580001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00580005, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00586000, controller) }
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100b8,0)}
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100b9,0)}
        WithdrawalQueueLibrary.WithdrawalQueue storage queue = ws.userWithdrawalQueue[controller];assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100ba,0)}
        uint256 fundedThrough = ws.fundedThroughEpoch;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000bb,fundedThrough)}

        for (uint128 idx = queue._head(); idx < queue._tail(); ++idx) {
            ILoanVault.WithdrawalRequest memory request = queue._peek(idx);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100ff,0)}
            // Queue epochs are non-decreasing, so the funded requests form a prefix.
            if (request.claimableEpoch > fundedThrough) break;
            netAssets += _payoutFor(ws, ds, request.claimableEpoch, request.shares);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000104,netAssets)}
            totalShares += request.shares;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000105,totalShares)}
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
    {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00590000, 1037618708569) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00590001, 4) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00590005, 585) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00596003, shares) }
        uint256 epochShares = ds.scheduledWithdrawalShares[epoch];assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000bc,epochShares)}
        if (epochShares == 0) return 0;
        return Math.mulDiv(shares, ws.epochFundedAssets[epoch], epochShares);
    }

    // ============ Funding ============

    /// @notice Funds every matured redemption at one price, burning the shares and reserving the cash.
    function fundRedemptions() external nonReentrant {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100bd,0)}
        _accrueInterest();
        if (ds.terminatedAt != 0) revert VaultTerminated();

        uint256 shares = ds.maturedRedeemShares;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000be,shares)}
        if (shares == 0) revert NothingMatured();

        uint256 supplyBefore = totalSupply();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000bf,supplyBefore)}
        uint256 need = _maturedLiability(shares, ds.totalAssets, supplyBefore);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000c0,need)}
        if (_cashForClaims(ds) < need) revert InsufficientFunds();

        _fundRedemptions(ds, shares, need, supplyBefore);
    }

    /// @dev `repay()` hook: funds matured redemptions if the cash covers them, else skips silently.
    function _fundMaturedIfCovered(LoanVaultDepositsStorage storage ds) internal {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005a0000, 1037618708570) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005a0001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005a0005, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005a6000, ds.slot) }
        if (ds.terminatedAt != 0) return;
        uint256 shares = ds.maturedRedeemShares;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000c1,shares)}
        if (shares == 0) return;
        uint256 supplyBefore = totalSupply();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000c2,supplyBefore)}
        uint256 need = _maturedLiability(shares, ds.totalAssets, supplyBefore);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000c3,need)}
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
    {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005b0000, 1037618708571) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005b0001, 4) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005b0005, 585) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005b6003, supplyBefore) }
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100c4,0)}
        // Split `need` pro-rata by shares; rounding dust goes to the last epoch so the parts sum to `need`.
        uint256 currentEp = VaultAccountingLib.currentEpoch(ds.genesisTimestamp, ds.epochDuration);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000c5,currentEp)}
        uint256 allocated;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000c6,allocated)}
        uint256 lastEpochWithShares;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000c7,lastEpochWithShares)}
        for (uint256 e = ws.fundedThroughEpoch + 1; e <= currentEp; ++e) {
            uint256 epochShares = ds.scheduledWithdrawalShares[e];assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000100,epochShares)}
            if (epochShares == 0) continue;
            uint256 alloc = Math.mulDiv(epochShares, need, shares);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000101,alloc)}
            ws.epochFundedAssets[e] = alloc;uint256 certora_local262 = ws.epochFundedAssets[e];assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000106,certora_local262)}
            allocated += alloc;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000107,allocated)}
            lastEpochWithShares = e;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000108,lastEpochWithShares)}
        }
        if (lastEpochWithShares != 0 && allocated < need) {
            ws.epochFundedAssets[lastEpochWithShares] += need - allocated;
        }
        ws.fundedThroughEpoch = currentEp;uint256 certora_local238 = ws.fundedThroughEpoch;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000ee,certora_local238)}

        _burn(address(this), shares);
        ds.totalAssets = ds.totalAssets > need ? ds.totalAssets - need : 0;uint256 certora_local239 = ds.totalAssets;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000ef,certora_local239)}
        _resetBasePeriod(ds);
        ds.reservedAssets += need;uint256 certora_local240 = ds.reservedAssets;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000f0,certora_local240)}
        ds.maturedRedeemShares = 0;uint256 certora_local241 = ds.maturedRedeemShares;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000f1,certora_local241)}
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

    function _redeem(address receiver) private returns (uint256 assets) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005c0000, 1037618708572) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005c0001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005c0005, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005c6000, receiver) }
        _requirePayee(receiver);
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100c8,0)}
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100c9,0)}
        if (ds.terminatedAt == 0) _requireWithdrawalsNotPaused();
        _requireApprovedLender(msg.sender);
        _accrueInterest();

        WithdrawalQueueLibrary.WithdrawalQueue storage queue = ws.userWithdrawalQueue[msg.sender];assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100ca,0)}
        if (queue._isEmpty()) revert NoPendingWithdrawal();

        uint256 fundedThrough = ws.fundedThroughEpoch;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000cb,fundedThrough)}
        uint256 totalShares;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000cc,totalShares)}
        while (!queue._isEmpty()) {
            ILoanVault.WithdrawalRequest memory request = queue._peek(queue._head());assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00010102,0)}
            if (request.claimableEpoch > fundedThrough) break;
            assets += _payoutFor(ws, ds, request.claimableEpoch, request.shares);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00000109,assets)}
            totalShares += request.shares;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0000010a,totalShares)}
            queue._dequeueFront();
        }
        if (totalShares == 0) revert NotYetClaimable();

        // `held` and `reservedAssets` drop together, so a claim cannot move `_cashForClaims`.
        ds.reservedAssets -= assets;uint256 certora_local242 = ds.reservedAssets;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000f2,certora_local242)}
        // `_payUsdc` re-stamps the watermark; the zero-payout path must stamp it too.
        if (assets != 0) _payUsdc(receiver, assets);
        else _stampCashWatermark();

        _refreshDelinquency();
        emit Withdraw(msg.sender, receiver, msg.sender, assets, totalShares);
    }

    /// @dev Rejects the zero address and the vault itself.
    function _requirePayee(address receiver) private view {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005d0000, 1037618708573) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005d0001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005d0005, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005d6000, receiver) }
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

    function _claimRecovery(address receiver) private returns (uint256 pay) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005e0000, 1037618708574) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005e0001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005e0005, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005e6000, receiver) }
        _requirePayee(receiver);
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100cd,0)}
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100ce,0)}

        if (ds.terminatedAt == 0) revert VaultNotTerminated();
        _accrueInterest();
        if (block.timestamp < _accrualCutoff(ds)) revert NotYetClaimable();
        _requireApprovedLender(msg.sender);

        _snapshotResolution(ds);
        _returnEscrowedShares(ds, ws, msg.sender);

        uint256 units = balanceOf(msg.sender);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000cf,units)}
        if (units == 0) revert NothingToClaim();

        uint256 pool = _cashForClaims(ds) + ds.totalRecoveryPaid;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000d0,pool)}
        if (pool > ds.frozenAssets) pool = ds.frozenAssets;

        uint256 entitled = Math.mulDiv(units, pool, ds.resolutionShares);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000d1,entitled)}
        uint256 drawn = ws.claimedRecovery[msg.sender];assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000d2,drawn)}
        if (entitled <= drawn) revert NothingToClaim();
        pay = entitled - drawn;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000f3,pay)}

        ws.claimedRecovery[msg.sender] = entitled;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000200f4,0)}
        ds.totalRecoveryPaid += pay;uint256 certora_local245 = ds.totalRecoveryPaid;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000f5,certora_local245)}
        _payUsdc(receiver, pay);

        emit RecoveryClaimed(msg.sender, pay, pool);
    }

    /// @dev Freezes share supply and book value on the first claim past the accrual cutoff.
    function _snapshotResolution(LoanVaultDepositsStorage storage ds) private {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005f0000, 1037618708575) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005f0001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005f0005, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff005f6000, ds.slot) }
        if (ds.resolutionShares != 0) return;
        uint256 supply = totalSupply();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000d3,supply)}
        if (supply == 0) revert NothingToClaim();
        ds.resolutionShares = supply;uint256 certora_local246 = ds.resolutionShares;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000f6,certora_local246)}
        ds.frozenAssets = ds.totalAssets;uint256 certora_local247 = ds.frozenAssets;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000f7,certora_local247)}
        emit WindDownSnapshot(supply, ds.totalAssets);
    }

    /// @dev Returns a lender's unfunded escrowed shares (once) and drops those queue entries.
    function _returnEscrowedShares(
        LoanVaultDepositsStorage storage ds,
        LoanVaultWithdrawalsStorage storage ws,
        address lender
    )
        private
    {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00600000, 1037618708576) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00600001, 3) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00600005, 73) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00606002, lender) }
        if (ws.escrowReturned[lender]) return;

        WithdrawalQueueLibrary.WithdrawalQueue storage queue = ws.userWithdrawalQueue[lender];assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100d4,0)}
        uint256 fundedThrough = ws.fundedThroughEpoch;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000d5,fundedThrough)}
        // Capped at the cutoff epoch: accrual never matures anything past it.
        uint256 currentEp = VaultAccountingLib.currentEpoch(ds.genesisTimestamp, ds.epochDuration);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000d6,currentEp)}
        uint256 cutoff = _accrualCutoff(ds);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000d7,cutoff)}
        if (cutoff != type(uint256).max) {
            uint256 cutoffEp = VaultAccountingLib.epochAtTimestamp(cutoff, ds.genesisTimestamp, ds.epochDuration);
            if (currentEp > cutoffEp) currentEp = cutoffEp;
        }
        uint256 owed;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000d8,owed)}
        uint256 maturedOwed;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000d9,maturedOwed)}
        // Walk from the tail: funded requests form a prefix, so the unfunded escrow is the suffix.
        while (!queue._isEmpty()) {
            ILoanVault.WithdrawalRequest memory request = queue._peek(queue._tail() - 1);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00010103,0)}
            // Funded requests stay claimable via redeem().
            if (request.claimableEpoch <= fundedThrough) break;
            owed += request.shares;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0000010b,owed)}
            // Only matured epochs were counted in `maturedRedeemShares`.
            if (request.claimableEpoch <= currentEp) maturedOwed += request.shares;
            // Unschedule so a later boundary cannot re-mature these shares.
            ds.scheduledWithdrawalShares[request.claimableEpoch] -= request.shares;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff0002010c,0)}
            queue._dequeueBack();
        }
        if (owed == 0) return;

        // Latched only once shares move, so an empty walk can be retried.
        ws.escrowReturned[lender] = true;bool certora_local248 = ws.escrowReturned[lender];assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000f8,certora_local248)}
        ds.maturedRedeemShares = ds.maturedRedeemShares > maturedOwed ? ds.maturedRedeemShares - maturedOwed : 0;uint256 certora_local249 = ds.maturedRedeemShares;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000f9,certora_local249)}
        _transfer(address(this), lender, owed);
        emit EscrowReturned(lender, owed);
    }

    // ============ Fees ============

    /// @notice Sweeps accrued protocol fees to `feeRecipient`.
    function collectFees() external onlyVaultManager nonReentrant {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100da,0)}
        _accrueInterest();

        uint256 amount = ds.accruedFees;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000db,amount)}
        if (amount == 0) revert ZeroAmount();
        address recipient = _getWithdrawalsStorage().feeRecipient;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000dc,recipient)}
        if (recipient == address(0)) revert FeeRecipientCannotBeZeroAddress();
        if (amount > _feeSweepable(ds)) revert InsufficientFunds();

        ds.accruedFees = 0;uint256 certora_local250 = ds.accruedFees;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000fa,certora_local250)}
        _payUsdc(recipient, amount);
        _refreshDelinquency();
        emit FeeCollected(recipient, amount);
    }

    /// @notice Post-cutoff, pays the borrower any cash above the outstanding lender book and accrued fee.
    function sweepResidual() external onlyVaultManager nonReentrant returns (uint256 swept) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100dd,0)}
        if (ds.terminatedAt == 0) revert VaultNotTerminated();
        _accrueInterest();
        if (block.timestamp < _accrualCutoff(ds)) revert NotYetClaimable();

        uint256 free = _feeSweepable(ds);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000de,free)} // cash above the outstanding lender book
        swept = free > ds.accruedFees ? free - ds.accruedFees : 0;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000fb,swept)}
        if (swept == 0) revert ZeroAmount();

        _payUsdc(ds.borrower, swept);
        emit ResidualSwept(ds.borrower, swept);
    }

    /// @dev Cash the fee may draw: free liquidity while live; once terminated, cash above all lender claims.
    function _feeSweepable(LoanVaultDepositsStorage storage ds) private view returns (uint256) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00610000, 1037618708577) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00610001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00610005, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00616000, ds.slot) }
        if (ds.terminatedAt == 0) return _freeLiquidity();

        // The lender book is final only at the accrual cutoff; sweeping earlier could jump ahead of it.
        if (block.timestamp < _accrualCutoff(ds)) return 0;

        // Lenders are owed the frozen book (or the pool, before the snapshot) less recovery paid.
        uint256 lenderBook = ds.resolutionShares != 0 ? ds.frozenAssets : ds.totalAssets;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000df,lenderBook)}
        uint256 outstanding = lenderBook > ds.totalRecoveryPaid ? lenderBook - ds.totalRecoveryPaid : 0;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000e0,outstanding)}

        uint256 cash = _cashForClaims(ds);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000e1,cash)} // already nets out the funded-but-unclaimed pot
        return cash > outstanding ? cash - outstanding : 0;
    }

    /// @notice Sets the fee recipient; reverts on the zero address.
    function setFeeRecipient(address newRecipient) external onlyVaultManager {
        if (newRecipient == address(0)) revert FeeRecipientCannotBeZeroAddress();
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100e2,0)}
        address old = ws.feeRecipient;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000e3,old)}
        ws.feeRecipient = newRecipient;address certora_local252 = ws.feeRecipient;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000fc,certora_local252)}
        emit FeeRecipientUpdated(old, newRecipient);
    }

    /// @notice Accrued protocol fees awaiting `collectFees()`, projected to now.
    function accruedFees() external view returns (uint256) {
        (, uint256 projFees,) = _projectedPoolNow();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100e4,0)}
        return projFees;
    }

    /// @notice Every epoch at or below this has been funded in full.
    function fundedThroughEpoch() external view returns (uint256) {
        return _getWithdrawalsStorage().fundedThroughEpoch;
    }

    /// @notice Extra cash `fundRedemptions()` needs to succeed now (0 if covered or terminated).
    function redemptionFundingShortfall() external view returns (uint256) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100e5,0)}
        if (ds.terminatedAt != 0) return 0;

        (uint256 projAssets,, uint256 projMatured) = _projectedPoolNow();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100e6,0)}
        if (projMatured == 0) return 0;

        uint256 need = _maturedLiability(projMatured, projAssets, totalSupply());assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000e7,need)}
        uint256 cash = _cashForClaims(ds);assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000e8,cash)}
        return need > cash ? need - cash : 0;
    }

    /// @notice Wind-down recovery already drawn by `lender`.
    function claimedRecovery(address lender) external view returns (uint256) {
        return _getWithdrawalsStorage().claimedRecovery[lender];
    }

    /// @notice Wind-down share count and frozen book; both 0 until the first `claimRecovery()`.
    function resolutionSnapshot() external view returns (uint256 shares, uint256 frozenBook) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100e9,0)}
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
    {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00630000, 1037618708579) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00630001, 4) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00630005, 585) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00636003, claimableEpoch) }
        WithdrawalQueueLibrary.WithdrawalQueue storage queue = ws.userWithdrawalQueue[controller];assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100ea,0)}

        if (!queue._isEmpty()) {
            ILoanVault.WithdrawalRequest storage lastRequest = queue._backMut();
            if (lastRequest.claimableEpoch == claimableEpoch) {
                lastRequest.shares += shares;
                return;
            }
        }
        queue._enqueue(ILoanVault.WithdrawalRequest({ shares: shares, claimableEpoch: claimableEpoch }));
    }

    function _initializeWithdrawalsStorage(ConstructorParams calldata _params) internal {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00620000, 1037618708578) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00620001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00620005, 4) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00626200, _params) }
        LoanVaultWithdrawalsStorage storage s = _getWithdrawalsStorage();assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000100eb,0)}
        s.feeRecipient = _params.feeRecipient;address certora_local253 = s.feeRecipient;assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff000000fd,certora_local253)}
    }
}
