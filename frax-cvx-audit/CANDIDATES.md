# Candidate Dispositions

## C-01 — `cvxFxsStaking` pre-fee shares / withdrawable deficit

**Disposition:** latent/conditional source behavior; not feasible at `lockIncentive=0`; not a current mainnet finding.

- Production path: default `deposit(uint256)` → `deposit(amount,false)` → mint nominal shares → `FxsDepositor` mints post-fee cvxFXS.
- Real withdrawal: attacker receives 1000 cvxFXS after a 1000-FXS deposit at 30 bps; direct baseline is 997.
- Victim effect: 997 cvxFXS withdrawable and 3 residual unbacked shares.
- Controls: direct no-lock deposit; 334-wei minimum deficit; 333-wei zero-deficit boundary.
- User-supplied Etherscan screenshot shows `lockIncentive=0`; the full 1000-FXS zero-bps control gives zero deficit, zero attacker advantage, and zero unbacked shares.
- Current conclusion: not exploitable under the pictured configuration. The screenshot is not block-pinned fork evidence; reassess only if a defensible fork shows a nonzero fee.
- Evidence: `scripts/staking_lock_incentive_poc.py`, `evidence/staking-lock-incentive-poc.json`.

## C-02 — `FeeDepositV2` incentive trapping during conversion

**Disposition:** reproduced conditional source defect; yield-trapping lead, outside permissionless-profit requirement.

- Production path: locked conversion mints `cvxRewards + incentiveFxs` but notifies only `cvxRewards`.
- Reproduced residual: 3 cvxFXS; owner rescue rejected; repeat distribution does not sweep it.
- Missing promotion evidence: deployed conversion configuration, accrued incentive, current trapped balance, and pinned-fork replay.
- Evidence: `scripts/fee_conversion_poc.py`, `evidence/fee-conversion-poc.json`.

## C-03 — Reward front-running, lazy accounting, and conservation

**Disposition:** no vulnerability promoted within tested model.

- Exact production bytecode for MultiRewards and Fraxtal StakedCvxFxs.
- 32 × 128 steps per contract, 9,374 successful transactions including setup.
- Exact per-user model, actual receipt timestamps, conservation including residuals, and victim/attacker sandwich control.
- Limitations: mocked external tokens/booster, bounded sequences, no live hooks or malicious registered tokens.

## C-04 — `cvxFXB` paused/zero-debt ERC4626 accounting

**Disposition:** PASS in restricted model; no vulnerability promoted.

- 32 × 128 steps, 5,226 successful transactions including setup.
- Covers deposit/mint/redeem/withdraw/donation/transfer/delegated redeem and rounding.
- Explicitly excludes leverage, oracle, yield, liquidity, and current-mainnet claims.

## C-05 — `cvxFXB` leverage-mode debt/collateral paths

**Disposition:** 32 × 128 campaign PASS in restricted model; no vulnerability promoted.

- Campaign: 5,537 successful transactions including setup, with 389 oracle rebalances and 373 explicit rebalances.
- Production `cvxFXB` with real token transitions against local single-position lender, 1:1 debt shares, 1:1 sFRAX vault, and deterministic oracle.
- Excludes interest, liquidations, restricted lender liquidity, and deployed oracle behavior.

## C-06 — `cvxFXB` unused reentrancy guard

**Disposition:** review lead only; not a finding.

The contract inherits `ReentrancyGuard` but does not apply `nonReentrant`. No permissionless callback using the actual FXS/FXB/FRAX token assumptions was shown to create value extraction. Owner-configured swapper behavior is not treated as a permissionless attacker.

## C-07 — Slither detector output

**Disposition:** triage input, not independent vulnerability evidence.

The production-filtered run reported 148 results across nine detector types. Results require source review and executable economic validation; raw detector counts are not findings. Full and filtered logs/JSON are preserved under `evidence/`.

## C-08 — FPIS migration conversion rate

**Disposition:** rejected as a current bug.

Relevant history and tests use the intended rate of 3. A historical or arithmetic observation without a permissionless withdrawal path was not promoted.

## C-09 — Historical `cvxFXB` changes

**Disposition:** historical context only.

Commit `076dff9` added delegated allowance spending and the one-share seed; `38bd971` added defensive borrow subtraction and utilization guards. These historical fixes are not reported as current vulnerabilities.

## C-10 — `cvxFXBSwapper` ignores oracle-validity boolean

**Disposition:** conditional oracle-validity lead; no current-mainnet finding or attacker profit.

- Production `processRewards()` discards the first return value from `updateExchangeRate()` and always proceeds to the configured exchange.
- Production-bytecode PoC: when the local lender returns `false`, a permissionless call still pulls 100 FRAX and delivers 100 FXB to the configured `cvxFXB`; minimum output is 49.5 FXB at the mocked rate/slippage.
- True-flag control follows the same path; attacker token deltas remain zero in both scenarios.
- Missing promotion evidence: deployed false/stale oracle state, actual exchange and MEV path, signed protocol loss, and positive attacker net P&L after costs.
- Existing leverage campaign does not cover this branch because its lender mock always returns `true`.
- Evidence: `scripts/oracle_validity_poc.py`, `poc/OracleValidityMocks.sol`, `evidence/oracle-validity-poc.json`.

## C-11 — Donation/PPS and issuer-affiliate recheck

**Disposition:** no additional vulnerability promoted in the local models.

- `cvxFXB.totalAssets()` counts local FXB plus lender collateral. Donated FXB is a real asset and is added to collateral by `_addCollateral()`; it is not treated as a phantom stale-receipt balance.
- `StakedCvxFxs.totalAssets()` returns `totalSupply()`, so direct token donations do not create the sDOLA-style instantaneous PPS path.
- A `cvxFXB` deposit that computes zero shares performs no token pull because the transfer is inside `if (shares > 0)`, limiting the classic first-depositor victim-loss construction.
- FRAX/FXB issuer affiliation is not an exemption: external Fraxlend feed identity, deviation, freshness, composition, and actual swap execution remain unverified without a pinned deployment.
