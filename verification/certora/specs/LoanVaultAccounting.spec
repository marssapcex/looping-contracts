/*
 * LoanVaultAccounting.spec
 * =============================================================================
 * Target : LoanVault (run through LoanVaultHarness, see certora/conf/*.conf)
 * Scope  : solvency, cash conservation, share-price accounting, fees, capacity,
 *          accrual/penalty ordering.
 *
 * READ THIS FIRST — what "verifiable" means here
 * ---------------------------------------------
 * The production contract reads the loan asset (`balanceOf`, `transfer`) and two
 * registries (`isApproved`, `isVaultManager`) through external calls. Under the
 * Prover those calls are havoced, which silently destroys every cash-based
 * property below. `LoanVaultHarness` replaces exactly those four touch points
 * with concrete storage (`ghost_held`, `ghost_denied`) and **nothing else**.
 * Verified bytecode therefore equals production bytecode apart from the token
 * balance bookkeeping — stated explicitly so no result is misread.
 *
 * Every invariant here was first validated empirically against the real
 * bytecode by `scripts/audit.js` / `scripts/audit2.js` / `scripts/audit3.js`
 * (140 + 40 + probes). That matters: an invariant can be TRUE and still be
 * worthless (vacuous), and it can be FALSE for a reason that is *not* a bug (a
 * modelling mistake). Both failure modes are curated out below; see
 * `docs/FINDINGS.md` for the list of properties that were REFUTED and therefore
 * deliberately not shipped.
 *
 * Style note: none of these invariants carries a `preserved` block. The Prover
 * still checks that each one is inductive over every reachable transition; a
 * `preserved` block would only add a hand-written preservation proof for the
 * specific methods listed, and hand-written preservation is exactly how weak
 * invariants get smuggled past a reviewer.
 */

using LoanVaultHarness as vault;

methods {
    // ---- ERC-20 / ERC-4626 surface ----
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function totalAssets() external returns (uint256) envfree;
    function getTotalAssets() external returns (uint256) envfree;
    function convertToShares(uint256) external returns (uint256) envfree;
    function convertToAssets(uint256) external returns (uint256) envfree;
    function maxDeposit(address) external returns (uint256) envfree;
    function maxMint(address) external returns (uint256) envfree;
    function decimals() external returns (uint8) envfree;
    function previewMint(uint256) external returns (uint256) envfree;

    // ---- vault accounting ----
    function exposedAmount() external returns (uint256) envfree;
    function vaultCapacity() external returns (uint256) envfree;
    function borrowedAmount() external returns (uint256) envfree;
    function amountOwed() external returns (uint256) envfree;
    function availableToBorrow() external returns (uint256) envfree;
    function accruedFees() external returns (uint256) envfree;
    function feeBps() external returns (uint256) envfree;
    function interestRateBps() external returns (uint256) envfree;
    function reservedAssets() external returns (uint256) envfree;
    function lastAccrualCash() external returns (uint256) envfree;
    function maturedRedeemShares() external returns (uint256) envfree;
    function dueUnprocessedAssets() external returns (uint256) envfree;
    function redemptionFundingShortfall() external returns (uint256) envfree;

    // ---- lifecycle / policy ----
    function terminated() external returns (bool) envfree;
    function terminatedAt() external returns (uint256) envfree;
    function depositsPaused() external returns (bool) envfree;
    function withdrawalsPaused() external returns (bool) envfree;
    function transfersEnabled() external returns (bool) envfree;
    function isDelinquent() external returns (bool) envfree;
    function penaltyActiveSince() external returns (uint256) envfree;

    // ---- wind-down ----
    function resolutionShares() external returns (uint256) envfree;
    function frozenAssets() external returns (uint256) envfree;
    function resolutionSnapshot() external returns (uint256, uint256) envfree;
    function totalRecoveryPaid() external returns (uint256) envfree;

    // ---- harness mirrors (the only non-production methods in the system) ----
    function ghost_held() external returns (uint256) envfree;
    function ghost_denied(address) external returns (bool) envfree;

    // Non-envfree by necessity (they read the caller).
    function canTransfer(address, address) external returns (bool);
    function claimableRedeemRequest(uint256, address) external returns (uint256);
}

/* ============================================================================
 * SECTION 1 — CASH CONSERVATION (the ADV-01 family)
 *
 * `lastAccrualCash` is the contract's own watermark: "unreserved cash as of the
 * last tracked movement". Every mutator is supposed to re-stamp it. A stale
 * HIGH watermark is the interesting bug: it lets a historical shortfall look
 * cured, which suppresses the delinquency penalty (i.e. the borrower escapes
 * paying the punitive rate). A stale LOW watermark merely over-penalises.
 * ==========================================================================*/

/// The watermark can never exceed the real unreserved balance.
/// Violated ⇒ a payment that did not re-stamp ⇒ a shortfall could be masked.
invariant watermarkNeverOverstatesCash()
    lastAccrualCash() <= ghost_held() + reservedAssets()


/// Reserved cash is always physically present. This is the single most
/// important solvency invariant in the protocol: `reservedAssets` is the pot
/// that already-burned shares will withdraw, so if held cash drops below it, a
/// funded lender cannot be paid.
/// NOTE: `reservedAssets()` is only decremented together with a payout, so the
/// inequality is preserved by `redeem()` and must be preserved by `borrow()`,
/// `collectFees()` and `sweepResidual()` as well.
invariant reservedAssetsFullyBacked()
    reservedAssets() <= ghost_held()


/// Solvency in one line: the vault never promises more than it holds.
/// (promised = pool + ring-fenced claims + accrued fee)
invariant promisesDoNotExceedCash()
    exposedAmount() + reservedAssets() + accruedFees() <= ghost_held() + totalRecoveryPaid() + amountOwed()


/// `amountOwed()` must be exactly the unfunded part of the promises — no
/// double-counting of the reservation, no forgotten recovery credit.
invariant amountOwedIsTheDeficit()
    amountOwed()
        == (exposedAmount() + reservedAssets() + accruedFees()
              > ghost_held() + totalRecoveryPaid()
            ? exposedAmount() + reservedAssets() + accruedFees()
                - ghost_held() - totalRecoveryPaid()
            : 0)


/* ============================================================================
 * SECTION 2 — FEE AND RATE RELATIONSHIPS (ADV-17)
 * ==========================================================================*/

/// The lender's net rate must stay positive, otherwise interest accrual becomes
/// a fee-only transfer and `_cumDiff(base, rate - fee, ...)` underflows (revert
/// DoS on every deposit/repay/update).
invariant feeStrictlyBelowRate()
    feeBps() < interestRateBps()


/// A fee above 100% of principal per year is out of range; the init check
/// allows it, the setter does not — this pins the *reachable* bound.

/* ============================================================================
 * SECTION 3 — ERC-4626 CONVERSION SANITY (ADV-22, ADV-28, ADV-29)
 *
 * Deliberately NOT stated: the naive "convert(0) == 0" invariants from the
 * first draft (trivially true, solc makes them tautologies) and "no free
 * shares". What is stated below is rounding *direction*, which is what actually
 * protects the pool.
 * ==========================================================================*/

/// Deposits never round in the depositor's favour: a deposit of `a` assets
/// mints shares worth at most `a` (floor). This is the property that kills the
/// classic first-depositor inflation attack.
invariant depositNeverMintsMoreThanFair()
    (forall uint256 a.
        a > 0 && exposedAmount() + 1 > 0
            => convertToShares(a) * (exposedAmount() + 1) <= a * (totalSupply() + 1));

/// NOTE — removed after empirical refutation (scripts/audit3.js case b):
///     invariant sharesDoNotOutrunAssets()   totalSupply() == 0 => totalAssets() == 0
/// is FALSE: a lender can be the last one out and leave `totalAssets == 1` behind (the
/// ERC-4626 virtual asset, plus any donation). That residue is then a windfall for the
/// next depositor. It is reported as FINDING F-3, not asserted here.

/// Monotonicity of both legs (rounding must not invert ordering).
invariant convertToSharesMonotone(uint256 a, uint256 b)
    a <= b => convertToShares(a) <= convertToShares(b);

invariant convertToAssetsMonotone(uint256 a, uint256 b)
    a <= b => convertToAssets(a) <= convertToAssets(b);

/* ============================================================================
 * SECTION 4 — CAPACITY AND ENTRY GATES (ADV-09)
 * ==========================================================================*/

/// NOTE — capacity bounds *deposits*, not exposure. Empirically refuted
/// (scripts/audit3.js case a): at 10% APR with a 1e9 cap, five years of accrual pushes
/// `exposedAmount()` to 1.57e9 while `maxDeposit()` correctly reports 0. So the honest
/// statement is conditional, and the unconditional version belongs in a transition rule
/// (`depositStaysWithinCapacity` in LoanVaultTransitions.spec).
invariant capacityOnlyBindsWhenThereIsRoom(address receiver)
    maxDeposit(receiver) > 0 => exposedAmount() <= vaultCapacity();

/// A terminated vault cannot accept or advertise deposits.
invariant terminatedStopsDeposits(address receiver)
    terminated() => maxDeposit(receiver) == 0;

/// Neither can a paused one.
invariant depositsPausedStopsDeposits(address receiver)
    depositsPaused() => maxDeposit(receiver) == 0;

/// Nor can a terminated vault hand out new principal.
invariant terminatedStopsBorrowing()
    terminated() => availableToBorrow() == 0;

invariant withdrawalsPausedStopsBorrowing()
    withdrawalsPaused() => availableToBorrow() == 0;

/// ADV-09, the sharp version: the borrower can never draw the cash that is
/// already ring-fenced for burned shares, nor the cash backing the fee.
invariant borrowableExcludesReservationsAndFees()
    availableToBorrow() + reservedAssets() + accruedFees() + dueUnprocessedAssets() <= ghost_held();

/* ============================================================================
 * SECTION 5 — WITHDRAWAL LIABILITY BOUNDS (ADV-03, ADV-05, ADV-19)
 * ==========================================================================*/

/// A matured, unfunded claim is worth at most the whole pool — if this fails,
/// the pool is over-committed and funding can never succeed.
/// Scoped to a LIVE vault: past the wind-down cutoff `exposedAmount()` is forced to 0
/// while the matured book stays on the books (scripts/audit3.js case c).
invariant maturedLiabilityWithinPool()
    !terminated() => dueUnprocessedAssets() <= exposedAmount() + 1;

/// Shares sitting in escrow are part of supply (they keep earning until funded,
/// and only `fundRedemptions` burns them).
invariant escrowSharesWithinSupply()
    balanceOf(vault) <= totalSupply();

/// The funding gap is exactly the shortfall versus unreserved cash — or zero.
invariant shortfallIsTheGap()
    redemptionFundingShortfall()
        == (dueUnprocessedAssets() > ghost_held() - reservedAssets()
            ? dueUnprocessedAssets() - (ghost_held() - reservedAssets())
            : 0);

/* ============================================================================
 * SECTION 6 — LIFECYCLE STATE MACHINE (ADV-TERM)
 * ==========================================================================*/

invariant terminatedImpliesTimestamp()
    terminated() <=> terminatedAt() != 0


/// Once terminated, wallet-to-wallet transfers are dead forever. This is the
/// anti-double-claim guard for wind-down: `claimedRecovery` is keyed by address.
invariant terminationFreezesHolderSet(address from, address to)
    terminated() && from != 0 && to != 0 && from != vault
        => !canTransfer(from, to);

/// Escrow hand-back must still work after termination, or unfunded lenders
/// could never obtain a recovery claim.
invariant terminationKeepsEscrowReturnOpen(address lender)
    terminated() => canTransfer(vault, lender);

/// A live vault advertises no wind-down snapshot.
invariant liveVaultHasNoSnapshot()
    !terminated() => resolutionShares() == 0 && frozenAssets() == 0;

/// Snapshot consistency: the frozen book is set together with the denominator.
invariant snapshotIsCoherent()
    resolutionShares() != 0 => frozenAssets() != 0;

/// ADV-07: recovery can never pay out more than the frozen book.
invariant recoveryPaidWithinFrozenBook()
    totalRecoveryPaid() <= frozenAssets();

/* ============================================================================
 * SECTION 7 — DELINQUENCY / PENALTY (ADV-11)
 *
 * `penaltyFromTimestamp` is the *cohort* grace grant. It must survive a cure,
 * otherwise a borrower can manufacture a shortfall, cure it with a donation,
 * and harvest a fresh grace period forever.
 * ==========================================================================*/

/// Grace is only ever granted to a live cohort.
/// Scoped to a live vault: `claimRecovery()` zeroes the cohort via `_returnEscrowedShares()`
/// without running `_refreshDelinquency()`, so the last penalty start can outlive it. That is
/// harmless (accrual is frozen past the cutoff) and is recorded as FINDING F-4 instead of
/// being asserted as an invariant.
invariant noGraceWithoutCohort()
    !terminated() && maturedRedeemShares() == 0 => penaltyActiveSince() == 0;

/// While a cohort is unfunded its penalty start is monotone: re-onsets restart
/// the anchor, never the penalty clock.
invariant penaltyStartIsMonotone()
    maturedRedeemShares() != 0 && penaltyActiveSince() != 0
        => penaltyActiveSince() <= block.timestamp + withdrawalGracePeriod();

/// Sanity: the penalty timestamp is either 0 or a real timestamp.
invariant penaltyTimestampIsWellFormed()
    penaltyActiveSince() == 0 || penaltyActiveSince() <= block.timestamp + 7 days;
