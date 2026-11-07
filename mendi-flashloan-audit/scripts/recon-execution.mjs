import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
let ethers;
try {
  ({ ethers } = require(path.resolve(root, '../.audit-tools/venus-oracle-build/node_modules/ethers')));
} catch {
  ({ ethers } = require('ethers'));
}

const RPC_URL = process.env.RPC_URL;
const RECON = process.env.RECON;
if (!RPC_URL || !RECON) throw new Error('Set RPC_URL and RECON=evidence/linea-recon-<block>.json');
const base = JSON.parse(fs.readFileSync(path.resolve(root, RECON), 'utf8'));
const provider = new ethers.JsonRpcProvider(RPC_URL, 59144, { staticNetwork: true });
const blockNumber = base.block.number;
const blockTag = blockNumber;
const block = await provider.getBlock(blockTag);
if (!block || block.hash.toLowerCase() !== base.block.hash.toLowerCase()) throw new Error('Pinned block hash differs from base recon');

const AAVE_POOL = '0xc47b8C00b0f69a36fa203Ffeac0334874574a8Ac';
const QUOTER_V2 = '0x42bE4D6527829FeFA1493e1fb9F3676d2425C3C1';
const UNISWAP_FACTORY = '0x31FAfd4889FA1269F7a13A66eE0fB458f27D72A9';
const FEE_TIERS = [100, 500, 3000, 10000];
const FLASH = {
  WETH: { amountIn: 10n ** 18n },
  USDC: { amountIn: 1_000n * 10n ** 6n },
  USDT: { amountIn: 1_000n * 10n ** 6n },
  WBTC: { amountIn: 10n ** 6n }, // 0.01 WBTC, 8 decimals
  wstETH: { amountIn: 10n ** 18n },
  ezETH: { amountIn: 10n ** 18n },
  weETH: { amountIn: 10n ** 18n },
};
const GAS_RESERVE_WEI = BigInt(process.env.GAS_RESERVE_WEI ?? '1000000000000000');

const pool = new ethers.Contract(AAVE_POOL, [
  'function FLASHLOAN_PREMIUM_TOTAL() view returns (uint128)',
  'function getReserveData(address) view returns ((uint256 data) configuration,uint128 liquidityIndex,uint128 currentLiquidityRate,uint128 variableBorrowIndex,uint128 currentVariableBorrowRate,uint128 currentStableBorrowRate,uint40 lastUpdateTimestamp,uint16 id,address aTokenAddress,address stableDebtTokenAddress,address variableDebtTokenAddress,address interestRateStrategyAddress,uint128 accruedToTreasury,uint128 unbacked,uint128 isolationModeTotalDebt)',
], provider);
const erc20 = new ethers.Contract(ethers.ZeroAddress, ['function balanceOf(address) view returns (uint256)'], provider);
const quoter = new ethers.Contract(QUOTER_V2, [
  'function quoteExactInputSingle((address tokenIn,address tokenOut,uint256 amountIn,uint24 fee,uint160 sqrtPriceLimitX96)) returns (uint256 amountOut,uint160 sqrtPriceX96After,uint32 initializedTicksCrossed,uint256 gasEstimate)',
], provider);

async function read(contract, signature, args = []) {
  return contract.getFunction(signature)(...args, { blockTag });
}
async function capture(fn) {
  try { return { ok: true, value: await fn() }; }
  catch (error) { return { ok: false, error: error.shortMessage || error.message }; }
}
function jsonReplacer(_key, value) { return typeof value === 'bigint' ? value.toString() : value; }
function usdValue(amount, decimals, priceUsd1e18) {
  return (amount * priceUsd1e18) / 10n ** BigInt(decimals);
}
function resultBigInt(result) {
  if (!result?.ok || result.value === undefined) return undefined;
  return BigInt(result.value);
}
function bit(data, index) { return Boolean((data >> BigInt(index)) & 1n); }

const marketList = Object.values(base.markets);
const byUnderlyingSymbol = new Map(marketList.map(item => [item.underlyingSymbol.toUpperCase(), item]));
const aaveReserves = {};
for (const market of marketList) {
  const reserveResult = await capture(() => read(pool, 'getReserveData(address)', [market.underlying]));
  if (!reserveResult.ok) {
    aaveReserves[market.symbol] = { underlying: market.underlying, reserveResult };
    continue;
  }
  const reserve = reserveResult.value;
  const configuration = reserve[0][0];
  const aToken = reserve[8];
  const token = new ethers.Contract(market.underlying, erc20.interface, provider);
  const availableLiquidity = await read(token, 'balanceOf(address)', [aToken]);
  aaveReserves[market.symbol] = {
    underlying: market.underlying,
    reserveResult,
    aToken,
    availableLiquidity,
    active: bit(configuration, 56),
    frozen: bit(configuration, 57),
    paused: bit(configuration, 60),
    flashLoanEnabled: bit(configuration, 63),
  };
}
const premiumResult = await capture(() => read(pool, 'FLASHLOAN_PREMIUM_TOTAL()'));
const flashPremiumBps = premiumResult.ok ? premiumResult.value : 0n;

const quotes = [];
for (const collateral of marketList) {
  const collateralUsdPrice = resultBigInt(collateral.usdPriceResult);
  for (const [flashSymbol, flash] of Object.entries(FLASH)) {
    const flashMarket = byUnderlyingSymbol.get(flashSymbol);
    if (!flashMarket || flashMarket.underlying.toLowerCase() === collateral.underlying.toLowerCase()) continue;
    const flashUsdPrice = resultBigInt(flashMarket.usdPriceResult);
    const reserve = aaveReserves[flashMarket.symbol];
    for (const fee of FEE_TIERS) {
      const quoteResult = await capture(() => quoter.getFunction('quoteExactInputSingle').staticCall({
        tokenIn: flashMarket.underlying,
        tokenOut: collateral.underlying,
        amountIn: flash.amountIn,
        fee,
        sqrtPriceLimitX96: 0,
      }, { blockTag }));
      const item = {
        collateral: collateral.symbol,
        collateralUnderlying: collateral.underlying,
        flashSymbol,
        flashUnderlying: flashMarket.underlying,
        fee,
        amountIn: flash.amountIn,
        quoteResult,
        quoter: QUOTER_V2,
        factory: UNISWAP_FACTORY,
      };
      if (!quoteResult.ok || collateralUsdPrice === undefined || flashUsdPrice === undefined) {
        quotes.push(item);
        continue;
      }
      const amountOut = quoteResult.value[0];
      if (amountOut === 0n) {
        quotes.push(item);
        continue;
      }
      const flashFee = (flash.amountIn * flashPremiumBps + 9_999n) / 10_000n;
      const acquisitionCostUsd = usdValue(flash.amountIn, flashMarket.underlyingDecimals, flashUsdPrice);
      const flashFeeUsd = usdValue(flashFee, flashMarket.underlyingDecimals, flashUsdPrice);
      const costIncludingFlashUsd = acquisitionCostUsd + flashFeeUsd;
      const collateralOracleValueUsd = usdValue(amountOut, collateral.underlyingDecimals, collateralUsdPrice);
      const weightedCollateralUsd = (collateralOracleValueUsd * BigInt(collateral.collateralFactor)) / 10n ** 18n;
      let bestDebt;
      for (const debt of marketList) {
        const debtUsdPrice = resultBigInt(debt.usdPriceResult);
        if (debtUsdPrice === undefined || debtUsdPrice === 0n || debt.debtStops.length !== 0) continue;
        const maxBorrowByLiquidity = (weightedCollateralUsd * 10n ** BigInt(debt.underlyingDecimals)) / debtUsdPrice;
        const candidateAmount = [maxBorrowByLiquidity, BigInt(debt.cash), BigInt(debt.borrowCapacity)].reduce((a, b) => a < b ? a : b);
        const borrowUsd = usdValue(candidateAmount, debt.underlyingDecimals, debtUsdPrice);
        const upperBoundNetBeforeExitAndGas = borrowUsd - costIncludingFlashUsd;
        if (!bestDebt || upperBoundNetBeforeExitAndGas > bestDebt.upperBoundNetBeforeExitAndGas) {
          bestDebt = {
            symbol: debt.symbol,
            maxBorrowByLiquidity,
            candidateAmount,
            borrowUsd,
            upperBoundNetBeforeExitAndGas,
            debtStops: debt.debtStops,
          };
        }
      }
      Object.assign(item, {
        amountOut,
        flashFee,
        flashFeeUsd,
        acquisitionCostUsd,
        costIncludingFlashUsd,
        collateralOracleValueUsd,
        weightedCollateralUsd,
        oracleToExecutionRatio: costIncludingFlashUsd === 0n ? undefined : (collateralOracleValueUsd * 10n ** 18n) / costIncludingFlashUsd,
        breakEvenRatio: BigInt(collateral.collateralFactor) === 0n ? undefined : (10n ** 36n) / BigInt(collateral.collateralFactor),
        supplyCapacityAcceptsOutput: BigInt(collateral.supplyCapacity) >= amountOut,
        flashLiquidityAcceptsInput: reserve?.availableLiquidity !== undefined && reserve.availableLiquidity >= flash.amountIn,
        flashReserveEligible: reserve?.active === true && reserve?.paused === false && reserve?.flashLoanEnabled === true,
        collateralStops: collateral.collateralStops,
        bestDebt,
      });
      item.candidateOnly = Boolean(
        premiumResult.ok && bestDebt && bestDebt.upperBoundNetBeforeExitAndGas > 0n &&
        item.supplyCapacityAcceptsOutput && item.flashLiquidityAcceptsInput && item.flashReserveEligible &&
        collateral.collateralStops.length === 0 && bestDebt.debtStops.length === 0
      );
      quotes.push(item);
    }
  }
}

const candidates = quotes.filter(item => item.candidateOnly).sort((a, b) => {
  const an = a.bestDebt.upperBoundNetBeforeExitAndGas;
  const bn = b.bestDebt.upperBoundNetBeforeExitAndGas;
  return an === bn ? 0 : an > bn ? -1 : 1;
});

// Flash the collateral itself: this removes the acquisition swap and directly tests whether
// Mendi's oracle/CF permits enough debt to buy back the flash asset after every explicit cost.
const sameAssetQuotes = [];
const wethUsdPrice = resultBigInt(byUnderlyingSymbol.get('WETH')?.usdPriceResult) ?? 0n;
const gasReserveUsd = (GAS_RESERVE_WEI * wethUsdPrice) / 10n ** 18n;
for (const [flashSymbol, flash] of Object.entries(FLASH)) {
  const collateral = byUnderlyingSymbol.get(flashSymbol.toUpperCase());
  if (!collateral) continue;
  const collateralUsdPrice = resultBigInt(collateral.usdPriceResult);
  const reserve = aaveReserves[collateral.symbol];
  const flashFee = (flash.amountIn * flashPremiumBps + 9_999n) / 10_000n;
  const repayment = flash.amountIn + flashFee;
  const gasReserveFlash = collateralUsdPrice && collateralUsdPrice > 0n
    ? (gasReserveUsd * 10n ** BigInt(collateral.underlyingDecimals)) / collateralUsdPrice
    : undefined;
  const routeStops = [...collateral.collateralStops];
  if (!premiumResult.ok) routeStops.push('FLASH_PREMIUM_UNKNOWN');
  if (reserve?.active !== true || reserve?.paused !== false || reserve?.flashLoanEnabled !== true) routeStops.push('FLASH_RESERVE_INELIGIBLE');
  if (reserve?.availableLiquidity === undefined || reserve.availableLiquidity < flash.amountIn) routeStops.push('FLASH_LIQUIDITY_SHORTFALL');
  if (collateralUsdPrice === undefined || collateralUsdPrice === 0n) routeStops.push('COLLATERAL_PRICE_UNKNOWN');
  if (BigInt(collateral.supplyCapacity) < flash.amountIn) routeStops.push('SUPPLY_CAPACITY_SHORTFALL');
  if (gasReserveFlash === undefined) routeStops.push('GAS_RESERVE_CONVERSION_UNKNOWN');
  const collateralOracleValueUsd = collateralUsdPrice === undefined ? undefined : usdValue(flash.amountIn, collateral.underlyingDecimals, collateralUsdPrice);
  const weightedCollateralUsd = collateralOracleValueUsd === undefined ? undefined : (collateralOracleValueUsd * BigInt(collateral.collateralFactor)) / 10n ** 18n;

  for (const debt of marketList) {
    const debtUsdPrice = resultBigInt(debt.usdPriceResult);
    const debtStops = [...debt.debtStops];
    if (debtUsdPrice === undefined || debtUsdPrice === 0n) debtStops.push('DEBT_PRICE_UNKNOWN');
    let candidateAmount = 0n;
    if (weightedCollateralUsd !== undefined && debtUsdPrice !== undefined && debtUsdPrice > 0n) {
      const maxBorrowByLiquidity = (weightedCollateralUsd * 10n ** BigInt(debt.underlyingDecimals)) / debtUsdPrice;
      candidateAmount = [maxBorrowByLiquidity, BigInt(debt.cash), BigInt(debt.borrowCapacity)].reduce((a, b) => a < b ? a : b);
    }
    if (candidateAmount === 0n) debtStops.push('ZERO_CANDIDATE_BORROW');
    const sameToken = debt.underlying.toLowerCase() === collateral.underlying.toLowerCase();
    const exitFees = sameToken ? [0] : FEE_TIERS;
    for (const exitFee of exitFees) {
      const quoteResult = sameToken
        ? { ok: true, value: [candidateAmount, 0n, 0, 0n], synthetic: 'SAME_ASSET_NO_EXIT_SWAP' }
        : await capture(() => quoter.getFunction('quoteExactInputSingle').staticCall({
          tokenIn: debt.underlying,
          tokenOut: collateral.underlying,
          amountIn: candidateAmount,
          fee: exitFee,
          sqrtPriceLimitX96: 0,
        }, { blockTag }));
      const amountOut = quoteResult.ok ? quoteResult.value[0] : undefined;
      const netFlashBeforeGas = amountOut === undefined ? undefined : amountOut - repayment;
      const netFlashAfterGasReserve = netFlashBeforeGas === undefined || gasReserveFlash === undefined ? undefined : netFlashBeforeGas - gasReserveFlash;
      const item = {
        strategy: 'FLASH_COLLATERAL_MINT_BORROW_EXIT_REPAY',
        collateral: collateral.symbol,
        collateralUnderlying: collateral.underlying,
        debt: debt.symbol,
        debtUnderlying: debt.underlying,
        flashAmount: flash.amountIn,
        flashFee,
        repayment,
        candidateAmount,
        exitFee,
        quoteResult,
        amountOut,
        collateralOracleValueUsd,
        weightedCollateralUsd,
        gasReserveWei: GAS_RESERVE_WEI,
        gasReserveUsd,
        gasReserveFlash,
        netFlashBeforeGas,
        netFlashAfterGasReserve,
        routeStops,
        debtStops,
      };
      item.profitableCandidateOnly = Boolean(item.netFlashAfterGasReserve !== undefined && item.netFlashAfterGasReserve > 0n && routeStops.length === 0 && debtStops.length === 0);
      sameAssetQuotes.push(item);
    }
  }
}
const sameAssetCandidates = sameAssetQuotes.filter(item => item.profitableCandidateOnly).sort((a, b) => {
  const an = a.netFlashAfterGasReserve;
  const bn = b.netFlashAfterGasReserve;
  return an === bn ? 0 : an > bn ? -1 : 1;
});
const evidence = {
  provenance: 'PINNED_LINEA_EXECUTION_SCREENING_NOT_AN_EXPLOIT',
  baseRecon: RECON,
  rpcHost: new URL(RPC_URL).host,
  block: base.block,
  aavePool: AAVE_POOL,
  quoterV2: QUOTER_V2,
  uniswapFactory: UNISWAP_FACTORY,
  premiumResult,
  flashPremiumBps,
  aaveReserves,
  quotes,
  candidates,
  sameAssetQuotes,
  sameAssetCandidates,
  gasReserve: { wei: GAS_RESERVE_WEI, usd: gasReserveUsd, wethUsdPrice },
  interpretation: {
    positiveUpperBoundRequiresForkProof: true,
    netBeforeDebtExitSlippageAndGas: true,
    sameAssetNetIncludesFlashPremiumExitQuoteAndGasReserve: true,
    directSinglePoolQuotesOnly: true,
    noMainnetTransactionOrProfit: true,
  },
};
const output = path.join(root, 'evidence', `linea-execution-${blockNumber}.json`);
fs.writeFileSync(output, `${JSON.stringify(evidence, jsonReplacer, 2)}\n`);
console.log(JSON.stringify({
  output,
  block: evidence.block,
  flashPremiumBps,
  successfulQuotes: quotes.filter(x => x.quoteResult.ok).length,
  totalQuotes: quotes.length,
  candidates: candidates.map(item => ({
    collateral: item.collateral,
    flashSymbol: item.flashSymbol,
    fee: item.fee,
    amountIn: item.amountIn,
    amountOut: item.amountOut,
    costIncludingFlashUsd: item.costIncludingFlashUsd,
    weightedCollateralUsd: item.weightedCollateralUsd,
    bestDebt: item.bestDebt,
  })),
  sameAssetQuoteCount: sameAssetQuotes.length,
  sameAssetCandidates,
}, jsonReplacer, 2));
