# Frax-CVX Audit Artifacts

Start with [`REPORT.md`](REPORT.md). Candidate details, invariants, and emergency controls are in [`CANDIDATES.md`](CANDIDATES.md), [`INVARIANTS.md`](INVARIANTS.md), and [`PAUSE.md`](PAUSE.md).

## Provenance

- Upstream: `https://github.com/convex-eth/frax-cvx-platform`
- Pin: `74901235a58c86677d552ef8c5041d9790fa9924`
- Production source: `contracts/` (unchanged from the pinned tree)
- Test-only mocks: `poc/`
- Source hashes: `reference/SHA256SUMS`; verification output: `evidence/source-hash-check.log`

## Reproduce

Run from repository root. The build script expects npm dependencies from `.audit-tools/frax-cvx-build`; the Python environment used for the recorded run is `.audit-tools/venv`.

```bash
node frax-cvx-audit/scripts/compile.cjs

.audit-tools/venv/bin/python frax-cvx-audit/scripts/staking_lock_incentive_poc.py
.audit-tools/venv/bin/python frax-cvx-audit/scripts/fee_conversion_poc.py
.audit-tools/venv/bin/python frax-cvx-audit/scripts/oracle_validity_poc.py

.audit-tools/venv/bin/python frax-cvx-audit/scripts/stateful_rewards.py \
  --seed 12648430 --sequences 32 --steps 128 \
  --output frax-cvx-audit/evidence/stateful-rewards.json

.audit-tools/venv/bin/python frax-cvx-audit/scripts/stateful_cvxfxb.py \
  --seed 3851 --sequences 32 --steps 128 \
  --output frax-cvx-audit/evidence/stateful-cvxfxb.json

.audit-tools/venv/bin/python frax-cvx-audit/scripts/stateful_cvxfxb_leverage.py \
  --seed 61617 --sequences 32 --steps 128 \
  --output frax-cvx-audit/evidence/stateful-cvxfxb-leverage.json
```

Recorded Python tools: Web3 7.16.0, eth-tester 0.14.0b1, py-evm 0.12.1b1, eth-utils 6.0.0, Slither 0.11.6, and crytic-compile 0.4.2. See `requirements-audit.txt`. The exact npm lockfile is preserved in the external build-tool directory when available; the audit source uses solc 0.8.10 and OpenZeppelin Contracts 4.9.6.

## Evidence map

- Conditional staking deficit and zero-incentive negative control: `evidence/staking-lock-incentive-poc.json` and `staking-lock-incentive-run.log`
- User-supplied zero-incentive screenshot (not block-pinned): `evidence/user-provided-lock-incentive-zero.png` and `.sha256`
- Conditional fee trapping: `evidence/fee-conversion-poc.json` and `fee-conversion-run.log`
- Conditional oracle-validity flag bypass: `evidence/oracle-validity-poc.json`, `oracle-validity-run.log`, and `oracle-validity-build.log`
- Reward campaign: `evidence/stateful-rewards.json` and `stateful-campaign.log`
- Paused `cvxFXB`: `evidence/stateful-cvxfxb.json` and `stateful-cvxfxb-campaign.log`
- Leverage `cvxFXB`: `evidence/stateful-cvxfxb-leverage.json` and `stateful-cvxfxb-leverage-campaign.log`
- Build/static analysis: `evidence/build.log`, `compiled.json`, `artifacts.json`, `slither*.log/json`

All PoCs using local mocks or storage overrides are labeled as such. They do not verify current deployment configuration or mainnet impact. No positive net mainnet attacker P&L is claimed.
