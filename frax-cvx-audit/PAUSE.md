# Pause, Guard, and Emergency-Path Analysis

## cvxFxsStaking

- There is no global deposit/withdraw pause.
- Reward administration is guarded indirectly by `IVoterProxy(vefxsProxy).operator()` and the current booster `rewardManager`.
- `recoverERC20` cannot withdraw cvxFXS and cannot withdraw a registered reward token. It cannot repair a share/backing deficit.
- `stake` and `withdraw` are `nonReentrant`; FXS `deposit` is also `nonReentrant`.
- Permissionless reward claims cannot redirect another user's rewards arbitrarily: the unguarded path uses the account or its configured redirect, while arbitrary forwarding requires the account itself.

For the conditional pre-fee deficit lead:

- Setting `FxsDepositor.lockIncentive=0` prevents fee-driven deficits. The user-supplied screenshot shows zero and the zero-bps control confirms no deficit; any historical/pre-existing deficit would require separate block-pinned state, which has not been established.
- Direct `stake(cvxFXS)` avoids the FXS conversion mismatch.
- `deposit(amount, true)` does not subtract a new no-lock incentive and therefore avoids this specific deficit; any previously accrued incentive creates surplus backing rather than a shortfall.
- There is no owner withdrawal of cvxFXS to recapitalize or socialize losses through the existing staking rescue function. Recapitalization would require an external token transfer and an explicit remediation plan.

## FxsDepositor

- `feeManager` controls `lockIncentive`, limited to 30 bps.
- `lockFxs()` is permissionless and pays all accrued incentive to its caller; this is the intended lock-call incentive, not by itself an exploit.
- There is no pause on deposits or locking.
- The external staker is immutable; the minter is immutable. The PoC's staker and initial fee-manager storage are local setup, not mainnet state.

## FeeDepositV2

- Administrative functions require the hardcoded owner.
- Distribution can be restricted with `UseDistributors` and the distributor mapping; setting `UseDistributors=false` makes distribution permissionless.
- `rescueToken` explicitly rejects both FXS and cvxFXS. It cannot recover the conditionally trapped conversion incentive.
- Disabling `convertVlcvxRewards` avoids the specific conversion path for future distributions, but does not release an existing trapped cvxFXS balance.
- Receiver-specific `requireProcessing` hooks are configuration-dependent; local PoCs do not establish their deployed values.

## cvxFXB

- `setPaused(true)` is owner-only and first repays all outstanding borrow shares, then sets the flag.
- While paused, `updateBalances()` returns before borrowing/collateral management. Deposits and withdrawals remain available, with collateral kept idle; the paused/zero-debt campaign exercises this mode.
- `migrate()` is migrator-role-only, behind a configured migration contract and a one-week timelock. It repays debt, removes collateral, changes token/lender through the migration contract, disables the swapper/operator, and pauses the vault.
- Owner and migrator role transfers are two-step. Operator changes are owner-only and subject to `operatorTime`.
- `processRewards()` repays debt before sending FRAX to the configured swapper. It requires a nonzero swapper and a FRAX balance above `swapbuffer`.
- Although the contract inherits `ReentrancyGuard`, its external functions do not use `nonReentrant`. No permissionless profitable callback path was established with the actual token assumptions; the unused guard is not promoted as a vulnerability.

The leverage-mode mock does not prove real Fraxlend repayment liquidity, oracle safety, liquidation behavior, or migration safety. Those require deployed-state/fork validation.

## MultiRewards and Fraxtal StakedCvxFxs

- MultiRewards `active` gates reward addition; it is not a universal staking pause.
- Reward distributor approval and reward hooks are manager-guarded through the voter proxy/booster chain.
- Fraxtal `StakedCvxFxs` lets the reward manager invalidate a malfunctioning reward token, causing integral calculation to skip it. This does not pause stake/withdraw.
- Fraxtal `emergencyWithdraw` deliberately skips reward checkpoints; uncheckpointed reward entitlement can be lost, as documented in source.
- Neither local reward campaign establishes the current booster, reward manager, hook, or external-token behavior on a live network.
