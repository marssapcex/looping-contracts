# Pause, Guards, and Entry-Point Routing

## Live-state limitation and reopening semantics

The pool and treasury have no `paused()` flag or pause/unpause entry point. FOX has a token-level transfer gate: when `transferStatus == false`, transfers revert unless either sender or recipient is whitelisted. `setTransferState(bool)` is owner-only and has no timelock; enabling transfers takes effect immediately in that transaction. L2Beat records historical activation transaction `0x353d51e1eab23dcc173c49c4d44cd89041d7600fc654154da060cf842ea346f2` at block 115148019, before the incident. Current status is not RPC-verified.

There is no measured pause-reopening delay: source shows **0 seconds of additional delay after the owner enabling transaction**, not a claim that an owner will enable it. Other gates are authorization, one-time initialization, referral registration, time-aligned vesting, and the inviter threshold. No Solidity `nonReentrant` guard exists on the pool/treasury paths; supplied FOX/USDT/LP have no attacker callback, and trusted router/treasury calls did not yield a profitable reentry candidate.

This session made no live calls or transactions. Local calls used PyEVM; canonical mainnet routing comes from the preserved pinned traces (`run.log:157-159`).

## `FoxLpBondsPool` — proxy `0x9fa6…D1A0`, implementation `0x58E2…655A`

| Entry point | Caller/guard/routing | Status |
|---|---|---|
| `initialize(...)` | `initializer`; sets owner/config, paths and infinite token approvals | Implementation constructor disables direct initialization; local ERC1967 initialization succeeds. No proxy takeover evidence. |
| `stake(uint256,uint256)` | Any referred user; pulls USDT, quotes/trades/adds LP, treasury mint, log write | **Vulnerable confirmed path**, FINDING-001. No pause bit. |
| `setGovernance(address)` | `onlyOwner` | Admin configuration; excluded. |
| `getSwapPrice(uint256)` | Public view → router `getAmountsOut` → discount log | Same-block spot source used by finding; canonical quote at `run.log:17-18`. |
| `getDiscountRate`, `getAlignedDiscountRate` | Public views → ratio log | Source-reviewed; local fixed discount only matches pinned quote. |
| Public getters for constants/config, `stakeInfoMap`, `fulMingingDaysMap`, path indices | Public storage views | Screenshot zeroes belong to implementation tab; pinned proxy read-back script required. |

Inherited `FoxPoolBase` routes:

| Entry point | Caller/guard/routing | Status |
|---|---|---|
| `redeem(stakeId)` | Only stake owner; treasury burns sFOX/transfers FOX, then pool transfers principal | Principal linearity source-reviewed; no profitable reentry/double redemption found. |
| `checkpoint(stakeId)` | `onlyGovernance`; updates reward checkpoint and log | Admin route; excluded. |
| `timeLock(stakeId,lockDays)` | Only stake owner, no active ful-mining; treasury time-lock and log | Trusted time-lock pool required; no direct attacker mint. |
| `startFulMinging`, `endFulMinging` | Only stake owner; supported days and start/end time gates | State machine only; no standalone payout. |
| `getPendingReward`, `getTotalReward`, `getPendingPrincipal` | Public views; reward loop/principal computation | No profit route; long loops can be gas-expensive but gas-only DoS excluded. |
| `getRewardRate`, `getAlignedRewardRate` | Public views → reward ratio log | Descending endpoint underflow can revert; admin configuration only. |
| Public storage getters | `stakeDays`, token/treasury/log/router addresses, rates, governance, mappings | Required pinned reads listed in `scripts/fork-readback.sh`. |

## `Treasury` — proxy `0x361d…01cc`, implementation `0x8761…e04D`

| Entry point | Caller/guard/routing | Status |
|---|---|---|
| `initialize` | `initializer`; stores tokens/configuration | Local proxy initialization succeeds; no pause. |
| `lpBonds` | `onlyStakingPool`; LP→DEAD, FOX/sFOX/rFOX mint, immediate inviter FOX | **Cash-out leg of FINDING-001**; direct attacker calls rejected (`run.log:145`). |
| `burnBonds` | `onlyStakingPool`; FOX burn/mint and inviter transfer | Not invoked by supplied LP pool stake path; same trusted accounting requires review if another pool is added. |
| `stake` | `onlyStakingPool`; pulls FOX, mints sFOX/rFOX | No direct permissionless caller. |
| `redeem` | `onlyStakingPool`; sFOX→DEAD then FOX→pool | Supplied tokens no callbacks; no double-spend shown. |
| `timeLock` | Staking pool or FOX distributor; configured lock pool | Trusted routing; no direct payout to caller. |
| `timeLockFul` | Only ful distributor | Trusted routing. |
| `rebase`, `startFulMinging` | `onlyGovernance` | Admin routes; excluded. |
| `lendFox`, `retrieveUsdt` | `onlyRBSExecutor` | Privileged mint/rescue; excluded. |
| Setters: governance, distributors, RBS executor, staking pool, time-lock pools | `onlyOwner` | Admin configuration; excluded. |
| Public getters / list lookups | Storage views | Authorization and token links included in pinned read-back. |

## FOX — `0xdF81…bb93`

| Entry point | Caller/guard/routing | Status |
|---|---|---|
| ERC20 `transfer`, `transferFrom`, `approve`, `increase/decreaseAllowance` | Anyone for own/approved balance; `_update` applies transfer gate and target-pool tax | Actual 2.5% sell tax included in replay; allowance race/MEV not promoted. |
| `mint` | Only configured treasury | Canonical treasury mint path succeeds; direct unauthorized mint not available. |
| `burn` | Anyone burns own FOX | Self-harm excluded. |
| `addWhitelist`, `removeWhitelist`, `setTargetPool`, `setTreasury`, `setTransferState` | `onlyOwner` | Transfer enable/target/treasury configuration; no timelock, admin-only. |
| `transferGovernance`, `setFeeReceiver`, `setSellRates` | `onlyGovernance`; sell rate constrained 250–3000 bps | Admin-only. |
| Standard Ownable ownership routes | Current owner | Admin-only. |
| Views: tax/config/whitelist/balances/supply | Public | Pinned tax/target/treasury/transferStatus reads in fork script. |

## Referral, log, and ratio contracts

- `Referral.initialize` is one-time proxy setup. Owner `setReferral` and signed public `setReferral` bind a user/inviter and increment the log. Signed route checks caller=user, 600-second timeout, unused user, valid inviter, and signer. The original attacker already had a binding; the registry's owner binding for a fresh helper is explicitly a replay surrogate, not a claimed privilege bypass.
- `Log.addBlockId` requires `operatorMap[msg.sender]`; views expose count/history. Local pool and referral are configured as operators.
- `RewardRatioLog.logRatio` is operator-only, monotonic in 8-hour timestamps, ratio ≤10000. Ratio getters are views. Owner/operator manipulation is excluded.
- sFOX/rFOX `mint` requires configured treasury; their owner `setTreasury` is admin-only.

## Promotion rule for any guarded bypass

A new guarded-path claim requires exact pinned code, a real permissionless transaction path, withdrawal to the attacker, and positive all-cost P&L. Admin-only transfer/treasury/referral configuration is not itself a finding. The promoted incident path requires none of those privileged calls during the attack transaction.
