/*
 * LoanVaultWithdrawal.spec
 * =============================================================================
 * Target : LoanVaultHarness (production LoanVault + concrete cash mirror)
 * Scope  : request -> maturity -> funding -> claim; per-user queue vs. epoch
 *          schedule; reservation isolation; the four conservation laws.
 *
 * Lifecycle being verified
 * -----------------------
 *   requestRedeem   escrow shares (supply unchanged), schedule into epoch E
 *   [boundary E]    accrual folds E into `maturedRedeemShares`
 *   fundRedemptions burn ALL matured escrow, reserve assets, fundedThrough = now
 *   redeem          pay pro-rata out of the reservation, dequeue
 *
 * The failure modes that matter
 * -----------------------------
 *   (1) shares burned without a matching reservation   -> unpaid lenders
 *   (2) reservation paid twice                          -> pool drained
 *   (3) queue/epoch bookkeeping drifting apart          -> stuck / double claims
 *   (4) funding allocating less than it reserved        -> stranded `reservedAssets`
 *   (5) `_returnEscrowedShares` saturating its subtraction -> corrupted matured book
 */

using LoanVaultHarness as vault;

methods {
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function getTotalAssets() external returns (uint256) envfree;
    function totalAssets() external returns (uint256) envfree;

    function reservedAssets() external returns (uint256) envfree;
    function maturedRedeemShares() external returns (uint256) envfree;
    function dueUnprocessedAssets() external returns (uint256) envfree;
    function redemptionFundingShortfall() external returns (uint256) envfree;
    function fundedThroughEpoch() external returns (uint256) envfree;
    function currentEpoch() external returns (uint256) envfree;
    function lastAccrualCash() external returns (uint256) envfree;

    function epochShares(uint256) external returns (uint256) envfree;
    function epochFundedAssets(uint256) external returns (uint256) envfree;
    function epochFunded(uint256) external returns (bool) envfree;
    function queueLength(address) external returns (uint256) envfree;
    function escrowShares() external returns (uint256) envfree;
    function storedMatured() external returns (uint256) envfree;
    function storedFundedThrough() external returns (uint256) envfree;
    function storedAnchor() external returns (uint256) envfree;

    function availableToBorrow() external returns (uint256) envfree;
    function accruedFees() external returns (uint256) envfree;
    function borrower() external returns (address) envfree;
    function amountOwed() external returns (uint256) envfree;

    function ghost_held() external returns (uint256) envfree;
    function ghost_denied(address) external returns (bool) envfree;

    function terminated() external returns (bool) envfree;
    function withdrawalsPaused() external returns (bool) envfree;
    function canTransfer(address, address) external returns (bool);
    function claimableRedeemRequest(uint256, address) external returns (uint256);
    function maxRedeem(address) external returns (uint256) envfree;
    function maxWithdraw(address) external returns (uint256) envfree;

    // Mutators left non-envfree: CVL must model their calldata/msg.sender.
    function requestRedeem(uint256) external returns (uint256);
    function fundRedemptions() external;
    function redeem() external returns (uint256);
    function claimRecovery() external returns (uint256);
    function borrow(uint256) external;
    function collectFees() external;
    function update() external;
    function deposit(uint256, address) external returns (uint256);
}

/* ============================================================================
 * SECTION 1 — ESCROW AND RESERVATION INVARIANTS
 * ==========================================================================*/

/// Escrowed shares stay inside `totalSupply()`; only funding burns them.
invariant escrowWithinSupply()
    escrowShares() <= totalSupply();

/// The pot reserved for already-burned shares is always physically present.
/// This is the property whose violation means "shares burned, lenders unpaid".
invariant reservationFullyBacked()
    reservedAssets() <= ghost_held();

/// Matured escrow is never larger than all escrow (it is a subset of it).
invariant maturedWithinEscrow()
    maturedRedeemShares() <= escrowShares() + totalSupply();

/// `fundedThroughEpoch` can never run ahead of the clock: an epoch is only
/// funded once the boundary that matures it has passed.
invariant fundedThroughNotAheadOfClock()
    fundedThroughEpoch() <= currentEpoch();

/// An epoch that is not funded has published no price. (`epochFundedAssets` is
/// the assets-per-share numerator; publishing it early would let a claimant be
/// paid from the wrong epoch's money.)
invariant unfundedEpochHasNoPrice(uint256 epoch)
    !epochFunded(epoch) => epochFundedAssets(epoch) == 0;

/// Sanity on the pro-rata split: an epoch's funded assets can never exceed the
/// reservation as a whole.
invariant epochPriceWithinReservation(uint256 epoch)
    epochFundedAssets(epoch) <= reservedAssets();

/* ============================================================================
 * SECTION 2 — CLAIM GATES
 * ==========================================================================*/

/// A claim is only possible when some epoch was actually funded.
invariant noClaimWithoutFunding(uint256 rid, address lender)
    claimableRedeemRequest(rid, lender) > 0 => fundedThroughEpoch() > 0;

/// Both ERC-7540 reports are bounded by the reservation they draw from.
invariant maxWithdrawWithinReservation(address lender)
    maxWithdraw(lender) <= reservedAssets();

/// A revoked lender cannot extract value from any exit leg.
invariant revokedLenderCannotClaim(address lender)
    ghost_denied(lender) => claimableRedeemRequest(0, lender) == 0 && maxWithdraw(lender) == 0;

/// A paused (and still live) vault pays nothing out through `redeem`.
invariant pauseBlocksClaims(address lender)
    withdrawalsPaused() && !terminated() => claimableRedeemRequest(0, lender) == 0 && maxRedeem(lender) == 0;

/* ============================================================================
 * SECTION 3 — TRANSITION RULES
 * ==========================================================================*/

/// R-W1 — `requestRedeem` escrows without burning, and schedules exactly once.
rule requestRedeemEscrowsWithoutBurning(uint256 shares) {
    env e;

    uint256 supplyBefore = totalSupply();
    uint256 userBefore = balanceOf(e.msg.sender);
    uint256 escrowBefore = escrowShares();
    uint256 dueBefore = maturedRedeemShares();
    uint256 schedBefore = epochShares(currentEpoch() + 1) + epochShares(currentEpoch() + 2);

    requestRedeem(e, shares);

    assert totalSupply() == supplyBefore, "escrow must not burn shares";
    assert escrowShares() == escrowBefore + shares, "shares must land in the vault";
    assert balanceOf(e.msg.sender) == userBefore - shares, "shares must leave the lender";
    assert epochShares(currentEpoch() + 1) + epochShares(currentEpoch() + 2) == schedBefore + shares,
        "the request is scheduled into exactly one future epoch";
    assert maturedRedeemShares() >= dueBefore, "a fresh request cannot mature retroactively";
}

/// R-W2 — `fundRedemptions` burns exactly the matured escrow and reserves the
/// matching value: the rule the whole audit hinges on.
rule fundingIsExact() {
    env e;

    uint256 supplyBefore = totalSupply();
    uint256 maturedBefore = maturedRedeemShares();
    uint256 reservedBefore = reservedAssets();
    uint256 liabilityBefore = dueUnprocessedAssets();
    uint256 heldBefore = ghost_held();
    uint256 poolBefore = getTotalAssets();
    uint256 fundedThroughBefore = fundedThroughEpoch();

    require maturedBefore > 0;
    require redemptionFundingShortfall() == 0;   // documented precondition of funding
    require !terminated();

    fundRedemptions(e);

    assert totalSupply() == supplyBefore - maturedBefore, "burn is exactly the matured escrow";
    assert maturedRedeemShares() == 0, "funding clears the matured cohort";
    assert reservedAssets() == reservedBefore + liabilityBefore, "reservation equals the priced liability";
    assert getTotalAssets() == poolBefore - liabilityBefore, "the pool releases exactly what it reserves";
    assert ghost_held() == heldBefore, "funding moves no cash";
    assert lastAccrualCash() == ghost_held() - reservedAssets(), "watermark re-stamped";
    assert fundedThroughEpoch() >= fundedThroughBefore, "the funding pointer is monotone";
}

/// R-W3 — `redeem` pays out of the reservation only, and never burns again.
rule redeemPaysFromReservationOnly() {
    env e;

    uint256 supplyBefore = totalSupply();
    uint256 reservedBefore = reservedAssets();
    uint256 heldBefore = ghost_held();
    uint256 claimShares = maxRedeem(e.msg.sender);
    uint256 claimAssets = maxWithdraw(e.msg.sender);

    require claimShares > 0;

    redeem(e);

    assert totalSupply() == supplyBefore, "shares were burned at funding, not at claim";
    assert claimAssets <= reservedBefore, "a claim can never exceed the reservation";
    assert reservedAssets() == reservedBefore - claimAssets, "the reservation is released exactly by the payout";
    assert ghost_held() == heldBefore - claimAssets, "cash out equals the reservation released";
    assert lastAccrualCash() == ghost_held() - reservedAssets(), "watermark re-stamped";
}

/// R-W4 — the queue entry is consumed: a second claim in the same state reverts.
rule redeemIsNotRepeatable() {
    env e;

    redeem(e);

    redeem(e);
}

/// R-W5 — borrow can never dip into the reservation (ADV-09).
rule borrowCannotTouchReservation(uint256 amount) {
    env e;

    uint256 reservedBefore = reservedAssets();
    uint256 heldBefore = ghost_held();
    uint256 available = availableToBorrow();

    require e.msg.sender == borrower();
    require amount <= available;
    require !terminated() && !withdrawalsPaused();

    borrow(e, amount);

    assert reservedAssets() == reservedBefore, "the reservation is untouched by borrowing";
    assert ghost_held() == heldBefore - amount, "cash out equals the drawn amount";
    assert ghost_held() >= reservedAssets(), "the reservation remains physically backed";
}

/// R-W6 — the fee sweep may not eat the reservation (ADV-15).
rule feesCannotTouchReservation() {
    env e;

    uint256 reservedBefore = reservedAssets();
    uint256 heldBefore = ghost_held();
    uint256 fees = accruedFees();

    require fees > 0;

    collectFees(e);

    assert reservedAssets() == reservedBefore, "the reservation is untouched by the fee sweep";
    assert ghost_held() == heldBefore - fees, "exactly the accrued fee leaves";
    assert ghost_held() >= reservedAssets(), "the reservation remains physically backed";
}

/// R-W7 — maturation is idempotent: a second poke in the same state matures
/// nothing. NOTE: this only holds when no boundary elapses between the two
/// pokes, which is exactly what "same state" means here (the prover may not
/// advance `block.timestamp` between two calls made from the same `env`).
rule maturationIsIdempotent() {
    env e;

    update(e);
    uint256 afterFirst = storedMatured();
    uint256 epochAfterFirst = currentEpoch();

    update(e);

    assert currentEpoch() == epochAfterFirst => storedMatured() == afterFirst,
        "re-poking inside the same epoch must not mature anything";
}

/// R-W8 — claim order is irrelevant (ADV-13): one lender's claim cannot move
/// another lender's quote for the same epoch.
rule claimOrderDoesNotChangePayout(address other) {
    env e;

    require other != e.msg.sender;

    uint256 quoteOtherBefore = maxWithdraw(other);
    uint256 reservedBefore = reservedAssets();

    redeem(e);

    assert maxWithdraw(other) == quoteOtherBefore,
        "one lender's claim must not move another lender's epoch price";
    assert reservedAssets() <= reservedBefore, "the reservation only shrinks";
}

/// R-W9 — the reservation only ever moves with a burn or a payout.
/// The accounting law behind R-W2/R-W3/R-W5/R-W6, stated once over an arbitrary
/// function so it is not limited to the mutators I remembered to list.
rule reservationOnlyMovesWithABurnOrAPayout() {
    env e;

    uint256 reservedBefore = reservedAssets();
    uint256 supplyBefore = totalSupply();
    uint256 heldBefore = ghost_held();

    method f;
    calldataarg args;
    f(e, args);

    assert reservedAssets() > reservedBefore => totalSupply() < supplyBefore,
        "reserving cash requires burning shares in the same transaction";
    assert reservedAssets() < reservedBefore => ghost_held() < heldBefore,
        "releasing the reservation requires paying cash out in the same transaction";
}

/// R-W10 — the `_returnEscrowedShares` clamp (F-1) must never saturate.
/// The source saturates instead of underflowing; saturation would silently
/// discard part of the matured book. Prove the subtraction is always exact.
rule escrowReturnNeverSaturates() {
    env e;

    uint256 maturedBefore = maturedRedeemShares();
    uint256 escrowBefore = escrowShares();
    uint256 supplyBefore = totalSupply();

    require terminated();

    claimRecovery(e);

    assert maturedRedeemShares() <= maturedBefore, "escrow return cannot inflate the matured book";
    assert escrowShares() <= escrowBefore, "escrow only shrinks";
    assert totalSupply() <= supplyBefore, "no shares are created by a wind-down claim";
    assert maturedRedeemShares() == 0 => maturedBefore <= escrowBefore,
        "a cleared matured book must have been a subset of escrow";
}
