# Ellipsis / BSC Permissionless-Loss Audit Report

Date: 2026-11-06  
Scope: supplied `MultiFeeDistribution`, `LpTokenStaker`, EPS Vyper token, and two-asset CryptoSwap Vyper implementation/proxy  
Result: **0 promoted FINDINGs; 2 LEADs**  
Mainnet status: **unmeasured — no defensible BSC archive pin or mainnet withdrawal/P&L**

## Executive result

No candidate is promoted. The exact deployed Solidity and Vyper sources were compiled and exercised locally, but both BSC RPC endpoints failed during TLS handshake and none of the eight screenshots contains a block number. A pinned mainnet fork, deployed-state read-back, real attacker withdrawal, and positive all-cost P&L therefore could not be established (`run.log:2-5,457`).

The strongest result is a real local EVM counterexample in the deployed LP emission logic. It produces a positive model-EPS withdrawal and is retained as **LEAD-001**, not represented as a BSC drain. A second lead records a confirmed wrong-account view result with no demonstrated asset movement. Generic reentrancy/compiler warnings and admin-only concerns are not inflated into findings.

This report does not assert that the deployed contracts are safe, currently exploitable, or historically exploited.

## Deployed scope and provenance

| Component | Deployed identity | Audit source |
|---|---|---|
| EPS token | `0xA7f552078dcC247C2684336020c03648500C6d9F` | `vyper/EllipsisToken.vy`, Vyper 0.2.11 |
| EPS staker | `0x4076CC26EFeE47825917D0feC3A79d0bB9a6bB5c` | `contracts/MultiFeeDistribution.sol`, exact solc 0.7.6, 200 optimizer runs |
| LP staker | `0xcce949De564fE60e7f96C85e55177F8B9E4CF61b` | `contracts/LpTokenStaker.sol`, exact deployed body |
| CryptoSwap proxy | `0xFD4afeAc39DA03a05f61844095A75c4fB7D766DA` | `vyper/CurveCryptoSwap2ETH.vy`, Vyper 0.3.4 |
| CryptoSwap implementation | `0x1E97685aa5b1F9c6Dc44aF52a1BBa8049F43226c` | Same implementation source; runtime unverified by RPC |

The deployed Solidity target matches Ellipsis initial commit `0e22a202e52bbf6d439e296e0cbe4da307720df0`, not current upstream HEAD. Flattened BscScan references and target-body hashes are preserved in `reference/` and `evidence/source-integrity.json`. All screenshot values, addresses, balances, rates, supplies, and timestamps are transcribed with their unverified status in `SIGNATURE.md`.

## LEAD-001 — Stale emission rate is applied before schedule advancement

**Status:** local-model LEAD; mainnet impact unproven  
**Source:** `contracts/LpTokenStaker.sol:183-195,199-212`  
**Details:** [`leads/LEAD-001.md`](leads/LEAD-001.md)

`_massUpdatePools` accrues every pool's entire elapsed interval using the old `rewardsPerSecond`, then applies and pops at most one expired emission-schedule entry. After the first rate is active, a delayed call crossing later schedule boundaries therefore accrues the whole interval at the stale rate.

The exact deployed-source local PoC performs a permissionless deposit, delayed claim, LP withdrawal, and MFD early exit:

| Signed delta / quantity | Raw 18-decimal model units | Evidence |
|---|---:|---|
| Attacker LP delta | `0` | `run.log:52` |
| Attacker EPS withdrawal / net model P&L | `+100000000000000000000000` (+100,000 EPS) | `run.log:53-55` |
| Gas and flash-loan cost | `0` model EPS; USD unmeasured | `run.log:54` |
| Protocol retained EPS delta | `+100000000000000000000000` | `run.log:56` |
| Victim EPS / LP delta | `0 / 0` | `run.log:57-58` |
| Schedule-correct gross EPS | `120000000000000000000000` | `run.log:59` |
| Excess withdrawal vs on-time control | `+40000000000000000000000` (+40,000 EPS) | `run.log:60` |
| On-time control withdrawal | `60000000000000000000000` | `run.log:44-46` |

**why_unproven:** the local LP/EPS tokens are mocks and `vm.warp` constructs the idle interval. The displayed deployed rate is zero but not Anvil-verified; historical schedule entries and actual idle intervals are unknown. No deployed LP position, EPS liquidity, stablecoin sweep, gas denominated in a value-bearing asset, or mainnet victim loss is measured. Accordingly, the +100,000 figure is only model EPS, never a mainnet dollar profit.

**Next check:** run `scripts/fork-readback.sh` with an archive RPC and numeric screenshot-correlated pin. If a nonzero stale interval is available, replay on Anvil at that pin, sweep EPS through a real liquid route, include all costs, and require positive net P&L before promotion. Full steps are in the lead.

## LEAD-002 — `unlockedBalance(user)` uses the caller's earnings

**Status:** confirmed view defect; integration LEAD only  
**Source:** `contracts/MultiFeeDistribution.sol:174-183`  
**Details:** [`leads/LEAD-002.md`](leads/LEAD-002.md)

The function starts with `balances[user].unlocked` but iterates `userEarnings[msg.sender]`. The exact-source test confirms that an attacker querying a victim sees attacker earnings, while a victim querying the attacker sees zero (`run.log:65-67`). No tokens move and MFD's own withdrawal functions do not consume this view.

**why_unproven:** no integration relying on the incorrect value, victim loss, attacker withdrawal, or positive P&L is known. The lead provides a pinned `cast call` comparison and requires an integration-level withdrawal before any promotion.

## Negative money-loss results

- **Curve callback:** `exchange_extended` requires exact input funding and shares `@nonreentrant('lock')` with swaps/liquidity mutations. Exact-Vyper nested exchange is rejected (`run.log:23-25`).
- **Curve initialization:** second `initialize` reverts (`run.log:32`). No proxy takeover is claimed without storage read-back.
- **Curve quote/withdrawal:** quote matches execution; proportional withdrawal burns LP once and returns both coins (`run.log:27-37`). These are local 18-decimal mock-coin results, not mainnet prices.
- **LP reentrancy:** late writes exist, but supplied Curve LP/EPS/MFD paths have no attacker transfer callback. Owner-added malicious tokens are excluded. No profitable callback was shown.
- **MFD reentrancy/mint:** EPS has no transfer hooks; reward claims are guarded, and unauthorized mint reverts (`run.log:64`).
- **Expired locks:** withdrawing without a reward update dilutes the withdrawer and benefits remaining lockers; this is self-harm/griefing rather than an attacker-profit path.
- **Views/admin:** zero-allocation view revert, missing deployed `addReward` period-finish initialization, oracle configuration, reward recovery, and ownership paths do not establish a permissionless withdrawal and are not promoted.

Detailed disposition of all 17 candidates and Slither references is in `CANDIDATES.md`. Slither analyzed 13 contracts with 102 detectors and returned 94 results; all money-relevant outputs were manually triaged (`run.log:456`).

## Campaign and test evidence

- **13 tests pass per seed across 8 seeds: 104 passing test instances, 0 failures** (`run.log:451`; final suite `run.log:449`).
- **24,000 fuzz executions:** three fuzz tests × 1,000 CI runs × eight seeds (`run.log:452`). These cover LP principal round trips, STATE0 stale-emission replays, and exact-Vyper swap quote/execution.
- **2,880 campaign rows:** ten extreme states, nine drain strategies, four capital tiers, eight seeds (`run.log:453`). A–C execute 2,160 local arithmetic cases. Tier D contributes 720 skips because protocol-wide TVL was not measured at ≥ `$1e9` (`run.log:454`).
- **168 local campaign counterexamples** are stale-emission variants. Canonical `S0-T0-A-seed0` is replayed using real EVM transactions and the withdrawal/P&L assertions above (`run.log:455`).
- Full row-level evidence: `evidence/campaign.csv`; summary: `evidence/campaign.json` and `evidence/campaign-run.log`.

The arithmetic campaign is explicitly a model. Gas and flash-loan cost are zero in model units, EPS/USD is unpriced, and no row is promoted. Dust-only rounding, admin-rug claims, MEV, and self-harm are excluded.

## Tool and corpus limitations

Exact compilers were used: solc `0.7.6+commit.7338295f`, Vyper `0.2.11+commit.5db35ef`, and Vyper `0.3.4+commit.f31f0ec` (`run.log:3`). Vyper bytecode/runtime artifacts are in `evidence/`; Curve tests use a clearly tagged local runtime-etch surrogate for a fresh proxy, followed by real initialization and transaction calls. That surrogate is not mainnet state.

`vulnchain` is absent, so no incident IDs or loss figures are asserted (`run.log:6`). The supplied Hacken v1 and PeckShield V2 audit PDFs were read from exact GitHub blobs; their admin-dependent and different-contract findings are compared in `CANDIDATES.md`, not copied into this report.

## Reproduction

From `ellipsis-audit/` with Foundry on `PATH`:

```sh
npm install --ignore-scripts
python3 scripts/campaign.py
FOUNDRY_PROFILE=ci forge test --match-path 'poc/*.t.sol' --fuzz-seed 0 -vvv
```

Run seeds `0` through `7` for the recorded 24,000 fuzz executions. Exact Vyper compilation commands and source provenance are recoverable from `SIGNATURE.md`, `scripts/`, and `evidence/`. No command broadcasts a transaction or requires a private key.

## Artifact index

- `SIGNATURE.md` — addresses, compiler/source provenance, all eight image transcriptions, RPC status, and read-back plan.
- `INVARIANTS.md` — 14 unit-aware invariants and campaign coverage.
- `PAUSE.md` — complete external routing/guard inventory and reopening semantics.
- `CANDIDATES.md` — 17 triaged candidates and prior-audit mechanism comparison.
- `poc/` — exact deployed Solidity tests and exact Vyper runtime tests.
- `leads/` — both unproven leads with `why_unproven` and next checks.
- `run.log` — eight-seed test output, signed P&L, and final aggregates.
- `evidence/` — campaign rows, compiler artifacts, Slither log, source hashes, and original screenshots.

**Final promotion result: 0 FINDINGs. LEAD-001 and LEAD-002 remain unproven on BSC mainnet (`run.log:457`).**
