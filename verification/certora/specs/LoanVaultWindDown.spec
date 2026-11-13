/*
 * LoanVaultWindDown.spec
 * =============================================================================
 * Target : LoanVaultHarness
 * Scope  : terminate -> freeze -> escrow return -> pro-rata recovery ->
 *          residual sweep. Highest-risk transition in the protocol: the vault
 *          stops being a pool and becomes a fixed claim on a frozen book.
 *
 * The five properties that decide whether lenders lose money
 * ---------------------------------------------------------
 *   (1) the snapshot (denominator + book) is written ONCE and never moves
 *   (2) a lender cannot draw more than its pro-rata entitlement
 *   (3) cumulative claims are monotone and idempotent (no double claim)
 *   (4) total recovery paid never exceeds the frozen book
 *   (5) the residual sweep and the fee sweep never take lender cash
 *
 * Entitlement arithmetic, straight from the source:
 *     pool     = min(_cashForClaims() + totalRecoveryPaid, frozenAssets)
 *     entitled = floor(units * pool / resolutionShares)
 *     pay      = entitled - claimedRecovery[msg.sender]
 * The tricky part — and a classic source of false positives — is that the pool
 * *includes* what was already paid out, so a test that forgets
 * `totalRecoveryPaid` reports phantom under/over-payment on every claim.
 */

using LoanVaultHarness as vault;

methods {
    function terminated() external returns (bool) envfree;
    function terminatedAt() external returns (uint256) envfree;
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function getTotalAssets() external returns (uint256) envfree;
    function totalAssets() external returns (uint256) envfree;

    function resolutionShares() external returns (uint256) envfree;
    function frozenAssets() external returns (uint256) envfree;
    function totalRecoveryPaid() external returns (uint256) envfree;
    function claimedRecovery(address) external returns (uint256) envfree;
    function reservedAssets() external returns (uint256) envfree;
    function accruedFees() external returns (uint256) envfree;
    function maturedRedeemShares() external returns (uint256) envfree;
    function escrowShares() external returns (uint256) envfree;
    function queueLength(address) external returns (uint256) envfree;

    function ghost_held() external returns (uint256) envfree;
    function convertToAssets(uint256) external returns (uint256) envfree;
    function canTransfer(address, address) external returns (bool);
    function maxDeposit(address) external returns (uint256) envfree;
    function availableToBorrow() external returns (uint256) envfree;
    function borrower() external returns (address) envfree;

    function fundRedemptions() external;
    function claimRecovery() external returns (uint256);
    function claimRecovery(address) external returns (uint256);
    function sweepResidual() external returns (uint256);
    function redeem() external returns (uint256);
    function collectFees() external;
    function terminate() external;
    function repay(uint256) external;
    function update() external;
}

/* ============================================================================
 * SECTION 1 — SNAPSHOT IMMUTABILITY (ADV-08)
 * ==========================================================================*/

/// Once written, the denominator never changes. Changing it would re-price
/// every lender's entitlement after some of them already claimed.
rule snapshotIsWrittenOnce() {
    env e;

    claimRecovery(e);
    uint256 sharesAfterFirst = resolutionShares();
    uint256 bookAfterFirst = frozenAssets();

    require sharesAfterFirst > 0;

    claimRecovery(e);
    claimRecovery(e);

    assert resolutionShares() == sharesAfterFirst, "resolution denominator must never move";
    assert frozenAssets() == bookAfterFirst, "frozen book must never move";
}

/// The snapshot is coherent: both halves are written together.
invariant snapshotIsCoherent()
    resolutionShares() != 0 => frozenAssets() != 0 && resolutionShares() <= totalSupply() + escrowShares();

/// A live vault has no snapshot.
invariant liveVaultHasNoSnapshot()
    !terminated() => resolutionShares() == 0 && frozenAssets() == 0;

/// The frozen book is the pool at the moment of freezing — it can never exceed
/// what the vault had actually earned. (It is assigned from `totalAssets` in
/// `_snapshotResolution`; a larger value would mean paying out more than par.)
invariant frozenBookIsAtMostPrincipalPlusInterest()
    frozenAssets() <= getTotalAssets() + totalRecoveryPaid() + reservedAssets();

/* ============================================================================
 * SECTION 2 — ENTITLEMENT BOUNDS (ADV-06, ADV-07, ADV-18)
 * ==========================================================================*/

/// ADV-07: cumulative recovery never exceeds the frozen book.
invariant totalRecoveryPaidWithinBook()
    totalRecoveryPaid() <= frozenAssets();

/// ADV-06: a lender's cumulative draw never exceeds its pro-rata entitlement,
/// computed on the *current* pool (which already includes prior payouts).
invariant claimedWithinEntitlement(address lender)
    resolutionShares() > 0 =>
        claimedRecovery(lender) <=
            (balanceOf(lender) * (ghost_held() - reservedAssets() + totalRecoveryPaid())) / resolutionShares();

/// ADV-06 (capped form): the entitlement itself is capped at the frozen book.
invariant claimedWithinFrozenBook(address lender)
    claimedRecovery(lender) <= frozenAssets();

/// Nothing can be claimed before termination — `claimRecovery` reverts.
invariant noRecoveryWhileLive(address lender)
    !terminated() => claimedRecovery(lender) == 0;

/// The escrow return is a one-shot event per lender; the queue must not be able
/// to hand the same shares back twice. (The latch is `escrowReturned[lender]`.)
rule escrowReturnHappensAtMostOnce() {
    env e;

    claimRecovery(e);
    uint256 escrowAfterFirst = escrowShares();

    claimRecovery(e);

    assert escrowShares() <= escrowAfterFirst, "escrow shares are never handed out twice";
}

/* ============================================================================
 * SECTION 3 — RECOVERY RULES
 * ==========================================================================*/

/// R-D1 — the payout is exactly `entitled - drawn`, bounded by the pool.
rule recoveryPayoutIsTheIncrement() {
    env e;

    uint256 heldBefore = ghost_held();
    uint256 reservedBefore = reservedAssets();
    uint256 paidBefore = totalRecoveryPaid();
    uint256 claimedBefore = claimedRecovery(e.msg.sender);
    uint256 units = balanceOf(e.msg.sender);
    uint256 denom = resolutionShares();
    uint256 book = frozenAssets();

    require terminated();
    require denom > 0;               // a snapshot already exists

    uint256 pay = claimRecovery(e);

    // Pool AFTER the payout, reconstructed the way the contract sees it:
    //   pool = min(cashForClaims + totalRecoveryPaid, frozenAssets)
    uint256 cashAfter = ghost_held() - reservedAssets();
    uint256 poolRaw = cashAfter + totalRecoveryPaid();
    uint256 pool = poolRaw < book ? poolRaw : book;

    assert heldBefore == ghost_held() + pay, "the payout is exactly the cash that left";
    assert reservedAssets() == reservedBefore, "recovery never touches the reservation";
    assert totalRecoveryPaid() == paidBefore + pay, "cumulative payout is tracked exactly";
    assert claimedRecovery(e.msg.sender) >= claimedBefore, "the recorded draw is monotone";
    assert claimedRecovery(e.msg.sender) == (units * pool) / denom,
        "the draw is recorded at the entitlement, not at the payout";
}

/// R-D2 — a lender with nothing left to claim reverts instead of drawing dust.
rule noZeroPayoutClaims() {
    env e;

    claimRecovery(e);
    claimRecovery(e);   // must revert: entitled <= drawn
}

/// R-D3 — claiming pays out of cash only, never out of the reservation.
rule recoveryDoesNotTouchReservation() {
    env e;

    require terminated();
    resolutionShares() > 0;

    uint256 reservedBefore = reservedAssets();
    claimRecovery(e);

    assert reservedAssets() == reservedBefore, "recovery is drawn from free cash, not from the reservation";
    assert ghost_held() >= reservedAssets(), "the reservation stays backed";
}

/// R-D4 — `convertToAssets` past the cutoff reports the *gross* entitlement
/// (what a lender would get if nobody else had drawn yet) and is therefore
/// non-decreasing in the pool's cash, but never exceeds book.
invariant recoveryValueWithinBook(uint256 shares)
    terminated() => convertToAssets(shares) <= frozenAssets() + 1;

/* ============================================================================
 * SECTION 4 — POST-TERMINATION POLICY (ADV-TERM)
 * ==========================================================================*/

/// The holder set is frozen: no wallet-to-wallet share transfer survives
/// termination. This is what makes address-keyed `claimedRecovery` sound — a
/// seller cannot sell shares whose recovery they already claimed.
invariant terminationFreezesHolderSet(address from, address to)
    terminated() && from != 0 && to != 0 && from != vault => !canTransfer(from, to);

/// ...while the vault can still hand escrow shares back, otherwise unfunded
/// lenders could never obtain a recovery claim at all.
invariant escrowReturnStaysOpen(address lender)
    terminated() => canTransfer(vault, lender);

/// No new deposits and no new principal once terminated.
invariant terminationStopsEntry(address receiver)
    terminated() => maxDeposit(receiver) == 0 && availableToBorrow() == 0;

/// Funding is closed at termination: `fundRedemptions` reverts, so the matured
/// book is only ever cleared by the escrow return from here on.
rule fundingIsClosedAfterTermination() {
    env e;

    require terminated();

    fundRedemptions(e);
}

/// R-S1 — the residual sweep pays only the borrower, and only cash above the
/// outstanding lender book plus the accrued fee (ADV-15).
rule residualSweepLeavesLenderBook() {
    env e;

    uint256 heldBefore = ghost_held();
    uint256 paidBefore = totalRecoveryPaid();
    uint256 reservedBefore = reservedAssets();
    uint256 book = frozenAssets();
    uint256 outstanding = book > paidBefore ? book - paidBefore : 0;

    require terminated();

    uint256 swept = sweepResidual(e);

    assert heldBefore == ghost_held() + swept, "the sweep pays out exactly what it reports";
    assert ghost_held() >= reservedBefore + outstanding,
        "whatever the sweep, every lender claim stays funded";
    assert reservedAssets() == reservedBefore, "the reservation is not a source for the residual";
}

/// R-S2 — the fee sweep is junior to lenders once terminated (ADV-15).
rule terminatedFeeSweepIsJunior() {
    env e;

    uint256 paidBefore = totalRecoveryPaid();
    uint256 reservedBefore = reservedAssets();
    uint256 book = frozenAssets();
    uint256 outstanding = book > paidBefore ? book - paidBefore : 0;

    require terminated();

    collectFees(e);

    assert ghost_held() >= reservedBefore + outstanding,
        "a fee sweep must never eat into the outstanding lender book";
}

/// R-S3 — termination is irreversible: once terminated, no call path revives the
/// vault. (The `terminatedAt` field is only ever assigned from 0.)
rule terminationIsIrreversible() {
    env e;

    require terminated();
    uint256 stamp = terminatedAt();

    method f;
    calldataarg args;
    f(e, args);

    assert terminated() && terminatedAt() == stamp, "wind-down must be a one-way door";
}
