# Oracle and accounting-boundary incident research

**Research date:** 2026-11-07  
**Scope:** lending, margin, collateralized issuance, staking/reward valuation, wrapper/vault accounting, and adjacent verifier/collateral comparators.  
**Corpus:** [`corpus.csv`](corpus.csv), 49 sourced entries, 2019–2026.

## Result

The incidents do not reduce to “manipulate an oracle.” The useful audit split is:

1. **Source-market manipulation** — spot AMM, thin order book, correlated median/source capture, LP/virtual price, or permissioned-by-stake reporting.
2. **Internal accounting used as a price** — `balanceOf`, `totalAssets/totalSupply`, `convertToAssets`, cToken exchange rate, AUM/share, or NAV composition.
3. **Authenticity and freshness boundaries** — unsigned proofs, compromised verifier/RPC infrastructure, stale rounds, wrong feed, decimals, missing quote conversion, or inconsistent risk-oracle configuration.
4. **Asset/route admission and execution accounting** — counterfeit collateral, unbacked mints, circular swap paths, and user-declared output mistaken for actual received value.
5. **Non-oracle comparators** — empty-market rounding, missing post-donation solvency checks, read-only reentrancy, and governance capture must not be mislabeled as price-feed failures.

The most reusable new boundaries are:

- **Cap writes must cover every way a counted position can increase.** A mint/deposit-path cap does not constrain direct ERC20 transfers, third-party mint-to-market, or externally credited lending positions.
- **A receipt-token balance is not realizable NAV.** Price each constituent at conservative executable value, bound abrupt PPS changes, and remove impaired strategies from the active set rather than merely setting their allocation cap to zero.
- **Declared route output is not actual output.** Use terminal-hop and actual balance-delta checks; reject routes that reconsume a previously produced terminal asset.
- **A valid API return type is not valid data.** Preserve and enforce validity flags, freshness, deviation bounds, feed identity, decimals, quote composition, and authentication before any swap/borrow/liquidation.
- **Liquidation volume, gross assets borrowed, bad debt, attacker proceeds, nominal token collapse, frozen value, returned value, and rollback value are separate quantities.** The corpus records them separately and does not sum them.

## Reuse rules for the active audits

- Entries dated 2026 are `EXCLUDED_2026_REPRODUCTION` or `COMPARATOR_2026_NO_REPRODUCTION`: their already-exploited mechanisms must not be re-reported as new audit findings.
- Historical entries are differential-test references, not evidence that a current deployment is vulnerable.
- Full Sail remains low confidence because no protocol postmortem was located. No PoC is derived from its uncertain details.
- A local mock counterexample proves only the modeled accounting rule. Current-mainnet promotion still requires pinned state, a permissionless path, a real withdrawal, and positive net P&L after costs.
- Issuer-affiliate assets (for example FRAX/FXB and related receipt tokens) remain inside oracle, share-accounting, and route-validation review; they are not exempt because an oracle is described as external.

## Artifacts

| File | Purpose |
|---|---|
| [`corpus.csv`](corpus.csv) | Machine-readable incidents, source/confidence, economic distinctions, four reuse flags, and reproduction policy |
| [`INCIDENTS.md`](INCIDENTS.md) | Family-level synthesis and high-signal case comparisons |
| [`sources/PRIMARY_NOTES.md`](sources/PRIMARY_NOTES.md) | Preserved factual extracts from primary or strongest technical reports |
| [`INVARIANTS.md`](INVARIANTS.md) | Executable unit-aware invariants and negative controls |
| [`POC_PATTERNS.md`](POC_PATTERNS.md) | State sequences, promotion conditions, P&L, and fork-test requirements |
| [`TARGET_RECHECK.md`](TARGET_RECHECK.md) | Application to HyperLend, Ellipsis, FOX, and Frax-CVX; new leads and exclusions |
| [`../poc/OracleAccountingBoundaries.t.sol`](../poc/OracleAccountingBoundaries.t.sol) | Local Foundry counterexamples for donation/cap, NAV, circular routes, authenticity, and deviation bounds |
| [`../frax-cvx-audit/scripts/oracle_validity_poc.py`](../frax-cvx-audit/scripts/oracle_validity_poc.py) | Production-bytecode conditional `cvxFXBSwapper` validity-flag PoC |

## Reproduce and validate

From the repository root, with the documented tool directories restored:

```bash
python3 oracle-accounting-research/scripts/validate_corpus.py
FOUNDRY_PROFILE=ci .audit-tools/bin/forge test --match-path poc/OracleAccountingBoundaries.t.sol -vvv
FOUNDRY_PROFILE=ci .audit-tools/bin/forge test --match-path 'poc/*.t.sol' -vv
node frax-cvx-audit/scripts/compile.cjs
.audit-tools/venv/bin/python frax-cvx-audit/scripts/oracle_validity_poc.py
sha256sum -c frax-cvx-audit/reference/SHA256SUMS
sha256sum -c oracle-accounting-research/SHA256SUMS
```

Recorded results: corpus validation PASS; 7/7 new boundary tests and 23/23 total root tests pass; Frax-CVX false/true validity scenarios pass with zero attacker token delta; 152 production/reference hash checks pass. Tool versions are in `evidence/tool-versions.log`.

## Source grades

- **A:** protocol, governance, risk-manager, or official postmortem.
- **B:** named security firm or technical reconstruction with transaction-level detail.
- **C:** secondary report with incomplete primary corroboration.

Sources are cited per row in `corpus.csv`. Search-derived facts are not treated as pinned-fork evidence.
