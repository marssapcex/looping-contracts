// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title ILoanVault
/// @notice Types, errors and events for LoanVault (reconstructed verbatim from the audited source dump).
interface ILoanVault {
    struct ConstructorParams {
        address asset;
        address borrower;
        address feeRecipient;
        address lenderRegistry;
        string name;
        string symbol;
        uint256 interestRateBps;
        uint256 feeBps;
        uint256 initialCapacity;
        uint256 minimumDepositAmount;
        uint256 penaltyRateBps;
        uint256 withdrawalGracePeriod;
        uint256 epochDuration;
        uint256 withdrawalNotice;
    }

    struct WithdrawalRequest {
        uint256 shares;
        uint256 claimableEpoch;
    }

    struct EpochWithdrawalRequest {
        uint256 shares;
        uint256 fundedAssets;
        bool funded;
    }

    error ZeroAmount();
    error ZeroShares();
    error InsufficientShares();
    error ExceedsCapacity();
    error NotYetClaimable();
    error NoPendingWithdrawal();
    error BorrowerCannotBeZeroAddress();
    error AssetCannotBeZeroAddress();
    error InvalidDepositAmount();
    error TransferNotApproved(address from, address to);
    error UnexpectedTransferAmount();
    error PreviewNotSupported();
    error NothingMatured();
    error NothingToClaim();
    error ReceiverCannotBeZeroAddress();
    error InvalidReceiver();
    error InterestRateExceedsMax();
    error InitialCapacityCannotBeZero();
    error InterestRateBelowMin();
    error InterestRateNotAboveFee();
    error NoScheduledRate();
    error RateAlreadyActivated();
    error InsufficientFunds();
    error FeeRecipientCannotBeZeroAddress();
    error InvalidFeeBps();
    error NotVaultManager();
    error NotBorrower();
    error LenderRegistryCannotBeZeroAddress();
    error RegistryRoleManagerMismatch();
    error LenderNotApproved();
    error PenaltyRateExceedsMax();
    error GracePeriodExceedsMax();
    error InvalidEpochDuration();
    error InvalidWithdrawalNotice();
    error VaultDelinquent();
    error VaultTerminated();
    error VaultNotTerminated();
    error BorrowerUnchanged();

    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );
    event TransfersEnabledUpdated(bool enabled);
    event RedemptionsFunded(uint256 indexed throughEpoch, uint256 shares, uint256 assets);
    event WindDownSnapshot(uint256 resolutionShares, uint256 frozenAssets);
    event EscrowReturned(address indexed lender, uint256 shares);
    event RecoveryClaimed(address indexed lender, uint256 amount, uint256 poolAtClaim);
    event ResidualSwept(address indexed borrower, uint256 amount);
    event InterestAccrued(uint256 interest, uint256 newTotalAssets, uint256 newExposedAmount);
    event CapacityUpdated(uint256 oldCapacity, uint256 newCapacity, uint256 exposedAmount);
    event Terminated(uint256 totalAssetsAtTerminate, uint256 amountOwedAtTerminate, uint256 timestamp);
    event LenderRegistryUpdated(address indexed newRegistry);
    event Borrowed(address indexed borrower, uint256 amount);
    event Repaid(address indexed borrower, address indexed payer, uint256 amount);
    event BorrowerUpdated(address indexed oldBorrower, address indexed newBorrower);
    event DelinquencyStarted(uint256 indexed dueEpoch, uint256 dueAssets, uint256 dueAt);
    event DelinquencyCured(uint256 timestamp);
    event FeeCollected(address indexed recipient, uint256 amount);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event FeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event PenaltyRateBpsUpdated(uint256 oldRateBps, uint256 newRateBps);
    event InterestRateScheduled(uint256 oldRateBps, uint256 newRateBps, uint256 activationEpoch);
    event InterestRateActivated(uint256 oldRateBps, uint256 newRateBps, uint256 activationEpoch);
    event InterestRateScheduleCancelled(uint256 pendingRateBps, uint256 activationEpoch);

    function pauseDeposits() external;
    function unpauseDeposits() external;
    function pauseWithdrawals() external;
    function unpauseWithdrawals() external;
}
