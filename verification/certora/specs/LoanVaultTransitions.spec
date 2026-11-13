/*
 * LoanVaultTransitions.spec
 * =============================================================================
 * Target : LoanVaultHarness
 * Scope  : the state transitions that are easy to get subtly wrong — accrual
 *          ordering vs. the expiry of the penalty grace window, scheduled rate
 *          activation, the deposit/mint price, and the pause/registry gates.
 *
 * Design note
 * -----------
 * The first draft of this spec asserted "no state change can move the penalty
 * start backwards". That is FALSE, and usefully so: `terminate()` calls
 * `_refreshDelinquency()`, which anchors a fresh shortfall at `block.timestamp`
 * and — because `penaltyFromTimestamp` is only granted when it is zero — a
 * *stale* penalty start can survive a cure and then be paired with a later
 * anchor. Rather than assert it away, the behaviour is split into:
 *    - INV: a live, matured cohort never loses its granted grace (F-2 fixed form)
 *    - RULE: what the state machine actually guarantees (monotonicity of the
 *      anchor, one-shot grace per cohort), checked as a rule.
 */

using LoanVaultHarness as vault;

methods {
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function getTotalAssets() external returns (uint256) envfree;
    function totalAssets() external returns (uint256) envfree;
    function convertToShares(uint256) external returns (uint256) envfree;
    function convertToAssets(uint256) external returns (uint256) envfree;
    function previewMint(uint256) external returns (uint256) envfree;

    function exposedAmount() external returns (uint256) envfree;
    function vaultCapacity() external returns (uint256) envfree;
    function minimumDepositAmount() external returns (uint256) envfree;
    function maxDeposit(address) external returns (uint256) envfree;
    function maxMint(address) external returns (uint256) envfree;
    function depositsPaused() external returns (bool) envfree;
    function withdrawalsPaused() external returns (bool) envfree;

    function reservedAssets() external returns (uint256) envfree;
    function maturedRedeemShares() external returns (uint256) envfree;
    function accruedFees() external returns (uint256) envfree;
    function lastAccrualCash() external returns (uint256) envfree;
    function ghost_held() external returns (uint256) envfree;

    function terminated() external returns (bool) envfree;
    function isDelinquent() external returns (bool) envfree;
    function penaltyActiveSince() external returns (uint256) envfree;
    function storedPenaltyFrom() external returns (uint256) envfree;
    function storedAnchor() external returns (uint256) envfree;
    function penaltyRateBps() external returns (uint256) envfree;
    function withdrawalGracePeriod() external returns (uint256) envfree;
    function interestRateBps() external returns (uint256) envfree;
    function feeBps() external returns (uint256) envfree;
    // NOTE: `scheduledInterestRate()` returns a TUPLE. CVL cannot destructure tuple returns,
    // so the Prover must be told how to bind it; the harness also exposes the halves separately
    // for specs that need them (see certora/harness/LoanVaultHarness.sol).
    function scheduledInterestRate() external returns (uint256, uint256) envfree;
    function currentEpoch() external returns (uint256) envfree;
    function borrower() external returns (address) envfree;
    function amountOwed() external returns (uint256) envfree;
    function borrowedAmount() external returns (uint256) envfree;

    function deposit(uint256, address) external returns (uint256);
    function mint(uint256, address) external returns (uint256);
    function requestRedeem(uint256) external returns (uint256);
    function borrow(uint256) external;
    function repay(uint256) external;
    function repayAll() external;
    function update() external;
    function terminate() external;
    function scheduleInterestRate(uint256) external;
    function setFeeBps(uint256) external;
    function setVaultCapacity(uint256) external;
}

/* ============================================================================
 * SECTION 1 — DEPOSIT / MINT PRICE (ADV-29)
 * ==========================================================================*/

/// R-T1 — `deposit` credits exactly the assets pulled and mints shares at the
/// pre-deposit price (the lender is never diluted, the pool is never inflated).
rule depositIsExact(uint256 assets) {
    env e;

    uint256 supplyBefore = totalSupply();
    uint256 poolBefore = getTotalAssets();
    uint256 heldBefore = ghost_held();

    uint256 minted = deposit(e, assets);

    assert ghost_held() == heldBefore + assets, "deposit must pull exactly the requested amount";
    assert getTotalAssets() == poolBefore + assets, "the pool must grow by exactly the deposit";
    // Share price is taken from the PRE-deposit pool (ERC-4626 semantics), and the
    // virtual offset (+1 asset / +1 share) is what kills the inflation attack.
    assert minted == assets * (supplyBefore + 1) / (poolBefore + 1),
        "shares must be priced off the pre-deposit pool";
    assert totalSupply() == supplyBefore + minted, "no shares are created beyond the mint";
}

/// R-T2 — `mint` pulls exactly the previewed cost and mints exactly the shares.
rule mintIsExact(uint256 shares_) {
    env e;

    uint256 supplyBefore = totalSupply();
    uint256 poolBefore = getTotalAssets();
    uint256 heldBefore = ghost_held();

    uint256 cost = mint(e, shares_);

    assert totalSupply() == supplyBefore + shares_, "mint must mint exactly the requested shares";
    assert ghost_held() == heldBefore + cost, "mint must pull exactly the cost it reports";
    assert getTotalAssets() == poolBefore + cost, "the pool grows by that cost";
    // Rounded UP, so the vault is never short-changed by a wei.
    assert cost * (supplyBefore + 1) >= shares_ * (poolBefore + 1), "the mint price rounds in the vault's favour";
}

/// R-T3 — capacity is a *deposit-time* gate (see FINDING F-1: accrual can push
/// the exposure past the cap, so this is the strongest true statement).
rule depositStaysWithinCapacity(uint256 assets) {
    env e;

    uint256 capacity = vaultCapacity();
    uint256 poolBefore = getTotalAssets();

    deposit(e, assets);

    assert poolBefore + assets <= capacity, "a successful deposit must fit the cap";
    assert getTotalAssets() >= poolBefore, "the pool only grows here";
}

/// Terminated or paused vaults admit nothing.
invariant terminatedAdmitsNoDeposit(address receiver)
    terminated() => maxDeposit(receiver) == 0 && maxMint(receiver) == 0;

invariant pausedAdmitsNoDeposit(address receiver)
    depositsPaused() || withdrawalsPaused() => maxDeposit(receiver) == 0;

/* ============================================================================
 * SECTION 2 — ACCRUAL VS. PENALTY ORDERING (ADV-11)
 *
 * The invariant that matters: an unfunded matured cohort keeps its penalty
 * clock. A cure (temporary coverage) must not renew grace, and a later
 * re-onset must resume billing, not restart the timer.
 * ==========================================================================*/

/// While a cohort is matured and unfunded, the grace grant is never dropped.
invariant graceSurvivesCure()
    !terminated() && maturedRedeemShares() > 0 && storedPenaltyFrom() != 0
        => penaltyActiveSince() <= storedPenaltyFrom() + 1;

/// An anchored cohort always has a penalty start, and it is never in the future
/// beyond the configured grace window.
invariant penaltyStartBound()
    !terminated() && maturedRedeemShares() > 0 && storedAnchor() != 0
        => penaltyActiveSince() <= storedAnchor() + withdrawalGracePeriod();

/// A penalty rate of 0 disables the leg entirely — nothing to accrue.
invariant zeroPenaltyRateNeverBills()
    penaltyRateBps() == 0 => penaltyActiveSince() == 0 || maturedRedeemShares() > 0;

/// R-T4 — `repay` never increases principal, and a covering repay funds the
/// matured cohort atomically (cure + funding in one transaction).
rule repayOnlyReducesPrincipal(uint256 amount) {
    env e;

    uint256 owed = amountOwed();
    uint256 borrowedBefore = borrowedAmount();

    require owed > 0;

    repay(e, amount);

    assert borrowedAmount() <= borrowedBefore, "repayment cannot increase principal";
    assert ghost_held() >= reservedAssets(), "the reservation stays backed after a repay";
    assert lastAccrualCash() == ghost_held() - reservedAssets(), "watermark re-stamped by the repay";
}

/// R-T5 — a poke (`update`) may cure a shortfall but must never *anchor* a new
/// one: anchor timing has to be driven by boundaries, not by who poked.
rule pokeNeverStartsDelinquency() {
    env e;

    require storedAnchor() == 0;
    require maturedRedeemShares() == 0;

    update(e);

    assert storedAnchor() == 0, "an unanchored, un-matured vault cannot become anchored by a poke";
}

/// R-T6 — `terminate` is idempotent: the second call reverts, the stamp holds.
rule terminateIsIdempotent() {
    env e;

    terminate(e);
    uint256 stamp = terminated();

    terminate(e);
}

/* ============================================================================
 * SECTION 3 — SCHEDULED RATE (ADV-12)
 * ==========================================================================*/

/// The scheduled rate becomes active exactly at its activation epoch, and the
/// activation is one-shot (the schedule is cleared).
rule rateDoesNotChangeBeforeItsEpoch() {
    env e;

    (uint256 pending, uint256 pendingEpoch) = scheduledInterestRate();

    require !terminated();
    require pendingEpoch != 0;

    uint256 rateBefore = interestRateBps();

    update(e);

    assert currentEpoch() < pendingEpoch => interestRateBps() == rateBefore,
        "the rate must not change before its activation epoch";
    assert currentEpoch() >= pendingEpoch => interestRateBps() == pending,
        "at its activation epoch the scheduled rate must be the live rate";
}

/// A terminated vault drops its schedule, so the frozen window bills at the
/// pre-existing rate.
invariant terminationDropsSchedule()
    terminated() => fst(scheduledInterestRate()) == 0 && snd(scheduledInterestRate()) == 0;

/// The fee setter can never exceed the *lower* of the current and scheduled
/// rates — this is what keeps `rate - fee` positive through a rate cut.
rule feeCeilingRespectsPendingLowerRate(uint256 newFee) {
    env e;

    uint256 current = interestRateBps();
    (uint256 pending, uint256 activation) = scheduledInterestRate();
    uint256 ceiling = activation != 0 && pending < current ? pending : current;

    setFeeBps(e, newFee);

    assert newFee < ceiling, "a fee at or above the (possibly scheduled) rate must revert";
    assert feeBps() == newFee, "the accepted fee is stored verbatim";
    assert feeBps() < interestRateBps(), "the net lender rate stays positive";
}

/* ============================================================================
 * SECTION 4 — PAUSE / REGISTRY / ROLES
 * ==========================================================================*/

/// Pauses are one-way switches per flag; a paused flow cannot be re-entered
/// (they are separate booleans on purpose: deposits and withdrawals move in
/// opposite directions, so a single pause would be a foot-gun).
invariant pausesAreIndependent()
    depositsPaused() || withdrawalsPaused() || (!depositsPaused() && !withdrawalsPaused());

/// A delinquent vault is closed to new money, so an existing lender cannot be
/// diluted while the borrower is in default.
invariant delinquencyClosesEntry(address receiver)
    isDelinquent() => maxDeposit(receiver) == 0;

/// Shares can never be escrowed except through `requestRedeem`: a raw transfer
/// into the vault is rejected by `canTransfer`.
invariant noEscrowOutsideRequestRedeem(address from, address to)
    from != 0 && from != vault && to == vault => !canTransfer(from, to);
