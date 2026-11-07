# Mendi Finance — flash-loan audit

Target: Mendi lending on Linea, pinned at `134d766bb7a07c9485f180d7d5edeb1fd9e30828`.

## Current result

The prioritized lead is missing freshness validation in the active `MixedPriceOracleV3` at `0x05b1b5b09251355fdEb13c768987Ab750D2c6865`: address-feed quotes use `latestAnswer()` without `updatedAt`/round checks. The older V2 artifact is retained for exact-source tests and historical provenance; it is not the active Unitroller oracle.

This root cause is **already publicly reported in upstream issue #3**, but that does not disqualify it for this investigation. It remains a candidate if unfixed and exploitable. It is not yet a proven live exploit: pinned CF/caps/pause/cash, Aave liquidity, executable DEX quotes, complete repayment/exit and liquid net P&L are still required. No mainnet transaction or profit is claimed.

See [REPORT.md](REPORT.md) for provenance, negative controls and the complete evidence boundary.

## Validation completed

```text
MixedPriceOracleV2: 5/5 unit tests passed
Artifact main sources: all selected sources match
Aave + Uniswap + Mendi fork harness: compiled with solc 0.8.10
State-changing fork: not executed
```

## Run pinned recon

```sh
export RPC_URL='https://linea-rpc.publicnode.com'
node scripts/recon-linea.mjs
export RECON='evidence/linea-recon-<block>.json'
node scripts/recon-execution.mjs
```

Provide both generated JSON files for candidate selection. `BLOCK=<number>` may be set before base recon for a historical pinned state.

## Tests

```sh
node scripts/check-provenance.cjs
../.audit-tools/bin/forge test -vvv
../.audit-tools/bin/forge build poc/MendiStaleCollateralFork.t.sol --sizes
node --check scripts/recon-linea.mjs
node --check scripts/recon-execution.mjs
```

## Main components

- `upstream/`: pinned Mendi contracts and Linea artifacts.
- `artifact-matched/CToken-legacy.sol`: legacy CToken source extracted from artifact metadata.
- `test/MixedPriceOracleV2.t.sol`: freshness/scaling and negative controls.
- `scripts/recon-linea.mjs`: market/oracle/feed/implementation recon.
- `scripts/recon-execution.mjs`: Aave flash and Uniswap execution screening.
- `poc/MendiStaleCollateralFork.t.sol`: real flash → mint → borrow → exit → repay harness with liquid-balance accounting.
