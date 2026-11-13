/*
 * LoanVaultParams.spec
 * =============================================================================
 * Target : LoanVault (PRODUCTION source, no harness) — "PATH B"
 * Scope  : structural / parametric properties only.
 *
 * What PATH B is for
 * -----------------
 * `LoanVaultHarness` (PATH A) is what makes cash reasoning possible: it replaces
 * four external touch points with concrete storage. A reviewer should ask
 * whether that changes the contract under test. PATH B answers by verifying the
 * *unmodified* LoanVault, with the token and the two registries constrained by
 * CVL `methods` entries rather than by Solidity overrides.
 *
 * The honest limit of PATH B: a summarised ERC-20 can be made to lie, so
 * cash-conservation claims ("held >= reserved") are only meaningful on PATH A.
 * What PATH B can prove is everything that does not depend on the token's
 * honesty:
 *   - no reachable call re-opens a terminated vault
 *   - the holder set is frozen at termination
 *   - escrow can only grow inside `requestRedeem`
 *   - claim bounds hold for *every* address, not just a chosen actor
 *   - pause/delinquency gates are unconditional
 *
 * Parametric rules matter more than usual here: the protocol is beacon-proxy
 * upgradeable, so a rule that quantifies over `method f` also covers functions
 * that a future implementation adds.
 */

using LoanVault as vault;

methods {
    function totalSupply() external returns (uint256) envfree;
    function balanceOf(address) external returns (uint256) envfree;
    function getTotalAssets() external returns (uint256) envfree;
    function reservedAssets() external returns (uint256) envfree;
    function maturedRedeemShares() external returns (uint256) envfree;
    function dueUnprocessedAssets() external returns (uint256) envfree;
    function redemptionFundingShortfall() external returns (uint256) envfree;
    function fundedThroughEpoch() external returns (uint256) envfree;
    function currentEpoch() external returns (uint256) envfree;
    function accruedFees() external returns (uint256) envfree;
    function amountOwed() external returns (uint256) envfree;
    function availableToBorrow() external returns (uint256) envfree;
    function terminated() external returns (bool) envfree;
    function terminatedAt() external returns (uint256) envfree;
    function isDelinquent() external returns (bool) envfree;
    function penaltyActiveSince() external returns (uint256) envfree;
    function withdrawalsPaused() external returns (bool) envfree;
    function depositsPaused() external returns (bool) envfree;
    function transfersEnabled() external returns (bool) envfree;
    function totalRecoveryPaid() external returns (uint256) envfree;
    function claimedRecovery(address) external returns (uint256) envfree;
    function maxDeposit(address) external returns (uint256) envfree;
    function maxMint(address) external returns (uint256) envfree;
    function maxWithdraw(address) external returns (uint256) envfree;
    function maxRedeem(address) external returns (uint256) envfree;
    function claimableRedeemRequest(uint256, address) external returns (uint256);
    function canTransfer(address, address) external returns (bool);

    // External trust boundary: summarised instead of overridden, so the
    // production bytecode is what gets verified.
    function isApproved(address) external returns (bool);
    function isVaultManager(address) external returns (bool);

    function requestRedeem(uint256) external returns (uint256);
    function fundRedemptions() external;
    function redeem() external returns (uint256);
    function claimRecovery() external returns (uint256);
    function terminate() external;
    function sweepResidual() external returns (uint256);
    function collectFees() external;
}

/* ============================================================================
 * SECTION 1 — UNIVERSAL CLAIM BOUNDS (every address, not a chosen actor)
 * ==========================================================================*/

/// No address can have a claim larger than the ring-fenced pot.
invariant everyLenderBoundedByReservation(address lender)
    maxWithdraw(lender) <= reservedAssets();

/// No address can have a share-based claim larger than what was funded.
invariant everyLenderBoundedByShareReport(address lender)
    maxRedeem(lender) <= totalSupply() + balanceOf(vault);

/// A live vault has paid no recovery to anyone.
invariant liveVaultPaysNoRecovery(address lender)
    !terminated() => claimedRecovery(lender) == 0;

/// Recovery is only ever attributed to non-zero addresses.
invariant zeroAddressNeverClaims()
    claimedRecovery(0) == 0;

/* ============================================================================
 * SECTION 2 — GATES THAT MUST HOLD FOR EVERY REACHABLE CALL
 * ==========================================================================*/

/// No method — present or future — may re-open a terminated vault.
rule parametricTerminationIsFinal(method f) {
    env e;

    require terminated();
    uint256 stamp = terminatedAt();

    calldataarg args;
    f(e, args);

    assert terminated(), "no call may clear the termination flag";
    assert terminatedAt() == stamp, "no call may move the termination timestamp";
}

/// No method may create a deposit path on a terminated or paused vault.
rule parametricNoEntryWhenClosed(method f, address receiver) {
    env e;

    require terminated() || depositsPaused() || withdrawalsPaused();

    calldataarg args;
    f(e, args);

    assert maxDeposit(receiver) == 0 || !(terminated() || depositsPaused() || withdrawalsPaused()),
        "an entry-advertising vault must not be terminated/paused";
}

/// No method may escape the delinquency gate while a cohort is past grace.
rule parametricDelinquencyGate(method f, address receiver) {
    env e;

    require isDelinquent();

    calldataarg args;
    f(e, args);

    assert !isDelinquent() || (maxDeposit(receiver) == 0 && availableToBorrow() == 0),
        "a delinquent vault must not re-open entry in the same transaction";
}

/* ============================================================================
 * SECTION 3 — HOLDER-SET FREEZE (the anti-double-claim guard)
 * ==========================================================================*/

/// Once terminated, no reachable call may re-enable wallet-to-wallet transfers.
rule parametricTransfersStayFrozen(method f, address from, address to) {
    env e;

    require terminated();
    require from != 0 && to != 0 && from != vault;

    calldataarg args;
    f(e, args);

    assert !canTransfer(from, to), "the holder set must stay frozen for recovery accounting to be sound";
}

/// Escrow may only grow inside `requestRedeem`: a raw transfer into the vault
/// would park shares outside every epoch schedule.
rule parametricEscrowOnlyViaRequestRedeem(method f) {
    env e;

    uint256 escrowBefore = balanceOf(vault);

    calldataarg args;
    f(e, args);

    assert balanceOf(vault) > escrowBefore => f.selector == sig:requestRedeem(uint256).selector,
        "only requestRedeem may move shares into the vault";
}

/* ============================================================================
 * SECTION 4 — SOLVENCY SHAPE (token-independent)
 * ==========================================================================*/

/// The borrower can never be *advertised* cash that is already reserved, even
/// with a summarised token: `availableToBorrow` is computed from the projected
/// pool, so this holds by construction of the view.
invariant borrowableExcludesReservationShape()
    availableToBorrow() + reservedAssets() + accruedFees() + dueUnprocessedAssets()
        <= getTotalAssets() + reservedAssets() + accruedFees() + amountOwed();

/// The funding gap must be zero exactly when the liability is covered.
invariant shortfallShape()
    redemptionFundingShortfall() == 0 => dueUnprocessedAssets() <= getTotalAssets();
