# SomniaLend × dreamDEX — pinned fork economic PoC

Measures, on pinned Somnia mainnet state, whether a flashloan can push a dreamDEX CLOB book far
enough that SomniaLend's oracle re-read inside the same transaction credits the attacker with more
borrow power than the flashloan costs. This is the Mango-style shape: the protocol's code does what
it says, the question is whether its price source can be moved for less than the borrowing it unlocks.

Nothing in this directory is a source-code bug hunt. It **has** now been executed on Somnia: see
[`REPORT.md`](REPORT.md) for the measured result at block 461 020 184 and the raw logs in
`evidence/`. Results are only valid when the JSON in `results/` and the logs in `evidence/` come
from a real fork run at a pinned block, which is what those files are.

## Two ways to clear the RPC

**A. The proxy (works with any forge, including 2.0).** Somnia rejects EIP-1898 block objects;
the bundled proxy rewrites them to block numbers. No version hunting:

```bash
node eip1898-proxy.mjs --upstream https://api.infra.mainnet.somnia.network --port 8546 &
forge test --fork-url http://127.0.0.1:8546 --fork-block-number <N> --match-test test_attack -vv
```

`bootstrap-poc.sh ~/my-poc` builds a folder with the PoC, forge-std, the proxy and a `go.sh` that
does the above. Verified against a fake RPC that rejects the object form exactly like Somnia.

**B. Forge 1.7.1.** Sends plain hex block numbers, no proxy needed.

## Why Forge 1.7.1 is the fallback and not the default

Somnia's RPC rejects EIP-1898 block objects (`{"blockHash": ...}`) with `-32602 invalid parameters`.
Forge ≥ 1.8 sends that form on every account read during fork bootstrap, so the run dies with

```
failed to get account for 0x0000000000000000000000000000000000000000
```

Forge ≤ 1.7 sends hex block numbers and works. Same report upstream:
`somnia-chain/dreamdex-bot-kit` issue #37.

> **`foundryup -v 1.7.1` no longer works.** foundryup 2.x only knows stable/nightly, so that
> command prints `foundryup 2.0.0` and silently keeps your current forge. Install the exact
> release tarball instead:

```bash
curl -L -o f.tar.gz https://github.com/foundry-rs/foundry/releases/download/v1.7.1/foundry_v1.7.1_darwin_arm64.tar.gz
mkdir -p ~/.foundry/v1.7.1 && tar xzf f.tar.gz -C ~/.foundry/v1.7.1
FORGE=~/.foundry/v1.7.1/forge ./run-fork.sh sweep     # darwin_amd64 / linux_amd64 / linux_arm64
```

`run-fork.sh` now refuses to run on forge >= 1.8 without the proxy and tells you which of the two
routes to take.

## Run it on the fork

```bash
cd somnialend-audit
npm ci --prefix tools            # pure-JS solc 0.8.24, no platform binaries

export SOMNIA_RPC_URL=https://api.infra.mainnet.somnia.network
export SOMNIA_FORK_BLOCK=$(cast block-number --rpc-url "$SOMNIA_RPC_URL")

./run-fork.sh recon      # reserves, aTokens, feeds, staleness, CLOB params, books, depth
./run-fork.sh control    # flashloan with no trade: proves the oracle does not move
./run-fork.sh sweep      # all atomic zero-seed directions, size sweep
```

`./run-fork.sh all` runs recon → control → sweep. Logs land in `evidence/`, JSON per scenario in
`results/`. Unit tests for the harness itself (arithmetic + revert decoding, no chain):
`./run-fork.sh unit`.

## What each scenario does

Both directions are zero-seed: the contract starts with no tokens, borrows only gas from the tester.

| Scenario | Flash | Trade | Collateral supplied | Borrowed |
|---|---|---|---|---|
| `somi-pump-supply` | USDso | IOC **bid** on SOMI/USDso, pushes the ask up | WSOMI (wrapped from the fill) | max USDso, optionally every other enabled reserve |
| `usdso-pump-supply` | USDC.e | IOC **ask** on USDC.e/USDso, pushes USDso up | USDso | max USDC.e, optionally the rest |

The decisive output of `recon` is the **required edge** per reserve, `(1 + premium) / LTV − 1`:
that is the gap between what you pay and what the protocol credits that a flash-loaned round trip
has to clear. Measured on chain at block 461 020 184 it is 6 675 bps for WSOMI and 3 340 bps for
USDso; the realized gaps were 2–34 bps and 0 bps respectively.

Both scenarios then answer the same question with one number:

```
coverage = borrowPowerAfterSupply / (flashAmount + premium), in base currency
```

`coverage > 10 000 bps` is the necessary condition for the round trip to repay itself. If coverage is
below that, the path is a loss by construction regardless of how far the book moved, and the fork log
prints the size sweep so the number is visible instead of asserted.

The report also prints the two numbers that decide whether coverage could ever clear:

* `edgeRequiredBps` — `(1 + premium) / LTV − 1`: the gap between what the attacker pays and what the
  oracle credits that is needed for break even at the reserve's real LTV.
* `unitEdgeBps` — that gap as actually measured in the run: oracle value of the bought collateral
  versus base currency paid.
* `breakevenLtvBps` — the LTV at which this specific fill would have broken even.

The mirror family (supply the flash asset, borrow the opposite reserve, sell it) is not implemented
because it is structurally unrepayable: the flash principal must stay liquid to be returned, so it
cannot also be locked as collateral.

## How P&L is counted

A run counts as profitable only when the Pool's `flashLoanSimple` returned (amount + premium pulled)
**and** a strictly positive USDso balance is still owned by the contract. Abandoned collateral,
outstanding debt, bad debt, gross borrow size and theoretical quotes are never counted as profit.

When the attack cannot repay, the harness reverts with `Shortfall(SomniaMetrics)`, and the test
decodes the full metric set out of the revert payload: oracle before/after, book before/after,
realized fill price, coverage, borrow power, health factor, and the shortfall in flash-asset units and
base currency. A failing run is therefore still a measured data point.

## Files

```
src/Interfaces.sol        Aave V3 Pool/Oracle + dreamDEX CLOB + ERC20 surface actually used
src/SomniaLendAttack.sol  flashloan receiver, CLOB IOC orders, supply/borrow, metrics
src/Economics.sol         break-even algebra (coverage, required edge, break-even LTV)
test/SomniaLendEconomicPoC.t.sol  fork repro + control + sweep + JSON writer
test/HarnessUnit.t.sol    offline checks of the harness accounting
test/Economics.t.sol      offline checks of the break-even algebra
run-fork.sh               recon | control | sweep | all | unit
```

## Attack contract addresses (Somnia mainnet 5031)

Pool `0xEC6758e6324c167DB39B6908036240460a2b0168`
Oracle `0x9b7B5d69a08071ce74C2f3D655038E3b782eAaFc`
DIA SOMI adapter `0x1f5f46B0DABEf8806a1f33772522ED683Ba64E27` (DIA oracle `0xbA0E0750A56e995506CA458b2BdD752754CF39C4`)
WSOMI `0x046EDe9564A72571df6F5e44d0405360c0f4dCab`
USDso `0x00000022dA000002656c64D9eA6011ea952D008A`
USDC.e `0x28BEc7E30E6faee657a03e19Bf1128AaD7632A00`
CLOB: SOMI/USDso `0x035De7403eac6872787779CCA7CCF1b4CDb61379`, USDC.e/USDso `0x47fD2f18426f67106DBaC82F6d21D446c5F2120b`
dreamDEX SpotPool proxy reader `0x55790554C0d6914edb90F8d05B2f0bBc85605026`

The CLOB ABI (`getPoolParams`, `getBookLevels`, `getAutoPullRequirement`, `placeOrder`) follows
`somnia-chain/dreamdex-bot-kit`; native SOMI is the sentinel `0x28f34DeFd2b4CB48d9eE6d89f2Be4Bc601694c00`
and is wrapped into WSOMI before it is supplied.
