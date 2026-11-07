# RACA/FLOKI stale-collateral target analysis

## Verdict

**The proposed current-state GameFi exploit is rejected as an executable candidate on the available primary-source evidence.** The stopping condition is the deprecated market state, not a claim that every Binance quote is fresh or correct:

- the GameFi off-boarding artifacts describe RACA/FLOKI as already having collateral factor zero before Phase 4;
- VIP-642 generates `setCollateralFactor(vToken, 0, 0)` for the in-scope GameFi markets;
- the VIP-679 simulation explicitly checks FLOKI CF/LT zero and MINT/BORROW paused for FLOKI and GameFi USDT;
- after VIP-679, FLOKI MAIN is a fixed ChainlinkOracle exit price, not BinanceOracle.

With `collateralFactorMantissa = 0`, every oracle valuation contributes zero borrowing power. With collateral MINT paused, a new attacker cannot create the required vToken collateral. With debt-market BORROW paused, debt cannot be increased. Any one of these guards independently stops the proposed chain.

This is a **current-target rejection**, not a proof about every historical block and not a claim that merged governance source is itself live execution evidence. `scripts/recon-gamefi.mjs` must be run at a selected BSC block to verify the actual state. No live RPC read, state-changing fork execution, withdrawal, or positive net profit has been demonstrated in this workspace.

## Target identities

The deployment artifacts resolve the intended isolated **GameFi** pool, not the Venus Core pool:

| Component | Address |
|---|---|
| GameFi Comptroller | `0x1b43ea8622e76627B81665B1eCeBB4867566B963` |
| PoolRegistry proxy | `0x9F7b01A536aFA00EF10310A162877fd792cD0666` |
| ResilientOracle | `0x6592b5DE802159F3E74B2486b091D11a8256ab8A` |
| BinanceOracle proxy | `0x594810b741d136f1960141C0d8Fb4a91bE78A820` |
| RACA | `0x12BB890508c125661E03b09EC06E404bc9289040` |
| vRACA_GameFi | `0xE5FE5527A5b76C75eedE77FdFA6B80D52444A465` |
| FLOKI | `0xfb5B838b6cfEEdC2873aB27866079AC55363D37E` |
| vFLOKI_GameFi | `0xc353B7a1E13dDba393B5E120D4169Da7185aA2cb` |
| vUSDT_GameFi | `0x4978591f17670A846137d9d613e333C38dc68A37` |
| vUSDD_GameFi | `0x9f2FD23bd0A5E08C5f2b9DD6CF9C96Bfb5fA515C` |

Pinned isolated-pools revision: `UPSTREAM_ISOLATED_POOLS_COMMIT`. Pinned VIP repository revision: `UPSTREAM_VIPS_COMMIT`.

## Oracle semantics inspected

The exact-source-matched `BinanceOracle` implementation reads `latestRoundDataByName(symbol, "USD")` from a Binance feed registry. It checks positive answer, non-future timestamp, and the configured per-symbol `maxStalePeriod`, then normalizes decimals. It does **not** read Pancake reserves or derive price from a DEX trade.

Therefore:

- a flash loan cannot directly raise this oracle's answer by moving a DEX pool;
- an accepted answer can still differ from executable DEX acquisition cost;
- absent Pivot/Fallback changes failure handling but does not create borrowing power;
- a reported 1,500-second stale window is only a freshness bound, not proof of divergence or exploitability;
- an expired answer makes the affected price path revert unless governance repoints the source.

The GameFi `Comptroller.preBorrowHook()` calls `updatePrices(borrower)`, checks the borrow cap, and computes account liquidity using the collateral factor. `preMintHook()` enforces MINT pause and supply cap. These are the consumer guards that the candidate must pass.

## Governance/off-boarding evidence

Pinned source is under `upstream/vips/`; hashes are in `evidence/vips-source-sha256.txt`.

### VIP-634 / Phase 4, merged 2026-06-29

`vips/vip-634/bscmainnet.ts` states that the scoped markets already had CF reduced to zero by prior off-boarding. `vips/vip-634/phase4Markets.ts` includes all four GameFi markets: FLOKI, RACA, USDD and USDT. It moves them to deprecation parameters and closes residual cap gaps.

Primary PR: https://github.com/VenusProtocol/vips/pull/721

### VIP-642 / Phase 4 step 2, merged 2026-07-09

`vips/vip-642/zeroCollateralParams.ts` generates `setCollateralFactor(address,uint256,uint256)` with CF=0 and LT=0 for every in-scope non-already-zero market. Its BSC simulation iterates the GameFi entries and asserts both values are zero after execution.

Primary PR: https://github.com/VenusProtocol/vips/pull/731

### VIP-679 / FLOKI exit price, merged 2026-11-05

`vips/vip-679/bscmainnet.ts` sets FLOKI's fixed USD price to `0.00002228e18` on ChainlinkOracle and makes that adapter MAIN, with no Pivot/Fallback and caching disabled. Its description says this is an exit price for a deprecated market, not a live feed or authorization to reopen borrowing.

`simulations/vip-679/bscmainnet.ts` asserts:

- normalized FLOKI price is correct for 9 token decimals;
- CF=0 and LT=0;
- MINT (action 0) and BORROW (action 2) remain paused for vFLOKI and GameFi vUSDT;
- redemption works only after outstanding debt is cleared.

Primary PR: https://github.com/VenusProtocol/vips/pull/791

Merged PR state is not substituted for pinned chain state. It is, however, strong contrary evidence that must be checked before spending effort on an exploit transaction.

## Economic gate for any historical or different-pool candidate

Ignoring all limits for a moment:

```text
maxBorrowUsd ≈ acquiredCollateral × oraclePrice × collateralFactor
```

Before fees, a necessary condition is approximately:

```text
oraclePrice / dexExecutionPrice > 1 / collateralFactor
```

At CF=50%, oracle valuation must exceed roughly twice actual acquisition cost. The realized threshold is stricter after DEX impact, token transfer tax, flash fee, exit slippage and gas. At CF=0, the required ratio is infinite and no divergence suffices.

Even with positive ratio, extraction is bounded by:

```text
min(account liquidity, debt-market cash, remaining borrow cap)
```

Collateral acquisition is separately bounded by supply capacity and MINT pause. Gross borrowed assets are not profit. Profit requires positive liquid token balances after flash repayment, all swaps, token taxes and gas, with residual vToken collateral and debt reported separately rather than counted as liquid proceeds.

## Compiled fork harness

`poc/GameFiStaleCollateralFork.t.sol` implements the requested chain against real contract interfaces:

1. Pancake flash swap supplies the acquisition asset.
2. Router buys collateral using the fee-on-transfer-supporting method; actual balance delta determines mint amount.
3. The borrower enters the real collateral market, mints vTokens and borrows the selected GameFi debt asset.
4. Debt is swapped back to the flash asset when needed; the pair is repaid and liquid balances are swept.
5. The test logs signed liquid deltas, residual vToken collateral and residual debt. Profit is based only on the post-exit flash-token delta, never on gross borrow or residual collateral.

Build validation:

```sh
cd venus-stale-collateral-audit
../.audit-tools/bin/forge build --sizes
```

Result: **compiled successfully with solc 0.8.25**. The harness has **not** been executed against a fork because no pinned RPC state has been supplied and the current candidate is stopped by the market guards above. Compilation is not a PoC pass.

`EXPECT_REVERT=true` supports negative controls. `REQUIRE_PROFIT=true` plus `MIN_FLASH_NET` can require a minimum liquid delta reserved for gas/other costs; the logged delta itself is explicitly before gas.

## Required pinned recon

Run with a BSC archive RPC and an explicit block for reproducibility:

```sh
cd venus-stale-collateral-audit
RPC_URL='https://bsc-rpc.publicnode.com' \
BLOCK=131549804 \
node scripts/recon-gamefi.mjs
```

`BLOCK` may be omitted to select the RPC's latest block once; the script then pins every subsequent read to that block. The example block above is the VIP-679 authoring snapshot, **not** a claim that it is the best exploitation block.

Output:

```text
evidence/gamefi-recon-<block>.json
```

The script records:

- block number/hash/timestamp and RPC host (not RPC credentials);
- EIP-1967 implementation/beacon slots, beacon implementations and code hashes;
- PoolRegistry/vToken identity and Comptroller oracle address;
- CF/LT, supply/borrow caps, remaining capacities, MINT/BORROW pauses;
- vToken cash, total supply, borrows, bad debt and exchange rate;
- Resilient token config, caching, current MAIN source and price or captured revert;
- Binance symbol override, stale bound, registry round answer/updatedAt/decimals and age;
- Pancake V2 pairs/reserves and direct-router execution quotes at several notionals when the candidate is not already stopped;
- explicit screening stop reasons.

The router's `getAmountsOut` is a theoretical AMM output and may exclude token-level transfer taxes. The state-changing harness measures actual received collateral and therefore does not rely on that approximation for P&L.

## Inputs still needed to attempt any non-rejected candidate

Provide the generated pinned JSON. If a candidate remains after its stop checks, also provide or select:

1. **Block**: a block before off-boarding, or a current block for a different active pool. A current post-offboarding GameFi block cannot satisfy CF>0/unpaused requirements without contrary chain evidence.
2. **Flash pair**: a Pancake-compatible pair containing the flash asset with sufficient liquidity. Its fee formula must be known; the harness default conservatively repays `1000/997 + 1` and includes that overpayment in P&L.
3. **Buy route**: direct or multi-hop `BUY_PATH`; V3 pool addresses/route if no usable V2 route exists.
4. **Exit route**: `EXIT_PATH` when debt and flash assets differ.
5. **Sizes**: `FLASH_AMOUNT` and `BORROW_AMOUNT`, bounded by actual acquisition output, supply capacity, account liquidity, debt cash and borrow-cap headroom.
6. **Profit threshold**: `MIN_FLASH_NET`, reserving enough for gas and any cost not represented in the fork.

Example harness invocation, intentionally using placeholders rather than fabricated values:

```sh
RPC_URL="$RPC_URL" BLOCK="$BLOCK" \
FLASH_PAIR="$FLASH_PAIR" FLASH_TOKEN="$FLASH_TOKEN" \
COLLATERAL_VTOKEN="$COLLATERAL_VTOKEN" DEBT_VTOKEN="$DEBT_VTOKEN" \
FLASH_AMOUNT="$FLASH_AMOUNT" BORROW_AMOUNT="$BORROW_AMOUNT" \
BUY_PATH="$BUY_PATH" EXIT_PATH="$EXIT_PATH" \
REQUIRE_PROFIT=true MIN_FLASH_NET="$MIN_FLASH_NET" \
../.audit-tools/bin/forge test \
  --match-test testForkCandidate_executeRepayAndMeasureNet -vvvv
```

No private key or real mainnet transaction is needed for the fork.

## Reporting decision

Do not report the following as an exploit:

- no Pivot/Fallback by itself;
- `maxStalePeriod=1500` by itself;
- a Binance answer that is old but still accepted;
- a large gross borrow without flash repayment;
- residual vToken collateral or bad debt as attacker profit;
- merged VIP source without pinned execution state.

The evidence currently supports a rejected/deprecated-market analysis and reusable recon/PoC harness, **not a live RACA/FLOKI vulnerability submission**.
