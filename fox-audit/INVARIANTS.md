# Unit-Aware Invariants

`U` and `F` are raw 18-decimal USDT and FOX reserves. All arithmetic below uses integer floor division unless FOX tax rounding is explicitly stated. Local invariants do not assert current BSC state.

| ID | Invariant | Evidence / result |
|---|---|---|
| INV-01 — Spot units | `rawQuote = floor((1e18*9975*U)/(F*10000+1e18*9975))` returns raw USDT per 1 FOX. Incident model: `U=2786697198864505157273333`, `F=496041716814196640205248`, raw quote `5603812687200652594`. | Exact replay `run.log:17`; pair model tested through all seeds. |
| INV-02 — Discount units | If active, `discountedQuote = rawQuote*(10000-discountRate)/10000`; a discount >10000 underflows/reverts rather than producing a valid negative price. Local endpoints fixed at 299 bps only to match the pinned quote `5436258687853353081`. | `contracts/FoxLpBondsPool.sol:108-133`; `run.log:18,41`. Live endpoint storage unclaimed. |
| INV-03 — Pre-trade credit | `stakeAmount = effectivePoolUsdt*1e18/discountedQuote` is computed before the protocol swap and never recomputed. | Source lines 146-153; canonical amount `82777517744964801045863495` at `run.log:20`. **Violated economically by post-trade payout → FINDING-001.** |
| INV-04 — Fee-aware AMM swap | For input `a`, output is `floor(a*9975*reserveOut/(reserveIn*10000+a*9975))`; balances must satisfy the 0.25%-fee constant-product check after every swap. | `poc/AMM.sol`; canonical output/P&L exactly matches registry at `run.log:23-26`. |
| INV-05 — Inviter gate | Liquid inviter amount is zero unless `stakeDays>=180` and effective deposit ≥`1000e18`; otherwise `inviter=stakeAmount*300/10000` raw FOX. | Canonical `2483325532348944031375904` (`run.log:21`); 179-day control zero (`run.log:94,99`). |
| INV-06 — Treasury FOX conservation | `lpBonds` mints `stakeAmount+inviter` FOX to treasury, transfers `inviter`, and retains `stakeAmount`; it separately mints `stakeAmount` sFOX to the pool. | Canonical treasury and pool balances both `82777517744964801045863495` (`run.log:33-34`). |
| INV-07 — Reward FOX | For stake days ≥180, distributor rFOX mint equals `stakeAmount*1100/10000`; otherwise zero. | Canonical `9105526951946128115044984` (`run.log:35`); 179-day zero (`run.log:113`). |
| INV-08 — LP sink | `lpBonds` must move exactly the reported LP amount from the pool to `0x…dEaD`; LP is not attacker liquid. Local `feeTo=0` means LP quantities need not equal mainnet even when reserve/P&L values match. | Source `Treasury.sol:176-185`; local dead LP at `run.log:36`, model caveat `run.log:41`. |
| INV-09 — Sell-tax rounding | Non-whitelisted FOX sale to target pair sends `fee=floor(amount*250/10000)` to fee receiver and `amount-fee` to the pair. This is not `floor(amount*9750/10000)` at dust level. | `contracts/Fox.sol:55-70`; exact canonical sale/P&L at `run.log:21-26`. Dust alone is not a finding. |
| INV-10 — USDT conservation | In the canonical local model with no other USDT actor, attacker net USDT equals the negative of pair USDT delta. | `+530941023056701789655683` vs `−530941023056701789655683` (`run.log:24,26`), and every seed `run.log:130-137`. |
| INV-11 — Scale threshold | A small stake must not be assumed profitable merely because the same code path executes. | 1,000 USDT control nets `−968677415328099749904` before locked-bond valuation (`run.log:54,63,85`). |
| INV-12 — Liquid-settlement necessity | Removing inviter liquidity must remove the demonstrated immediate cash-out even though stale bond accounting remains. | 179-day control: inviter 0, attacker final USDT 0, net `−450000000000000000000000000` (`run.log:94-104`). |
| INV-13 — Principal vesting | Before end, cumulative vested principal is linear in aligned 8-hour steps on original stake amount minus prior redemption; after end it is exactly remaining principal, never more than `amount-amountRedeemed`. | `FoxPoolBase.sol:248-279`; source reviewed. No profitable double redemption found. |
| INV-14 — Authorization / initialization | Direct `Treasury.lpBonds` requires `stakingPoolMap[msg.sender]`; pool/treasury/referral implementations disable initializers and proxies call `initializer` exactly once. | Campaign rejects 240 direct calls (`run.log:145`); local ERC1967 proxies execute successfully. Screenshot zero implementation values are not proxy state. |

## Campaign accounting

The campaign has 2,880 rows and 320 positive local counterexamples (`run.log:142,149`). Capital tiers are raw 18-decimal USDT: A=1, B=1,000,000, C=450,000,000, D=`1e15`. Tier D is skipped because current screenshot liquidity around `$1.6M` is not protocol-wide TVL ≥ `$1e9` (`run.log:146,155`). Canonical `S0-C-A-seed0` maps to the real EVM replay (`run.log:150-152`).

Strategies include canonical stake/sell, no sale, pre-buy, pre-sell, USDT donation, FOX donation, no discount, no inviter, and direct treasury access. Pre/post donation cost basis is included; free donations are not treated as attacker capital. Gas and flash-loan costs are zero only in arithmetic rows, while real EVM native gas and live incident net are reported separately.
