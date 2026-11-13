// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { LoanVault } from "../../src/LoanVault.sol";
import { WithdrawalQueueLibrary } from "../../src/WithdrawalQueueLibrary.sol";

using WithdrawalQueueLibrary for WithdrawalQueueLibrary.WithdrawalQueue;

/// @title LoanVaultHarness
/// @notice Verification wrapper around the *unmodified* LoanVault.
///
/// Why this exists: four vault dependencies are external calls to unknown code
/// (`loanAsset.balanceOf`, `loanAsset.safeTransfer(From)`, `lenderRegistry.isApproved`,
/// `roleManager.isVaultManager`). Under the Certora Prover every external call is havoced, which turns
/// `_cashForClaims()`, the delinquency test, funding and the recovery pool into unconstrained values.
/// Invariants stated over them are then either vacuous or trivially false, and the counterexamples are
/// meaningless.
///
/// The harness overrides those four touch points with a concrete, in-storage mirror of the token balance
/// and a storage-backed admission answer. The result is a closed system: no external call survives in the
/// verified bytecode, so every reachable state is a real protocol state and every counterexample is a
/// real sequence of protocol calls.
///
/// Deliberate choices:
///  * `_isApprovedLender` defaults to **true** and can be revoked/invoked through `setApproved`, so the
///    prover can reach every exit leg *and* the revoked-lender paths.
///  * `ghost_*` views expose the daily liquidity accounting (reserved + matured + fees vs. held cash)
///    that the production ABI does not surface.
contract LoanVaultHarness is LoanVault {
    /// @dev Mirrors the loan-asset balance held by this contract (the source of `_heldAssetsUsdc`).
    uint256 public ghost_held;

    // ---- Share-flow ghosts -------------------------------------------------
    // Maintained by overriding `_update` and recording *exactly* what it already
    // does. No protocol logic is consulted, so these are true by construction and
    // give the CVL a conservation law it can actually close:
    //     totalSupply            == ghost_minted - ghost_burned
    //     balanceOf(address(this)) == ghost_escrowIn - ghost_escrowOut
    //     ghost_burned            == ghost_burnedFromVault
    uint256 public ghost_minted;
    uint256 public ghost_burned;
    uint256 public ghost_escrowIn;
    uint256 public ghost_escrowOut;
    uint256 public ghost_burnedFromVault;

    /// @dev Transparent instrumentation. Placed BEFORE `super._update` so a reverting
    ///      transfer can never leave the ghost ahead of the real state.
    function _update(address from, address to, uint256 value) internal override {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00000000, 1037618708480) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00000001, 3) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00001000, from) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00001001, to) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00001002, value) }
        if (from == address(0)) ghost_minted += value;
        if (to == address(0)) ghost_burned += value;
        if (to == address(this)) ghost_escrowIn += value;
        if (from == address(this)) {
            ghost_escrowOut += value;
            if (to == address(0)) ghost_burnedFromVault += value;
        }
        super._update(from, to, value);
    }

    /// @dev The address allowed through `onlyVaultManager`.
    address public immutable harnessManager;

    /// @dev Explicit denials; everything else is admitted.
    mapping(address => bool) public ghost_denied;

    constructor(address manager_) {
        harnessManager = manager_;
        // `LoanVault`'s constructor calls `_disableInitializers()`, which exists to lock the *implementation*
        // behind a beacon proxy. The prover models a single instance, not the factory + proxy pair, so the
        // lock is undone here. This changes no vault logic: it only re-opens `initialize()` on this instance.
        assembly {
            sstore(0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00, 0)
        }
    }

    // ============================================================
    // Money movement (concrete mirror of a well-behaved ERC-20)
    // ============================================================

    /// @dev Overrides `LoanVaultDeposits._heldAssetsUsdc`.
    function _heldAssetsUsdc() internal view override returns (uint256) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00010000, 1037618708481) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00010001, 0) }
        return ghost_held;
    }

    /// @dev Same effect as `safeTransferFrom` from a well-behaved ERC-20: the vault is credited.
    ///      Fee-on-transfer assets are excluded by `deposit()`'s own balance check.
    function _pullUsdc(address, uint256 usdcAmount) internal override {
        unchecked {
            ghost_held += usdcAmount;
        }
        _stampCashWatermark();
    }

    /// @dev `require` instead of silent underflow: a payout above the mirrored balance is a hard
    ///      counterexample, never a wrapped value.
    function _payUsdc(address to, uint256 usdcAmount) internal override {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00040000, 1037618708484) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00040001, 2) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00041000, to) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00041001, usdcAmount) }
        require(to != address(0), "PAY_TO_ZERO");
        require(ghost_held >= usdcAmount, "PAY_EXCEEDS_HELD");
        unchecked {
            ghost_held -= usdcAmount;
        }
        _stampCashWatermark();
    }

    // ============================================================
    // Access control / admission
    // ============================================================

    function _requireVaultManager() internal view override {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00020000, 1037618708482) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00020001, 0) }
        require(msg.sender == harnessManager, "NOT_MANAGER");
    }

    /// @dev Stands in for `lenderRegistry.isApproved(who)`. Default is admitted (so every exit leg is
    ///      reachable); `setApproved(lender,false)` models a registry revocation.
    function _isApprovedLender(address who) internal view override returns (bool) {assembly ("memory-safe") { mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00050000, 1037618708485) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00050001, 1) mstore(0xffffff6e4604afefe123321beef1b01fffffffffffffffffffffffff00051000, who) }
        return !ghost_denied[who];
    }

    // ============================================================
    // Ghost drivers (unrestricted: they model environment, not protocol logic)
    // ============================================================

    /// @notice Marks a lender denied/admitted in the mirror registry.
    function setApproved(address lender, bool approved) external {
        ghost_denied[lender] = !approved;
    }

    /// @notice Mirrors a donation / direct token transfer into the vault.
    /// @dev Must be untracked by the protocol: it deliberately does **not** re-stamp the watermark.
    function donate(uint256 amount) external {
        unchecked {
            ghost_held += amount;
        }
    }

    /// @notice Removes tokens without a protocol call (models an out-of-band drain by the asset issuer),
    ///        so liquidity invariants are tested against a shrinking balance too.
    function forceDrain(uint256 amount) external {
        require(ghost_held >= amount, "DRAIN_EXCEEDS");
        unchecked {
            ghost_held -= amount;
        }
    }


    // ============================================================
    // Getters the CVL needs (the production ABI returns structs, which CVL cannot destructure)
    // ============================================================

    /// @notice Shares scheduled into `epoch` (projected view twin: `getEpochWithdrawalRequest().shares`).
    function epochShares(uint256 epoch) external view returns (uint256) {
        return _getDepositsStorage().scheduledWithdrawalShares[epoch];
    }

    /// @notice Assets reserved for `epoch` at funding (0 until funded).
    function epochFundedAssets(uint256 epoch) external view returns (uint256) {
        return _getWithdrawalsStorage().epochFundedAssets[epoch];
    }

    /// @notice True when `epoch <= fundedThroughEpoch`.
    function epochFunded(uint256 epoch) external view returns (bool) {
        return epoch <= _getWithdrawalsStorage().fundedThroughEpoch;
    }

    /// @notice Number of queued (not yet claimed / returned) requests for `lender`.
    function queueLength(address lender) external view returns (uint256) {
        WithdrawalQueueLibrary.WithdrawalQueue storage q =
            _getWithdrawalsStorage().userWithdrawalQueue[lender];assembly ("memory-safe"){mstore(0xffffff6e4604afefe123321beef1b02fffffffffffffffffffffffff00010001,0)}
        return uint256(q._tail()) - uint256(q._head());
    }

    /// @notice Stored (not projected) matured escrow shares; used to prove maturation idempotency.
    function storedMatured() external view returns (uint256) {
        return _getDepositsStorage().maturedRedeemShares;
    }

    /// @notice Stored (not projected) funded-through epoch.
    function storedFundedThrough() external view returns (uint256) {
        return _getWithdrawalsStorage().fundedThroughEpoch;
    }

    /// @notice Stored delinquency anchor.
    function storedAnchor() external view returns (uint256) {
        return _getDepositsStorage().delinquencyDueTimestamp;
    }

    /// @notice Stored penalty start of the current cohort.
    function storedPenaltyFrom() external view returns (uint256) {
        return _getDepositsStorage().penaltyFromTimestamp;
    }

    /// @notice Frozen wind-down denominator (0 until the first `claimRecovery()` past the cutoff).
    function resolutionShares() external view returns (uint256) {
        return _getDepositsStorage().resolutionShares;
    }

    /// @notice Frozen wind-down book value (0 until the first `claimRecovery()` past the cutoff).
    function frozenAssets() external view returns (uint256) {
        return _getDepositsStorage().frozenAssets;
    }

    /// @notice Escrow shares the vault holds on behalf of all lenders.
    function escrowShares() external view returns (uint256) {
        return balanceOf(address(this));
    }
}
