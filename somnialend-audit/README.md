# SomniaLend / dreamDEX economic fork harness

Mainnet-fork-only PoC for two independent hypotheses:

1. **SOMI revaluation:** flashloan USDso → IOC buy native SOMI on dreamDEX → wrap WSOMI → reread AaveOracle in the same callback → supply WSOMI → borrow maximum USDso → repay the flashloan.
2. **USDso revaluation:** flashloan USDC.e → IOC sell USDC.e for USDso on dreamDEX → reread AaveOracle in the same callback → supply USDso → borrow maximum USDC.e → repay the flashloan.

The default attack leaves the supplied collateral and debt in place. It does not need to reverse the collateral trade: the borrowed flash asset funds repayment. Liquid **surplus** USDC.e/WETH/WBTC is optionally sold back to USDso through real IOC orders while retaining enough of the flash asset for repayment. This measures executable proceeds rather than valuing gross debt at a manipulated oracle.

## Status

- `forge build` passes with Forge 1.7.1 and solc 0.8.24.
- The sandbox's direct TLS connections to both Somnia RPC endpoints fail before `createSelectFork`; no local chain result is claimed.
- `.github/workflows/somnialend-fork.yml` executes the same tests on a GitHub-hosted runner, pins the block in its log, and uploads raw logs plus JSON results.
- See `REPORT.md` and `evidence/` for the latest actual execution disposition. Compilation is not an exploit result.

## Deployed scope

| Contract | Address |
|---|---|
| SomniaLend Pool proxy | `0xEC6758e6324c167DB39B6908036240460a2b0168` |
| AaveOracle | `0x9b7B5d69a08071ce74C2f3D655038E3b782eAaFc` |
| WSOMI | `0x046EDe9564A72571df6F5e44d0405360c0f4dCab` |
| USDC.e | `0x28BEc7E30E6faee657a03e19Bf1128AaD7632A00` |
| WETH | `0x936Ab8C674bcb567CD5dEB85D8A216494704E9D8` |
| USDso | `0x00000022dA000002656c64D9eA6011ea952D008A` |
| WBTC | `0xC5098b3cA516784323872F17235fa074E167D3D2` |
| SOMI/USDso SpotPool | `0x035De7403eac6872787779CCA7CCF1b4CDb61379` |
| USDC.e/USDso SpotPool | `0x47fD2f18426f67106DBaC82F6d21D446c5F2120b` |
| WETH/USDso SpotPool | `0xa936da11B57b50A344e1293AAaE5232885ea2bDE` |
| WBTC/USDso SpotPool | `0x25bfF6B7B5E2243424F38E75de7ab03C0522a5EA` |

Recon resolves the Pool EIP-1967 implementation, reserve/aToken/variableDebtToken configuration, every configured oracle source and EIP-1967 feed implementation, feed decimals/rounds/timestamps, flash premium, CLOB parameters and five book levels. It does not infer feeds from marketing or assume Chainlink/CAPO.

The dreamDEX interface is the post-June-2026 `placeOrder` ABI from `somnia-chain/dreamdex-bot-kit` commit `4e75896896e024c03e2033d5920514f249998cd6`. The old `placeTakerOrderWithoutVault` path is intentionally absent. Runtime `getPoolParams`, `getAutoPullRequirement`, and `placeOrder` calls validate the deployed surface at the pinned block; source-repository correspondence alone is not treated as deployed-bytecode proof.

## Run locally

Requirements: Foundry 1.7.1, Node 22, the root `lib/forge-std` submodule, and `npm ci --prefix tools` from this directory.

```bash
cd somnialend-audit
npm ci --prefix tools
export SOMNIA_RPC_URL=https://api.infra.mainnet.somnia.network
# Pin a real block; never silently replace it with latest inside a test.
export SOMNIA_FORK_BLOCK="$(cast block-number --rpc-url "$SOMNIA_RPC_URL")"

./run-fork.sh recon
./run-fork.sh control
./run-fork.sh measured
./run-fork.sh zero-seed
```

`run-fork.sh` uses `forge` from `PATH` or the pinned npm Forge binary. Tests reject a missing block, a non-5031 chain, or a fork whose actual block differs from `SOMNIA_FORK_BLOCK`.

### Parameters

| Environment variable | Default | Meaning |
|---|---:|---|
| `SOMI_FLASH_USDSO` | `25000e18` | USDso flash amount for SOMI branch |
| `USDSO_ATTACK_FLASH_USDC` | `1000e6` | USDC.e flash amount for USDso branch |
| `DEX_BUY_LIMIT_BPS` | `11000` | Maximum SOMI buy limit versus best ask |
| `DEX_SELL_LIMIT_BPS` | `9000` | Minimum USDC.e sell limit versus best bid |
| `DEX_UNWIND_LIMIT_BPS` | `9000` | Minimum liquid-surplus unwind limit |
| `BORROW_BPS` | `10000` | Fraction of Aave `availableBorrowsBase` to borrow |
| `BORROW_ALL_OPPOSITE_RESERVES` | `false` | After borrowing the flash asset, iterate all other non-collateral reserves |
| `UNWIND_LIQUID_SURPLUS` | `true` | IOC-sell liquid non-USDso surplus after borrowing |

Amounts are raw token units. Orders are rounded to live tick/lot bounds and sized against `getAutoPullRequirement`; partial IOC fills are measured by wallet balance deltas. Empty books, no fills, native SOMI stuck in the DEX vault, and repayment shortfalls are not silently converted into profits.

## Test meanings

- `test_recon_exact_live_configuration`: read-only pinned configuration/book baseline.
- `test_control_no_trade_no_oracle_delta`: flashloan and repayment without trading; only the explicitly seeded premium is spent.
- `test_somi_instrumented_with_loss_coverage`: executes the full path even if the attack loses. The USDso seed is subtracted from net USDso. This is a measurement, not a zero-capital exploit.
- `test_usdso_instrumented_with_loss_coverage`: same for the USDso branch. A losing result can have positive/negative deltas in different assets; the report does not combine them using a manipulated oracle.
- `test_somi_atomic_zero_seed`: no seed. Requires real execution, supply, borrow, successful repayment, and positive net USDso after repayment.
- `test_usdso_atomic_zero_seed`: no seed. Requires positive net USDso after actual surplus USDC.e unwind and zero remaining net USDC.e exposure.

A zero-seed test reverting on insufficient repayment is an atomic exploit failure. The instrumented test exists to retain complete oracle/borrow/P&L measurements for that case; it must never be presented as proof of zero-capital profit.

## Accounting semantics

- **DEX impact:** top-of-book before/after plus effective execution price computed from actual token deltas, including fees.
- **Oracle impact:** collateral and debt prices reread inside the flashloan callback immediately after the CLOB fill; signed bps deltas are logged.
- **Borrow impact:** actual post-supply `availableBorrowsBase` versus the same acquired collateral valued at the pre-trade oracle and live LTV.
- **Maximum borrow:** raw amount per asset, capped by current aToken cash and then enforced by the real Pool.
- **Liquid P&L:** signed token deltas after flash repayment and actual surplus unwinds. Zero-seed USDso is liquid atomic proceeds; EOA gas is reported separately and not fake-deducted with a zero gas price.
- **Debt/collateral:** remaining base values, health factor, current bad debt (`max(debt-collateral,0)`), and debt if collateral becomes worthless are separate fields. Gross borrow, potential future bad debt, and residual collateral are not profit.

JSON artifacts are written under `results/`; raw verbose traces are under `evidence/`. Generated JSON is ignored by Git so a later run cannot silently rewrite historical claims; pinned logs/results should be copied into named evidence files when reporting them.

## Sources

- Somnia RPC: https://docs.somnia.network/network/rpcs
- SomniaLend flashloan flow: https://docs.somnialend.finance/flash-loans
- Verified AaveOracle: https://explorer.somnia.network/address/0x9b7B5d69a08071ce74C2f3D655038E3b782eAaFc
- dreamDEX ABI/source kit: https://github.com/somnia-chain/dreamdex-bot-kit/tree/4e75896896e024c03e2033d5920514f249998cd6
