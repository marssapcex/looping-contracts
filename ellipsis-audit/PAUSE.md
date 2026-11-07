# Pause, Guards, and Entry-Point Routing

## Live-state limitation

No supplied contract has a global `paused()` flag or a general pause/kill-switch entry point in the reviewed source. That is a source-level statement, **not** a claim that every path is live on BSC at a particular block. Both RPC endpoints failed before `eth_chainId`, so no live call or test transaction was broadcast. All tests are local, read-only with respect to mainnet, and use no private keys.

Guard types found:

1. `onlyOwner` / current token `minter` / Curve factory `admin` authorization.
2. MFD `minters` and per-token `rewardDistributors` authorization.
3. `nonReentrant` in Solidity and `@nonreentrant('lock')` in Vyper.
4. One-time CryptoSwap initialization through `mid_fee == 0`.
5. Time gates for locks, rewards, emissions, and Curve admin ramps; these are not pause switches.

There is no paused path to reopen and therefore no pause-reopening delay to measure. Reentrancy locks are transaction-scoped, not time-locked: the nested exact-Vyper swap is rejected (`run.log:23-25`), while later independent swaps execute in the same local test suite. Post-transaction lock reopening delay is 0 seconds by EVM transaction semantics; this is not a mainnet measurement.

## `MultiFeeDistribution` — `0x4076…bB5c`

| Entry point(s) | Caller/guard and routing | Inspection/test result |
|---|---|---|
| `stake(uint256,bool)` | Anyone; `nonReentrant updateReward(msg.sender)`; pulls EPS from caller | Locked stake and expiry tested locally; no pause flag. |
| `mint(address,uint256)` | Only `minters[msg.sender]`; `updateReward(user)`; mints EPS to MFD and credits earned balance | Unauthorized caller reverts (`run.log:64`). LP staker is the configured local minter. |
| `withdraw(uint256)` | Anyone for own balance; `nonReentrant updateReward`; unlocked first, then earned with penalty | Exercised indirectly by exact accounting tests and reviewed at `contracts/MultiFeeDistribution.sol:312-355`; no cross-account target. |
| `getReward()` | Anyone for own rewards; `nonReentrant updateReward` | Called by `exit` in local PoCs; reward token balance zeroed before transfer at lines 360-365. |
| `exit()` | Anyone for own balance; `updateReward`; calls `getReward` | Actual local EPS withdrawal at `run.log:48-60`; outer function lacks its own `nonReentrant`, but supplied EPS has no callback and inner reward claim is guarded. |
| `withdrawExpiredLocks()` | Anyone for own expired locks; no updateReward/nonReentrant modifier | Principal test passes (`run.log:63`). Missing reward update is self-diluting, not an attacker-profit route; see CANDIDATES C-03. |
| `notifyRewardAmount(address,uint256)` | Only approved distributor for an already registered token; `updateReward(address(0))`; pulls reward tokens | Privileged configuration, excluded as an attack path. Deployed `addReward` initialization caveat is C-10. |
| `addReward`, `approveRewardDistributor` | `onlyOwner` | Admin routing; excluded from permissionless findings. |
| `recoverERC20` | `onlyOwner`; cannot recover staking token or registered reward token | Admin rescue; no permissionless absolute-balance sweep. |
| `transferOwnership`, `renounceOwnership` | `onlyOwner` | Admin routing; excluded. |
| `lastTimeRewardApplicable`, `rewardPerToken`, `getRewardForDuration`, `claimableRewards` | Public views | Reviewed for supply selection and arithmetic. |
| `totalBalance`, `unlockedBalance`, `earnedBalances`, `lockedBalances`, `withdrawableBalance` | Public views | `unlockedBalance(user)` incorrectly reads `userEarnings[msg.sender]`; local wrong-account result at `run.log:65-67`, no transfer. Other views use the supplied user. |
| Getters: `stakingToken`, `rewardTokens`, `rewardData`, `minters`, `rewardDistributors`, `userRewardPerTokenPaid`, `rewards`, `totalSupply`, `lockedSupply`, `rewardsDuration`, `lockDuration`, `owner` | Public constants/storage views | Screenshot values transcribed in SIGNATURE; none is Anvil-verified. |

## `LpTokenStaker` — `0xcce949…F61b`

| Entry point(s) | Caller/guard and routing | Inspection/test result |
|---|---|---|
| `deposit(uint256,uint256)` | Anyone for own account and owner-added pool; updates all pools, mints pending reward through MFD, pulls LP | Principal fuzz and emission PoCs pass. External calls precede some allocation writes; supplied LP/minter path has no attacker callback. |
| `withdraw(uint256,uint256)` | Anyone up to own `user.amount`; updates all pools, claims, reduces allocation, transfers LP | Full LP principal returned in local withdrawal PoC (`run.log:52`). |
| `emergencyWithdraw(uint256)` | Anyone for own full balance; LP transfer precedes zeroing user state | Source-reviewed and Slither-flagged. Actual supplied Curve LP token has no transfer callback; owner-added malicious tokens are excluded. No profitable mainnet replay. |
| `claim(uint256[])` | Anyone for own pids; updates all pools then MFD mint | Duplicate pid does not double mint (`run.log:62`). Schedule ordering produces LEAD-001. |
| `start`, `setMinter` | `onlyOwner`; each one-time by zero-state checks | Called during local deployment; admin setup only. |
| `addPool`, `addOracle` | `onlyOwner`; pool update/oracle call | Owner-added duplicate/malicious assets and malicious oracles are excluded. |
| `poolLength`, `claimableReward` | Public views | Deployed view can divide by zero when total allocation is zero and LP supply is nonzero; view-only C-11. Screenshot `poolLength=12` unverified. |
| Getters: `rewardMinter`, `rewardsPerSecond`, `poolInfo`, `emissionSchedule`, `userInfo`, `totalAllocPoint`, `startTime`, `oracles`, `owner` | Public storage views | Required pinned reads are in `scripts/fork-readback.sh`. Current displayed rate zero is not Anvil-verified. |

## EPS token — `0xA7f5…6d9F`

| Entry point(s) | Caller/guard and routing | Inspection/test result |
|---|---|---|
| `transfer`, `transferFrom` | Anyone for own/approved EPS; raw 18-decimal amounts; no callback | Exact Vyper 0.2.11 source compiled. Safe arithmetic underflow reverts; infinite allowance is not decremented. |
| `approve`, `increaseAllowance`, `decreaseAllowance` | Anyone for own allowance | Standard ERC-20 allowance race is not treated as a protocol drain/MEV finding. |
| `mint`, `burnFrom` | Only current `minter` | Screenshot shows MFD as minter; unauthorized MFD path also reverts locally. |
| `set_minter` | Only current `minter`; single-step replacement | Privileged routing; no permissionless takeover found. |
| `decimals`, `name`, `symbol`, `totalSupply`, `balanceOf`, `allowance`, `minter` | Public views | Displayed values recorded; no Anvil read-back. |

## Two-asset CryptoSwap — proxy `0xFD4a…66DA`, implementation `0x1E97…226c`

| Entry point(s) | Caller/guard and routing | Inspection/test result |
|---|---|---|
| `exchange` | Anyone; payable; `@nonreentrant('lock')`; optional native-WBNB handling | Exact runtime quote/execution passes (`run.log:27-30`). |
| `exchange_underlying` | Anyone; payable; same lock; native-WBNB route | Source-inspected alongside `exchange`; no live WBNB route claimed without fork state. |
| `exchange_extended` | Anyone; payable; same lock; caller-selected callback signature, sender and receiver; callback must fund exactly `dx` | Nested swap rejected and exact input/output deltas checked (`run.log:23-25`). No free callback mint. |
| `add_liquidity` | Anyone; payable; same lock; pulls both coins and mints LP | Initial local liquidity succeeds; exact runtime. |
| `remove_liquidity` | Anyone for own LP; same lock; burns LP then proportional transfers | Exact burn and coin payouts at `run.log:33-37`. |
| `remove_liquidity_one_coin` | Anyone for own LP; same lock; computes/burns/transfers then tweaks price | Source-reviewed for state ordering; no mainnet drain claimed. |
| `withdraw_admin_fees` | Anyone, but factory fee receiver/converter and LP minter are trusted configuration | No direct attacker recipient. Reentrancy into normal pool functions remains locked only when those functions are called; no profitable route proven. |
| `ramp_A_gamma`, `stop_ramp_A_gamma`, `commit_new_parameters`, `apply_new_parameters`, `revert_new_parameters` | Curve factory admin; commit/apply has `ADMIN_ACTIONS_DELAY = 3 days`; ramp minimum 1 day | Admin-only and excluded. These delays are not pause-reopening measurements. |
| `initialize` | Anyone technically, but only while `mid_fee==0`; sets factory to caller | Second call reverts locally (`run.log:32`). Implementation constructor sets nonzero `mid_fee`; deployed proxy state still requires archive verification. |
| `__default__` | Payable native receiver; no pause | Native gifts are later accounted by pool gulp logic; no assertion that native balance equals internal balances without a pinned read. |
| Views: `get_dy`, `calc_token_amount`, `calc_withdraw_one_coin`, `lp_price`, `A`, `gamma`, `fee`, `get_virtual_price`, `price_oracle` | Public view/math routes | `get_dy` matches execution locally. Other views source-reviewed; no mainnet quote presented. |
| Public getters: `token`, `coins`, `price_scale`, `last_prices`, `last_prices_timestamp`, A/gamma ramp fields, fee/profit fields, `balances`, `D`, `factory`, `virtual_price`, `admin_actions_deadline` | Public storage views | Required pinned read-back listed in SIGNATURE/fork script; screenshot has none of these values. |

## Promotion rule for guarded paths

A guard bypass is not promoted from a source smell. It requires a tagged PoC at a verified BSC pin, a real withdrawal to the attacker, and positive all-cost P&L. Any future state override must be labeled, then replayed using real transactions from the pinned state before promotion. None of the local results currently meets that mainnet gate.
