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
if (!RPC_URL) throw new Error('Set RPC_URL to a BSC archive endpoint');
const provider = new ethers.JsonRpcProvider(RPC_URL, 56, { staticNetwork: true });
const blockNumber = process.env.BLOCK ? Number(process.env.BLOCK) : await provider.getBlockNumber();
if (!Number.isSafeInteger(blockNumber) || blockNumber <= 0) throw new Error('BLOCK must be a positive integer');
const blockTag = blockNumber;
const block = await provider.getBlock(blockTag);
if (!block) throw new Error(`Block ${blockNumber} not found`);

const ADDRESSES = {
  poolRegistry: '0x9F7b01A536aFA00EF10310A162877fd792cD0666',
  comptroller: '0x1b43ea8622e76627B81665B1eCeBB4867566B963',
  resilientOracle: '0x6592b5DE802159F3E74B2486b091D11a8256ab8A',
  binanceOracle: '0x594810b741d136f1960141C0d8Fb4a91bE78A820',
  boundValidator: '0x6E332fF0bB52475304494E4AE5063c1051c7d735',
  pancakeV2Factory: '0xcA143Ce32Fe78f1f7019d7d551a6402f5350c73E',
  pancakeV2Router: '0x10ED43C718714eb63d5aA57B78B54704E256024E',
  nativeAsset: '0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB',
};
const ASSETS = {
  RACA: { token: '0x12BB890508c125661E03b09EC06E404bc9289040', vToken: '0xE5FE5527A5b76C75eedE77FdFA6B80D52444A465' },
  FLOKI: { token: '0xfb5B838b6cfEEdC2873aB27866079AC55363D37E', vToken: '0xc353B7a1E13dDba393B5E120D4169Da7185aA2cb' },
};
const DEBTS = {
  USDT: { token: '0x55d398326f99059fF775485246999027B3197955', vToken: '0x4978591f17670A846137d9d613e333C38dc68A37' },
  USDD: { token: '0xd17479997f34dd9156deef8f95a52d81d265be9c', vToken: '0x9f2FD23bd0A5E08C5f2b9DD6CF9C96Bfb5fA515C' },
};
const QUOTES = {
  USDT: DEBTS.USDT.token,
  USDD: DEBTS.USDD.token,
  USDC: '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d',
  WBNB: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
};
const EIP1967_IMPLEMENTATION = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382f';
const EIP1967_BEACON = '0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50';

function artifact(relative) {
  return JSON.parse(fs.readFileSync(path.join(root, relative), 'utf8'));
}
const comptrollerAbi = artifact('upstream/isolated-pools/deployments/bscmainnet/ComptrollerImpl.json').abi;
const vTokenAbi = artifact('upstream/isolated-pools/deployments/bscmainnet/VTokenImpl.json').abi;
const poolRegistryAbi = artifact('upstream/isolated-pools/deployments/bscmainnet/PoolRegistry.json').abi;
const resilientAbi = artifact('../venus-resilient-oracle-audit/upstream/deployments/bscmainnet/ResilientOracle_Implementation.json').abi;
const binanceAbi = artifact('../venus-resilient-oracle-audit/upstream/deployments/bscmainnet/BinanceOracle_Implementation.json').abi;
const boundAbi = artifact('../venus-resilient-oracle-audit/upstream/deployments/bscmainnet/BoundValidator_Implementation.json').abi;
const erc20Abi = [
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function balanceOf(address) view returns (uint256)',
];
const factoryAbi = ['function getPair(address,address) view returns (address)'];
const pairAbi = [
  'function token0() view returns (address)',
  'function token1() view returns (address)',
  'function getReserves() view returns (uint112,uint112,uint32)',
  'function price0CumulativeLast() view returns (uint256)',
  'function price1CumulativeLast() view returns (uint256)',
  'function totalSupply() view returns (uint256)',
];
const routerAbi = ['function getAmountsOut(uint256,address[]) view returns (uint256[])'];
const beaconAbi = ['function implementation() view returns (address)'];
const feedAbi = [
  'function latestRoundDataByName(string,string) view returns (uint80,int256,uint256,uint256,uint80)',
  'function decimalsByName(string,string) view returns (uint8)',
];

const comptroller = new ethers.Contract(ADDRESSES.comptroller, comptrollerAbi, provider);
const poolRegistry = new ethers.Contract(ADDRESSES.poolRegistry, poolRegistryAbi, provider);
const resilient = new ethers.Contract(ADDRESSES.resilientOracle, resilientAbi, provider);
const binance = new ethers.Contract(ADDRESSES.binanceOracle, binanceAbi, provider);
const bound = new ethers.Contract(ADDRESSES.boundValidator, boundAbi, provider);
const factory = new ethers.Contract(ADDRESSES.pancakeV2Factory, factoryAbi, provider);
const router = new ethers.Contract(ADDRESSES.pancakeV2Router, routerAbi, provider);

async function read(contract, signature, args = []) {
  return contract.getFunction(signature)(...args, { blockTag });
}
async function capture(fn) {
  try { return { ok: true, value: await fn() }; }
  catch (error) { return { ok: false, error: error.shortMessage || error.message }; }
}
async function codeEvidence(address) {
  const code = await provider.getCode(address, blockTag);
  return { address, bytes: (code.length - 2) / 2, keccak256: ethers.keccak256(code) };
}
async function implementationEvidence(proxy, slot = EIP1967_IMPLEMENTATION) {
  const raw = await provider.getStorage(proxy, slot, blockTag);
  return { proxy, slot, raw, implementation: ethers.getAddress(`0x${raw.slice(-40)}`) };
}
function errorResult(error) {
  return { ok: false, error: error.shortMessage || error.message };
}
function decimalsScale(decimals) {
  if (decimals > 18) throw new Error(`Unsupported token decimals ${decimals}`);
  return 10n ** BigInt(18 - decimals);
}
function wholePrice(rawPrice, tokenDecimals) {
  return rawPrice / decimalsScale(tokenDecimals);
}
function usdValue(baseAmount, decimals, priceWhole) {
  return (baseAmount * priceWhole) / (10n ** BigInt(decimals));
}
function formatRatio(numerator) {
  return ethers.formatUnits(numerator, 18);
}
function jsonReplacer(_key, value) {
  if (typeof value === 'bigint') return value.toString();
  if (Array.isArray(value)) return value.map(item => item);
  return value;
}

const quoteCache = new Map();
async function quoteData(symbol, tokenAddress) {
  if (quoteCache.has(tokenAddress)) return quoteCache.get(tokenAddress);
  const token = new ethers.Contract(tokenAddress, erc20Abi, provider);
  const decimals = Number(await read(token, 'decimals()'));
  let oracleAsset = tokenAddress;
  let rawPrice;
  let priceError;
  try { rawPrice = await read(resilient, 'getPrice(address)', [tokenAddress]); }
  catch (error) {
    if (symbol === 'WBNB') {
      try {
        oracleAsset = ADDRESSES.nativeAsset;
        rawPrice = await read(resilient, 'getPrice(address)', [oracleAsset]);
      } catch (nativeError) { priceError = nativeError.shortMessage || nativeError.message; }
    } else priceError = error.shortMessage || error.message;
  }
  const result = { symbol, token: tokenAddress, decimals, oracleAsset, rawPrice, priceWhole: rawPrice === undefined ? undefined : wholePrice(rawPrice, decimals), priceError };
  quoteCache.set(tokenAddress, result);
  return result;
}

async function marketData(label, tokenAddress, vTokenAddress) {
  const token = new ethers.Contract(tokenAddress, erc20Abi, provider);
  const vToken = new ethers.Contract(vTokenAddress, vTokenAbi, provider);
  const [symbol, decimals, underlying, registeredVToken, comptrollerOracle, market, supplyCap, borrowCap, mintPaused, borrowPaused, cash, totalSupply, totalBorrows, badDebt, exchangeRate] = await Promise.all([
    read(token, 'symbol()'),
    read(token, 'decimals()'),
    read(vToken, 'underlying()'),
    read(poolRegistry, 'getVTokenForAsset(address,address)', [ADDRESSES.comptroller, tokenAddress]),
    read(comptroller, 'oracle()'),
    read(comptroller, 'markets(address)', [vTokenAddress]),
    read(comptroller, 'supplyCaps(address)', [vTokenAddress]),
    read(comptroller, 'borrowCaps(address)', [vTokenAddress]),
    read(comptroller, 'actionPaused(address,uint8)', [vTokenAddress, 0]),
    read(comptroller, 'actionPaused(address,uint8)', [vTokenAddress, 2]),
    read(vToken, 'getCash()'),
    read(vToken, 'totalSupply()'),
    read(vToken, 'totalBorrows()'),
    read(vToken, 'badDebt()'),
    read(vToken, 'exchangeRateStored()'),
  ]);
  const currentSupplyUnderlying = (totalSupply * exchangeRate) / (10n ** 18n);
  const supplyCapRemaining = supplyCap === ethers.MaxUint256 ? ethers.MaxUint256 : (supplyCap > currentSupplyUnderlying ? supplyCap - currentSupplyUnderlying : 0n);
  const borrowCapRemaining = borrowCap === ethers.MaxUint256 ? ethers.MaxUint256 : (borrowCap > totalBorrows + badDebt ? borrowCap - totalBorrows - badDebt : 0n);
  return {
    label, token: tokenAddress, vToken: vTokenAddress, symbol, decimals: Number(decimals), underlying, registeredVToken, comptrollerOracle,
    isListed: market[0], collateralFactorMantissa: market[1], liquidationThresholdMantissa: market[2],
    supplyCap, currentSupplyUnderlying, supplyCapRemaining, borrowCap, totalBorrows, badDebt, borrowCapRemaining,
    mintPaused, borrowPaused, cash, totalSupply, exchangeRate,
  };
}

async function oracleData(asset) {
  const token = new ethers.Contract(asset.token, erc20Abi, provider);
  const symbol = await read(token, 'symbol()');
  const decimals = Number(await read(token, 'decimals()'));
  const override = await read(binance, 'symbols(string)', [symbol]);
  const effectiveSymbol = override || symbol;
  const [tokenConfig, rawPriceResult, mainPrice, maxStale, sidRegistry, directRegistry, bounds] = await Promise.all([
    read(resilient, 'getTokenConfig(address)', [asset.token]),
    capture(() => read(resilient, 'getPrice(address)', [asset.token])),
    capture(() => read(binance, 'getPrice(address)', [asset.token])),
    read(binance, 'maxStalePeriod(string)', [effectiveSymbol]),
    read(binance, 'sidRegistryAddress()'),
    read(binance, 'feedRegistryAddress()'),
    capture(() => read(bound, 'validateConfigs(address)', [asset.token])),
  ]);
  const rawPrice = rawPriceResult.ok ? rawPriceResult.value : undefined;
  let feedRegistry = directRegistry;
  if (sidRegistry !== ethers.ZeroAddress) feedRegistry = await read(binance, 'getFeedRegistryAddress()');
  const feed = new ethers.Contract(feedRegistry, feedAbi, provider);
  const [round, feedDecimals] = await Promise.all([
    read(feed, 'latestRoundDataByName(string,string)', [effectiveSymbol, 'USD']),
    read(feed, 'decimalsByName(string,string)', [effectiveSymbol, 'USD']),
  ]);
  const updatedAt = round[3];
  const age = BigInt(block.timestamp) - updatedAt;
  return {
    symbol, decimals, override, effectiveSymbol, tokenConfig,
    mainOracle: tokenConfig[1][0], mainIsBinance: tokenConfig[1][0].toLowerCase() === ADDRESSES.binanceOracle.toLowerCase(),
    rawPriceResult, rawPrice, priceWhole: rawPrice === undefined ? undefined : wholePrice(rawPrice, decimals), mainPrice,
    maxStalePeriod: maxStale, sidRegistry, feedRegistry, feedDecimals,
    feed: { roundId: round[0], answer: round[1], startedAt: round[2], updatedAt: round[3], answeredInRound: round[4] },
    ageSeconds: age, acceptedByStalePeriod: age >= 0n && age <= maxStale,
    bounds,
  };
}

async function pairsForAsset(asset, oracle, collateralMarket, debtMarkets) {
  const results = [];
  for (const [quoteSymbol, quoteToken] of Object.entries(QUOTES)) {
    const pairAddress = await read(factory, 'getPair(address,address)', [asset.token, quoteToken]);
    if (pairAddress === ethers.ZeroAddress) {
      results.push({ quoteSymbol, quoteToken, pair: pairAddress });
      continue;
    }
    const pair = new ethers.Contract(pairAddress, pairAbi, provider);
    const [token0, token1, reserves, cumulative0, cumulative1, lpSupply, quote] = await Promise.all([
      read(pair, 'token0()'), read(pair, 'token1()'), read(pair, 'getReserves()'),
      read(pair, 'price0CumulativeLast()'), read(pair, 'price1CumulativeLast()'), read(pair, 'totalSupply()'),
      quoteData(quoteSymbol, quoteToken),
    ]);
    const record = { quoteSymbol, quoteToken, pair: pairAddress, token0, token1, reserves, cumulative0, cumulative1, lpSupply, quote, executions: [] };
    if (quote.priceWhole === undefined || oracle.priceWhole === undefined || collateralMarket.collateralFactorMantissa === 0n) {
      record.skippedExecution = {
        missingQuotePrice: quote.priceWhole === undefined,
        missingCollateralPrice: oracle.priceWhole === undefined,
        zeroCollateralFactor: collateralMarket.collateralFactorMantissa === 0n,
      };
      results.push(record);
      continue;
    }
    const inputAmounts = quoteSymbol === 'WBNB'
      ? [1n, 10n, 100n, 1_000n].map(x => x * 10n ** 18n)
      : [1_000n, 10_000n, 100_000n, 1_000_000n].map(x => x * (10n ** BigInt(quote.decimals)));
    for (const amountIn of inputAmounts) {
      try {
        const amounts = await read(router, 'getAmountsOut(uint256,address[])', [amountIn, [quoteToken, asset.token]]);
        const amountOut = amounts[1];
        const costUsd = usdValue(amountIn, quote.decimals, quote.priceWhole);
        const executionPriceWhole = (costUsd * (10n ** BigInt(oracle.decimals))) / amountOut;
        const ratio = (oracle.priceWhole * (10n ** 18n)) / executionPriceWhole;
        const requiredRatio = (10n ** 36n) / collateralMarket.collateralFactorMantissa;
        const weightedCollateralUsd = (usdValue(amountOut, oracle.decimals, oracle.priceWhole) * collateralMarket.collateralFactorMantissa) / (10n ** 18n);
        const debts = [];
        for (const debt of Object.values(debtMarkets)) {
          const debtQuote = await quoteData(debt.symbol, debt.token);
          if (debtQuote.priceWhole === undefined) {
            debts.push({ symbol: debt.symbol, error: debtQuote.priceError });
            continue;
          }
          const maxBorrowByLiquidity = debtQuote.priceWhole === 0n ? 0n : (weightedCollateralUsd * (10n ** BigInt(debt.decimals))) / debtQuote.priceWhole;
          const candidateAmount = [maxBorrowByLiquidity, debt.cash, debt.borrowCapRemaining].reduce((a, b) => a < b ? a : b);
          const borrowUsd = usdValue(candidateAmount, debt.decimals, debtQuote.priceWhole);
          debts.push({
            symbol: debt.symbol, maxBorrowByLiquidity, candidateAmount, borrowUsd,
            upperBoundNetBeforeFlashExitAndGas: borrowUsd - costUsd,
            candidateOnly: borrowUsd > costUsd && collateralMarket.isListed && debt.isListed && !collateralMarket.mintPaused && !debt.borrowPaused && collateralMarket.supplyCapRemaining >= amountOut,
          });
        }
        record.executions.push({
          amountIn, amountOut, costUsd, executionPriceWhole, oraclePriceWhole: oracle.priceWhole,
          oracleToExecutionRatio: ratio, oracleToExecutionRatioDecimal: formatRatio(ratio),
          breakEvenRatio: requiredRatio, breakEvenRatioDecimal: formatRatio(requiredRatio),
          weightedCollateralUsd, supplyCapAcceptsInput: collateralMarket.supplyCapRemaining >= amountOut,
          debts,
        });
      } catch (error) {
        record.executions.push({ amountIn, ...errorResult(error) });
      }
    }
    results.push(record);
  }
  return results;
}

const implementationSlots = {
  resilientOracle: await implementationEvidence(ADDRESSES.resilientOracle),
  binanceOracle: await implementationEvidence(ADDRESSES.binanceOracle),
  poolRegistry: await implementationEvidence(ADDRESSES.poolRegistry),
  comptrollerBeacon: await implementationEvidence(ADDRESSES.comptroller, EIP1967_BEACON),
  vRacaBeacon: await implementationEvidence(ASSETS.RACA.vToken, EIP1967_BEACON),
  vFlokiBeacon: await implementationEvidence(ASSETS.FLOKI.vToken, EIP1967_BEACON),
};
const beacons = {};
for (const [name, item] of Object.entries(implementationSlots)) {
  if (name.endsWith('Beacon') && item.implementation !== ethers.ZeroAddress) {
    beacons[name] = {
      beacon: item.implementation,
      implementation: await capture(() => read(new ethers.Contract(item.implementation, beaconAbi, provider), 'implementation()')),
    };
  }
}

const assets = {};
for (const [label, asset] of Object.entries(ASSETS)) {
  const [oracle, collateralMarket] = await Promise.all([oracleData(asset), marketData(label, asset.token, asset.vToken)]);
  assets[label] = { ...asset, oracle, market: collateralMarket };
}
const debtMarkets = {};
for (const [label, debt] of Object.entries(DEBTS)) debtMarkets[label] = await marketData(label, debt.token, debt.vToken);
for (const [label, asset] of Object.entries(ASSETS)) {
  assets[label].pancakeV2 = await pairsForAsset(asset, assets[label].oracle, assets[label].market, debtMarkets);
}

const codeAddresses = new Set([
  ...Object.values(ADDRESSES), ...Object.values(ASSETS).flatMap(x => [x.token, x.vToken]), ...Object.values(DEBTS).flatMap(x => [x.token, x.vToken]),
  ...Object.values(implementationSlots).map(x => x.implementation), ...Object.values(beacons).map(x => x.beacon),
]);
const code = [];
for (const address of codeAddresses) if (address && address !== ethers.ZeroAddress) code.push(await codeEvidence(address));

const screening = {};
for (const [label, item] of Object.entries(assets)) {
  const stops = [];
  if (!item.market.isListed) stops.push('COLLATERAL_MARKET_NOT_LISTED');
  if (item.market.collateralFactorMantissa === 0n) stops.push('ZERO_COLLATERAL_FACTOR_NO_BORROWING_POWER');
  if (item.market.mintPaused) stops.push('COLLATERAL_MINT_PAUSED');
  if (item.market.supplyCapRemaining === 0n) stops.push('ZERO_SUPPLY_CAPACITY');
  if (item.oracle.priceWhole === undefined) stops.push('NO_READABLE_RESILIENT_PRICE');
  const debtStops = {};
  for (const [debtLabel, debt] of Object.entries(debtMarkets)) {
    const reasons = [];
    if (!debt.isListed) reasons.push('DEBT_MARKET_NOT_LISTED');
    if (debt.borrowPaused) reasons.push('DEBT_BORROW_PAUSED');
    if (debt.borrowCapRemaining === 0n) reasons.push('ZERO_BORROW_CAPACITY');
    if (debt.cash === 0n) reasons.push('ZERO_CASH');
    debtStops[debtLabel] = reasons;
  }
  screening[label] = { collateralStops: stops, debtStops };
}

const evidence = {
  provenance: 'PINNED_BSC_READ_ONLY_RECON_NOT_AN_EXPLOIT',
  rpcHost: new URL(RPC_URL).host,
  chainId: (await provider.getNetwork()).chainId,
  block: { number: blockNumber, hash: block.hash, timestamp: block.timestamp },
  addresses: ADDRESSES,
  implementationSlots,
  beacons,
  code,
  assets,
  debtMarkets,
  screening,
  interpretation: {
    positiveScreeningDoesNotProveProfit: true,
    requiredNextStep: 'State-changing same-transaction fork PoC with flash repayment and final liquid balances',
    noDexManipulationOfBinanceFeedObservedInCode: true,
  },
};
fs.mkdirSync(path.join(root, 'evidence'), { recursive: true });
const output = path.join(root, 'evidence', `gamefi-recon-${blockNumber}.json`);
fs.writeFileSync(output, `${JSON.stringify(evidence, jsonReplacer, 2)}\n`);
console.log(JSON.stringify({ output, block: evidence.block, assets: Object.fromEntries(Object.entries(assets).map(([label, item]) => [label, {
  priceWhole: item.oracle.priceWhole,
  ageSeconds: item.oracle.ageSeconds,
  maxStalePeriod: item.oracle.maxStalePeriod,
  cachingEnabled: item.oracle.tokenConfig[3],
  mainOracle: item.oracle.mainOracle,
  mainIsBinance: item.oracle.mainIsBinance,
  collateralFactor: item.market.collateralFactorMantissa,
  mintPaused: item.market.mintPaused,
  supplyCapRemaining: item.market.supplyCapRemaining,
  screening: screening[label],
  pairs: item.pancakeV2.map(pair => ({ pair: pair.pair, quote: pair.quoteSymbol, executions: pair.executions?.map(x => ({ amountIn: x.amountIn, amountOut: x.amountOut, ratio: x.oracleToExecutionRatioDecimal, breakEven: x.breakEvenRatioDecimal, debts: x.debts })) })),
}])) }, jsonReplacer, 2));
