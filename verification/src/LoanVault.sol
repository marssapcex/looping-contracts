// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import { LoanVaultBorrower } from "./LoanVaultBorrower.sol";
import { VaultAccountingLib } from "./VaultAccountingLib.sol";
import { WithdrawalQueueLibrary } from "./WithdrawalQueueLibrary.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ILoanVault } from "./interfaces/ILoanVault.sol";

/// @title LoanVault
/// @author Axcess Protocol
/// @notice Single-borrower lending vault with epoch-based fixed-rate mechanics.
contract LoanVault is LoanVaultBorrower {
    using WithdrawalQueueLibrary for WithdrawalQueueLibrary.WithdrawalQueue;

    /// @notice Storage-layout generation; the factory refuses a beacon upgrade to a different value.
    uint256 public constant LAYOUT_VERSION = 1;

    /// @dev Locks the implementation contract; vaults are deployed as beacon proxies.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @notice Initializes the vault; called once by the factory at deployment.
    function initialize(ConstructorParams calldata _params) external initializer {
        _initializeBase(_params);
        _initializeDepositsStorage(_params);
        _initializeWithdrawalsStorage(_params);
    }

    // ============ Pause/Unpause Functions ============

    /// @notice Pauses deposits.
    function pauseDeposits() external onlyVaultManager {
        _pauseDeposits();
    }

    /// @notice Unpauses deposits.
    function unpauseDeposits() external onlyVaultManager {
        _unpauseDeposits();
    }

    /// @notice Pauses `requestRedeem`, `borrow` and pre-termination `redeem`.
    function pauseWithdrawals() external onlyVaultManager {
        _pauseWithdrawals();
    }

    /// @notice Unpauses withdrawal-side flows.
    function unpauseWithdrawals() external onlyVaultManager {
        _unpauseWithdrawals();
    }

    //////////////////////////////////////////////////////////////
    //////////////////// ERC-4626: entry leg /////////////////////
    //////////////////////////////////////////////////////////////

    /// @notice Deposits `assets` for `receiver`; shares mint at the live price and earn immediately.
    function deposit(
        uint256 assets,
        address receiver
    )
        external
        whenDepositsNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        _validateEntry(ds, receiver);
        if (assets < ds.minimumDepositAmount) revert InvalidDepositAmount();

        _accrueInterest();
        _checkCapacity(ds, assets);

        shares = VaultAccountingLib.convertToShares(assets, ds.totalAssets, totalSupply(), _decimalsOffset());
        if (shares == 0) revert ZeroShares();

        _enterPool(ds, receiver, assets, shares);
    }

    /// @notice Mints exactly `shares` for `receiver`, pulling their cost rounded up.
    function mint(uint256 shares, address receiver)
        external
        whenDepositsNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroShares();
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        _validateEntry(ds, receiver);

        _accrueInterest();
        assets = VaultAccountingLib.convertToAssetsRoundUp(shares, ds.totalAssets, totalSupply(), _decimalsOffset());
        if (assets < ds.minimumDepositAmount) revert InvalidDepositAmount();
        _checkCapacity(ds, assets);

        _enterPool(ds, receiver, assets, shares);
    }

    /// @dev Requires a live vault and a registry-approved `receiver` (approval is per vault).
    function _validateEntry(LoanVaultDepositsStorage storage ds, address receiver) private view {
        if (receiver == address(0)) revert ReceiverCannotBeZeroAddress();
        if (ds.terminatedAt != 0) revert VaultTerminated();
        _requireApprovedLender(receiver);
    }

    /// @dev Pulls before crediting and requires the balance to grow by exactly `assets` (no fee-on-transfer).
    function _enterPool(LoanVaultDepositsStorage storage ds, address receiver, uint256 assets, uint256 shares) private {
        if (_unfundedPastGrace()) revert VaultDelinquent();

        uint256 balanceBefore = _heldAssetsUsdc();
        _pullUsdc(msg.sender, assets);
        if (_heldAssetsUsdc() != balanceBefore + assets) revert UnexpectedTransferAmount();

        _mint(receiver, shares);
        ds.totalAssets += assets;
        _resetBasePeriod(ds);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // ============ ERC-4626 views ============

    /// @notice The loan asset the vault is denominated in.
    function asset() external view returns (address) {
        return address(_getDepositsStorage().loanAsset);
    }

    /// @notice True when `from` may transfer shares to `to` right now.
    function canTransfer(address from, address to) public view returns (bool) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        if (from == address(0) || to == address(0)) return true; // mint / burn
        if (from == address(this)) return true; // escrow hand-back at wind-down
        // Only `requestRedeem` escrows; a raw transfer in would park shares outside every epoch schedule.
        if (to == address(this)) return escrowInFlight;
        // Holder set freezes at wind-down: `claimedRecovery` is per address, so a sale could double-claim.
        if (ds.terminatedAt != 0) return false;
        if (!ds.transfersEnabled) return false;
        return true;
    }

    /// @notice Projected total assets (ERC-4626); same as `getTotalAssets`.
    function totalAssets() external view returns (uint256) {
        return getTotalAssets();
    }

    /// @notice Converts `assets` to shares at the projected price.
    function convertToShares(uint256 assets) public view returns (uint256) {
        (uint256 projAssets,,) = _projectedPoolNow();
        return VaultAccountingLib.convertToShares(assets, projAssets, totalSupply(), _decimalsOffset());
    }

    /// @notice Converts `shares` to assets: projected par, or recovery value once wind-down accrual has frozen.
    function convertToAssets(uint256 shares) public view returns (uint256) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        if (ds.terminatedAt != 0 && block.timestamp >= _accrualCutoff(ds)) {
            return _recoveryValue(ds, shares);
        }
        (uint256 projAssets,,) = _projectedPoolNow();
        return VaultAccountingLib.convertToAssets(shares, projAssets, totalSupply(), _decimalsOffset());
    }

    /// @dev Gross pro-rata recovery for `shares` (ignores amounts already drawn), capped at book.
    function _recoveryValue(LoanVaultDepositsStorage storage ds, uint256 shares) private view returns (uint256) {
        uint256 denom = ds.resolutionShares != 0 ? ds.resolutionShares : totalSupply();
        if (denom == 0) return 0;
        uint256 book = ds.resolutionShares != 0 ? ds.frozenAssets : ds.totalAssets;

        uint256 pool = _cashForClaims(ds) + ds.totalRecoveryPaid;
        if (pool > book) pool = book;
        return Math.mulDiv(shares, pool, denom);
    }

    /// @notice Max assets `receiver` can deposit now.
    function maxDeposit(address receiver) public view returns (uint256) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        if (
            ds.terminatedAt != 0 || depositsPaused() || withdrawalsPaused() || _unfundedPastGrace()
                || !_isApprovedLender(receiver)
        ) {
            return 0;
        }
        (uint256 p,,) = _projectedPoolNow();
        if (p >= ds.vaultCapacity) return 0;
        uint256 room = ds.vaultCapacity - p;
        // ERC-4626: deposit(maxDeposit(x)) must not revert, so report 0 for sub-minimum or zero-share room.
        if (room < ds.minimumDepositAmount) return 0;
        return convertToShares(room) == 0 ? 0 : room;
    }

    /// @notice Maximum shares `receiver` could mint now (share-denominated `maxDeposit`).
    function maxMint(address receiver) external view returns (uint256) {
        uint256 shares = convertToShares(maxDeposit(receiver));
        if (shares == 0) return 0;
        (uint256 projAssets,,) = _projectedPoolNow();
        uint256 cost = VaultAccountingLib.convertToAssetsRoundUp(shares, projAssets, totalSupply(), _decimalsOffset());
        return cost < _getDepositsStorage().minimumDepositAmount ? 0 : shares;
    }

    /// @notice Shares `deposit(assets)` would mint now.
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /// @notice Assets `mint(shares)` would pull now, rounded up.
    function previewMint(uint256 shares) external view returns (uint256) {
        (uint256 projAssets,,) = _projectedPoolNow();
        return VaultAccountingLib.convertToAssetsRoundUp(shares, projAssets, totalSupply(), _decimalsOffset());
    }

    /// @notice ERC-7540: net assets `owner` (as controller) can claim now.
    function maxWithdraw(address owner) external view returns (uint256) {
        if (_redeemBlocked(owner)) return 0;
        (uint256 netAssets,) = _previewClaim(owner);
        return netAssets;
    }

    /// @notice ERC-7540: shares `owner` (as controller) can claim now; same gate as `maxWithdraw`.
    function maxRedeem(address owner) external view returns (uint256) {
        if (_redeemBlocked(owner)) return 0;
        (, uint256 shares_) = _previewClaim(owner);
        return shares_;
    }

    /// @notice Always reverts: ERC-7540 async redeem has no synchronous preview.
    function previewWithdraw(uint256) external pure returns (uint256) {
        revert PreviewNotSupported();
    }

    /// @notice Always reverts: ERC-7540 async redeem has no synchronous preview.
    function previewRedeem(uint256) external pure returns (uint256) {
        revert PreviewNotSupported();
    }

    //////////////////////////////////////////////////////////////
    /////////////////////// View Functions ///////////////////////
    //////////////////////////////////////////////////////////////

    /// @notice Base annual interest rate in bps, excluding any delinquency penalty.
    function interestRateBps() external view returns (uint256) {
        return _getDepositsStorage().interestRateBps;
    }

    /// @notice Address `borrow()` sends funds to.
    function borrower() external view returns (address) {
        return _getDepositsStorage().borrower;
    }

    /// @notice Deposit cap on the active pool (accrued interest included), in loan-asset units.
    function vaultCapacity() external view returns (uint256) {
        return _getDepositsStorage().vaultCapacity;
    }

    /// @notice Principal currently drawn via `borrow()` and not yet repaid.
    function borrowedAmount() external view returns (uint256) {
        return _getBorrowerStorage().borrowedAmount;
    }

    /// @notice Cash the borrower can draw now: held cash less reserved claims, matured liability and fees.
    function availableToBorrow() public view returns (uint256) {
        if (withdrawalsPaused() || _getDepositsStorage().terminatedAt != 0 || _unfundedPastGrace()) return 0;
        return _freeLiquidityProjected();
    }

    /// @notice Borrower's obligation: pool + reserved claims + fees, less cash held and recovery paid.
    function amountOwed() public view returns (uint256) {
        // One projection for both legs, so the figure is independent of poke timing.
        (uint256 projAssets, uint256 projFees,) = _projectedPoolNow();
        return _fundingDeficit(projAssets, projFees);
    }

    /// @notice Timestamp of the last interest accrual.
    function lastAccrualTimestamp() external view returns (uint256) {
        return _getDepositsStorage().lastAccrualTimestamp;
    }

    /// @notice `controller`'s queued redemption request at absolute queue index `idx`.
    function getUserWithdrawalRequest(
        address controller,
        uint128 idx
    )
        external
        view
        returns (uint256 shares, uint256 claimableEpoch, bool funded)
    {
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();
        ILoanVault.WithdrawalRequest memory request = ws.userWithdrawalQueue[controller]._peek(idx);
        return (request.shares, request.claimableEpoch, request.claimableEpoch <= ws.fundedThroughEpoch);
    }

    /// @notice Interest-earning base: the projected pool, or 0 past the termination epoch's end.
    function exposedAmount() public view returns (uint256) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        if (ds.terminatedAt != 0 && block.timestamp >= _accrualCutoff(ds)) return 0;
        (uint256 projAssets,,) = _projectedPoolNow();
        return projAssets;
    }

    /// @notice True once the vault has been terminated (wind-down mode).
    function terminated() external view returns (bool) {
        return _getDepositsStorage().terminatedAt != 0;
    }

    /// @notice Timestamp of `terminate()` (0 = live); accrual stops at the end of that epoch.
    function terminatedAt() external view returns (uint256) {
        return _getDepositsStorage().terminatedAt;
    }

    /// @notice Recipient of swept protocol fees.
    function feeRecipient() external view returns (address) {
        return _getWithdrawalsStorage().feeRecipient;
    }

    /// @notice Shares scheduled for `_epoch`, assets reserved for them (0 until funded), and whether funded.
    /// @dev NOTE: returns the struct type `ILoanVault.EpochWithdrawalRequest`, not a bare tuple. CVL must
    ///      bind it with `=> (uint256 shares, uint256 fundedAssets, bool funded) params`.
    function getEpochWithdrawalRequest(uint256 _epoch) external view returns (EpochWithdrawalRequest memory) {
        LoanVaultWithdrawalsStorage storage ws = _getWithdrawalsStorage();
        return EpochWithdrawalRequest({
            shares: _getDepositsStorage().scheduledWithdrawalShares[_epoch],
            fundedAssets: ws.epochFundedAssets[_epoch],
            funded: _epoch <= ws.fundedThroughEpoch
        });
    }

    //////////////////////////////////////////////////////////////
    /////////////////////// Delinquency //////////////////////////
    //////////////////////////////////////////////////////////////

    /// @notice True while matured redemptions sit unfunded past grace; blocks deposit, mint and borrow.
    function isDelinquent() external view returns (bool) {
        return _unfundedPastGrace();
    }

    /// @notice Timestamp the penalty runs from (0 = no shortfall anchored); a future time during grace.
    function penaltyActiveSince() public view returns (uint256) {
        LoanVaultDepositsStorage storage ds = _getDepositsStorage();
        // An armed anchor (stored or projected) keeps billing even if live cash now covers.
        uint256 anchor = _projectedDelinquencyAnchor();
        if (anchor == 0 && !_isDelinquentProjected()) return 0;
        uint256 stored = ds.penaltyFromTimestamp;
        if (stored != 0) return stored;
        return anchor == 0 ? 0 : anchor + ds.withdrawalGracePeriod;
    }

    /// @notice Repays the full `amountOwed()` as of execution.
    function repayAll() external nonReentrant {
        _accrueInterest();
        uint256 owed = amountOwed();
        if (owed == 0) revert ZeroAmount();
        _settleRepayment(owed);
        // The deficit can be below `borrowedAmount` (e.g. donations); a full payoff zeroes it.
        LoanVaultBorrowerStorage storage bs = _getBorrowerStorage();
        if (bs.borrowedAmount != 0) bs.borrowedAmount = 0;
    }

    /// @notice Current epoch number (0-based from the vault's genesis timestamp).
    function currentEpoch() public view returns (uint256) {
        return
            VaultAccountingLib.currentEpoch(_getDepositsStorage().genesisTimestamp, _getDepositsStorage().epochDuration);
    }

    /// @notice Active pool value projected to now (view twin of `_accrueInterest`).
    function getTotalAssets() public view returns (uint256) {
        (uint256 projAssets,,) = _projectedPoolNow();
        return projAssets;
    }

    //////////////////////////////////////////////////////////////
    ////////////////// ERC20 Overrides / Gate ////////////////////
    //////////////////////////////////////////////////////////////

    /// @notice Share decimals: mirrors the loan asset's decimals (offset 0).
    function decimals() public view override returns (uint8) {
        return _getDepositsStorage().assetDecimals + _decimalsOffset();
    }

    /// @dev Enforces `canTransfer` on every share movement; no registry check on either endpoint.
    function _update(address from, address to, uint256 value) internal virtual override {
        if (!canTransfer(from, to)) revert TransferNotApproved(from, to);
        super._update(from, to, value);
    }

    /// @notice ERC-165; supports only the ERC-165 interface id.
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == 0x01ffc9a7; // ERC-165
    }
}
