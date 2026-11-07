# FoxLpBondsPool Security Audit Report

Date: 2026-11-06  
Chain: BNB Smart Chain  
Result: **1 historical incident-backed FINDING; 0 additional promoted findings**  
Historical pin: attack block **116169049**, pre-attack fork **116169048**  
Current status at user-run pin **132016403**: **old permissionless path blocked by `Unauthorized`; arithmetic patch unverified**

## Executive result

**FINDING-001 — Pre-trade spot pricing plus same-transaction liquid inviter mint allows reserve-distortion monetization.**

`FoxLpBondsPool.stake()` calculates FOX-denominated bond principal from the current FOX/USDT spot quote, then swaps half the deposit through that same pair. The large internal swap radically increases FOX's post-trade price, but the already-calculated `stakeAmount` is not reduced or recomputed from execution/backing. `Treasury.lpBonds()` trusts that amount and immediately pays a liquid 3% inviter reward. Selling only that reward into the reserve-skewed pair can return more USDT than the attacker supplied.

The supplied narrative identifies the correct general area but gets the exploitation sequence wrong:

- The attacker did **not** need to pre-inflate FOX before `stake()`. The quote is taken first.
- The protocol's own USDT→FOX swap then makes FOX scarce and expensive.
- The attacker sells the **liquid inviter reward**, not the entire locked bond principal.
- The live trace reports about **112,976.12 USDT net to the attack contract**; L2Beat separately records **677,549.0505 USDT gross pair depletion** (`run.log:159-160`).

The finding is promoted on historical mainnet evidence and an independent exact-source reproduction, not on the screenshot narrative alone.

A user-executed current-state fork at block **132016403** subsequently reached `stake()` but reverted `Error("Unauthorized")` for a fresh caller. It produced no inviter FOX, sale, attacker P&L, or pair delta. This demonstrates that the old permissionless caller path was blocked at that pin by the `onlyOperator` guard. It does not establish that the underlying quote-then-trade arithmetic was changed, nor that an already authorized operator cannot execute it. The diagnostic test's `PASS` is not an exploit-success assertion (`evidence/current-user-replay.log`).

## FINDING-001 — Quote-then-trade bond accounting and immediate liquid reward drain USDT

**Severity:** Critical  
**Status:** historical mainnet incident confirmed; exact-source local replay positive  
**Permissionless path:** referred staker → `stake()` → treasury inviter transfer → FOX/USDT sale  
**Affected source:** `contracts/FoxLpBondsPool.sol:124-169`; `contracts/Treasury.sol:176-185`

### Root cause

1. **Spot quote before execution.** `getSwapPrice()` calls `getAmountsOut(1e18, [FOX,USDT])` at lines 124-133. This is a same-block reserve quote, not a TWAP or execution-independent oracle.
2. **Principal frozen before the protocol moves the market.** Line 151 computes:

   ```text
   stakeAmount = poolUsdtBalance * 1e18 / discountedPreTradeSpot
   ```

3. **Same-pair reserve distortion.** Line 153 swaps half the USDT into FOX; line 157 adds liquidity at the new ratio. There is no maximum stake relative to pair depth and no post-trade backing check.
4. **Liquid payout from stale accounting.** Lines 164-169 derive a 3% inviter amount when `stakeDays >= 180` and deposit ≥1,000 USDT. Treasury lines 176-185 burn LP, mint `_stakeAmount + inviterRewardAmount`, mint sFOX/rFOX, and immediately transfer liquid inviter FOX.
5. **Immediate monetization.** The inviter sells that FOX into the now USDT-heavy/FOX-scarce pair. FOX's actual 2.5% sell tax is included in the replay; it does not prevent profit.

The caller's `_swapPrice` check does not fix this. Passing `type(uint256).max` disables the upward-price branch, but even a bidirectional spot-slippage check would not establish post-trade backing. The missing invariant is that mint/credit must be bounded by executed value, with a stake-size/price-impact limit and no same-transaction liquid reward.

### Live incident evidence

- Transaction: `0x8e1775cbfd44db29744cc6687ff1822d2c47321de6e94062f789ad6181ad5514`
- Attack block: `116169049`; canonical pre-attack fork: `116169048` (`run.log:8`).
- Canonical DeFiHackLabs source replays original calldata against the already-deployed attack contract, with no state override, and asserts approximately `112,976 USDT` gained (`run.log:158`).
- Trace-derived live values (`run.log:159`):

| Live quantity | Value |
|---|---:|
| Aggregated flash liquidity | `481,974,785.536796421654333021 USDT` |
| Total treasury FOX mint | `91,319,059 FOX` |
| Liquid inviter reward | `2,659,778 FOX` |
| FOX reaching pair after sell tax | `2,593,283 FOX` |
| USDT sale output | `482,652,334 USDT` |
| Net to original attack contract | **`+112,976.12 USDT`** |

The approximately `$118.7K` report is consistent with this attacker-net account. L2Beat instead measures **677,549.050517106599255604 USDT / $676,520.83 gross pair loss** (`run.log:160`). These are different accounting views and are not contradictory.

### Independent exact-source local withdrawal and P&L

This session deployed the exact pool, base, treasury, FOX, sFOX, rFOX, referral and log Solidity bodies behind real ERC1967 proxies. The local Pancake model uses 0.25% fees, the real pre-attack reserves, the pinned discounted quote, and the actual FOX 2.5% sell tax. The 450M USDT minted war chest and owner-bound referral are explicitly tagged setup surrogates for flash liquidity and the pre-existing referral. Flash-loan fees are zero in this model.

| Signed quantity | Raw / displayed value | Evidence |
|---|---:|---|
| Initial model capital | `450,000,000 USDT` | `run.log:15,42` |
| Raw pre-trade quote | `5.603812687200652594 USDT/FOX` | `run.log:17` |
| Discounted pre-trade quote | `5.436258687853353081 USDT/FOX` | `run.log:18` |
| Post-trade discounted quote | `36,230.017044034683496808 USDT/FOX` | `run.log:19` |
| Bond principal / pool sFOX | `82,777,517.744964801045863495 FOX` | `run.log:20,33` |
| Liquid inviter FOX | `2,483,325.532348944031375904 FOX` | `run.log:21,44` |
| Attacker final USDT | `450,530,941.023056701789655683` | `run.log:23,45` |
| **Attacker net USDT before native gas** | **`+530,941.023056701789655683`** | `run.log:24,46` |
| Pair USDT delta | **`−530,941.023056701789655683`** | `run.log:26,47` |
| Attacker FOX after sale | `0` | `run.log:25` |
| Treasury retained FOX | `82,777,517.744964801045863495` | `run.log:34` |
| Distributor rFOX | `9,105,526.951946128115044984` | `run.log:35` |
| Flash-loan fee | `0 USDT`, model only | `run.log:40` |
| Native gas including all deployment/setup | `16,017,425 gas`, `0.016017425 BNB` at 1 gwei | `run.log:37-39,161` |

USDT P&L and BNB gas are deliberately not mixed without a pinned BNB/USDT conversion. The historical finding does not depend on this model's zero flash-loan fee: the canonical original-transaction evidence supplies the live net figure.

### Controls

- **Small stake:** with 1,000 USDT, the same stake-and-reward-sale path returns only 31.322584671900250096 USDT, a `−968.677415328099749904 USDT` immediate delta before assigning value to the locked bond (`run.log:54,62-65,81-86`). This demonstrates scale dependence.
- **No liquid inviter:** with `stakeDays=179`, the same 450M deposit produces zero inviter FOX and zero immediate USDT return (`run.log:93-104,120-125`). This validates the liquid-reward leg.
- **Eight seeds:** eight exact-source EVM replays match the integer model row-for-row, all with positive canonical-strategy profit and inverse pair USDT deltas (`run.log:128-137`).

### Why earlier narratives are insufficient

- Pre-manipulating FOX **up** before the quote would reduce, not increase, `stakeAmount`. Pre-manipulating it down could inflate units but is a different, cost-bearing strategy. The confirmed incident uses the protocol's own post-quote swap.
- Failure to “recalculate after the swap” is only harmful because the stale amount supports a **liquid same-transaction payout** that can be sold at the distorted price. A locked credit by itself is not the demonstrated instant profit.
- Zero `amountOutMin`/liquidity minimums are dangerous but generic MEV/sandwich claims are excluded. They are not needed for the confirmed self-contained path.

### Remediation

1. Do not price bonds from the same AMM pair the function trades. Use a manipulation-resistant external oracle/TWAP with liquidity and freshness checks.
2. Derive credit from executed assets and post-trade backing, not `deposit / preTradeSpot`; include a conservative maximum price-impact and stake-to-depth cap.
3. Remove immediate liquid inviter FOX. Vest it or settle it in a non-transferable claim that cannot be sold in the pricing transaction.
4. Add an atomic invariant comparing treasury mint/credit with LP fair value and reserve movement; abort on excessive reserve displacement.
5. Use nonzero execution minimums as defense in depth, while recognizing they do not replace accounting fixes.

## Campaign and static triage

The unit-aware campaign contains **2,880 rows**: 10 reserve states × 9 strategies × 4 capital tiers × 8 seeds (`run.log:139-150`). Results:

- 1,536 executed local-model rows;
- 240 rejected direct-treasury calls due `onlyStakingPool`;
- 384 zero-reserve skips;
- 720 tier-D skips because protocol-wide TVL ≥ `$1e9` was not measured;
- 320 positive local counterexamples (`run.log:142-155`).

Canonical `S0-C-A-seed0` exactly matches the real EVM replay's raw quote, stake amount, inviter reward, profit, and pair delta (`run.log:150-152`). Model gas and flash-loan cost are zero and never substituted for live net profit.

Seventeen additional candidates—including donation capture, direct treasury mint, initialization, reentrancy, owner configuration, principal redemption, reward loops, slippage, and pre-manipulation variants—are triaged in `CANDIDATES.md`. None is independently promoted.

## Reproduction

```sh
cd fox-audit
npm install --ignore-scripts
node scripts/compile.cjs
python3 scripts/campaign.py
../.audit-tools/venv/bin/python scripts/replay.py --case canonical
../.audit-tools/venv/bin/python scripts/replay.py --case small
../.audit-tools/venv/bin/python scripts/replay.py --case no-inviter
../.audit-tools/venv/bin/python scripts/replay.py --case evm-seeds
```

Pinned mainnet verification when an archive endpoint and Foundry are available:

```sh
BSC_ARCHIVE_RPC='https://your-bsc-archive' ./scripts/fork-readback.sh
BSC_ARCHIVE_RPC='https://your-bsc-archive' ./scripts/run-pinned-replay.sh
```

The fork test uses the original caller, attack contract, and exact calldata with no storage override. RPC failures and unavailable compiler/tool paths are recorded in `run.log:2-5` and `SIGNATURE.md`.

## Artifact index

- `SIGNATURE.md` — identities, source provenance, screenshots, RPC/tool record, and evidence hierarchy.
- `INVARIANTS.md` — 14 unit-aware accounting and AMM invariants.
- `PAUSE.md` — routing, authorization, transfer-disable behavior, and entry-point inventory.
- `CANDIDATES.md` — full candidate disposition.
- `poc/FoxLpBondsPoolFork.t.sol` — no-override original-calldata fork test.
- `poc/FoxCurrentFork.t.sol` — explicit-pin current-state diagnostic; labels `deal()` capital and referral-owner setup overrides.
- `evidence/current-user-replay.log` — user-executed block-132016403 `Unauthorized` result.
- `scripts/replay.py` — exact-source local EVM replay and controls.
- `evidence/` — artifacts, raw replay JSON/logs, campaign, screenshots, and build/tool output.
- `reference/` — canonical DeFiHackLabs PoC, registry pinned output/source, and L2Beat incident record.

**Final result: FINDING-001 is confirmed for the historical incident. At user-run pin 132016403, the old fresh-caller permissionless path was blocked by `onlyOperator`/`Unauthorized`; this is an effective current access-control mitigation observation, not proof of an arithmetic-code fix or of safety for authorized callers.**
