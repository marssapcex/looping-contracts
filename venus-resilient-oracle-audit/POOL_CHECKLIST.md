# Pinned-block Venus / PancakeSwap review checklist

Use this only after selecting a specific BSC block and verified pool addresses. Every read, trace, balance, and config value in one candidate review must use the same block unless explicitly labeled as a transaction simulation.

## 0. Evidence header

Record before testing:

- [ ] archive RPC endpoint and chain ID (expected BSC mainnet 56, but verify);
- [ ] block number and block hash;
- [ ] PoolRegistry, Comptroller, vToken, underlying, oracle proxy, and oracle source addresses;
- [ ] transaction simulation hash, full call trace, receipts, state diffs, and attacker balance deltas;
- [ ] source commit/bytecode hash for every implementation used;
- [ ] a clear separation of observed pinned state, simulated state overrides, and hypothetical attacker actions.

Do not mix current `latest` prices with historical caps/reserves.

## 1. Verify the oracle identity before using this audit

Candidate artifact addresses, **not yet live-verified here**:

```text
ResilientOracle proxy:         0x6592b5DE802159F3E74B2486b091D11a8256ab8A
artifact implementation:       0x90d840f463c4E341e37B1D51b1aB16Bc5b34865C
BoundValidator proxy:          0x6E332fF0bB52475304494E4AE5063c1051c7d735
artifact implementation:       0xbE4176749a74320641e24102B2Af2Ca37FAF2DF1
EIP-1967 implementation slot:  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382f
```

At the pinned block:

- [ ] Read the proxy implementation slot and confirm it equals the implementation being audited.
- [ ] Read `eth_getCode` for proxy, implementation, BoundValidator, and every Main/Pivot/Fallback source; hash and save the bytes.
- [ ] Compare executable bytecode with the artifact/local reproduction, not only the contract name.
- [ ] Read `nativeMarket()`, `vai()`, `boundValidator()`, `CACHE_SLOT()`, and `paused()`.
- [ ] Confirm the chain supports transient storage at that block; the artifact targets Cancun.
- [ ] If any implementation/code hash differs, stop applying this report and audit the actual implementation.

Example call shapes (use the actual ABI for decoding):

```bash
cast storage "$ORACLE" "$IMPLEMENTATION_SLOT" --block "$BLOCK" --rpc-url "$RPC"
cast call "$ORACLE" 'boundValidator()' --block "$BLOCK" --rpc-url "$RPC"
cast call "$ORACLE" 'nativeMarket()' --block "$BLOCK" --rpc-url "$RPC"
cast call "$ORACLE" 'vai()' --block "$BLOCK" --rpc-url "$RPC"
cast call "$ORACLE" 'paused()' --block "$BLOCK" --rpc-url "$RPC"
```

## 2. Enumerate real Venus markets, not just DEX pairs

- [ ] Obtain PoolRegistry/Comptroller addresses from verified Venus deployment artifacts or a verified registry call at the pinned block.
- [ ] Enumerate each pool's vTokens using that deployment's actual ABI. A prior `markets=0` result is an empty/wrong candidate, not evidence that Venus has no markets.
- [ ] Confirm each Comptroller's oracle address at the pinned block; do not assume every pool uses the screenshot oracle.
- [ ] Resolve every vToken's underlying. Handle special cases in artifact-matched ResilientOracle:
  - native market (`vBNB` candidate in the artifact constructor) uses `NATIVE_TOKEN_ADDR = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB`;
  - VAI uses the configured `vai` address;
  - other vTokens call `underlying()`.
- [ ] Record market pause state, borrow/supply caps, collateral factor, liquidation incentive, close factor, available cash, total borrows, total reserves, and borrower permissions.

A PancakeSwap pair's reserves prove only DEX state. They do not prove that the token is Venus collateral, that debt is borrowable, or that cash is available.

## 3. Dump every asset's oracle configuration

For each underlying key:

- [ ] Call `getTokenConfig(asset)` and decode `(asset, oracles[3], enableFlagsForOracles[3], cachingEnabled)`.
- [ ] Call `getOracle(asset, role)` for MAIN=0, PIVOT=1, FALLBACK=2 as a cross-check.
- [ ] Call `validateConfigs(asset)` on BoundValidator and decode lower/upper anchor ratios.
- [ ] Save Main, Pivot, Fallback `getPrice(asset)` results and each source's own timestamp/decimals metadata.
- [ ] Record the AccessControlManager and authorized governance callers for token/validator configuration. Do not treat governance-set behavior as permissionless.

Classify the route explicitly:

| Configuration | Expected artifact-matched behavior |
|---|---|
| Pivot absent/disabled | Nonzero Main can be returned without BoundValidator |
| Pivot enabled and nonzero | Main↔Pivot, then Fallback↔Pivot |
| Pivot enabled but zero/reverts | No direct unbounded Main acceptance; final Main↔Fallback requires both nonzero and valid bounds |
| Main zero/disabled, no Pivot | Fallback alone is insufficient |
| Cached price already present in transaction | Cached value returned before all current source/config reads |

## 4. Audit source independence, freshness, and scaling

For every Main/Pivot/Fallback contract:

- [ ] Identify its implementation and all upstream feeds: Chainlink aggregator, Binance oracle, RedStone payload, Pancake pair/pool, correlated-token exchange rate, cap, or another wrapper.
- [ ] Check whether roles share an upstream feed even when role addresses differ. Same aggregator/pair means correlated, not independent.
- [ ] Verify output scaling expected by Venus. Compare raw decimals and actual values against a trusted reference at the same block.
- [ ] Verify stale-price behavior: heartbeat, `updatedAt`, minimum update interval, sequencer/grace checks, zero/negative handling, and whether stale values revert or are returned.
- [ ] For capped/correlated sources, read snapshot timestamp/value and determine exactly what permissionless `updateSnapshot()` changes. A swallowed snapshot revert must not be mistaken for a fresh snapshot.
- [ ] Query the current bound ratio and simulate `validatePriceWithAnchorPrice` for honest and manipulated values. Overflow/revert is fail-closed, not acceptance.

Stop or downgrade a no-Pivot lead if Main is a robust, fresh, independent source that the attacker cannot economically manipulate.

## 5. PancakeSwap-specific source checks

First determine whether the oracle actually uses Pancake V2, V3, or another source. Do not infer the oracle mechanism from a pair address alone.

For V2-style sources:

- [ ] `token0`, `token1`, `getReserves`, reserve timestamp, cumulative prices, pair code hash, and oracle's observation window.
- [ ] Determine whether the source uses spot reserves, TWAP, cumulative-price deltas, liquidity-weighted data, or a capped snapshot.
- [ ] Compute the trade required to move the **actual consumed value** far enough, held for the required observation duration. Spot-reserve movement is not equivalent to instant TWAP movement.
- [ ] Include the cost of maintaining the distortion and restoring/selling the position, not just the initial swap.

For V3-style sources:

- [ ] `slot0`, current liquidity, tick spacing, observation cardinality, `observe` results, and oracle window.
- [ ] Model tick-crossing liquidity and observation cardinality; do not use V2 constant-product math.

For every DEX route:

- [ ] Record real exit liquidity for borrowed assets and attacker inventory after the borrow.
- [ ] Include DEX fees, flash fees, price impact, slippage, and gas in both manipulation and exit legs.

## 6. Prove the same-transaction consumer call path

For each candidate action (`borrow`, collateralized mint/redeem, liquidation, or another value-changing call):

- [ ] Trace the complete attacker-reachable call sequence, including flash-loan callbacks and Comptroller hooks.
- [ ] Mark every `updatePrice`, `updateAssetPrice`, `updateSnapshot`, `getUnderlyingPrice`, `getPrice`, and source `getPrice` call in order.
- [ ] Confirm the pool reads the same ResilientOracle proxy and the same underlying cache key.
- [ ] Confirm the asset's `cachingEnabled` is true at the pinned state.
- [ ] Show that the attacker can cause a valid value to be cached before the pool read and can change relevant state afterward in the same transaction.
- [ ] Show the cached direction benefits the action. Overvaluation for borrow and undervaluation for liquidation are different candidates.
- [ ] If the only sequence is “cache in tx1, borrow in tx2,” reject it: the Anvil evidence shows transient cache is cleared.
- [ ] If no attacker-reachable consumer reads after the cache write in that transaction, reject the cache lead.

A static `eth_call` that returns a manipulated price is not enough. Execute a state-changing simulation with all calls in one transaction.

## 7. Full exploit preconditions and economics

A candidate must pass every item:

- [ ] Flash-loan provider, amount, fee, and repayment asset are available at the pinned block.
- [ ] Collateral supply is accepted; supply cap and mint pause do not block it.
- [ ] Borrow cap, borrow pause, collateral factor, account liquidity, available vToken cash, and any borrower whitelist permit the intended borrow.
- [ ] Oracle manipulation/cache action remains valid through the exact pool call order.
- [ ] Borrowed tokens reach the attacker-controlled contract/EOA and are not merely account notional.
- [ ] Exit swaps succeed at real pinned liquidity after price impact.
- [ ] Flash principal + fee is repaid in the same transaction.
- [ ] Residual collateral/debt is valued separately; unwithdrawable collateral is not counted as cash.
- [ ] Final liquid attacker balances exceed initial balances after all fees and gas.

Report these quantities separately:

```text
gross Venus borrow
attacker liquid proceeds after exit
flash-loan principal + fee repaid
residual collateral and debt
protocol bad debt or shortfall
gas and all swap/flash fees
signed attacker net P&L
```

Do not substitute gross borrow, TVL outflow, cached notional, or bad debt for attacker profit.

## 8. Mandatory negative controls

Run the same candidate with:

- [ ] caching disabled — should remove cache-specific delta;
- [ ] an independent fresh Pivot and tight bounds — manipulated Main/Fallback should be rejected;
- [ ] cache write and borrow in separate transactions — no transient carryover;
- [ ] oracle paused — public price reads must revert;
- [ ] zero Main/Fallback — no final zero price;
- [ ] honest unchanged source — attacker net delta should be zero or negative;
- [ ] borrow cap/available cash reduced below the requested amount — action should revert or proceeds fall;
- [ ] exit liquidity removed or priced realistically — no paper profit based on spot mark price.

## 9. Stop criteria / claim labels

- **NO_LIVE_SOURCE_MATCH:** implementation or bytecode differs from the audited artifact.
- **NOT_A_CACHE_VECTOR:** caching disabled, no same-transaction consumer, or only cross-transaction poisoning proposed.
- **NOT_A_PIVOT_FAIL_OPEN:** artifact-matched Pivot zero/revert behavior is being confused with the supplied variant.
- **CONFIGURATION_RISK_ONLY:** no-Pivot, correlated roles, wide bounds, or stale source exists but no permissionless value-changing path is shown.
- **LEAD_ONLY:** branch and consumer exist, but caps/liquidity/repayment/net P&L are unresolved.
- **EXPLOIT_DEMONSTRATED_AT_PINNED_STATE:** full state-changing simulation proves repayment and positive liquid net proceeds, with receipts/traces/balances saved.

Do not use the final label without the complete economic evidence.
