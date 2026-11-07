# Venus ResilientOracle audit workspace

Aggressive, executable review of the user-supplied `ResilientOracle`/`Transient` text **and** the Venus source revision matching the BSC deployment artifacts.

## Bottom line

- Supplied text: does not compile as provided; its enabled-Pivot-zero/revert fail-open is a supplied-variant behavior.
- Artifact-matched Venus source: no-Pivot Main acceptance is real but configuration-dependent; enabled Pivot zero/revert does not directly fail open to Main.
- Transient cache: same-transaction first-valid-price-wins is confirmed; cross-transaction poisoning is refuted with mined Anvil transactions.
- BoundValidator: threshold writes are ACM-gated; correlated feeds and governance-wide bounds remain configuration risks.
- No live pool exploit, permissionless withdrawal, or positive net P&L is claimed.

Read [`REPORT.md`](REPORT.md) first, then [`POOL_CHECKLIST.md`](POOL_CHECKLIST.md) before investigating a specific market.

## Directory guide

| Path | Purpose |
|---|---|
| `reference/` | User-supplied source text; not chain verified and intentionally not repaired |
| `contracts/` | Minimal testable reconstruction of the supplied text |
| `TESTABLE_SOURCE_DIFF.patch` | Exact supplied → testable changes |
| `poc/` | 29 supplied-reconstruction branch/fuzz tests and mocks |
| `deployed-source/` | Exact source revision matching Venus BSC implementation artifacts |
| `deployed-source/../DEPLOYED_SOURCE_COMMIT` | Selected revision `edb889b…` |
| `upstream/` | Current upstream comparison sources and BSC deployment artifacts |
| `upstream-poc/` | 18 tests against `deployed-source/` and the real BoundValidator logic |
| `evidence/` | Compiler logs, test logs, source/bytecode checks, and mined transient-storage results |
| `BYPASS_MATRIX.md` | 42 accepted/rejected/conditional hypotheses with controls |
| `POOL_CHECKLIST.md` | Required pinned-block configuration, consumer, and net-P&L checks |
| `PROVENANCE.md` | Detailed source identity, dependency versions, and assurance limits |

The directory name `upstream-poc` is retained for the test harness, but its imports point to `deployed-source/`, not the newer comment-only upstream snapshot.

## Reproduce

From this directory, with the workspace's `.audit-tools` dependencies installed:

```bash
./scripts/test.sh
```

This runs:

1. 29 supplied-reconstruction tests;
2. 18 artifact-matched source tests;
3. source-hash and executable-bytecode verification against deployment artifacts;
4. the expected failed compilation of the exact supplied source;
5. clean-chain Anvil transient tests for both models.

Individual commands:

```bash
../.audit-tools/bin/forge test -vv

(
  cd upstream-check
  ../../.audit-tools/bin/forge test -vv
)

node scripts/verify-artifacts.mjs
./scripts/check-supplied.sh
./scripts/test-transient.sh
```

The transient script starts a temporary local Anvil on port 8546 and stops it on exit. It uses Cancun transient storage and separate mined transactions, not just Foundry calls.

## Key evidence

- `evidence/supplied-tests.log` — 29/29 supplied-reconstruction tests.
- `evidence/deployed-source-tests.log` — 18/18 artifact-matched tests.
- `evidence/supplied-compile.log` — expected exact-source compiler blocker.
- `evidence/deployment-source-match.json` — 130 revisions checked, one exact ResilientOracle source-hash match.
- `evidence/source-integrity.json` — source hashes and executable-bytecode comparison for ResilientOracle and BoundValidator.
- `evidence/upstream-transient-evm.json` — artifact-matched same-transaction and separate-transaction results with transaction hashes.
- `evidence/transient-evm.json` — equivalent supplied-reconstruction control.
- `SHA256SUMS` — deliverable integrity manifest.

## Assurance boundary

The tested ResilientOracle revision reproduces the executable runtime bytecode in Venus's GitHub BSC implementation artifact, with only the 32-byte IPFS metadata digest different. BoundValidator also matches this way. This is strong source/artifact evidence, **not** a pinned-block proof that the live proxy still points to that implementation.

No BSC archive RPC state, live market config, Pancake reserve manipulation, pool call trace, flash-loan repayment, or exit economics has been used. Follow `POOL_CHECKLIST.md` and do not upgrade a configuration behavior into a mainnet exploit without those steps.
