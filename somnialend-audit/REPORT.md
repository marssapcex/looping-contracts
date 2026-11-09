# SomniaLend economic execution report

## Current disposition

**Harness compiled; economic conclusion pending an actual pinned fork run.** No profitable exploit, oracle manipulation, bad debt, or protocol safety is asserted from compilation or source inspection.

Local execution attempts on 2026-11-06 failed in `setUp` before any chain read because the sandbox TLS connection was terminated for both:

- `https://api.infra.mainnet.somnia.network`
- `https://explorer.somnia.network/api/eth-rpc`

The failure was `vm.createSelectFork ... client error (Connect); tls handshake eof`: **0 fork tests passed or executed**. This is an environment failure, not a negative economic result.

The GitHub Actions workflow `SomniaLend pinned economic fork` is the execution route. Its pinned block, raw logs, JSON, recon outcome, instrumented attack outcome, and zero-seed outcome must be attached here before any final monetary conclusion.

## Evidence table

| Item | Result |
|---|---|
| Solc 0.8.24 / Forge 1.7.1 build | Passed |
| Pinned Somnia block | Pending workflow |
| Pool implementation/reserves/feeds | Pending workflow recon |
| No-trade control | Pending |
| SOMI DEX execution/oracle delta/borrow delta/net liquid P&L | Pending |
| USDso DEX execution/oracle delta/borrow delta/net liquid P&L | Pending |
| Zero-seed atomic repayment and profit | Pending; instrumented coverage is not a substitute |
| Actual/potential bad debt | Pending |

## Required interpretation

1. An unchanged oracle with unchanged borrow power is a measured negative result only when the recon/instrumented log at a named block shows the real IOC fill and subsequent same-callback oracle read.
2. Gross borrowed assets and debt left behind are not profit. Zero-seed positive liquid balances after repayment and real surplus unwind are the atomic profit criterion.
3. Instrumented loss coverage permits accounting of a losing path but is subtracted token-by-token. It is never evidence that the attack self-funds.
4. `badDebtNowBase` is only current debt minus collateral if positive. `debtIfCollateralZeroBase` is a stress quantity, not realized bad debt.
5. A source code comment saying “Chainlink” does not identify the configured source. Only pinned `getSourceOfAsset` results and feed implementation reads count.
