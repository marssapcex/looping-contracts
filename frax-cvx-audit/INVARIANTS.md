# Frax-CVX Invariants and Model Boundaries

## Reward accounting

### MultiRewards

For every registered reward token:

- `rewardPerTokenStored` follows the independent time/rate/supply model using the actual receipt block timestamp.
- A user's lazy pending balance plus the current balance-times-integral term matches the contract after deposits, withdrawals, claims, transfers of time, and reward notifications.
- Claiming zeroes stored pending rewards and transfers exactly the modeled amount to the selected receiver.
- `funded = claimed + residual contract balance` for each completed sequence, up to explicitly modeled integer dust; residual balances are measured, not discarded.
- With zero supply, no new per-token accrual is attributed to a user.
- A late deposit must not capture rewards accrued before that deposit. The negative sandwich control gives the victim 100 FXS and the attacker zero.

### Fraxtal StakedCvxFxs

- Donations increase the global reward integral only according to the balance-minus-remaining rule.
- Per-user checkpoints preserve lazily accrued `claimable_reward` until a claim.
- Token transfers checkpoint sender and receiver before balances change.
- Unguarded `getReward(account)` sends only to the account or its configured redirect; the guarded overload requires `msg.sender == account`.
- `donated = claimed + residual contract balance` for each completed sequence, including residual integral dust.
- Emergency withdrawal intentionally skips checkpointing and is not modeled as preserving uncheckpointed rewards.

Campaign evidence: `evidence/stateful-rewards.json`, seed `12648430`, 32 × 128 steps per contract, 9,374 successful transactions including setup. This is bounded evidence, not exhaustive assurance.

## cvxFxsStaking backing solvency

Let `B = cvxFxs.balanceOf(staking)` and `S = staking.totalSupply`, excluding no other token:

- After ordinary staking, withdrawals, and FXS conversion deposits, `B >= S` should hold for all users to exit at one cvxFXS per share.
- Any FXS deposit path must increase `S` by no more than the actual cvxFXS balance delta delivered to the staking contract.
- A depositor must not withdraw more cvxFXS than an honest direct conversion baseline plus any explicitly documented reward.
- One user's immediate deposit/withdraw round trip must not reduce another user's withdrawable backing.

**Conditional violation reproduced:** when `lockIncentive=30`, default no-lock deposit increases `S-B` by the fee. A 1000-FXS deposit produces a 3-cvxFXS deficit; the depositor withdraws 1000 cvxFXS and the prior victim retains 3 unbacked shares. The 334/333-wei boundary pair confirms integer-fee causality. Conversely, the 1000-FXS zero-bps control has `S-B=0`, zero attacker advantage, and zero unbacked victim shares. A user-supplied screenshot shows zero incentive, so this is not a current exploit under that configuration. The screenshot has no block number and is not pinned-fork evidence. See `evidence/staking-lock-incentive-poc.json`.

## Fee conversion and conservation

For `FeeDepositV2` vlCVX conversion:

- The amount notified to the reward sink should equal the actual cvxFXS amount received from `FxsDepositor`, including any consumed `incentiveFxs`.
- No protected protocol token should become undistributable solely because an incentive was outstanding before conversion.
- Repeating distribution with no new fees should not leave an additional unaccounted protocol balance.
- The caller incentive is a configured distribution cost and is not counted as attacker exploit profit.

**Conditional violation reproduced:** 3 cvxFXS remains in `FeeDepositV2`; `rescueToken` rejects it and repeat distribution leaves it unchanged. See `evidence/fee-conversion-poc.json`.

## cvxFXB ERC4626 accounting

In both paused and leverage-mode harnesses:

- `totalSupply` equals the independent share model, including the one-share deployment seed held by the vault.
- `totalAssets = local FXB balance + lender collateral` and equals the independent asset model.
- Deposits use floor shares; mints use ceiling assets; redeems use floor assets; withdrawals use ceiling shares.
- Donations increase assets without changing shares.
- Share transfers conserve the sum of user balances.
- Delegated redeem spends exactly the approved shares and cannot spend them twice.
- A user's withdrawal/redeem changes shares and assets by the exact preview/model amounts.

Paused campaign evidence: `evidence/stateful-cvxfxb.json`, seed `3851`, 32 × 128 steps, 5,226 successful transactions including setup.

Leverage-mode additions:

- Lender `debtShares` and `toBorrowAmount` agree under the explicit 1:1 debt model.
- All loose FXB is accounted as vault-local or lender collateral.
- Outside internal repay transitions, loose FRAX is zero after rebalancing.
- Active sFRAX claims match mock-vault FRAX backing, excluding redeemed sFRAX retained by the mock.
- `getProfit()` equals active sFRAX balance minus 1:1 debt in the restricted model.
- Oracle changes and public `updateBalances()` preserve FXB share/asset accounting while changing debt/collateral transitions.

The leverage campaign passed 32 × 128 steps with 5,537 successful transactions including setup (seed `61617`). The leverage mock has unrestricted FRAX liquidity, no interest or liquidations, and a 1:1 sFRAX vault. It does not establish economic safety under real Fraxlend/oracle/sFRAX conditions. Final campaign evidence is `evidence/stateful-cvxfxb-leverage.json` and its campaign log.

## Reward-swap oracle validity

For every `cvxFXBSwapper.processRewards()` call:

- If `updateExchangeRate()` returns `isBorrowAllowed=false`, the swapper must not call the exchange or move FRAX; expected deltas are zero.
- The configured exchange, input/output assets, oracle rate, decimals, and slippage units must agree; `minOut` must be checked against actual received FXB rather than call success.
- A false-validity or stale-price scenario must be compared with a valid control and signed attacker/protocol deltas, including MEV and gas.

**Conditional violation reproduced:** production bytecode still calls the exchange when the local lender returns `false`. It pulls 100 FRAX and delivers 100 FXB to `cvxFXB`; attacker token deltas are zero. This is a validity-boundary lead only, not mainnet loss or P&L evidence. See `evidence/oracle-validity-poc.json`.

Additional donation controls: `StakedCvxFxs.totalAssets()` equals `totalSupply()` rather than raw token balance; `cvxFXB` donations represent real FXB added to local/lender collateral; and zero-share `cvxFXB` deposits do not pull tokens. These observations do not verify the external Fraxlend oracle.

## Differential and shrinking strategy

- Compare contract state after every action to an independent integer model, not just final aggregate counts.
- Use receipt timestamps rather than predicted timestamps to avoid false positives.
- Compare exploit-path output to an honest direct-conversion baseline.
- Include zero-fee, minimum nonzero-fee, zero-balance, zero-share, and unbacked-victim boundaries where applicable.
- Preserve residual balances and dust in conservation equations.
- Treat harness/mock mismatches as harness failures until production state independently proves otherwise.
