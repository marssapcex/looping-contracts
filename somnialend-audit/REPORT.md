# SomniaLend × dreamDEX — measured fork result

Every number below comes from a pinned Somnia mainnet fork, executed in GitHub Actions with
Forge **1.7.1** (the highest version whose fork bootstrap the Somnia RPC accepts — 1.8+ sends
EIP-1898 block objects and gets `-32602`). Raw logs and per-run JSON are committed in
`evidence/` and `results/`; the run that produced them is named next to each table.

**Headline: the atomic attack does not pay at this block, and the reason is arithmetic, not luck.**
The DEX trade is profitable against the protocol's own valuation — but only by ~2–34 bps, while
the reserve's loan-to-value requires **3 340–6 675 bps** of edge before a flash-loaned round trip
can repay itself. Measured on state, not inferred from source.

| Run | Block | recon | control | sweep |
|---|---|---|---|---|
| 42693721296 | 461 020 184 | pass | pass | pass (8 scenarios, all shortfall) |

---

## 1. The live configuration (block 461 020 184)

Pool `0xEC6758e6324c167DB39B6908036240460a2b0168`, implementation `0x1C53629cd824c293ce0611BbA08E4B0f6e92e5cC`.
Oracle `0x9b7B5d69a08071ce74C2f3D655038E3b782eAaFc`, 8-decimal base currency, **no fallback oracle**,
flash premium **5 bps**.

| Reserve | Oracle price | LTV | Liq. threshold | **Edge needed** | aToken | aToken cash |
|---|---|---|---|---|---|---|
| WSOMI | 0.165944 | 60.00% | 72.50% | **6 675 bps** | 0xFe17…FF4A | 3 603 356.9 |
| USDso | 0.99984847 | 75.00% | 85.00% | **3 340 bps** | 0x3a58…3e86 | 132 329.2 |
| USDC.e | 0.99984847 | 75.00% | 85.00% | **3 340 bps** | 0x024c…f1a9 | 6 279.9 |
| WETH | 2 119.15 | 70.00% | 82.50% | **4 292 bps** | 0x27b5…211b | 13.97 |
| WBTC | 74 999.63 | 65.00% | 75.00% | **5 392 bps** | 0xb4c2…607e | 0.118 |

Edge needed = `(1 + premium) / LTV − 1`. This is the whole attack in one column: a flash-loaned
round trip only closes if the protocol values the collateral you just bought more than the price
you paid, by at least this much.

### Price sources

Every reserve reads a 1 519-byte DIA adapter (`latestRoundData`, `roundId = 0`, no
`EIP-1967` implementation slot). Two distinct feeds are in use:

- **SOMI** → `0xfA2b4bb4330f77d799d7f9093b68f1fDe21043A7`, answer `16594400`, `updatedAt` = block timestamp − 12 317 s (**3.4 hours stale**).
- **USDso and USDC.e** → **the same feed** `0x7052210aE4e3624975d706EF8901CDb455d7DEC4`, answer `99984847`, `updatedAt` − 56 333 s (**15.6 hours stale**).

Two reserves, including the one that is itself the accounting unit, priced by an identical
address. That is a real architectural observation, but see §4: it does not convert into profit here.

## 2. Book depth — how much money it takes to move a price

Cumulative asks on SOMI/USDso at the measured block:

| Levels | Worst ask | Walk | Cumulative USDso to lift |
|---|---|---|---|
| 1 | 0.1654 | 0 bps | 94.3 |
| 13 | 0.1800 | 882 bps | 35 715.0 |
| 16 | 0.3050 | 8 440 bps | 35 790.2 |
| 19 | 1.0000 | **50 459 bps** | 35 813.5 |

The last three levels are a thin tail: ~75 k USDso of buying moves the top of book from 0.1654 to
1.0 (a 6× move). So the book *can* be moved. This is exactly why the question had to be measured
rather than argued: reachable ≠ profitable.

## 3. Measured scenarios (block 461 020 184)

All runs are **zero-seed** (`seededBase = 0`), flash → IOC order → same-callback oracle reread →
wrap/supply → borrow max → repay, with the full metric set decoded out of the revert payload on
failure, so no run is a lost data point.

| Scenario | Notional | Realized fill | Oracle value vs paid | Edge needed | Coverage | Best-ask move | Oracle move | Net (base) |
|---|---|---|---|---|---|---|---|---|
| somi-pump-supply | 100 | 0.165405 | **+34 bps** | 6 675 | 6 038 | +6 bps | **0** | −39.63 |
| somi-pump-supply | 5 000 | 0.165580 | +23 bps | 6 675 | 6 028 | +18 bps | **0** | −198.65 |
| somi-pump-supply | 25 000 | 0.165850 | +7 bps | 6 675 | 6 012 | +42 bps | **0** | −997.31 |
| somi-pump-supply | 100 000 | 0.165933 | +2 bps | 6 675 | 8 687 | +60 bps | **0** | −1 313.00 |
| usdso-pump-supply | 25 | 0.999700 | 0 bps | 3 340 | 7 494 | 0 | **0** | −6.27 |
| usdso-pump-supply | 1 000 | 0.999622 | 0 bps | 3 340 | 7 493 | 0 | **0** | −250.75 |
| usdso-pump-supply | 3 000 | 0.999274 | 0 bps | 3 340 | 7 490 | 0 | **0** | −753.02 |
| usdso-pump-supply | 6 000 | 0.999187 | 0 bps | 3 340 | 7 490 | 0 | **0** | −1 506.43 |

Reading the two directions separately:

**SOMI.** Buying SOMI on dreamDEX pays 0.165405–0.165933 against an oracle of 0.165944, i.e. a
genuine **+2 to +34 bps** of free discount. It is real, it is consistent, and it is 200× too small.
Coverage tops out at 8 687 bps against the 10 000 needed, so the round trip cannot repay the flash
loan at any size tested; the shortfall is 39.6 SOMI-equivalent at 100 notional and 32 765 at 100 000.

**Oracle impact is zero in every single run.** The same-callback reread returns the identical
answer before and after the trade, for every size. A 60 bps best-ask move changes nothing. This is
the decisive measurement, and it is what the user asked for: not "the oracle is safe by design",
but "the oracle did not move while real size traded through it".

**USDso.** Achieved edge is a flat **0 bps**: you buy USDso at 0.99970 and the protocol values it at
0.99984847, a 15 bps gap that the 0.5% crossing slippage consumes entirely. Coverage sits at
7 490–7 494 bps. The USDso order also did not move the USDC.e/USDso book at the sizes tested.

**Control (no trade).** Flashloan of 1 000 USDso, no order, no supply: oracle before and after both
return `0.99984847`, best bid/ask unchanged, zero borrow, repaid in full, run explicitly marked
`seededBase = 4 999e4` (it was handed its own premium) and therefore *not* reportable as profit.
The control is the calibration that makes the numbers above meaningful.

## 4. What this does and does not establish

**Established, measured:**
1. The DEX/oracle basis is positive but tiny: +2–34 bps on SOMI, 0 bps on USDso after slippage.
2. Same-transaction oracle movement from real CLOB size is **zero** at every size tested, up to 35.8 k USDso of buying that lifted the best ask by 8 440 bps in the depth probe.
3. A 6× book move is affordable arithmetically (~75 k USDso) but is not what the fill captures: the realized execution price barely moves because the liquidity sits at the top of book.
4. The LTV gate requires 3 340–6 675 bps. The measured edge is 0–34 bps. The gap is two orders of magnitude, and it is a stated reserve parameter, not a bug.
5. The control proves the harness attributes nothing to a no-op.

**Not established, and deliberately not claimed:**
- No profit, no bad debt, no victim. `badDebtBase` is negative in every run (debt < collateral), so nothing here makes the lender whole-less.
- The two-feeds-one-address finding for USDso and USDC.e is reported as configuration, not as a vulnerability: nothing in the sweep converts it into a positive net.
- These are atomic results at one pinned block. A multi-block or capital-intensive strategy is out of scope by the user's own instruction, and would also need the oracle to actually move.
- Nothing here says the protocol is safe in general. It says this attack shape loses money at block 461 020 184, by the amount printed in the last column.

## 5. Reproduce

```bash
foundryup -v 1.7.1                 # mandatory: Somnia rejects EIP-1898 block objects
cd somnialend-audit && npm ci --prefix tools
export SOMNIA_RPC_URL=https://api.infra.mainnet.somnia.network
export SOMNIA_FORK_BLOCK=461020184
./run-fork.sh all                  # recon -> control -> sweep, logs to evidence/, JSON to results/
```

Sweep sizes are env-tunable (`SOMI_SWEEP_1..4`, `USDC_SWEEP_1..4`), as are the crossing limits
(`DEX_BUY_LIMIT_BPS`, `DEX_SELL_LIMIT_BPS`) and `BORROW_ALL_OPPOSITE_RESERVES`.
