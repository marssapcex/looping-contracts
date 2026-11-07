# Pause, routing, and guard matrix

No production contract inherits OpenZeppelin `Pausable`, declares a paused flag, or implements a timelock. Thus “not paused” means **no pause branch exists in the source**, not that every call succeeds: allowance, route freshness, pool whitelist, owner, reentrancy, and external-protocol checks still apply. There is no proxy implementation entry point in scope.

Mainnet `cast call` verification is blocked by the RPC failure recorded in `SIGNATURE.md`; selector values below were computed locally with `cast sig` (`leads/selectors.txt`). Local selector-level Foundry calls supplement the source routing. A guard revert is evidence that the selector routed to its guard, not evidence of a pause. Delay is **0 blocks** where an owner can directly change a setting; it is `N/A` for immutable guards. No admin action is used in an attack PoC.

| contract.entry point | selector | routed? | paused? | guard / expected rejection | function reopening or changing it | delay |
|---|---:|---|---|---|---|---|
| `Looping.openPosition` | `0x6af35ad2` | external | no | `nonReentrant`; `pools[_pool]`; token allowance; pool callback | `setPool` changes pool admission | 0 blocks, owner only |
| `Looping.closePosition` | `0x49d50971` | external | no | `nonReentrant`; `pools[_pool]`; user aToken allowance; pool accounting | `setPool` | 0 blocks, owner only |
| `Looping.executeOperation` | `0x1b11d0ff` | external callback | no | `pools[msg.sender]`; `initiator == address(this)`; no `nonReentrant` on this selector | `setPool` changes accepted caller | 0 blocks, owner only |
| `Looping.setPool` | `0x20bec12c` | external | no | `onlyOwner` | ownership transfer in OZ `Ownable` | 0 blocks |
| `Looping.setSwapper` | `0x3f2617cb` | external | no | `onlyOwner` | ownership transfer | 0 blocks |
| `Looping.setReferralAddress` | `0xb3caba5a` | external | no | `onlyOwner` | direct setter | 0 blocks |
| `Looping.rescueTokens` | `0x57376198` | external | no | `onlyOwner` | N/A; owner-only rescue | N/A |
| `StrategyManager.executeCall` | `0xfa2ae8c0` | public | no | `onlyOwner`; arbitrary target call is intentionally owner-only | ownership transfer | 0 blocks |
| `StrategyManager.executeMultiCall` | `0x859fd9d4` | external | no | `onlyOwner`; internally invokes owner-guarded `executeCall` | ownership transfer | 0 blocks |
| `StrategyManager.cleanOutTokens` | `0x7ccafffd` | external | no | `onlyOwnerOrSelf`; self-call is reachable only through owner `executeCall` | ownership transfer | 0 blocks |
| `StrategyManager.withdrawAllFromPool` | `0xdbf0a44d` | external | no | `onlyOwnerOrSelf`; external pool withdrawal checks still apply | ownership transfer | 0 blocks |
| `StrategyManagerFactory.createStrategyManager` | `0xe326648c` | external | no | one strategy per `(msg.sender,pool,yieldAsset,debtAsset)` | duplicate cannot be reopened; new parameters create a new manager | N/A |
| `GluexAdapter.setSwapPath` | `0x483103a4` | external | no | none; transaction-scoped transient data only | next transaction clears transient storage | 0 blocks / 1 transaction |
| `HypertradeAdapter.setSwapPath` | `0x483103a4` | external | no | none; transaction-scoped transient data only | next transaction clears transient storage | 0 blocks / 1 transaction |
| `LiquidSwapAdapter.setSwapPath` | `0x84564a72` | external | no | none; transaction-scoped transient data only | next transaction clears transient storage | 0 blocks / 1 transaction |
| all three adapters `.swapExactTokensForTokensSupportingFeeOnTransferTokens` | `0xac3893ba` | external | no | `nonReentrant`; deadline; route set in current transaction; router call; min-output | fresh route each transaction | 0 blocks / 1 transaction |
| `GluexAdapter.getSwapRoute` | `0x102b34a3` | external, non-view | no | current-transaction route check | fresh `setSwapPath` | 1 transaction |
| `HypertradeAdapter.getSwapRoute` | `0x102b34a3` | external, non-view | no | current-transaction route check | fresh `setSwapPath` | 1 transaction |
| `LiquidSwapAdapter.getSwapRoute` | different ABI: returns hops | external view | no | returns transient hops; empty after transaction | fresh `setSwapPath` | 1 transaction |
| `HypertradeAdapter.setHyperTradeRouter` | `0xe7f7cd31` | external | no | `onlyOwner`; nonzero router | direct setter | 0 blocks, owner only |
| `wHlpZapper.setLiquidSwapRouter` | `0xa6196fb1` | external | no | `onlyOwner`; nonzero router | direct setter | 0 blocks, owner only |
| `wHlpZapper.setHyperTradeRouter` | `0xe7f7cd31` | external | no | `onlyOwner`; nonzero router | direct setter | 0 blocks, owner only |
| `wHlpZapper.zapIn` | `0xde2c05cc` | external | no | deadline; router execution; min USDT0; depositor minimumMint | no pause; router can be replaced by owner | 0 blocks for router replacement |
| `wHlpZapper.zapInHypertrade` | `0xc8ec7933` | external payable | no | `nonReentrant`; deadline; native/value consistency; router success; min output/mint | no pause; router can be replaced by owner | 0 blocks for router replacement |
| `wHlpZapper.rescueTokens` | `0x57376198` | external | no | `onlyOwner` | N/A | N/A |
| adapter `receive` / empty calldata | no 4-byte selector | payable fallback/receive | no | accepts native wei; later swap wraps native balance to WHYPE | no withdrawal selector; owner rescue absent in adapters | N/A |
| `wHlpZapper` `receive` / empty calldata | no 4-byte selector | payable fallback/receive | no | accepts native wei | owner `rescueTokens(address(0),…)` | 0 blocks, owner only |
| unknown selector on adapters / zapper | N/A | payable fallback | no | accepts call and native wei; no arbitrary execution | N/A | N/A |
| unknown selector on `Looping`, managers, factory | N/A | no fallback | no | revert | N/A | N/A |

## Rescue / response observations

- `Looping.setPool(pool,false)` and `setSwapper(swapper,false)` are immediate owner actions (`contracts/Looping.sol:287-294`), so a compromised integration can be disabled in the owner's next included transaction; there is no enforced block delay.
- `HypertradeAdapter.setHyperTradeRouter` and both zapper router setters are immediate owner actions (`contracts/periphery/HypertradeAdapter.sol:40-44`, `contracts/periphery/wHlpZapper.sol:63-73`). `GluexAdapter.gluex` and `LiquidSwapAdapter.liquidSwapRouter` have no setter (`contracts/periphery/GluexAdapter.sol:17`, `LiquidSwapAdapter.sol:18-19`).
- There is no owner rescue on the three adapters. This makes their native/token residuals more important but does not by itself prove a permissionless loss.
- Mainnet block cost, owner identity, current code, current balances, and actual transaction inclusion delay remain unmeasured because no pinned RPC state is available.
