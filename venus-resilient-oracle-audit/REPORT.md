# Venus ResilientOracle aggressive bypass review

## Verdict

**No unconditional mainnet exploit, permissionless withdrawal, or positive attacker net P&L is established by this review.**

Three different artifacts must not be conflated:

1. The user-supplied text in `reference/`, which does not compile and has semantics that differ from Venus upstream.
2. The executable reconstruction in `contracts/`, used only to test the supplied text's intended branches.
3. `deployed-source/`, whose source hashes and executable runtime bytecode match Venus's BSC deployment artifacts. Live proxy pointers and pool configuration remain unverified until a pinned-block RPC review.

The user screenshot's oracle address, `0x6592b5DE802159F3E74B2486b091D11a8256ab8A`, matches Venus's BSC ResilientOracle proxy artifact. The artifact-matched implementation source is tested here; the supplied-only fail-open behaviors are **not** attributed to that address.

## The three claims

| Claim | Result on artifact-matched source | Required qualification |
|---|---|---|
| Main is accepted unconditionally without Pivot | **Confirmed as a configuration-dependent branch, not a permissionless vulnerability by itself.** | Main must be enabled and return nonzero; Pivot must be address zero or disabled. No BoundValidator call occurs on this branch. An enabled Pivot that reverts or returns zero does **not** directly fail open to Main in this source. |
| Permissionless transient-cache poisoning | **Rejected across transactions; confirmed only as same-transaction first-valid-price-wins behavior.** | `updateAssetPrice` is permissionless but accepts no attacker price. Caching must be enabled for the asset and `_getPrice` must succeed. `tstore` is contract- and transaction-scoped. A real same-transaction consumer and profitable economics are still required. |
| BoundValidator threshold manipulation | **No permissionless threshold setter was found.** | The artifact-matched BoundValidator uses ACM on `setValidateConfig`. Risks remain from governance-set wide bounds, correlated oracle roles/shared feeds, and manipulation of the prices used as validator inputs. The deployed-source ResilientOracle's `boundValidator` is immutable. |

## Artifact-matched source findings

### D-01 — No-Pivot operation deliberately reduces the oracle to one source

**Classification:** security-relevant design behavior; severity is configuration- and source-dependent.

At `deployed-source/contracts/ResilientOracle.sol:427-435`, `_getMainOraclePrice` returns `(mainOraclePrice, true)` without consulting BoundValidator when `pivotEnabled` is false. That boolean is derived from Pivot address/enable configuration at lines 373-387, not from whether a Pivot price was successfully obtained.

Consequences:

- With Pivot genuinely unconfigured/disabled, any nonzero Main price can be returned at line 388. There is no independent freshness, decimals, or deviation check in ResilientOracle.
- With Pivot configured and enabled but returning zero/reverting, lines 433-434 return `validated == false`. This is not the supplied variant's direct fail-open.
- If Pivot validation fails, Fallback can be validated against Pivot. If that is unavailable, the final Main↔Fallback path at lines 395-402 requires both prices nonzero and a successful bound check.
- Main = 0 is not a valid final price. Fallback = 0 is not a valid final price either.

**Exploit preconditions:** a no-Pivot configuration at the pinned block; a manipulable, stale, wrongly scaled, or otherwise incorrect Main source; a pool that uses that asset price for value extraction; and sufficient caps/liquidity/net proceeds. An attacker cannot enable this branch through `updateAssetPrice`.

**Tests:** `test_mainAcceptedOnlyWhenPivotIsActuallyUnconfiguredOrDisabled`, `test_enabledPivotReturningZeroDoesNotFailOpenToMain`, `test_enabledPivotRevertDoesNotFailOpenToMain`, `test_pivotInvalidUsesFinalMainFallbackComparison`, and `test_fallbackCannotStandaloneWithoutPivotOrMain`.

### D-02 — Transient cache freezes the first valid price for the rest of the transaction

**Classification:** same-transaction consistency/staleness risk; pool-dependent, not cross-transaction poisoning.

`updatePrice`/`updateAssetPrice` are permissionless (`243-255`). `_updateAssetPrice` returns immediately if a cache entry exists (`340-343`), optionally refreshes Main's snapshot, and caches `_getPrice` only when the asset's `cachingEnabled` flag is true (`345-354`). `_getPrice` returns a nonzero cached price before reading any oracle (`367-370`).

Confirmed behavior:

```text
same transaction: cache 100 -> Main changes to 200 -> oracle still returns 100
next transaction: cache 100 in tx1 -> Main changes to 200 in tx2 -> oracle returns 200
```

The cache does not let a caller submit an arbitrary integer. The first value must pass the same source selection and validation flow. If caching is disabled, the update function does not call `_getPrice` and does not write a price.

A real exploit would require all of the following:

1. The pinned configuration enables caching for the target underlying asset.
2. The attacker can begin the transaction with no existing cache entry and cause a chosen **valid** price to be cached, or can benefit from an honest price becoming stale later in that transaction.
3. Any required source manipulation/snapshot action is possible at the pinned state and does not make validation fail.
4. The pool consumes the same ResilientOracle proxy and underlying key later in the **same transaction**, after the attacker's state transition.
5. The cached direction is economically useful: for example, overvaluing collateral for a borrow or undervaluing a liability for liquidation. A stale price by itself does not establish either.
6. Caps, available cash, collateral factors, flash-loan repayment, swaps, fees, slippage, and gas permit a positive realized balance change.

**Tests/evidence:** `test_sameTransactionFirstValidPriceWins`, `test_assetSpecificCaching`, `test_cachingDisabledUpdateDoesNotValidatePrice`, `evidence/upstream-transient-evm.json`, and `evidence/transient-evm.json`.

### D-03 — Oracle independence and bound width are governance/configuration assumptions

**Classification:** configuration risk; no permissionless threshold write found.

`setTokenConfig` does not enforce distinct Main/Pivot/Fallback addresses or independent upstream feeds. Configuring the same mutable source as Main and Pivot made a 2× price pass the artifact-matched BoundValidator in the test. Distinct wrapper contracts sharing the same Chainlink aggregator, AMM pair, or other upstream input would create the same economic correlation even with distinct addresses.

`BoundValidator.setValidateConfig` is ACM-gated (`deployed-source/contracts/oracles/BoundValidator.sol:71-78`). It checks only nonzero ratios and `upper > lower`; it does not impose a maximum allowed width. A governance-set `[0.4e18, 1.6e18]` configuration accepted Main = 200 against Pivot = 100 in the test.

The validator computes `anchorRatio = anchorPrice * 1e18 / reportedPrice` (`104-112`). Zero reported price returns false; zero anchor or missing config reverts. Arithmetic overflow also reverts rather than accepting a price. These are fail-closed behaviors, not bypasses.

**Tests:** `test_correlatedMainAndPivotDefeatsCrossCheck`, `test_governanceConfiguredWideBoundsAcceptTwoXDeviation`, `test_boundConfigurationIsAccessControlled`, and `test_missingBoundConfigFailsClosedWithEnabledPivot`.

### D-04 — Freshness, decimals, and snapshot correctness belong to the external sources

**Classification:** explicit trust boundary; exploitability depends on the configured oracle implementation.

ResilientOracle calls `getPrice(asset)` but does not inspect an updated-at timestamp, source decimals, sequencer status, AMM update interval, or snapshot age. A mock source with `lastUpdated = 1` and a raw `1_000_000` value was returned unchanged in a no-Pivot configuration.

`_updateAssetPrice` intentionally swallows `mainOracle.updateSnapshot()` failures (`345-349`) and can continue to cache the source's current value. A successful `updateAssetPrice` therefore does not prove a snapshot advanced. This is not automatically a bug: non-capped oracles may intentionally revert the optional snapshot hook, and a correct source must enforce its own freshness. It becomes dangerous if a capped/Twap source returns an old snapshot as valid.

**Tests:** `test_stalenessAndDecimalsRemainSourceResponsibilities`, `test_snapshotFailureIsSwallowedAndPriceStillCaches`, and `test_existingCacheSkipsLaterSnapshot`.

### D-05 — Pause blocks reads, not snapshot/cache updates

**Classification:** operational asymmetry; no direct pause bypass.

`getPrice` and `getUnderlyingPrice` explicitly revert while paused (`279-295`). `updatePrice` and `updateAssetPrice` have no pause check. The tests confirm that an update while paused can call Main's snapshot hook and populate transient cache; public reads still revert until unpause, after which the cached value can be read in that transaction.

This does not let a borrower read a price while the oracle remains paused. It matters only for operational expectations and same-transaction pause/update/unpause sequences.

**Test:** `test_pauseBlocksReadsButNotUpdateOrSnapshot`.

### D-06 — Same-transaction configuration changes do not invalidate an existing cache entry

**Classification:** governance timing/consistency risk, subordinate to D-02.

Replacing a token configuration with all oracle roles disabled and caching disabled did not clear an already cached value; the subsequent read returned it. This is expected from the cache-first read path and the absence of a transient invalidation operation. It is not a cross-transaction persistence issue.

A governance transaction that both caches and reconfigures an asset, or a complex multicall involving governance and a pool, must account for this ordering. Ordinary attackers cannot call the ACM-gated configuration function.

**Test:** `test_configurationReplacementDoesNotClearTransientPrice`.

## Supplied-text-only findings

### S-00 — The exact supplied contract is not buildable

**Classification:** unconditional defect of the supplied text; not evidence of a deployed Venus defect.

The supplied source omits Pausable inheritance, internally calls `external` functions, assigns a two-value return to one variable, and calls a state-changing snapshot routine from a `view` read path. See `evidence/supplied-compile.log` and `TESTABLE_SOURCE_DIFF.patch`.

### S-01 — Enabled Pivot failure returns zero/revert fails open to Main in the supplied variant

**Classification:** supplied-variant branch; **not present in the artifact-matched source**.

The supplied `_getPrice` passes `pivotPrice != INVALID_PRICE` as `pivotEnabled` (`reference/ResilientOracle.sol:179-210`). Thus a configured/enabled Pivot that returns zero or reverts results in Main being marked validated without BoundValidator. The reconstruction confirms this with a reject-all validator.

The artifact-matched source instead passes the configuration boolean and explicitly returns `validated == false` when an enabled Pivot has zero price (`deployed-source/...:383-387, 430-435`). Do not apply S-01 to the screenshot address.

### S-02 — Fallback can be accepted without Pivot or Main in the supplied variant

**Classification:** supplied-variant branch; **not present in the artifact-matched source**.

In the supplied text, a zero/invalid Main enters `_getFallbackOraclePrice` when Fallback is enabled, and that function skips validation when `pivotPrice == 0`. The artifact-matched source marks Fallback unvalidated when Pivot price is zero and its final Main↔Fallback route requires both prices nonzero. A standalone Fallback therefore cannot rescue a zero/disabled Main without Pivot in the artifact-matched source.

### S-03 — Supplied batch configuration introduces a self-ACL requirement

The supplied `setTokenConfigs` calls `this.setTokenConfig`, making the oracle contract itself the caller that must pass the single-config ACM check. The test demonstrates the resulting configuration revert when self-permission is absent. Artifact-matched upstream uses an internal call and does not have this exact behavior. This is an operational configuration issue, not a price exploit.

## Defensive results and rejected bypasses

- Cross-transaction transient poisoning: rejected on both executable models with actual mined Anvil transactions.
- Zero as a final price: rejected; final routes require nonzero values.
- Invalid Main with a valid independent Pivot and no valid Fallback: reverts.
- Validator false/revert with an enabled Pivot: does not directly accept Main in the artifact-matched flow.
- Standalone Fallback without Pivot in the artifact-matched flow: rejected.
- Permissionless threshold or token configuration: rejected by ACM in the executable tests.
- Cache shared between different ResilientOracle proxy instances: rejected; transient storage is contract-scoped.
- Reading through cache while paused: rejected; public getters check pause before returning cache.
- Direct arbitrary cache-value injection: rejected; the external update function has no price argument and caching requires a successful `_getPrice`.

See `BYPASS_MATRIX.md` for the broader hypothesis inventory.

## Economic standard for any subsequent pool claim

A pool candidate is not an exploit until a state-changing pinned-state simulation or transaction demonstrates all of the following:

- flash liquidity is obtained and repaid in the same transaction, including fee;
- supply/borrow caps, collateral factor, available cash, market pause state, and borrower permissions are satisfied;
- the oracle update and pool read occur in the required same-transaction order;
- the borrowed assets are actually transferable to the attacker and exitable through real liquidity;
- all swap price impact, DEX/flash fees, gas, liquidation penalty/incentive, and residual collateral are accounted for;
- final attacker balances exceed initial balances after repayment.

Use signed net P&L in a common numéraire:

```text
net = sum((final_liquid_balance[i] - initial_liquid_balance[i]) * exit_value[i]) - gas
```

All flash-loan liabilities must be zero at the end. Unwithdrawable residual collateral is not cash. Gross Venus borrow, pool TVL outflow, cached notional, and protocol bad debt are separate quantities and are not attacker profit.

## Validation completed

- Supplied reconstruction: 29 tests, including two fuzz campaigns.
- Artifact-matched source and BoundValidator: 18 tests.
- Local mined-transaction transient tests: both models passed same-transaction and cross-transaction assertions.
- Exact supplied source: expected compiler failure preserved.
- Source hashes: exact deployment-artifact matches for the selected ResilientOracle revision and BoundValidator.
- Executable runtime bytecode: matches both BSC implementation artifacts; only each 32-byte IPFS metadata digest differs.

No live pool call trace, pinned-block configuration, or mainnet P&L is claimed.
