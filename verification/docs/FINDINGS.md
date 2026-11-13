# LoanVault — audit findings, refuted invariants, and how to read the specs

Everything below was produced against **real bytecode**, not by reading the source.
The EVM harness (`scripts/evm.js` + `scripts/setup.js`) deploys `LoanVault` behind
`LoanVaultHarness` with concrete `MockERC20` / `MockRoleManager` / `MockLenderRegistry`,
drives scripted adversarial sequences at chosen timestamps, and asserts each property
individually.

```
scripts/audit.js    142 checks   withdrawal lifecycle, delinquency, wind-down, queue, rates, pauses
scripts/audit2.js    42 checks   adversarial history: reservation isolation, pause bypass, inflation
scripts/audit3.js   probes       properties I could not decide by reading (capacity, dust, cutoff)
```

Current status: **184 passing, 0 failing**. The value of the exercise is not that
number — it is the list of properties that came back *refuted*, because those are
the ones a spec writer would otherwise ship as "proven".

---

## A. Refuted invariants — do **not** ship these

| # | Invariant as originally proposed | Verdict | Why |
|---|---|---|---|
| A1 | `exposedAmount() <= vaultCapacity()` | **FALSE** | `vaultCapacity` gates *deposits*, not accrual. At 10% APR and a 1e9 cap, five years take exposure to 1.57e9 while `maxDeposit()` correctly reports 0. The honest form is conditional: `maxDeposit(r) > 0 => exposed <= capacity`. |
| A2 | `totalSupply() == 0 => totalAssets() == 0` | **FALSE** | The last lender out leaves `totalAssets == 1` behind (the `+1` virtual asset in `convertToShares`/`convertToAssets`, plus any donation). Reproduced in `audit3.js` case (b). This is the ERC-4626 behaviour, not a bug, but the invariant is unsound. |
| A3 | `dueUnprocessedAssets() <= totalAssets()` | **FALSE past the wind-down cutoff** | `exposedAmount()` is forced to 0 once `block.timestamp >= _accrualCutoff`, while the matured book stays at 4e8. Real state from `audit3.js` case (c): `exposed=0, dueUnprocessed=400689268`. Must be scoped with `!terminated()`. |
| A4 | `maturedRedeemShares() == 0 => penaltyActiveSince() == 0` | **FALSE after a wind-down claim** | `claimRecovery` → `_returnEscrowedShares` zeroes the cohort but never calls `_refreshDelinquency`, so the stored penalty start outlives it (`audit3.js` case d: `matured=0, penaltyActiveSince=1700864000`). Harmless — accrual is frozen past the cutoff — but still a spec-killer. |
| A5 | `reservedAssets() <= totalAssets()` | **FALSE** | The pool releases the reservation at funding (`totalAssets -= need`), so the reserved pot legitimately exceeds the pool afterwards. The sound form is `reservedAssets() <= heldCash`. |
| A6 | `INV_RESERVED_NOT_ABOVE_POOL  reservedAssets() <= totalAssets() + reservedAssets()` | **TAUTOLOGY** | Reduces to `0 <= totalAssets()`. Same for `dueUnprocessedAssets() <= totalAssets() + dueUnprocessedAssets()` and `totalRecoveryPaid() >= 0`. These were in the first draft; they prove nothing and they add runtime. |
| A7 | `INV_RECOVERY_SNAPSHOT_VALID  fst(resolutionSnapshot()) != 0 ==> fst(...) > 0` | **TAUTOLOGY** | Restating the antecedent. |
| A8 | `getEpochWithdrawalRequest(epoch).third` | **NOT CVL** | The function returns `ILoanVault.EpochWithdrawalRequest` (a struct). CVL cannot project `.third`. Use the harness's `epochFunded(epoch)` / `epochShares(epoch)` / `epochFundedAssets(epoch)` instead. |
| A9 | `claimableRedeemRequest(...) <= balanceOf(lender)` | **MISMATCHED UNITS** | It returns **shares**, from `(, shares) = _previewClaim(...)` — not assets. Comparing it with `maxWithdraw` (assets) produces phantom failures; see `maxWithdraw` for the asset side. |
| A10 | `penaltyFromTimestamp` never granted twice for the same cohort | **needs a precise statement** | A *full repay* funds the cohort, which legitimately deletes the grant (`maturedRedeemShares == 0`). The meaningful test needs a cure that leaves the cohort unfunded (a donation), then a re-onset driven by accrual — `audit2.js` S11 proves no fresh grace. |
| A11 | "no external call can move `lastAccrualCash`" | **environment-dependent** | A plain ERC-20 `transfer` into the vault raises `held` without re-stamping the watermark. That is deliberate (a donation must not cure a past shortfall) but it means the *literal* equality `watermark == held - reserved` is only an invariant at mutator exit, not at arbitrary times. |

## B. Behavioural findings worth a second look (not exploitable as found)

| ID | Finding | Evidence | Severity |
|---|---|---|---|
| F-1 | `_returnEscrowedShares` **saturates** instead of underflowing: `maturedRedeemShares > maturedOwed ? diff : 0`. If `maturedOwed > maturedRedeemShares` the excess is silently discarded from the matured book while the shares are still handed back. No path was found that reaches it (the walk only subtracts shares that maturation already counted), but the clamp converts an accounting bug into a *silent* one. | `LoanVaultWithdrawal.spec::escrowReturnNeverSaturates` | Low / informational. The invariant that matters is `maturedOwed <= maturedRedeemShares` at that site — stated as a rule there. |
| F-2 | Rounding dust accumulates in `reservedAssets` and is **never swept**: after every funded lender claimed, 1 wei remained (`ADV-04`). `_feeSweepable` once terminated is `cashForClaims - outstanding`, and `outstanding = frozenAssets - totalRecoveryPaid` — dust sits between the two and stays in the vault forever. | `audit.js` S5 | Informational; economically nil, but it means "all claims paid ⇒ reserved == 0" is false, which breaks naive invariants. |
| F-3 | A residual `totalAssets == 1` after the last lender leaves is a windfall to the next depositor (and a permanent 1-wei liability in `amountOwed`). | `audit3.js` (b) | Informational (ERC-4626 virtual asset). |
| F-4 | `claimRecovery` can leave a stale `penaltyFromTimestamp` after the cohort is cleared, because it bypasses `_refreshDelinquency`. | `audit3.js` (d) | Informational (accrual frozen). |
| F-5 | `_isApprovedLender` must hold for **both** the `view` leg (`claimableRedeemRequest`, `maxWithdraw`) and the execution leg (`redeem`). A registry that answers differently between the two calls (e.g. a `revokeLender` front-run) makes the preview lie. The contract handles it (the second call reverts) but integrators that trust `maxWithdraw` will be surprised. | source read + `ADV-20` | Low, integrator-facing. |

## C. What *is* proven (shape of the guarantees)

The specs that ship are the ones that survived both the empirical pass and the
"is it vacuous?" test:

1. **Reservation isolation** — `borrow`, `collectFees`, `sweepResidual` and
   `claimRecovery` cannot touch `reservedAssets`; `redeem` releases it exactly by
   the payout. (`LoanVaultWithdrawal.spec` R-W3/R-W5/R-W6/R-W9, R-D3, R-S1/R-S2)
2. **Funding is exact** — burn == matured escrow, reservation == priced
   liability, pool decrement == reservation increment, cash untouched
   (`fundingIsExact`).
3. **Watermark discipline** — after every mutator, `lastAccrualCash == held -
   reserved` (`ADV-01`, checked over 56 mixed ops in `audit2.js` S14).
4. **Maturation idempotency** — no double-maturing across pokes
   (`maturationIsIdempotent`, `audit.js` S10).
5. **Wind-down snapshot immutability, entitlement bound, monotone claims**
   (`LoanVaultWindDown.spec`).
6. **Grace is one-shot per cohort** — a cure does not renew it, a re-onset keeps
   the original penalty clock (`audit2.js` S11).
7. **Termination freezes the holder set** while keeping escrow return open — the
   soundness condition for address-keyed `claimedRecovery`.

## D. How the harness changes the contract (read before quoting a result)

`LoanVaultHarness` overrides exactly four internal touch points:

| override | production | harness |
|---|---|---|
| `_heldAssetsUsdc()` | `loanAsset.balanceOf(this)` | `ghost_held` |
| `_pullUsdc` / `_payUsdc` | `safeTransferFrom` / `safeTransfer` | `ghost_held ±= amt` + `require` on overdraft |
| `_isApprovedLender()` | `lenderRegistry.isApproved` | `!ghost_denied[who]` |
| `_requireVaultManager()` | `roleManager.isVaultManager` | `msg.sender == harnessManager` |

No accounting logic is overridden. Without this, the Prover havocs every external
call and every cash-based invariant becomes unfalsifiable — which is the single
most common way a "green" Certora run means nothing. `LoanVaultParams.spec`
re-checks the structural properties against the **unmodified** source with
`methods` summaries instead, so the results can be cross-read.
