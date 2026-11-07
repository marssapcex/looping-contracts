# Frax-CVX Platform Security Audit

## Scope and evidence standard

- Target: `convex-eth/frax-cvx-platform`
- Source pin: `74901235a58c86677d552ef8c5041d9790fa9924`
- Production source copies and upstream tests are preserved under `contracts/` and `reference/upstream-test/`.
- `evidence/source-hash-check.log` records a clean source-hash check and an empty diff against the pinned upstream tree.
- Exact build: solc `0.8.10+commit.fc410830.Emscripten.clang`, optimizer 200 runs, OpenZeppelin Contracts 4.9.6. The current tree, including test-only mocks, builds 165 contracts from 117 source files. The three added contracts are local oracle-validity mocks; production source hashes remain unchanged.

The requested exploit standard is a permissionless attacker obtaining value with a real withdrawal and positive net P&L after costs. An arithmetic discrepancy alone is not treated as a completed exploit. **No mainnet vulnerability, deployment impact, or positive net attacker P&L is promoted by this report.** No verified archive-fork endpoint was available in this run, so current configuration and deployed state remain unverified. Local state overrides and mocks are explicitly identified and cannot establish mainnet impact.

## Executive result

Two conditional source-level defects were reproduced with production bytecode:

1. **`cvxFxsStaking` has a latent pre-fee share-minting defect, disabled at zero incentive.** With `FxsDepositor.lockIncentive > 0`, default FXS deposits create more shares than the cvxFXS backing delivered to the staking pool. However, the user subsequently supplied an Etherscan screenshot showing `lockIncentive = 0`. A new zero-incentive control produced zero deficit, zero attacker advantage, and zero unbacked victim shares. **C-01 is therefore not exploitable under the pictured configuration and is not a current mainnet finding.** The screenshot has no block number and is retained as user-supplied evidence, not substituted for pinned-fork proof.
2. **`FeeDepositV2` can trap accrued lock incentives during vlCVX conversion.** With conversion enabled and `FxsDepositor.incentiveFxs > 0`, `deposit(cvxRewards, true)` mints `cvxRewards + incentiveFxs` cvxFXS to `FeeDepositV2`, but only `cvxRewards` is notified to the reward sink. The incentive amount remains trapped and cannot be rescued with the existing `rescueToken` function.
3. **`cvxFXBSwapper.processRewards()` ignores the validity boolean returned by `updateExchangeRate()`.** A new production-bytecode PoC shows that a permissionless call still executes the Curve exchange when the mock lender returns `isBorrowAllowed=false`. The true-flag control follows the same path. Attacker token deltas are zero in this model; no stale deployed oracle, MEV proceeds, or positive net P&L is established.

None of these results is represented as a current-mainnet exploit. The first is blocked when `lockIncentive=0` and remains only a conditional hardening observation; any future nonzero configuration would require renewed pinned-fork review. The second demonstrates conditional yield trapping rather than permissionless attacker profit and still requires evidence of nonzero accrued incentives and conversion-enabled deployed state.

## Lead F-01: pre-fee share minting causes withdrawable staking deficits

**Status:** latent/conditional source behavior only. Reproduced at 30 bps, but the zero-bps control is safe. A user-supplied Etherscan screenshot shows zero; no current exploit is claimed.

**Affected paths:**

- `contracts/cvxFxsStaking.sol`: `deposit(uint256,bool)` mints `_amount` shares, and `deposit(uint256)` selects `_lock=false`.
- `contracts/FxsDepositor.sol`: no-lock deposits subtract `callIncentive = _amount * lockIncentive / 10000` and mint only `_amount - callIncentive` cvxFXS.

For a no-lock staking deposit of `A` with fee `f`, the staking pool receives `A-f` cvxFXS but issues `A` shares. Therefore:

```text
staking.totalSupply - cvxFxs.balanceOf(staking) increases by f
```

The deficit is not merely internal credit. If the pool already contains honest stakers' cvxFXS, the depositor can burn `A` shares and withdraw `A` cvxFXS immediately. Prior stakers bear the remaining `f` shortfall.

### Reproduced 1000-FXS example

Local configuration: `lockIncentive=30` (0.30%), production `cvxFxsStaking`, `FxsDepositor`, and `cvxFxsToken`; FXS and the external lock staker are mocks.

| Measurement | Raw value | Token units |
|---|---:|---:|
| Honest victim initial shares/backing | `1000000000000000000000` | 1000 |
| Attacker FXS delta | `-1000000000000000000000` | -1000 FXS |
| Attacker cvxFXS withdrawal delta | `1000000000000000000000` | +1000 cvxFXS |
| Honest direct no-lock baseline | `997000000000000000000` | 997 cvxFXS |
| Attacker gross advantage over baseline | `3000000000000000000` | 3 cvxFXS |
| Victim cvxFXS recovered | `997000000000000000000` | 997 cvxFXS |
| Victim residual unbacked shares | `3000000000000000000` | 3 |
| Attacker approve/deposit/withdraw gas | `258768000000000` wei ETH | local gas only |

The victim's full 1000-share withdrawal reverts after the attack because only 997 cvxFXS remains. The attacker made a real withdrawal, but **net P&L is unpriced**: no FXS/cvxFXS market conversion or gas-to-token conversion is claimed.

### Boundary and differential controls

- 334 wei FXS at 30 bps produces a one-wei fee and a one-wei withdrawable deficit.
- 333 wei produces zero fee and zero deficit.
- Repeating the full 1000-FXS attack with `lockIncentive=0` produces zero deficit, zero gross advantage, and zero residual unbacked shares.
- A direct no-lock deposit produces the expected `A-f` cvxFXS baseline.

User-supplied screenshot evidence: `evidence/user-provided-lock-incentive-zero.png`, SHA-256 `1680a09380bb399914ec1e348d7f2d5cd7d8b4c3813adb4af8e80b0e6b496dc2`. It shows zero but supplies no archive block, so it is not represented as pinned-fork state.

Artifacts:

- `scripts/staking_lock_incentive_poc.py`
- `evidence/staking-lock-incentive-poc.json`
- `evidence/staking-lock-incentive-run.log`

### Remediation

Mint shares from the actual cvxFXS balance delta received by the staking contract, rather than the nominal FXS input. The accounting update must still checkpoint rewards before increasing supply. A balance-delta implementation also handles the lock=true path when a previously accrued incentive is minted with the deposit. Add a continuous solvency invariant and a regression test covering default deposit followed by immediate withdrawal and a victim exit.

Setting `lockIncentive=0` would stop new deficits but would not repair existing unbacked shares. Until fixed, `stake(cvxFXS)` and the lock=true path avoid this specific pre-fee under-crediting of backing; those are path-specific mitigations, not a global fix.

## Lead F-02: conversion leaves lock incentive trapped in `FeeDepositV2`

**Status:** reproduced locally with production bytecode; conditional configuration; yield-trapping lead, not attacker-profit finding.

`FxsDepositor.deposit(amount, true)` adds any outstanding `incentiveFxs` to the amount minted. `FeeDepositV2.distribute()` nevertheless calls:

```solidity
IFxsDepositor(fxsDeposit).deposit(cvxRewards, true);
IRewards(vlcvx).notifyRewardAmount(cvxFxs, cvxRewards);
```

With a prior 3-FXS incentive and `cvxRewards = 407.647058823529411764` FXS, the PoC measured:

- reward sink notified: `407.647058823529411764` cvxFXS;
- `FeeDepositV2` residual balance: exactly `3` cvxFXS;
- owner `rescueToken(cvxFxs, ...)`: rejected;
- a second distribution: no reduction of the trapped balance.

A non-owner caller successfully triggered distribution with `UseDistributors=false`; its 10-FXS caller payment is the designed distribution incentive, not exploit P&L. A differential control using the legacy `FeeDeposit` swept `cvxRewards + 3` cvxFXS to the sink and retained zero, isolating the regression to V2's fixed-amount notification rather than the mock environment.

Artifacts:

- `scripts/fee_conversion_poc.py`
- `evidence/fee-conversion-poc.json`
- `evidence/fee-conversion-run.log`

**Remediation:** notify the actual cvxFXS balance delta received from conversion, including the incentive, and provide a deliberate recovery/distribution path for an already trapped balance. Test the integration with nonzero `incentiveFxs`, rather than testing each contract only with zero accrued incentives.

## Lead F-03: reward swap ignores oracle-validity result

**Status:** conditional source-level lead; not a current-mainnet finding and not attacker-profit evidence.

`cvxFXBSwapper.processRewards()` destructures `(,,uint256 exchangeRate) = IFraxLend(fraxlend).updateExchangeRate()`, discarding the first boolean. It then calculates `minOut` and calls the configured Curve exchange regardless of that validity result. This differs from the borrowing path, which explicitly checks `isBorrowAllowed` before borrowing.

The production-bytecode PoC deploys only local token, lender, and exchange mocks. With 100 FRAX, oracle rate `0.5e18`, slippage 99%, and the lender returning `false`, a non-owner caller still caused:

- one `updateExchangeRate()` call and one exchange call;
- 100 FRAX pulled from the swapper;
- minimum output `49.5e18` FXB;
- 100 FXB delivered to the configured `cvxFXB` receiver;
- zero attacker FRAX and FXB deltas.

A `true` validity control produced the same exchange path. This proves only that the boolean is not enforced. It does not establish that a deployed oracle can be stale or manipulated, that the actual exchange can be sandwiched profitably, or that an attacker can extract value.

Artifacts: `scripts/oracle_validity_poc.py`, `poc/OracleValidityMocks.sol`, `evidence/oracle-validity-poc.json`, and `evidence/oracle-validity-run.log`.

**Remediation:** require the returned validity/permission boolean before deriving `minOut` or exchanging. Bind the swap to the expected asset pair and current oracle composition, and add false-flag, stale-rate, wrong-decimals, and actual-output controls. A minimum-output check alone does not establish that the oracle was valid.

## Stateful and differential testing

All campaigns execute production contract bytecode. They are bounded model-based tests, not proofs of security.

| Harness | Campaign | Transactions including setup | Result | Explicit boundary |
|---|---:|---:|---|---|
| `MultiRewards` + Fraxtal `StakedCvxFxs` | 32 sequences × 128 steps per contract, seed `12648430` | 9,374 | PASS | Exact reward models, conservation, multi-user actions, timestamps, claims/transfers, sandwich control |
| `cvxFXB` paused/zero-debt | 32 × 128, seed `3851` | 5,226 | PASS | ERC4626 accounting only; no leverage/oracle/yield/mainnet claim |
| `cvxFXB` leverage-mode | 32 × 128, seed `61617` | 5,537 | PASS | Real token/debt/collateral transitions against local 1:1 mocks; no interest/liquidations/liquidity model |

The reward sandwich control credited the victim with 100 FXS and the attacker with zero. The `cvxFXB` harnesses cover deposits, mints, withdrawals, redeems, donations, share transfers, delegated redeems, and (in leverage mode) borrow/repay/collateral transitions and oracle-driven rebalancing. The leverage lender mock always returns `true` from `updateExchangeRate()` and therefore does not cover F-03's false-validity swapper branch; that branch has a separate PoC. Campaign counts are not a claim of exhaustive coverage.

Static analysis: the production-filtered Slither run contains 148 results across nine detector types (76 unused-return, 21 divide-before-multiply, 15 unchecked-transfer, 14 reentrancy-no-eth, 9 incorrect-equality, 7 arbitrary-send-erc20, 4 uninitialized-local, 1 uninitialized-state, 1 tautology). A detector result was not treated as a vulnerability without an executable path.

## What remains required before mainnet promotion

1. Select and record a defensible archive block; do not silently substitute `latest`.
2. Read and hash deployed bytecode and read `FxsDepositor.lockIncentive`, staking supply/backing, `FeeDepositV2` conversion flags, and accrued incentives at that block. If `lockIncentive` is zero, C-01 is closed for that block rather than advanced to P&L work.
3. Only if the required nonzero conditions exist, replay the candidate path against the fork without local storage/configuration overrides.
4. For F-03, call the actual Fraxlend `updateExchangeRate()` at the pin, preserve its boolean and both rates, identify the configured exchange, and compare a false/stale-validity swap against a valid control with actual output and MEV cost accounting.
5. Execute or faithfully price the cvxFXS-to-value exit; print signed attacker, protocol, and victim deltas and subtract gas and swap costs.
6. Separately assess any pre-existing deficit or trapped balance; fixing only future deposits does not restore affected users.

The absence of additional promoted findings is not a claim that the platform is bug-free. External oracle behavior, Fraxlend liquidity/interest/liquidations, sFRAX yield, owner/configuration history, deployed addresses, and current-mainnet state remain outside the local mock evidence.
