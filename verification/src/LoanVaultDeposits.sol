// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { LoanVaultBase } from "./LoanVaultBase.sol";
import { VaultAccountingLib } from "./VaultAccountingLib.sol";
import { IVaultLenderRegistry } from "./interfaces/IVaultLenderRegistry.sol";

/// @title LoanVaultDeposits
/// @author Axcess Protocol
/// @notice Deposits, interest accrual and epoch accounting.
/// @dev Shares mint at the live price. `_projectedPoolNow` is the exact view twin of accrual.
abstract contract LoanVaultDeposits is LoanVaultBase {
    using SafeERC20 for IERC20;

    // ============ Storage ============
    // Checked by StorageDerivation.t.sol.
    bytes32 private constant LOAN_VAULT_DEPOSITS_STORAGE_SLOT =
        0x262d722d2ab181bb3640b3ead694c3b840ad7f6766b89e81139e3c773ae3dc00;

    /// @dev ERC-7201 namespaced storage.
    /// @custom:storage-location erc7201:com.axcess.loanvault.deposits.storage
    struct LoanVaultDepositsStorage {
        // Set at initialization
        IERC20 loanAsset;
        uint8 assetDecimals;
        uint256 genesisTimestamp;
        uint256 interestRateBps;
        address borrower;
        // Borrower parameters
        uint256 vaultCapacity;
        uint256 minimumDepositAmount;
        // Lazy interest tracking
        uint256 totalAssets; // active pool (principal + accrued interest) as of lastAccrualTimestamp
        uint256 lastAccrualTimestamp;
        // Epoch => shares escrowed to mature at its start. Shares only, never priced; accrual folds
        // each matured epoch into `maturedRedeemShares` exactly once.
        mapping(uint256 => uint256) scheduledWithdrawalShares;
        // Per-vault lender gating
        IVaultLenderRegistry lenderRegistry;
        // Delinquency penalty
        uint256 penaltyRateBps; // extra APR (bps) charged while the vault is delinquent
        uint256 withdrawalGracePeriod; // seconds after a withdrawal's due time before penalty starts
        // Matured, unfunded escrowed shares. Still in the pool, earning base and penalty until funded.
        uint256 maturedRedeemShares;
        // 0 = healthy; else when the shortfall began (retroactive to the missed boundary).
        uint256 delinquencyDueTimestamp;
        // 0 = live; else the terminate() time. All interest accrues to the end of that epoch, then freezes.
        uint256 terminatedAt;
        // Scheduled rate change, active from the start of rateActivationEpoch (0 = none).
        uint256 pendingInterestRateBps; // meaningful only while rateActivationEpoch != 0
        uint256 rateActivationEpoch;
        // False = shares are exit-only; true = wallet-to-wallet transfers, with no registry check.
        bool transfersEnabled;
        uint256 accruedFees;
        // Cash funded for burned shares, awaiting `redeem()`. Ring-fenced: excluded from liquidity,
        // the delinquency test and the recovery pool.
        uint256 reservedAssets;
        // Wind-down denominator: supply frozen at the first `claimRecovery` past the cutoff (0 until then).
        uint256 resolutionShares;
        // Book value frozen with `resolutionShares`; caps recovery at par.
        uint256 frozenAssets;
        // Recovery paid so far. Recovery pool = held - reservedAssets + totalRecoveryPaid.
        uint256 totalRecoveryPaid;
        // `_cashForClaims` at the last tracked cash movement. Past boundaries test min(live, this),
        // so an untracked donation cannot cure a shortfall that already happened.
        uint256 lastAccrualCash;
        // Penalty start for the current unfunded cohort (0 = none): anchor + grace at first onset,
        // held until `maturedRedeemShares` is 0. Per cohort, so a brief cure cannot renew grace.
        uint256 penaltyFromTimestamp;
        // ---- Per-vault schedule, fixed at initialization ----
        uint256 epochDuration; // seconds per epoch
        uint256 withdrawalNotice; // notice before a boundary to claim at it
        // ---- Interest base period ----
        // Pool value at the period start. Every leg bills as a cumulative floor on it, so accrual
        // timing never changes totals. Resets at each epoch boundary (compounding) and pool cash event.
        uint256 interestBase;
        uint256 basePeriodStart; // start of the current base period
    }

    /// @notice Length of one epoch, in seconds. Fixed at initialization.
    function epochDuration() external view returns (uint256) {
        return _getDepositsStorage().epochDuration;
    }

    /// @notice Notice required before an epoch boundary to claim at it, in seconds.
    function withdrawalNotice() external view returns (uint256) {
        return _getDepositsStorage().withdrawalNotice;
    }

    /// @notice The minimum single deposit this vault accepts, in loan-asset units.
    function minimumDepositAmount() external view returns (uint256) {
        return _getDepositsStorage().minimumDepositAmount;
    }

    function _getDepositsStorage() internal pure returns (LoanVaultDepositsStorage storage s) {
        bytes32 slot = LOAN_VAULT_DEPOSITS_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    /// @dev Timestamp accrual stops at: end of the termination epoch, or max while live.
    function _accrualCutoff(LoanVaultDepositsStorage storage s) internal view returns (uint256) {
        uint256 t = s.terminatedAt;
        if (t == 0) return type(uint256).max;
        uint256 epochDur = s.epochDuration;
        return VaultAccountingLib.epochStartTime(
            VaultAccountingLib.epochAtTimestamp(t, s.genesisTimestamp, epochDur) + 1, s.genesisTimestamp, epochDur
        );
    }

    /// @inheritdoc LoanVaultBase
    function _feeCeilingRateBps() internal view override returns (uint256) {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        uint256 current = s.interestRateBps;
        if (s.rateActivationEpoch != 0 && s.pendingInterestRateBps < current) {
            return s.pendingInterestRateBps;
        }
        return current;
    }

    /// @dev Persists a scheduled rate change once the accrual loop reaches its activation boundary.
    function _foldScheduledRate(LoanVaultDepositsStorage storage s) private {
        emit InterestRateActivated(s.interestRateBps, s.pendingInterestRateBps, s.rateActivationEpoch);
        s.interestRateBps = s.pendingInterestRateBps;
        delete s.pendingInterestRateBps;
        delete s.rateActivationEpoch;
    }

    // ============ Lender registry (per-vault lender allowlist) ============

    /// @notice Points the vault at a different lender registry.
    function setLenderRegistry(address newRegistry) external onlyVaultManager {
        if (newRegistry == address(0)) revert LenderRegistryCannotBeZeroAddress();
        if (address(IVaultLenderRegistry(newRegistry).roleManager()) != address(_getConfigStorage().roleManager)) {
            revert RegistryRoleManagerMismatch();
        }
        _getDepositsStorage().lenderRegistry = IVaultLenderRegistry(newRegistry);
        emit LenderRegistryUpdated(newRegistry);
    }

    /// @notice Lender registry gating deposits and exits. Transfers do not consult it.
    function lenderRegistry() external view returns (address) {
        return address(_getDepositsStorage().lenderRegistry);
    }

    function _isApprovedLender(address who) internal view virtual returns (bool) {
        return _getDepositsStorage().lenderRegistry.isApproved(who);
    }

    function _requireApprovedLender(address who) internal view {
        if (!_isApprovedLender(who)) revert LenderNotApproved();
    }

    // ============ Transfer gate policy ============

    /// @notice Enables or disables wallet-to-wallet share transfers.
    function setTransfersEnabled(bool enabled) external onlyVaultManager {
        _getDepositsStorage().transfersEnabled = enabled;
        emit TransfersEnabledUpdated(enabled);
    }

    /// @notice True when wallet-to-wallet transfers are allowed.
    function transfersEnabled() external view returns (bool) {
        return _getDepositsStorage().transfersEnabled;
    }

    // ============ Exact projection (view twin of _accrueInterest) ============

    /// @dev Accumulators for `_accrueInterest`, flushed to storage once after the loop.
    struct AccrualRun {
        uint256 assets; // running pool value
        uint256 billedTo; // instant every leg is billed to (raw; clamped at the cutoff when used)
        uint256 interest; // total interest this run (event only)
        uint256 fees; // protocol fee banked this run
        uint256 matured; // shares that matured this run
        uint256 base; // interest base of the current period
        uint256 periodStart; // start of the current period
        uint256 cutoff; // timestamp billing stops at; max while live
    }

    /// @dev Working state for `_projectedPoolNow`. No supply field: shares burn only at funding, so
    ///      supply is constant across the walk.
    struct PoolProjection {
        uint256 assets;
        uint256 segStart; // instant every leg is billed to (raw; clamped at the cutoff when used)
        uint256 base; // interest base of the current period
        uint256 periodStart; // start of the current period
        uint256 rate;
        uint256 pendingRate;
        uint256 rateAct;
        uint256 anchor;
        uint256 maturedShares; // escrowed shares past their boundary and still unfunded
        uint256 cash; // unreserved cash — what the anchor decision tests the liability against
        uint256 fees;
        uint256 cutoff; // timestamp accrual stops at (see _accrualCutoff); max while live
        uint256 epochDur; // per-vault epoch length
        uint256 genesis; // vault genesis; in the struct, not a local, to keep the walk off the stack
    }

    function _seedProjection(LoanVaultDepositsStorage storage s) private view returns (PoolProjection memory p) {
        p.assets = s.totalAssets;
        p.anchor = s.delinquencyDueTimestamp;
        p.maturedShares = s.maturedRedeemShares;
        // min(live cash, watermark), as in `_maybeAnchorDelinquency`.
        p.cash = _cashForClaims(s);
        if (s.lastAccrualCash < p.cash) p.cash = s.lastAccrualCash;
        p.cutoff = _accrualCutoff(s);
    }

    /// @dev Projection twin of accrual's maturation step: matures `epoch` and may anchor delinquency.
    function _replayMaturation(
        LoanVaultDepositsStorage storage s,
        PoolProjection memory p,
        uint256 epoch,
        uint256 boundaryTs
    )
        private
        view
    {
        uint256 mShares = s.scheduledWithdrawalShares[epoch];
        p.maturedShares += mShares;
        // Mirrors `_maybeAnchorDelinquency`: tested at every boundary, not only fresh maturations.
        if (p.maturedShares == 0) return;
        if (p.anchor == 0 && p.cash < _maturedLiability(p.maturedShares, p.assets, totalSupply())) {
            p.anchor = boundaryTs;
        }
    }

    /// @dev Pool, fees and matured shares exactly as `_accrueInterest` would leave them now.
    function _projectedPoolNow()
        internal
        view
        returns (uint256 projAssets, uint256 projFees, uint256 projMaturedShares)
    {
        PoolProjection memory p = _projectPool();
        return (p.assets, p.fees, p.maturedShares);
    }

    /// @dev Replays every boundary since the last accrual in `_accrueInterest`'s order, then bills to now.
    function _projectPool() private view returns (PoolProjection memory p) {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        uint256 last = s.lastAccrualTimestamp;
        if (last == block.timestamp) {
            // Settled this block: storage is the projection. Only fields callers read are filled.
            p.assets = s.totalAssets;
            p.fees = s.accruedFees;
            p.maturedShares = s.maturedRedeemShares;
            p.anchor = s.delinquencyDueTimestamp;
            p.base = s.interestBase;
            p.periodStart = s.basePeriodStart;
            return p;
        }

        p = _seedProjection(s);
        p.segStart = last;
        p.base = s.interestBase;
        p.periodStart = s.basePeriodStart;
        p.rate = s.interestRateBps;
        p.pendingRate = s.pendingInterestRateBps;
        p.rateAct = s.rateActivationEpoch;
        p.fees = s.accruedFees;
        p.genesis = s.genesisTimestamp;
        p.epochDur = s.epochDuration;

        uint256 ce = VaultAccountingLib.currentEpoch(p.genesis, p.epochDur);
        uint256 lastEpoch = VaultAccountingLib.epochAtTimestamp(last, p.genesis, p.epochDur);
        if (p.cutoff != type(uint256).max) {
            uint256 cutoffEpoch = VaultAccountingLib.epochAtTimestamp(p.cutoff, p.genesis, p.epochDur);
            if (ce > cutoffEpoch) ce = cutoffEpoch;
            if (lastEpoch > ce) ce = lastEpoch;
        }

        for (uint256 i = lastEpoch; i <= ce; ++i) {
            if (i > lastEpoch) {
                // Bill to the boundary, then compound.
                _projectBoundary(s, p, p.genesis + i * p.epochDur);
            }

            // Rate fold: billing past this boundary uses the new rate.
            if (p.rateAct != 0 && i >= p.rateAct) {
                p.rate = p.pendingRate;
                p.rateAct = 0;
            }

            // Mature epoch i; epochs up to lastEpoch were folded by the last accrual.
            if (i > lastEpoch) {
                _replayMaturation(s, p, i, p.genesis + i * p.epochDur);
            }
        }
        _billProjection(s, p, block.timestamp);
    }

    /// @dev Bills to `boundary`, then starts a new period there (base := pool).
    function _projectBoundary(
        LoanVaultDepositsStorage storage s,
        PoolProjection memory p,
        uint256 boundary
    )
        private
        view
    {
        _billProjection(s, p, boundary);
        p.base = p.assets;
        p.periodStart = boundary;
    }

    /// @dev Projection twin of `_billPeriod`; the two must not diverge.
    function _billProjection(LoanVaultDepositsStorage storage s, PoolProjection memory p, uint256 rawTo) private view {
        uint256 to = rawTo > p.cutoff ? p.cutoff : rawTo;
        uint256 from = p.segStart > p.cutoff ? p.cutoff : p.segStart;
        if (to > from) {
            uint256 feeBps_ = _getConfigStorage().feeBps;
            uint256 netD = _cumDiff(p.base, p.rate - feeBps_, p.periodStart, from, to);
            uint256 feeD = _cumDiff(p.base, feeBps_, p.periodStart, from, to);
            uint256 penD;
            if (p.anchor != 0 && s.penaltyRateBps != 0) {
                uint256 pf = s.penaltyFromTimestamp;
                if (pf == 0) pf = p.anchor + s.withdrawalGracePeriod;
                penD = _cumDiff(p.base, s.penaltyRateBps, pf > p.periodStart ? pf : p.periodStart, from, to);
            }
            p.assets += netD + penD;
            p.fees += feeD;
        }
        if (rawTo > p.segStart) p.segStart = rawTo;
    }

    /// @dev floor(base·rate·(to−origin)) − floor(base·rate·(from−origin)). A difference of cumulative
    ///      floors, so any partition of an interval bills the same total.
    function _cumDiff(
        uint256 base,
        uint256 rateBps,
        uint256 origin,
        uint256 from,
        uint256 to
    )
        private
        pure
        returns (uint256)
    {
        if (to <= origin) return 0;
        uint256 hi = VaultAccountingLib.calculateInterest(base, rateBps, to - origin);
        uint256 lo = from <= origin ? 0 : VaultAccountingLib.calculateInterest(base, rateBps, from - origin);
        return hi - lo;
    }

    //////////////////////////////////////////////////////////////
    ///////////////// Interest Accrual + Settlement //////////////
    //////////////////////////////////////////////////////////////

    /// @dev Accrues interest to now, stepping through every epoch boundary since the last accrual.
    function _accrueInterest() internal {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();

        uint256 last = s.lastAccrualTimestamp;
        if (last == block.timestamp) return;

        uint256 genesis = s.genesisTimestamp;
        uint256 epochDur = s.epochDuration;
        uint256 _currentEpoch = VaultAccountingLib.currentEpoch(genesis, epochDur);
        uint256 lastAccrualEpoch = VaultAccountingLib.epochAtTimestamp(last, genesis, epochDur);

        AccrualRun memory a;
        a.assets = s.totalAssets;
        a.billedTo = last;
        a.base = s.interestBase;
        a.periodStart = s.basePeriodStart;
        uint256 cutoff = _accrualCutoff(s);
        a.cutoff = cutoff;
        // Clamp the walk at the cutoff so gas stays bounded and `claimRecovery` stays reachable.
        if (s.terminatedAt != 0) {
            uint256 cutoffEpoch = VaultAccountingLib.epochAtTimestamp(cutoff, genesis, epochDur);
            if (_currentEpoch > cutoffEpoch) _currentEpoch = cutoffEpoch;
            if (lastAccrualEpoch > _currentEpoch) _currentEpoch = lastAccrualEpoch;
        }

        for (uint256 i = lastAccrualEpoch; i <= _currentEpoch; ++i) {
            // 0. Bill the old period to the boundary, then compound (the only compounding point).
            if (i > lastAccrualEpoch) {
                _billPeriod(s, a, genesis + i * epochDur);
                a.base = a.assets;
                a.periodStart = genesis + i * epochDur;
            }

            // 1. Fold a scheduled rate at its boundary; billing past it uses the new rate.
            if (s.rateActivationEpoch != 0 && i >= s.rateActivationEpoch) {
                _foldScheduledRate(s);
            }

            // 2. Mature epoch i once (earlier epochs were folded by the previous run). Nothing burns
            //    before `fundRedemptions`, so supply is constant here and escrowed shares keep earning.
            if (i > lastAccrualEpoch) {
                uint256 mShares = s.scheduledWithdrawalShares[i];
                if (mShares != 0) a.matured += mShares;
                if (s.maturedRedeemShares + a.matured != 0) {
                    _maybeAnchorDelinquency(s, i, genesis, a.assets, a.matured);
                }
            }
        }
        _billPeriod(s, a, block.timestamp);

        s.lastAccrualTimestamp = block.timestamp;
        s.totalAssets = a.assets;
        s.interestBase = a.base;
        s.basePeriodStart = a.periodStart;
        if (a.fees != 0) s.accruedFees += a.fees;
        if (a.matured != 0) s.maturedRedeemShares += a.matured;
        // Written last, so the watermark reflects post-settlement cash.
        s.lastAccrualCash = _cashForClaims(s);

        emit InterestAccrued(a.interest, a.assets, block.timestamp >= cutoff ? 0 : a.assets);
    }

    /// @dev Bills the net (rate − fee), fee and penalty legs to `rawTo`, clamped at the cutoff. Reads
    ///      rate, fee and anchor from storage, so a fold or anchor earlier in the walk applies from there.
    function _billPeriod(LoanVaultDepositsStorage storage s, AccrualRun memory a, uint256 rawTo) private view {
        uint256 to = rawTo > a.cutoff ? a.cutoff : rawTo;
        uint256 from = a.billedTo > a.cutoff ? a.cutoff : a.billedTo;
        if (to > from) {
            uint256 feeBps_ = _getConfigStorage().feeBps;
            uint256 netD = _cumDiff(a.base, s.interestRateBps - feeBps_, a.periodStart, from, to);
            uint256 feeD = _cumDiff(a.base, feeBps_, a.periodStart, from, to);
            uint256 penD;
            if (s.delinquencyDueTimestamp != 0 && s.penaltyRateBps != 0) {
                // The cohort's stored start wins; anchor + grace is the fallback.
                uint256 pf = s.penaltyFromTimestamp;
                if (pf == 0) pf = s.delinquencyDueTimestamp + s.withdrawalGracePeriod;
                penD = _cumDiff(a.base, s.penaltyRateBps, pf > a.periodStart ? pf : a.periodStart, from, to);
            }
            a.assets += netD + penD;
            a.fees += feeD;
            a.interest += netD + feeD + penD;
        }
        if (rawTo > a.billedTo) a.billedTo = rawTo;
    }

    /// @dev Anchors delinquency at epoch `i`'s boundary if min(live cash, watermark) cannot cover the
    ///      matured claims. Retroactive to that boundary however late it is observed.
    function _maybeAnchorDelinquency(
        LoanVaultDepositsStorage storage s,
        uint256 i,
        uint256 cachedGenesisTimestamp,
        uint256 poolAssets,
        uint256 pendingMatured
    )
        private
    {
        if (s.delinquencyDueTimestamp != 0) return;
        // In-flight pool, since `s.totalAssets` is written after the walk. The cash clamp is
        // deliberately stricter than `_isDelinquent`.
        uint256 due = _maturedLiability(s.maturedRedeemShares + pendingMatured, poolAssets, totalSupply());
        uint256 cash = _cashForClaims(s);
        uint256 watermark = s.lastAccrualCash;
        if (watermark < cash) cash = watermark;
        if (cash >= due) return;
        uint256 dueAt = cachedGenesisTimestamp + i * s.epochDuration;
        s.delinquencyDueTimestamp = dueAt;
        // Grace is granted once per unfunded cohort, not per anchor.
        if (s.penaltyFromTimestamp == 0) s.penaltyFromTimestamp = dueAt + s.withdrawalGracePeriod;
        emit DelinquencyStarted(i, due, dueAt);
    }

    /// @dev Held loan asset minus `reservedAssets`; serves funding, the delinquency test and recovery.
    function _cashForClaims(LoanVaultDepositsStorage storage s) internal view returns (uint256) {
        uint256 held = _heldAssetsUsdc();
        uint256 reserved = s.reservedAssets;
        return held > reserved ? held - reserved : 0;
    }

    /// @dev Asset value of `shares` at the given pool's live price (rounds down); never a stored quote.
    function _maturedLiability(uint256 shares, uint256 poolAssets, uint256 poolSupply) internal pure returns (uint256) {
        if (shares == 0) return 0;
        return VaultAccountingLib.convertToAssets(shares, poolAssets, poolSupply, _decimalsOffset());
    }

    /// @dev Shortfall test: unreserved cash cannot cover matured, unfunded claims. A funded claim pays
    ///      out of `reservedAssets`, so a lender's own claim cannot tip it.
    function _isDelinquent() internal view returns (bool) {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        return _cashForClaims(s) < _maturedLiability(s.maturedRedeemShares, s.totalAssets, totalSupply());
    }

    /// @dev Matured redemptions unfunded past their cohort's grace, whatever the cash. Backs
    ///      `isDelinquent()` and gates deposit/mint/borrow. Projected.
    function _unfundedPastGrace() internal view returns (bool) {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        PoolProjection memory p = _projectPool();
        if (p.maturedShares == 0) return false;
        uint256 from = s.penaltyFromTimestamp;
        if (from == 0) {
            if (p.anchor == 0) return false;
            from = p.anchor + s.withdrawalGracePeriod;
        }
        return block.timestamp >= from;
    }

    /// @dev `_isDelinquent` on the projected pool, so views see boundaries nobody has poked.
    function _isDelinquentProjected() internal view returns (bool) {
        (uint256 projAssets,, uint256 projMaturedShares) = _projectedPoolNow();
        return _cashForClaims(_getDepositsStorage()) < _maturedLiability(projMaturedShares, projAssets, totalSupply());
    }

    /// @dev Stored anchor, else the one the next accrual would set (0 = none).
    function _projectedDelinquencyAnchor() internal view returns (uint256) {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        if (s.delinquencyDueTimestamp != 0) return s.delinquencyDueTimestamp;
        return _projectPool().anchor;
    }

    /// @notice Sets the protocol fee rate, in bps.
    function setFeeBps(uint256 _newFee) external onlyVaultManager {
        if (_newFee >= _feeCeilingRateBps()) revert InvalidFeeBps();
        _accrueInterest();
        VaultConfigStorage storage cs = _getConfigStorage();
        uint256 old = cs.feeBps;
        cs.feeBps = _newFee;
        emit FeeBpsUpdated(old, _newFee);
    }

    /// @dev Call at the end of every mutator. A new shortfall anchors at block.timestamp.
    function _refreshDelinquency() internal {
        _refreshDelinquency(true);
    }

    /// @dev `allowOnset` is false only for `update()`: a poke may cure but not anchor.
    function _refreshDelinquency(bool allowOnset) internal {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        // The grace grant ends only once the cohort is fully funded; a cure alone does not renew it.
        if (s.maturedRedeemShares == 0) delete s.penaltyFromTimestamp;

        if (s.delinquencyDueTimestamp != 0) {
            if (!_isDelinquent()) {
                s.delinquencyDueTimestamp = 0;
                emit DelinquencyCured(block.timestamp);
            }
        } else if (allowOnset && _isDelinquent()) {
            s.delinquencyDueTimestamp = block.timestamp;
            // Only a cohort's first onset earns grace; a later one resumes the penalty at once.
            if (s.penaltyFromTimestamp == 0) {
                s.penaltyFromTimestamp = block.timestamp + s.withdrawalGracePeriod;
            }
            emit DelinquencyStarted(
                VaultAccountingLib.currentEpoch(s.genesisTimestamp, s.epochDuration),
                _maturedLiability(s.maturedRedeemShares, s.totalAssets, totalSupply()),
                block.timestamp
            );
        }
    }

    //////////////////////////////////////////////////////////////
    /////////////////////////// Asset I/O ////////////////////////
    //////////////////////////////////////////////////////////////

    function _heldAssetsUsdc() internal view virtual returns (uint256) {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        return s.loanAsset.balanceOf(address(this));
    }

    /// @dev Starts a new base period (base := pool, start := now). Callers accrue first.
    function _resetBasePeriod(LoanVaultDepositsStorage storage s) internal {
        s.interestBase = s.totalAssets;
        s.basePeriodStart = block.timestamp;
    }

    /// @notice Pool value at the start of the current interest base period (projected).
    function interestBase() external view returns (uint256) {
        return _projectPool().base;
    }

    /// @notice Start of the current interest base period (projected).
    function basePeriodStart() external view returns (uint256) {
        return _projectPool().periodStart;
    }

    /// @dev Call after any change to held cash or `reservedAssets`, even without a transfer.
    function _stampCashWatermark() internal {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        s.lastAccrualCash = _cashForClaims(s);
    }

    function _pullUsdc(address from, uint256 usdcAmount) internal virtual {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        s.loanAsset.safeTransferFrom(from, address(this), usdcAmount);
        s.lastAccrualCash = _cashForClaims(s);
    }

    function _payUsdc(address to, uint256 usdcAmount) internal virtual {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        s.loanAsset.safeTransfer(to, usdcAmount);
        s.lastAccrualCash = _cashForClaims(s);
    }

    //////////////////////////////////////////////////////////////
    ////////////////////////// Keeper poke ///////////////////////
    //////////////////////////////////////////////////////////////

    /// @notice Permissionless poke: accrues interest and refreshes delinquency. Moves no funds.
    function update() external {
        _accrueInterest();
        _refreshDelinquency(false);
    }

    function _initializeDepositsStorage(ConstructorParams calldata _params) internal {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        IERC20 asset_ = IERC20(_params.asset);

        s.loanAsset = asset_;
        s.assetDecimals = _tryGetAssetDecimals(asset_);
        s.genesisTimestamp = block.timestamp;
        s.interestRateBps = _params.interestRateBps;
        s.borrower = _params.borrower;
        s.vaultCapacity = _params.initialCapacity;
        s.minimumDepositAmount = _params.minimumDepositAmount;
        s.lastAccrualTimestamp = block.timestamp;
        s.basePeriodStart = block.timestamp;
        s.lenderRegistry = IVaultLenderRegistry(_params.lenderRegistry);
        s.penaltyRateBps = _params.penaltyRateBps;
        s.withdrawalGracePeriod = _params.withdrawalGracePeriod;

        // 0 = protocol default.
        uint256 epochDuration_ =
            _params.epochDuration == 0 ? VaultAccountingLib.DEFAULT_EPOCH_DURATION : _params.epochDuration;
        uint256 withdrawalNotice_ =
            _params.withdrawalNotice == 0 ? VaultAccountingLib.DEFAULT_WITHDRAWAL_NOTICE : _params.withdrawalNotice;

        if (epochDuration_ < MIN_EPOCH_DURATION || epochDuration_ > MAX_EPOCH_DURATION) {
            revert InvalidEpochDuration();
        }
        // Notice <= epoch. Equal is valid: every request then waits at least one full epoch.
        if (withdrawalNotice_ > epochDuration_) revert InvalidWithdrawalNotice();

        s.epochDuration = epochDuration_;
        s.withdrawalNotice = withdrawalNotice_;
    }

    // ============ Penalty / Delinquency Getters ============

    /// @notice Extra APR (bps) charged on the interest base while the vault is delinquent.
    function penaltyRateBps() external view returns (uint256) {
        return _getDepositsStorage().penaltyRateBps;
    }

    /// @notice Updates the delinquency penalty rate, in bps (at most `MAX_PENALTY_RATE_BPS`).
    function setPenaltyRateBps(uint256 newRateBps) external onlyVaultManager nonReentrant {
        if (newRateBps > MAX_PENALTY_RATE_BPS) revert PenaltyRateExceedsMax();
        _accrueInterest();
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        uint256 old = s.penaltyRateBps;
        s.penaltyRateBps = newRateBps;
        emit PenaltyRateBpsUpdated(old, newRateBps);
    }

    /// @notice Seconds of grace from a withdrawal's due time before penalty starts. Fixed at init.
    function withdrawalGracePeriod() external view returns (uint256) {
        return _getDepositsStorage().withdrawalGracePeriod;
    }

    // ============ Scheduled interest-rate change ============

    /// @notice Schedules a new interest rate, in bps, active from the start of currentEpoch + 2.
    function scheduleInterestRate(uint256 newRateBps) external onlyVaultManager nonReentrant {
        if (newRateBps > MAX_INTEREST_RATE_BPS) revert InterestRateExceedsMax();
        if (newRateBps < MIN_INTEREST_RATE_BPS) revert InterestRateBelowMin();
        // Pairs with `setFeeBps` so the lender's net rate (rate - fee) stays positive.
        if (newRateBps <= _getConfigStorage().feeBps) revert InterestRateNotAboveFee();

        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        if (s.terminatedAt != 0) revert VaultTerminated();
        _accrueInterest(); // folds any prior activated-but-untouched schedule before overwriting it

        uint256 activationEpoch = VaultAccountingLib.currentEpoch(s.genesisTimestamp, s.epochDuration) + 2;
        s.pendingInterestRateBps = newRateBps;
        s.rateActivationEpoch = activationEpoch;
        emit InterestRateScheduled(s.interestRateBps, newRateBps, activationEpoch);
    }

    /// @notice Cancels a scheduled rate change before it activates.
    function cancelScheduledRate() external onlyVaultManager nonReentrant {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        if (s.rateActivationEpoch == 0) revert NoScheduledRate();
        if (VaultAccountingLib.currentEpoch(s.genesisTimestamp, s.epochDuration) >= s.rateActivationEpoch) {
            revert RateAlreadyActivated();
        }
        _accrueInterest();
        emit InterestRateScheduleCancelled(s.pendingInterestRateBps, s.rateActivationEpoch);
        delete s.pendingInterestRateBps;
        delete s.rateActivationEpoch;
    }

    /// @notice The scheduled rate change, if any (activationEpoch 0 = none).
    function scheduledInterestRate() external view returns (uint256 pendingRateBps, uint256 activationEpoch) {
        LoanVaultDepositsStorage storage s = _getDepositsStorage();
        return (s.pendingInterestRateBps, s.rateActivationEpoch);
    }

    /// @notice Value owed for matured, unfunded redemption requests, at the projected live price.
    function dueUnprocessedAssets() external view returns (uint256) {
        (uint256 projAssets,, uint256 projMaturedShares) = _projectedPoolNow();
        return _maturedLiability(projMaturedShares, projAssets, totalSupply());
    }

    /// @notice Escrowed shares past their boundary and not yet funded (projected).
    function maturedRedeemShares() external view returns (uint256) {
        (,, uint256 projMaturedShares) = _projectedPoolNow();
        return projMaturedShares;
    }

    /// @notice Cash already paid for burned shares and awaiting `redeem()`. Ring-fenced.
    function reservedAssets() external view returns (uint256) {
        return _getDepositsStorage().reservedAssets;
    }

    /// @notice Boundary-cash watermark: unreserved cash as of the last tracked movement.
    function lastAccrualCash() external view returns (uint256) {
        return _getDepositsStorage().lastAccrualCash;
    }

    /// @notice Cumulative wind-down recovery paid out.
    function totalRecoveryPaid() external view returns (uint256) {
        return _getDepositsStorage().totalRecoveryPaid;
    }

    /// @dev Exposure cap: accrued interest counts toward `vaultCapacity`. Callers accrue first.
    function _checkCapacity(LoanVaultDepositsStorage storage s, uint256 newDeposit) internal view {
        if (s.totalAssets + newDeposit > s.vaultCapacity) revert ExceedsCapacity();
    }
}
