# PoC patterns and promotion gates

Each pattern starts with a minimal local model, then requires a pinned deployment replay before promotion. Existing 2026 incidents are references only; do not replay them as new audit findings.

## P1 — Raw-donation cap bypass

```text
victim mints S <= cap
attacker attempts over-cap mint -> must revert
attacker or third party transfers D directly to market
represented(victim) = victimShares * rawCash / totalShares increases without cap
attacker monetizes only through a separately owned pre-existing claim/delegated borrow
```

Assertions: cap transition absent, represented claim increase, real borrow/withdrawal, signed non-donor loss. A donor who receives only their own inflated claim has no demonstrated profit. Negative control: internally tracked cash or donation-inclusive cap check. Local test: `test_DonationRaisesExistingClaimsDespiteMintCap`.

## P2 — Empty vault/index rounding

```text
deploy or identify near-empty market
mint minimum shares
donate D without shares
measure exchangeRate/PPS and floor/ceil at 1 wei
victim deposits A or attacker borrows/redeems
repeat small operations versus one large operation
```

Assertions: actual victim asset loss or attacker liquid profit, not just an extreme quoted rate. Test `totalSupply=0`, `1 wei`, first honest deposit, and rounding boundaries. Negative controls: virtual shares, seeded supply, zero-share revert/no-pull, nonzero minimum exchange rate. References: Resupply, Hundred, Sonne, Radiant, Raft.

## P3 — Stale/offboarded NAV donation

```text
honest and attacker hold vault shares before manipulation
curator sets strategy cap=0 but leaves it active
attacker externally credits stale receipt with accounted value V and realizable cost C < V
vault redeems attacker shares from healthy liquid strategy
```

Assertions: per-strategy NAV and liquidity, attacker `payout - principal - C - fees - gas`, victim residual and healthy-market delta. Negative control: remove strategy or value receipt at realizable conservative value. Local test: `test_ZeroCapActiveNavDonationVsRemovalControl` uses `V=90`, `C=0` explicitly and gets +45 before gas. That zero cost is a model assumption, never mainnet evidence.

## P4 — Instant vault PPS composed with lending liquidation

```text
record pool EMA and vault PPS independently
move LLAMMA/AMM into soft liquidation
reduce vault supply through redemptions if possible
donate/stake to vault recipient, increasing PPS without shares
read composed collateral oracle and execute hard liquidation/borrow
unwind and measure attacker cost, borrower equity, liquidator proceeds
```

Assertions: every multiplicand's one-block change, liquidation band state, actual debt repaid/collateral seized, and separate borrower/attacker/later-liquidator economics. Negative control: PPS cap/smoothing and reduced concentration. Reference: sDOLA; no 2026 reproduction in target audits.

## P5 — Source-market capture and guard convergence

```text
enumerate every spot/TWAP/median constituent and its liquidity
for capital tier A/B/C and delay T:
  move minimum subset of venues to target price
  read oracle before guard, during rejection, and after sustained convergence
  calculate borrow/liquidation capacity and extraction
```

Assertions: source updates, guard decisions and cost over the whole delay. A 37-minute rejection is not a permanent defense if the attacker can sustain convergence. Negative controls: independent deep sources, deviation/floor, rate-limited borrow and liquidation pause. References: Venus THE, UwU, Tectonic, Balance.

## P6 — Wrong/stale/invalid quote and configuration

```text
bind expected {asset, base, quote, feed, decimals, direction, round, min, max}
inject wrong feed, omitted quote conversion, stale timestamp, false validity, decimal mismatch
update only one of two interdependent configuration values
call borrow/swap/liquidate and measure actual output
```

Assertions: failure occurs before state-changing value flow, not merely an event or warning. Compare low/high rate and validity boolean. Negative control: complete atomic configuration and independent unit calculation. References: cbETH, Ploutos, Ribbon, Aave CAPO, Bonzo, LUNA.

Frax-CVX application: `frax-cvx-audit/scripts/oracle_validity_poc.py` proves only the ignored boolean with production `cvxFXBSwapper` bytecode. False and true cases both execute; attacker deltas are zero. Mainnet promotion additionally requires stale deployed state and profitable MEV/extraction.

## P7 — Circular route/output fabrication

```text
construct A→B (declared 100), B→A (90), A→B (80)
naive terminal sum = 180; actual final B = 80
open margin/borrow using declared 180
callback must compare actual 80 and post-action solvency
```

Assertions: connected hops, no nonfinal terminal output reconsumption, actual terminal balance delta, canonical pools and post-action health. Negative control: terminal-hop-only accounting plus actual-received check. Local test: `test_CircularRouteDoubleCountAndTerminalCheck`. Reference: Rhea; target recheck does not reproduce Rhea.

## P8 — Authenticity and counterfeit collateral

```text
submit valid-looking data with invalid proof
submit valid proof from wrong signer
list counterfeit canonical-looking token and pool
mint unbacked supply and attempt downstream borrow
```

Assertions: reject before storing/releasing; canonical token/issuer and verifier set; nominal mint and real withdrawal logged separately. Negative controls: correctly paired proof/signer and canonical deployment. Local test: `test_UnsignedProofAndWrongSignerRejectedOnlyByGuard`. References: Bonzo, Kelp, Ionic, Echo.

## P9 — Target route-endpoint negative control

For `Looping.openPosition`, use a pool that really pulls supplied collateral, mints debt, enforces post-action health, and repays flash liquidity. Correct endpoints must execute for the caller only. Wrong terminal asset must not be treated as declared yield collateral. Current local result: correct route 100 supply/100 debt; wrong terminal reverts; victim supply/debt/token deltas zero. This does not verify the external HyperLend pool, router bytecode, or mainnet deployment.

## Fork promotion checklist

1. Record exact source commit, deployed address, chain, archive block and bytecode hash.
2. Read feed/source/config/cap/active-set/residual/allowance state at that block; never silently use `latest`.
3. No storage overrides, admin pranks, self-donation presented as victim value, or free mock output in the promoted path.
4. Preserve valid and invalid controls, extreme tiers, stale rounds, min/max, and cross-user balances.
5. Assert a real withdrawal and positive attacker net P&L after all costs. Keep gross borrow, protocol bad debt, victim loss, frozen/recovered value, and nominal token changes in separate fields.
6. If any precondition is unavailable, retain `LEAD`/`NOT_A_CURRENT_MAINNET_FINDING` with `why_unproven` and the next read or test.
