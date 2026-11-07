# Bypass hypothesis matrix

**S** = supplied-text reconstruction (`poc/ResilientOracleBranches.t.sol`).  
**D** = deployment-artifact-matched source (`upstream-poc/UpstreamResilientOracle.t.sol`).

“Confirmed behavior” is not synonymous with an exploitable finding. No row alone establishes a live withdrawal or profit.

| # | Hypothesis | Result | Evidence / precondition |
|---:|---|---|---|
| 1 | Main skips BoundValidator when Pivot address is zero | Confirmed behavior in S and D | Main enabled/nonzero; D `test_mainAcceptedOnlyWhenPivotIsActuallyUnconfiguredOrDisabled`; S reject-all validator control |
| 2 | Main skips BoundValidator when Pivot is disabled | Confirmed behavior in S and D | Governance/configuration must disable Pivot |
| 3 | Enabled Pivot returning zero makes D accept Main without bounds | **Rejected for D; confirmed for S** | D proceeds to Fallback/Main↔Fallback or reverts; S passes `pivotPrice != 0` as enable boolean |
| 4 | Enabled Pivot revert makes D accept Main without bounds | **Rejected for D; confirmed for S** | Same distinction as #3 |
| 5 | Main = 0 is accepted as final price | Rejected in S and D | Final price must be nonzero |
| 6 | Fallback = 0 is accepted as final price | Rejected in S and D | Final price must be nonzero |
| 7 | Fallback alone is accepted with Main zero/disabled and no Pivot in D | **Rejected for D; confirmed for S** | D final Main↔Fallback check requires both nonzero |
| 8 | Valid Pivot + rejected Main + valid Fallback returns Fallback | Confirmed behavior in S and D | Fallback must independently pass Pivot bounds |
| 9 | Valid Pivot + rejected Main + no Fallback reverts | Confirmed behavior in S and D | Negative control |
| 10 | Main and Fallback can be compared if Pivot is invalid in D | Confirmed behavior in D | Both nonzero and BoundValidator must accept; route absent in S |
| 11 | Validator rejection can be ignored when Pivot exists in D | Rejected | Main validated flag must be true; Fallback/final checks remain |
| 12 | Validator revert fails open in D | Rejected | Main/Fallback calls catch and invalidate; final validator call reverts; no price acceptance |
| 13 | Missing BoundValidator asset config fails open | Rejected in D | `test_missingBoundConfigFailsClosedWithEnabledPivot`; no-Pivot branch never needs validator by design |
| 14 | Permissionless caller can change D validation thresholds | Rejected | ACM test `test_boundConfigurationIsAccessControlled` |
| 15 | Governance can configure bounds wide enough to accept 2× deviation | Confirmed configuration risk in D | Only positivity/order checked; `test_governanceConfiguredWideBoundsAcceptTwoXDeviation` |
| 16 | Same contract as Main and Pivot defeats independent deviation checking | Confirmed in S and D | `test_correlatedMainAndPivotDefeatsCrossCheck` / `test_correlatedOracleRolesDefeatIndependentCrossCheck` |
| 17 | Different role addresses guarantee independent feeds | Rejected as an assumption | Must trace shared aggregators/pairs/upstream inputs at pinned block |
| 18 | Manipulating Pivot to zero is a universal D validation bypass | **Rejected** | D does not fail open on zero Pivot; requires Main/Fallback final validation or reverts |
| 19 | Manipulating Pivot's nonzero anchor can help a manipulated Main pass | Plausible, source-dependent | Ratio must remain inside configured bounds; usually requires control/correlation of both prices or wide bounds |
| 20 | `updateAssetPrice` accepts an attacker-provided price value | Rejected | No price parameter; `_getPrice` must succeed before a cache write |
| 21 | Cache written in tx1 poisons a borrow in tx2 | **Rejected in S and D** | Mined Anvil evidence in `evidence/*transient-evm.json` |
| 22 | Cache freezes a valid price against a later source change in the same tx | Confirmed in S and D | Same-transaction consumer and useful price direction required |
| 23 | Cache survives disabling Main/config replacement in the same tx | Confirmed in S and D | Existing entry is read before current configuration |
| 24 | Turning caching off clears an already populated cache | Rejected in S and D | Existing entry remains until transaction end |
| 25 | Cache is shared by all ResilientOracle proxy instances | Rejected | Contract-scoped transient storage; S `test_cacheIsContractScoped` |
| 26 | Different assets share one cache entry | Rejected | Asset is included in the transient key; D per-asset caching test |
| 27 | Caching-disabled D update validates and caches anyway | Rejected | D update can snapshot but skips `_getPrice` and cache write when disabled |
| 28 | Existing cache entry causes repeated snapshot updates | Rejected in S reconstruction and D | Early return/uncached-only snapshot; tests assert one snapshot call |
| 29 | Snapshot revert prevents all subsequent price use | Rejected | Failure is swallowed; current source value may be accepted/cached |
| 30 | Successful update proves capped snapshot advanced | Rejected | Optional hook can fail silently; inspect source timestamp/cumulative state |
| 31 | ResilientOracle itself rejects stale source timestamps | Rejected | Freshness delegated to each external source |
| 32 | ResilientOracle normalizes arbitrary source decimals | Rejected | Raw source value is returned; configured sources must share expected scaling |
| 33 | Paused oracle returns cached price through public getter | Rejected in S and D | Pause check executes before cache return |
| 34 | Pause prevents `updateAssetPrice` and snapshot hooks | Rejected in S and D | Updates can run while paused; reads remain blocked |
| 35 | Pause → update → unpause can reveal the same-tx cached value | Confirmed behavior | Operational ordering issue; no read while still paused |
| 36 | Snapshot-hook reentrancy creates an independent arbitrary-price primitive | Not established | A malicious Main already controls price; reentrancy may only reproduce cache-order risks and needs a concrete source/consumer |
| 37 | Arbitrary `vToken` passed to `updatePrice` grants extra price-writing power | Rejected as an independent primitive | It only resolves an underlying and invokes the already permissionless asset update; pool must use trusted vTokens |
| 38 | Supplied batch config always works with only caller permission | Rejected for S | External self-call needs oracle self-ACL; D uses internal calls |
| 39 | Implementation can be reinitialized directly | Rejected in S; upstream constructor disables initializers | Proxy deployment must still initialize atomically and be verified |
| 40 | TLOAD/TSTORE works on every EVM chain regardless of hardfork | Rejected as a deployment assumption | Artifact targets Cancun; verify chain hardfork/opcode support at pinned block |
| 41 | Large validator arithmetic wraps and accepts a manipulated price | Rejected | Solidity checked arithmetic reverts; no wrong acceptance |
| 42 | Oracle branch behavior proves a profitable PancakeSwap/Venus attack | **Rejected as a logical inference** | Needs consumer call order, source manipulation cost, caps/cash, flash repayment, exit, and signed net P&L |

## Primary negative controls

The most important controls for pool review are:

1. Independent nonzero Pivot + tight bounds + invalid Main/Fallback ⇒ no price.
2. Enabled Pivot zero/revert in D ⇒ no direct unbounded Main acceptance.
3. Cache in one transaction ⇒ no effect in the next transaction.
4. Paused getter ⇒ revert even with cache populated.
5. Caching disabled in D ⇒ no cache write and no `_getPrice` call during update.
6. Main or Fallback zero ⇒ not a final price.
7. Same branch with an unchanged honest source ⇒ no attacker economic delta.
