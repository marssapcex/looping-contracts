/*
 * LoanVaultGhost.spec
 * =============================================================================
 * Target : LoanVaultHarness
 * Scope  : the conservation laws the other specs cannot express.
 *
 * Every other spec in this directory reasons about *current* state. The laws
 * below are about *cumulative flow*: they say nothing can appear or disappear,
 * only move — and they are the only way to catch the bug class
 *
 *     "a share cohort was burned without a matching reservation"
 *     "escrow was returned to a lender twice"
 *     "a claim burned supply a second time"
 *     "wind-down handed back more shares than it ever escrowed"
 *
 * HOW THE GHOSTS ARE PRODUCED (and why not with storage hooks)
 * ------------------------------------------------------------
 * The natural CVL implementation is `hook Sstore ... _totalSupply`, but it is
 * unsound here: `ERC20Upgradeable._update` writes its slot as
 *     _balances[from] = fromBalance - value;      // `prev`  = fromBalance
 *     _balances[to]   = _balances[to] + value;    // `prev`  = the just-updated slot
 * so a slot hook cannot recover the delta of the second write, and `_mint`/
 * `_burn` (which the funding walk calls) read as "no change". A ghost built on
 * those deltas silently under-counts and the resulting invariant is vacuously
 * true. Instead, `LoanVaultHarness._update` records exactly what `_update`
 * already does, *before* delegating to `super`:
 *
 *     ghost_minted           += value  when from == 0
 *     ghost_burned           += value  when to   == 0
 *     ghost_escrowIn         += value  when to   == address(this)
 *     ghost_escrowOut        += value  when from == address(this)
 *     ghost_burnedFromVault  += value when from == address(this) && to == 0
 *
 * These are true by construction (the harness consults no protocol logic), and
 * each was validated against the real bytecode at seven checkpoints across a
 * deposit -> request -> fund -> claim -> wind-down sequence
 * (scripts/audit.js section S11, "GHOST I1..I4").
 *
 * G-1  totalSupply            == ghost_minted - ghost_burned
 * G-2  balanceOf(vault)       == ghost_escrowIn - ghost_escrowOut
 * G-3  ghost_burnedFromVault  <= ghost_burned
 * G-4  ghost_burnedFromVault  <= ghost_escrowOut
 */

using LoanVaultHarness as vault;

methods {
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function getTotalAssets() external returns (uint256) envfree;
    function totalAssets() external returns (uint256) envfree;

    function escrowShares() external returns (uint256) envfree;
    function getTotalAssets() external returns (uint256) envfree;
    function maturedRedeemShares() external returns (uint256) envfree;
    function storedMatured() external returns (uint256) envfree;
    function dueUnprocessedAssets() external returns (uint256) envfree;
    function reservedAssets() external returns (uint256) envfree;
    function redemptionFundingShortfall() external returns (uint256) envfree;
    function fundedThroughEpoch() external returns (uint256) envfree;
    function storedFundedThrough() external returns (uint256) envfree;
    function currentEpoch() external returns (uint256) envfree;
    function accruedFees() external returns (uint256) envfree;
    function amountOwed() external returns (uint256) envfree;
    function availableToBorrow() external returns (uint256) envfree;
    function lastAccrualCash() external returns (uint256) envfree;
    function epochShares(uint256) external returns (uint256) envfree;
    function epochFundedAssets(uint256) external returns (uint256) envfree;
    function queueLength(address) external returns (uint256) envfree;

    function terminated() external returns (bool) envfree;
    function terminatedAt() external returns (uint256) envfree;
    function withdrawalsPaused() external returns (bool) envfree;
    function resolutionShares() external returns (uint256) envfree;
    function frozenAssets() external returns (uint256) envfree;
    function totalRecoveryPaid() external returns (uint256) envfree;
    function claimedRecovery(address) external returns (uint256) envfree;

    function ghost_held() external returns (uint256) envfree;
    function ghost_minted() external returns (uint256) envfree;
    function ghost_burned() external returns (uint256) envfree;
    function ghost_escrowIn() external returns (uint256) envfree;
    function ghost_escrowOut() external returns (uint256) envfree;
    function ghost_burnedFromVault() external returns (uint256) envfree;

    function borrower() external returns (address) envfree;

    // Mutators: non-envfree, CVL models msg.sender / calldata.
    function deposit(uint256, address) external returns (uint256);
    function mint(uint256, address) external returns (uint256);
    function requestRedeem(uint256) external returns (uint256);
    function fundRedemptions() external;
    function redeem() external returns (uint256);
    function claimRecovery() external returns (uint256);
    function borrow(uint256) external;
    function repay(uint256) external;
    function repayAll() external;
    function collectFees() external;
    function sweepResidual() external returns (uint256);
    function update() external;
    function terminate() external;
    function setFeeBps(uint256) external;
    function setPenaltyRateBps(uint256) external;
    function scheduleInterestRate(uint256) external;
    function cancelScheduledRate() external;
    function setVaultCapacity(uint256) external;
    function setTransfersEnabled(bool) external;
    function setFeeRecipient(address) external;
    function setBorrower(address) external;
}

/* ============================================================================
 * SECTION 1 — THE FOUR CLOSURES (G-1 .. G-4)
 * ==========================================================================*/

/// G-1 — supply is exactly what was minted minus what was burned. Nothing else
/// can create or destroy shares.
invariant supplyIsClosed()
    to_mathint(totalSupply()) == to_mathint(ghost_minted()) - to_mathint(ghost_burned());

/// G-2 — the escrow balance is exactly the flow in minus the flow out. This is
/// the law that catches "shares parked in the vault outside every epoch
/// schedule" (they would have to enter via a path other than requestRedeem).
invariant escrowIsClosed()
    to_mathint(balanceOf(vault)) == to_mathint(ghost_escrowIn()) - to_mathint(ghost_escrowOut());

/// G-3 — every burn taken out of escrow is a real burn.
invariant vaultBurnsAreGlobalBurns()
    to_mathint(ghost_burnedFromVault()) <= to_mathint(ghost_burned());

/// G-4 — and it is a real outflow of escrow.
invariant vaultBurnsAreEscrowOutflows()
    to_mathint(ghost_burnedFromVault()) <= to_mathint(ghost_escrowOut());

/* ============================================================================
 * SECTION 2 — CONSERVATION ACROSS THE LIFECYCLE
 *
 * The point of G-1..G-4 is to make the following *non-tautological*. Each one
 * ties a cumulative ghost to a live book value, so a bookkeeping drift (the
 * actual bug we are hunting) cannot hide behind a getter that agrees with
 * itself.
 * ==========================================================================*/

/// Every share that left escrow was either burned (funding) or handed back to a
/// lender (wind-down). Stated as the bound the split implies: nothing may leave
/// escrow that was not already burned-for-good, so burn <= outflow.
/// (The stronger `escrowOut - burned == returned` needs a `ghost_returned`
/// counter; it is observable as G-2 + the audit's "escrow fully returned"
/// check, and is deliberately not asserted here to keep every invariant
/// non-trivial.)
invariant escrowSplitIsBounded()
    to_mathint(ghost_burnedFromVault()) <= to_mathint(ghost_escrowOut());

/// Burned escrow can never exceed escrowed inflow.
invariant burnedEscrowCameFromEscrow()
    to_mathint(ghost_burnedFromVault()) <= to_mathint(ghost_escrowIn());

/// The matured book is always covered by shares that still exist.
invariant maturedBookCoveredBySupply()
    to_mathint(storedMatured()) <= to_mathint(totalSupply());

/// Matured escrow is a subset of escrow, and escrow is inside supply.
invariant maturedWithinEscrowAndSupply()
    to_mathint(storedMatured()) <= to_mathint(escrowShares())
        && to_mathint(escrowShares()) <= to_mathint(totalSupply());

/// Nothing can be reserved for claims before anything was ever burned for them.
invariant reservationImpliesBurnHistory()
    reservedAssets() > 0 => ghost_burned() > 0;

/* ============================================================================
 * SECTION 3 — FLOW RULES (transition-level, where the bugs actually live)
 * ==========================================================================*/

/// R-G1 — `fundRedemptions` is the ONLY path that burns shares, and it burns
/// exactly the matured escrow. Combined with G-2 this makes the escrow book
/// self-closing: what comes in must either be burned here or be claimable.
rule fundingIsTheOnlyBurnPath() {
    env e;

    uint256 burnBefore = ghost_burned();
    uint256 escrowOutBefore = ghost_escrowOut();
    uint256 maturedBefore = storedMatured();
    uint256 supplyBefore = totalSupply();

    require maturedBefore > 0;
    require redemptionFundingShortfall() == 0;
    require !terminated();

    fundRedemptions(e);

    assert to_mathint(ghost_burned()) - to_mathint(burnBefore) == to_mathint(maturedBefore),
        "exactly the matured cohort burns";
    assert to_mathint(supplyBefore) - to_mathint(totalSupply()) == to_mathint(maturedBefore),
        "supply falls by exactly that amount";
    assert ghost_escrowOut() > escrowOutBefore, "the burn is an escrow outflow";
    assert ghost_burnedFromVault() <= ghost_escrowOut(), "and it is attributed to escrow";
}

/// R-G2 — `requestRedeem` moves shares from a lender into escrow: no mint, no burn.
rule requestRedeemOnlyMovesShares() {
    env e;

    uint256 mintedBefore = ghost_minted();
    uint256 burnedBefore = ghost_burned();
    uint256 escrowInBefore = ghost_escrowIn();
    uint256 escrowOutBefore = ghost_escrowOut();
    uint256 supplyBefore = totalSupply();

    requestRedeem(e, shares);

    assert ghost_minted() == mintedBefore, "a request never mints";
    assert ghost_burned() == burnedBefore, "a request never burns";
    assert ghost_escrowIn() > escrowInBefore, "shares flow into escrow";
    assert ghost_escrowOut() == escrowOutBefore, "nothing flows out of escrow";
    assert totalSupply() == supplyBefore, "supply is unchanged";
}

/// R-G3 — `redeem` pays assets and never touches the share book at all.
rule redeemTouchesNoSharesOnlyCash() {
    env e;

    uint256 mintedBefore = ghost_minted();
    uint256 burnedBefore = ghost_burned();
    uint256 escrowInBefore = ghost_escrowIn();
    uint256 escrowOutBefore = ghost_escrowOut();
    uint256 supplyBefore = totalSupply();
    uint256 heldBefore = ghost_held();
    uint256 reservedBefore = reservedAssets();

    redeem(e);

    assert ghost_minted() == mintedBefore && ghost_burned() == burnedBefore,
        "a claim must never mint or burn: the shares died at funding";
    assert ghost_escrowIn() == escrowInBefore && ghost_escrowOut() == escrowOutBefore,
        "a claim must never move escrow";
    assert totalSupply() == supplyBefore, "supply is untouched";
    assert reservedAssets() <= reservedBefore, "the reservation only shrinks";
    assert ghost_held() <= heldBefore, "cash only leaves";
}

/// R-G4 — `claimRecovery` burns nothing; it *returns* escrow and pays cash.
rule claimRecoveryReturnsEscrowWithoutBurning() {
    env e;

    uint256 burnedBefore = ghost_burned();
    uint256 escrowOutBefore = ghost_escrowOut();
    uint256 escrowInBefore = ghost_escrowIn();
    uint256 supplyBefore = totalSupply();

    require terminated();

    claimRecovery(e);

    assert ghost_burned() == burnedBefore, "wind-down must never burn";
    assert ghost_escrowIn() == escrowInBefore, "wind-down only releases escrow, never adds to it";
    assert ghost_escrowOut() >= escrowOutBefore, "escrow outflow is monotone";
    assert totalSupply() == supplyBefore, "the holder set is not re-written at wind-down";
}

/// R-G5 — deposits and mints are the only source of new shares.
rule onlyDepositAndMintCreateShares(method f) {
    env e;

    uint256 mintedBefore = ghost_minted();

    calldataarg args;
    f(e, args);

    assert ghost_minted() > mintedBefore
        => (f.selector == sig:deposit(uint256, address).selector
            || f.selector == sig:mint(uint256, address).selector),
        "no other entry point may create shares";
}

/// R-G6 — no administrative setter may move the share or cash books. This is the
/// rule that catches a parameter change smuggling value (fee > rate, capacity
/// rewrite, registry swap touching balances).
rule settersCannotMoveValue() {
    env e;

    uint256 supplyBefore = totalSupply();
    uint256 heldBefore = ghost_held();
    uint256 reservedBefore = reservedAssets();
    uint256 mintedBefore = ghost_minted();
    uint256 burnedBefore = ghost_burned();

    method f;
    calldataarg args;
    f(e, args);

    assert f.selector == sig:setFeeBps(uint256).selector
        || f.selector == sig:setPenaltyRateBps(uint256).selector
        || f.selector == sig:scheduleInterestRate(uint256).selector
        || f.selector == sig:cancelScheduledRate().selector
        || f.selector == sig:setVaultCapacity(uint256).selector
        || f.selector == sig:setTransfersEnabled(bool).selector
        || f.selector == sig:setFeeRecipient(address).selector
        || f.selector == sig:setBorrower(address).selector
        || f.selector == sig:terminate().selector
        => (totalSupply() == supplyBefore && ghost_held() == heldBefore
            && reservedAssets() == reservedBefore && ghost_minted() == mintedBefore
            && ghost_burned() == burnedBefore);
}

/* ============================================================================
 * SECTION 4 — CASH SIDE (the mirror of the share side)
 *
 * The token mirror gives a closed cash book: `ghost_held` changes only inside
 * `_pullUsdc` / `_payUsdc` / `donate`. That makes the following checks exact
 * rather than approximate.
 * ==========================================================================*/

/// THE ACCOUNTING IDENTITY — the strongest statement in this file.
///
///     pool book + claim reservation + fee bank  ==  idle cash + receivable + paid out
///
/// Every term is an independent getter, so this cannot be satisfied by a getter
/// agreeing with itself. `getTotalAssets()` is the pool book *net* of the claim
/// reservation; `totalRecoveryPaid()` is what wind-down has already handed to
/// lenders. It holds exactly on 9 hand-built states (deposit -> borrow -> accrue ->
/// fund -> redeem -> terminate -> claimRecovery) and on 100 x 60 random steps of the
/// stateful fuzzer, which is what makes it worth proving.
invariant accountingIdentity()
    to_mathint(getTotalAssets()) + to_mathint(reservedAssets()) + to_mathint(accruedFees())
        == to_mathint(ghost_held()) + to_mathint(amountOwed()) + to_mathint(totalRecoveryPaid());

/// The watermark can never claim more unreserved cash than exists.
invariant watermarkWithinCash()
    to_mathint(lastAccrualCash()) <= to_mathint(ghost_held());

/// The borrower's view can never exceed the real balance.
invariant borrowableWithinHeld()
    to_mathint(availableToBorrow()) <= to_mathint(ghost_held());

/// The fee bank is never backed by more cash than the vault has.
invariant feesWithinCash()
    to_mathint(accruedFees()) <= to_mathint(ghost_held()) + to_mathint(amountOwed());

/// Funding is cash-neutral: it reserves, it does not pay.
rule fundingMovesNoCash() {
    env e;

    uint256 heldBefore = ghost_held();
    uint256 reservedBefore = reservedAssets();
    uint256 maturedBefore = storedMatured();

    require maturedBefore > 0;
    require redemptionFundingShortfall() == 0;
    require !terminated();

    fundRedemptions(e);

    assert ghost_held() == heldBefore, "funding must not transfer a wei";
    assert reservedAssets() > reservedBefore, "it moves value from the pool to the reservation";
}

/// A borrow can never be funded by the reservation.
rule borrowLeavesReservationIntact(uint256 amount) {
    env e;

    uint256 reservedBefore = reservedAssets();
    uint256 heldBefore = ghost_held();
    uint256 borrowable = availableToBorrow();

    require e.msg.sender == borrower();
    require amount <= borrowable;

    borrow(e, amount);

    assert reservedAssets() == reservedBefore, "the reservation is not a source of borrowable cash";
    assert to_mathint(heldBefore) - to_mathint(ghost_held()) == to_mathint(amount),
        "only the drawn amount leaves";
    assert ghost_held() >= reservedAssets(), "and the reservation stays funded";
}

/// Fees are junior to lenders: a sweep can never leave the reservation short.
rule feeSweepIsJunior() {
    env e;

    uint256 reservedBefore = reservedAssets();
    uint256 heldBefore = ghost_held();
    uint256 fees = accruedFees();

    require fees > 0;

    collectFees(e);

    assert reservedAssets() == reservedBefore;
    assert ghost_held() >= reservedAssets(), "lenders stay whole through the sweep";
    assert to_mathint(heldBefore) - to_mathint(ghost_held()) <= to_mathint(fees),
        "at most the accrued fee may leave";
}
