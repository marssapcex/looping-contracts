# Venus GameFi stale-collateral investigation

Evidence-bound analysis of the hypothesis that stale-but-unexpired BinanceOracle pricing lets an attacker buy RACA/FLOKI cheaply on a DEX and over-borrow from the Venus GameFi pool.

## Current result

The current candidate is **rejected on primary-source off-boarding evidence**: GameFi RACA/FLOKI are deprecated with zero collateral factors, and VIP simulations check zero CF/LT plus MINT/BORROW pause. VIP-679 also changes FLOKI MAIN from expired BinanceOracle to a fixed ChainlinkOracle exit price. These governance artifacts still need pinned RPC confirmation at the chosen block; they are not presented as a live execution proof.

No live exploit, withdrawal, or net profit is claimed. See [REPORT.md](REPORT.md) for the full analysis and exact evidence boundary.

## Recon

```sh
RPC_URL='https://bsc-rpc.publicnode.com' BLOCK=131549804 node scripts/recon-gamefi.mjs
```

The script writes `evidence/gamefi-recon-<block>.json`. It reads implementation slots, oracle/feed state, CF/LT, caps, pauses, cash/debt and Pancake execution quotes where applicable. Supply that JSON before attempting any state-changing PoC.

## Candidate fork harness

```sh
../.audit-tools/bin/forge build --sizes
```

The real-interface flash-loan/mint/borrow/repay harness compiles with solc 0.8.25. It is not marked as an executed or profitable PoC. Configuration and profit-accounting rules are documented in [REPORT.md](REPORT.md).

## Pinned upstream sources

- Isolated-pools commit: `UPSTREAM_ISOLATED_POOLS_COMMIT`
- VIP repository commit: `UPSTREAM_VIPS_COMMIT`
- VIP source hashes: `evidence/vips-source-sha256.txt`
