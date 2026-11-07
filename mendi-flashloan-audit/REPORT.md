# Mendi Finance flash-loan-oriented audit

## Current status

The active target is Mendi Finance lending on Linea at pinned source commit:

```text
134d766bb7a07c9485f180d7d5edeb1fd9e30828
```

The strongest source-level lead is **missing freshness validation in the active `MixedPriceOracleV3`**, combined with an Aave-flash-loan acquisition/mint/borrow path. Upstream issue [#3](https://github.com/mendi-finance/lending-protocol/issues/3), opened on 2026-07-21, publicly reports the same root cause and collateral-devaluation/borrow scenario. That disclosure establishes provenance, **not a stopping condition**: a known bug remains an active candidate here if it is still unfixed and executable. No pinned complete DEX execution, state-changing fork repayment, liquid exit or net profit has yet been demonstrated.

The Unitroller proxy currently returns active oracle `0x05b1b5b09251355fdEb13c768987Ab750D2c6865`, verified on LineaScan as `MixedPriceOracleV3`; the older V2 artifact `0xD2Ed953C240edC59D57E5CFB527Eb768048Fa012` is not the active oracle. The active V3 source retains `latestAnswer()` without checking `updatedAt` or round completeness. Constructor arguments for the older V2 encode all ten symbols as address feeds, not Pyth IDs, and must not be confused with current V3 configuration.

Pinned execution at block `32540628` (`0x19b1bf8e37420eed74f18b3b7908c13ce21f9679f7e9ad4372c48df3de5c6b9a`) now exists in `evidence/`. The complete diagnostic Aave → Uniswap → Mendi mint/borrow → exit → repayment path passed, with diagnostic seed excluded and liquid net **-0.963366051872584047 WETH before gas**. Direct-collateral screening produced no profitable candidate after exit quotes, Aave premium and a `0.001 ETH` gas reserve. A 2,000,000-block Borrow-event scan covered 27 accounts and found four small shortfalls; their gross liquidation incentives are only cents and no net liquidation profit is claimed.

## Deployment identities

| Component | Address |
|---|---|
| Unitroller | `0x1b4d3b0421dDc1eB216D230Bc01527422Fb93103` |
| Comptroller implementation artifact | `0x1a11669Ecf91692440Da95CC8A12DE80B1C3D9e3` |
| MixedPriceOracleV2 | `0xD2Ed953C240edC59D57E5CFB527Eb768048Fa012` |
| meWETH | `0xAd7f33984bed10518012013D4aB0458D37FEE6F3` |
| meUSDC | `0x333D8b480BDB25eA7Be4Dd87EEB359988CE1b30D` |
| meUSDT | `0xf669C3C03D9fdF4339e19214A749E52616300E89` |
| meDAI | `0x1f27f81C1D13Dd96A3b75d42e3d5d92b709869AA` |
| meWBTC | `0x9be5e24F05bBAfC28Da814bD59284878b388a40f` |
| mewstETH | `0xCeEd853798ff1c95cEB4dC48f68394eb7A86A782` |
| meezETH | `0x8a90D208666Deec08123444F67Bf5B1836074a67` |
| meweETH | `0x9B4971aC84054597EDEd7Dc7b4b7E8A0c90753B5` |
| mewrsETH | `0x109F4Af9ec6A5ede198f7A4d9d9d7390de29362A` |

These are deployment-artifact identities, not substitutes for reading the current Unitroller implementation, active oracle and proxy slots at a pinned block.

## Active candidate: stale-but-accepted collateral/debt prices (previously disclosed root cause)

### Source behavior

`MixedPriceOracleV2._getChainlinkPrice()` does:

```solidity
int256 price = IAggregatorV3(priceFeed).latestAnswer();
uint256 decimals = IAggregatorV3(priceFeed).decimals();
require(price > 0, "price cannot be zero");
```

It does not read or validate:

- `updatedAt`;
- round ID or `answeredInRound`;
- a protocol-defined `maxStalePeriod`;
- source confidence or an upper/lower circuit breaker.

Its Pyth branch similarly uses `getPriceUnsafe()` and validates only positive price and non-positive exponent. That branch is relevant if a Pyth ID is configured, but is not the branch used by the latest V2 constructor arguments. All ten configured symbols have address-shaped feed IDs; decoded rows are saved in `evidence/oracle-v2-constructor.json`.

For LST-like symbols, `_getPriceUSD()` recursively multiplies a ratio quote by another cToken symbol's USD quote. The same missing freshness rule applies to every leg. There is no guard against combining independently stale ratio and base-price timestamps. `MixedPriceOracleV3._getLatestPrice()` repeats the same `latestAnswer()` pattern; an open upstream PR adds a V3 deployment artifact, so the active oracle implementation must be read live rather than inferred from V2's artifact.

### Executed unit evidence

`test/MixedPriceOracleV2.t.sol` uses the exact source and solc `0.8.10`:

- a USDC answer 365 days old is accepted;
- `answeredInRound = 0` is accepted;
- 6-decimal USDC scaling produces `getPrice = 1e18` and `getUnderlyingPrice = 1e30`;
- a `1.05 weETH/ETH` ratio combined with `$2,000 ETH` produces `$2,100 weETH`;
- zero answer and missing config revert as negative controls.

Current result: **5/5 tests passed**. This proves missing freshness semantics, not live staleness or profitability.

### Required live conditions

A flash-funded exploit requires all of the following at one pinned block:

1. Collateral CF>0, MINT unpaused and sufficient supply capacity.
2. Debt BORROW unpaused, positive cash and sufficient strict borrow-cap headroom.
3. Oracle collateral value materially exceeds actual collateral acquisition cost, or debt is materially undervalued.
4. The configured feed still returns that answer despite its age.
5. Aave has the flash asset, with active/unpaused/flash-enabled reserve and enough liquidity.
6. A real DEX route executes the required acquisition and exit sizes.
7. Post-repayment liquid balances remain positive after flash premium, DEX impact, exit slippage and gas.

Before debt limits and costs:

```text
maxBorrowUsd ≈ acquiredCollateral × oraclePrice × collateralFactor
```

A necessary condition is approximately:

```text
oraclePrice / executionPrice > 1 / collateralFactor
```

The execution recon tightens this by subtracting Aave premium and limiting borrow by account liquidity, debt cash and cap. Its positive result remains only an upper bound before debt exit slippage and gas.

## Compound consumer checks

`Comptroller.borrowAllowed()`:

- rejects paused/unlisted markets;
- automatically enters the debt market when needed;
- requires nonzero debt oracle price;
- applies borrow cap and hypothetical account liquidity.

`Comptroller.mintVerify()` checks supply cap after mint using the post-mint exchange rate.

**Cap semantics differ from the previous Venus target:** zero supply cap and zero borrow cap mean **unlimited**, not closed. A nonzero borrow cap uses strict `nextTotalBorrows < borrowCap`, so remaining positive borrow capacity is `cap - totalBorrows - 1` when applicable.

`CToken.getCashPrior()` reads the actual underlying balance, so donation affects exchange rate. A pure flash-funded new position does not automatically make donation profitable: the attacker funds both the shares and donation. A pre-existing share position or a separate accounting error would be needed for the classic subsidy. No such profitable new chain has been shown.

## Provenance and legacy CToken split

`scripts/check-provenance.cjs` confirms **all selected artifact main sources match** the checked-out source. `MixedPriceOracleV2` and all selected Comptroller/Unitroller/cToken main files match their artifact metadata.

A dependency split exists:

- legacy WETH/USDC/USDT artifacts reference CToken keccak `0x3e60dea3...`;
- current CToken keccak is `0x0b18b867...`;
- the only source diff is the current first-mint lock of 1,000 cToken units to address zero.

`artifact-matched/CToken-legacy.sol` preserves the artifact-supplied legacy source. The legacy first-mint issue is **previously disclosed**: ScaleBit reported `CTO-1 First mintFresh Design Flaws`, status Acknowledged, and Mendi described an operational non-empty-market workaround. It remains eligible for investigation under the same known-bug rule, but a live claim would additionally require current implementation and an exploitable empty/tiny-market state. Artifact history alone does not establish either.

Provenance output: `evidence/source-provenance.json`.

## Other candidates screened

### Deprecated-market liquidation

`isDeprecated(cTokenBorrowed)` is true when CF=0, borrow is paused and reserve factor is 100%. Liquidation then bypasses shortfall and close-factor checks intentionally. This can make a flash-funded liquidation mechanically possible, but it is explicit Compound deprecation behavior, not by itself a new vulnerability. A report would require a misclassified active market and an unjust victim state.

### Reward distributor

Reward time is based on `block.timestamp`. Within one atomic transaction, elapsed time is zero, so flash mint/borrow does not itself accrue additional market emissions. Supplier settlement occurs in `mintAllowed()` before mint, and transfer/seize settle both accounts before balances change; there is no post-mint historical-index credit. Borrower settlement likewise occurs in `borrowAllowed()` before debt increases. The public claim function distributes stored accrued rewards rather than creating a same-block subsidy. No flash reward inflation has been shown.

### Malda Migrator incident

The reported fake-Comptroller Migrator issue belongs to Malda's successor code path. It is not evidence of a vulnerability in these Mendi core contracts and is not used as a finding here.

### Bug bounty authorization

No Mendi-specific live bug-bounty scope was verified in the current recon. All state-changing validation remains local/fork-only. Do not send a mainnet exploit transaction.

## Flash and execution infrastructure

Aave V3 Linea deployment from the Aave address book:

```text
Pool: 0xc47b8C00b0f69a36fa203Ffeac0334874574a8Ac
```

The address book lists relevant WETH/WBTC/USDC/USDT and LST reserves. Mendi WETH and WBTC use the same feed addresses as Aave for those assets; other feeds may differ. Aave is a flash-liquidity source and comparison point, not proof of executable acquisition price.

Uniswap V3 Linea:

```text
Factory:      0x31FAfd4889FA1269F7a13A66eE0fB458f27D72A9
QuoterV2:     0x42bE4D6527829FeFA1493e1fb9F3676d2425C3C1
SwapRouter02: 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a
```

The execution recon queries direct single-pool routes at fee tiers 100/500/3000/10000. Multi-hop or another DEX is required only if direct routes are absent or uneconomic.

## Required recon

Use a Linea archive endpoint:

```sh
cd mendi-flashloan-audit
export RPC_URL='https://linea-rpc.publicnode.com'
node scripts/recon-linea.mjs
```

The script selects the latest block once and pins every subsequent read, or honors `BLOCK=<number>`. Output:

```text
evidence/linea-recon-<block>.json
```

Then run execution screening against the exact same block hash:

```sh
export RECON='evidence/linea-recon-<block>.json'
node scripts/recon-execution.mjs
```

Output:

```text
evidence/linea-execution-<block>.json
```

Base recon records:

- Unitroller implementation/admin/oracle and cToken proxy implementation slots;
- artifact/live bytecode hashes where available;
- all markets, underlying addresses/decimals, CF, caps, pauses and deprecation state;
- cash, total supply/borrows/reserves and exchange rates;
- oracle prices or captured reverts;
- recursive oracle configs, feed answers, timestamps/age and decimals;
- correct zero-cap/unlimited and strict-borrow-cap semantics.

Execution recon adds:

- Aave reserve active/paused/flash-enabled flags and available liquidity;
- actual Aave flash premium;
- pinned Uniswap V3 execution quotes;
- acquisition cost plus flash premium versus CF-weighted oracle value;
- best eligible debt after cash/cap/account-liquidity limits;
- candidates only when the pre-exit/pre-gas upper bound is positive.

Supply both JSON files before claiming a live candidate. If there are no direct routes, provide the relevant multi-hop path or other Linea DEX pool addresses.

## Compiled state-changing fork harness

`poc/MendiStaleCollateralFork.t.sol` uses real Aave, Uniswap and Mendi interfaces:

1. `flashLoanSimple` obtains the flash asset.
2. SwapRouter02 acquires collateral; actual token balance determines mint size.
3. The borrower enters the real collateral market, mints and borrows.
4. Debt is swapped back to the flash asset when needed.
5. Aave pulls principal plus actual premium after the callback.
6. Only remaining liquid tokens are swept and measured. Residual cToken collateral and debt are logged separately and never counted as profit.

Build:

```sh
../.audit-tools/bin/forge build poc/MendiStaleCollateralFork.t.sol --sizes
```

Result: **compiled successfully with solc 0.8.10**. It has not been run against a pinned fork.

Run only after selecting parameters from recon:

```sh
RPC_URL="$RPC_URL" BLOCK="$BLOCK" \
FLASH_TOKEN="$FLASH_TOKEN" \
COLLATERAL_CTOKEN="$COLLATERAL_CTOKEN" DEBT_CTOKEN="$DEBT_CTOKEN" \
FLASH_AMOUNT="$FLASH_AMOUNT" BORROW_AMOUNT="$BORROW_AMOUNT" \
BUY_FEE="$BUY_FEE" EXIT_FEE="$EXIT_FEE" \
REQUIRE_PROFIT=true MIN_FLASH_NET="$MIN_FLASH_NET" \
FOUNDRY_PROFILE=fork ../.audit-tools/bin/forge test poc/MendiStaleCollateralFork.t.sol \
  --match-test testForkCandidate_flashMintBorrowExitRepayAndMeasureNet -vvvv
```

The logged liquid delta is before gas. `MIN_FLASH_NET` should reserve gas and any unmodelled cost. `EXPECT_REVERT=true` supports negative controls such as excessive borrow, paused actions and repayment shortfall.

## Reporting decision

Do not describe the missing-freshness root cause as newly discovered: upstream issue #3 already discloses it. That disclosure does not end the exploit investigation. A valid high-impact live demonstration still needs the pinned stale quote, active consumer state, available flash/DEX liquidity, a successful state-changing fork and signed liquid net proceeds after every cost. At present the evidence supports an active known-bug candidate and a complete validation harness, not a validated live Mendi exploit.

## References

- Mendi source: https://github.com/mendi-finance/lending-protocol
- ScaleBit audit (CTO-1 acknowledged): https://scalebit.xyz/reports/Mendi-Finance-Audit-Report.pdf
- Aave address book: https://github.com/bgd-labs/aave-address-book/blob/main/src/AaveV3Linea.sol
- Uniswap deployment list: https://gov.uniswap.org/t/official-uniswap-v3-deployments-list/24323
