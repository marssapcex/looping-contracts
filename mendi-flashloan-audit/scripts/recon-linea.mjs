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
if (!RPC_URL) throw new Error('Set RPC_URL to a Linea archive endpoint');
const provider = new ethers.JsonRpcProvider(RPC_URL, 59144, { staticNetwork: true });
const blockNumber = process.env.BLOCK ? Number(process.env.BLOCK) : await provider.getBlockNumber();
if (!Number.isSafeInteger(blockNumber) || blockNumber <= 0) throw new Error('BLOCK must be a positive integer');
const blockTag = blockNumber;
const block = await provider.getBlock(blockTag);
if (!block) throw new Error(`Block ${blockNumber} not found`);

const UNITROLLER = '0x1b4d3b0421dDc1eB216D230Bc01527422Fb93103';
const EXPECTED_MIXED_V2 = '0xD2Ed953C240edC59D57E5CFB527Eb768048Fa012';
const PYTH = '0xA2aa501b19aff244D90cc15a4Cf739D2725B5729';
const EIP1967_IMPLEMENTATION = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382f';

function artifact(relative) {
  return JSON.parse(fs.readFileSync(path.join(root, 'upstream/deployments/linea', relative), 'utf8'));
}
const comptrollerArtifact = artifact('Comptroller.json');
const cTokenArtifact = artifact('CErc20Upgradable_WETH_Implementation.json');
const oracleArtifact = artifact('MixedPriceOracleV2.json');
const comptroller = new ethers.Contract(UNITROLLER, comptrollerArtifact.abi, provider);
const oracle = new ethers.Contract(EXPECTED_MIXED_V2, oracleArtifact.abi, provider);
const pyth = new ethers.Contract(PYTH, [
  'function getPriceUnsafe(bytes32) view returns (int64 price, uint64 conf, int32 expo, uint256 publishTime)',
], provider);

const deploymentByAddress = new Map();
for (const filename of fs.readdirSync(path.join(root, 'upstream/deployments/linea'))) {
  if (!filename.endsWith('.json')) continue;
  const item = artifact(filename);
  if (item.address) deploymentByAddress.set(item.address.toLowerCase(), { filename, artifact: item });
}

const erc20Abi = [
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
];
const feedAbi = [
  'function decimals() view returns (uint8)',
  'function latestAnswer() view returns (int256)',
  'function latestTimestamp() view returns (uint256)',
  'function latestRoundData() view returns (uint80,int256,uint256,uint256,uint80)',
  'function description() view returns (string)',
];

async function read(contract, signature, args = []) {
  return contract.getFunction(signature)(...args, { blockTag });
}
async function capture(fn) {
  try { return { ok: true, value: await fn() }; }
  catch (error) { return { ok: false, error: error.shortMessage || error.message }; }
}
function jsonReplacer(_key, value) {
  return typeof value === 'bigint' ? value.toString() : value;
}
function resultValue(result) {
  return result.ok ? result.value : undefined;
}
function remainingStrictCap(cap, totalBorrows) {
  if (cap === 0n) return ethers.MaxUint256;
  // Compound requires totalBorrows + borrowAmount < borrowCap, not <=.
  return cap > totalBorrows ? cap - totalBorrows - 1n : 0n;
}
function remainingSupplyCap(cap, currentUnderlying) {
  if (cap === 0n) return ethers.MaxUint256;
  return cap > currentUnderlying ? cap - currentUnderlying : 0n;
}

async function codeEvidence(address) {
  const code = await provider.getCode(address, blockTag);
  const deployment = deploymentByAddress.get(address.toLowerCase());
  const deployedBytecode = deployment?.artifact.deployedBytecode;
  const hasHexArtifactBytecode = typeof deployedBytecode === 'string' && /^0x[0-9a-fA-F]*$/.test(deployedBytecode);
  return {
    address,
    artifact: deployment?.filename,
    bytes: (code.length - 2) / 2,
    liveKeccak256: ethers.keccak256(code),
    artifactKeccak256: hasHexArtifactBytecode ? ethers.keccak256(deployedBytecode) : undefined,
    artifactBytecodeMatches: hasHexArtifactBytecode ? ethers.keccak256(code) === ethers.keccak256(deployedBytecode) : undefined,
  };
}

const [implementation, pendingImplementation, admin, oracleAddress, closeFactor, liquidationIncentive, marketAddresses] = await Promise.all([
  read(comptroller, 'comptrollerImplementation()'),
  capture(() => read(comptroller, 'pendingComptrollerImplementation()')),
  read(comptroller, 'admin()'),
  read(comptroller, 'oracle()'),
  read(comptroller, 'closeFactorMantissa()'),
  read(comptroller, 'liquidationIncentiveMantissa()'),
  read(comptroller, 'getAllMarkets()'),
]);

const activeOracle = new ethers.Contract(oracleAddress, oracleArtifact.abi, provider);
const markets = {};
const configSymbols = new Set();
const codeAddresses = new Set([UNITROLLER, implementation, oracleAddress, PYTH]);

for (const cTokenAddress of marketAddresses) {
  const cToken = new ethers.Contract(cTokenAddress, cTokenArtifact.abi, provider);
  const [symbol, underlying, comptrollerAddress, tokenDecimals, cash, totalSupply, totalBorrows, totalReserves, exchangeRate, reserveFactor, interestRateModel, market, supplyCap, borrowCap, mintPaused, borrowPaused, deprecated, implementationRaw] = await Promise.all([
    read(cToken, 'symbol()'),
    read(cToken, 'underlying()'),
    read(cToken, 'comptroller()'),
    read(cToken, 'decimals()'),
    read(cToken, 'getCash()'),
    read(cToken, 'totalSupply()'),
    read(cToken, 'totalBorrows()'),
    read(cToken, 'totalReserves()'),
    read(cToken, 'exchangeRateStored()'),
    read(cToken, 'reserveFactorMantissa()'),
    read(cToken, 'interestRateModel()'),
    read(comptroller, 'markets(address)', [cTokenAddress]),
    read(comptroller, 'supplyCaps(address)', [cTokenAddress]),
    read(comptroller, 'borrowCaps(address)', [cTokenAddress]),
    read(comptroller, 'mintGuardianPaused(address)', [cTokenAddress]),
    read(comptroller, 'borrowGuardianPaused(address)', [cTokenAddress]),
    read(comptroller, 'isDeprecated(address)', [cTokenAddress]),
    provider.getStorage(cTokenAddress, EIP1967_IMPLEMENTATION, blockTag),
  ]);
  const token = new ethers.Contract(underlying, erc20Abi, provider);
  const [underlyingSymbol, underlyingDecimals, oraclePriceResult, usdPriceResult] = await Promise.all([
    read(token, 'symbol()'),
    read(token, 'decimals()'),
    capture(() => read(activeOracle, 'getUnderlyingPrice(address)', [cTokenAddress])),
    capture(() => read(activeOracle, 'getPrice(address)', [cTokenAddress])),
  ]);
  const currentSupplyUnderlying = (totalSupply * exchangeRate) / 10n ** 18n;
  const implementationAddress = ethers.getAddress(`0x${implementationRaw.slice(-40)}`);
  const item = {
    cToken: cTokenAddress,
    symbol,
    underlying,
    underlyingSymbol,
    underlyingDecimals: Number(underlyingDecimals),
    cTokenDecimals: Number(tokenDecimals),
    comptroller: comptrollerAddress,
    interestRateModel,
    reserveFactor,
    isListed: market[0],
    collateralFactor: market[1],
    isComped: market[2],
    supplyCap,
    currentSupplyUnderlying,
    supplyCapacity: remainingSupplyCap(supplyCap, currentSupplyUnderlying),
    supplyCapZeroMeansUnlimited: supplyCap === 0n,
    borrowCap,
    borrowCapacity: remainingStrictCap(borrowCap, totalBorrows),
    borrowCapZeroMeansUnlimited: borrowCap === 0n,
    mintPaused,
    borrowPaused,
    deprecated,
    cash,
    totalSupply,
    totalBorrows,
    totalReserves,
    exchangeRate,
    oraclePriceResult,
    usdPriceResult,
    implementationSlot: { raw: implementationRaw, implementation: implementationAddress },
  };
  const collateralStops = [];
  if (!item.isListed) collateralStops.push('NOT_LISTED');
  if (item.collateralFactor === 0n) collateralStops.push('ZERO_COLLATERAL_FACTOR');
  if (item.mintPaused) collateralStops.push('MINT_PAUSED');
  if (item.supplyCapacity === 0n) collateralStops.push('ZERO_SUPPLY_CAPACITY');
  if (!oraclePriceResult.ok) collateralStops.push('ORACLE_REVERT');
  const debtStops = [];
  if (!item.isListed) debtStops.push('NOT_LISTED');
  if (item.borrowPaused) debtStops.push('BORROW_PAUSED');
  if (item.borrowCapacity === 0n) debtStops.push('ZERO_BORROW_CAPACITY');
  if (item.cash === 0n) debtStops.push('ZERO_CASH');
  if (!oraclePriceResult.ok) debtStops.push('ORACLE_REVERT');
  markets[symbol] = { ...item, collateralStops, debtStops };
  configSymbols.add(symbol);
  codeAddresses.add(cTokenAddress);
  codeAddresses.add(implementationAddress);
  codeAddresses.add(underlying);
}

const configs = {};
const feeds = {};
async function loadConfig(symbol) {
  if (configs[symbol]) return;
  const config = await read(activeOracle, 'configs(string)', [symbol]);
  const priceId = config[0];
  const toSymbol = config[1];
  const underlyingDecimals = Number(config[2]);
  const isAddress = (BigInt(priceId) >> 160n) === 0n;
  const item = { symbol, priceId, toSymbol, underlyingDecimals, sourceType: isAddress ? 'ADDRESS_FEED' : 'PYTH_PRICE_ID' };
  configs[symbol] = item;
  if (toSymbol !== 'USD' && toSymbol !== symbol) await loadConfig(toSymbol);

  if (isAddress) {
    const address = ethers.getAddress(`0x${priceId.slice(-40)}`);
    const feed = new ethers.Contract(address, feedAbi, provider);
    const [decimalsResult, answerResult, roundResult, timestampResult, descriptionResult] = await Promise.all([
      capture(() => read(feed, 'decimals()')),
      capture(() => read(feed, 'latestAnswer()')),
      capture(() => read(feed, 'latestRoundData()')),
      capture(() => read(feed, 'latestTimestamp()')),
      capture(() => read(feed, 'description()')),
    ]);
    const round = resultValue(roundResult);
    const updatedAt = round?.[3] ?? resultValue(timestampResult);
    feeds[address] = {
      address,
      decimalsResult,
      answerResult,
      roundResult,
      timestampResult,
      descriptionResult,
      updatedAt,
      ageSeconds: updatedAt === undefined ? undefined : BigInt(block.timestamp) - updatedAt,
      adapterChecksFreshness: false,
    };
    codeAddresses.add(address);
  } else {
    const priceResult = await capture(() => read(pyth, 'getPriceUnsafe(bytes32)', [priceId]));
    const price = resultValue(priceResult);
    feeds[priceId] = {
      priceId,
      sourceType: 'PYTH',
      priceResult,
      publishTime: price?.[3],
      ageSeconds: price === undefined ? undefined : BigInt(block.timestamp) - price[3],
      adapterChecksFreshness: false,
    };
  }
}
for (const symbol of configSymbols) await loadConfig(symbol);

const code = [];
for (const address of codeAddresses) if (address && address !== ethers.ZeroAddress) code.push(await codeEvidence(address));

const evidence = {
  provenance: 'PINNED_LINEA_READ_ONLY_RECON_NOT_AN_EXPLOIT',
  rpcHost: new URL(RPC_URL).host,
  chainId: (await provider.getNetwork()).chainId,
  block: { number: blockNumber, hash: block.hash, timestamp: block.timestamp },
  upstreamCommit: fs.readFileSync(path.join(root, 'UPSTREAM_COMMIT'), 'utf8').trim(),
  unitroller: UNITROLLER,
  implementation,
  pendingImplementation,
  admin,
  oracle: oracleAddress,
  expectedMixedV2: EXPECTED_MIXED_V2,
  activeOracleMatchesArtifactAddress: oracleAddress.toLowerCase() === EXPECTED_MIXED_V2.toLowerCase(),
  closeFactor,
  liquidationIncentive,
  markets,
  configs,
  feeds,
  code,
  interpretation: {
    zeroCapsMeanUnlimitedNotClosed: true,
    noFreshnessCheckInMixedPriceOracleV2Source: true,
    staleFeedIsNotSufficientForProfit: true,
    requiredNextStep: 'Executable DEX/flash quotes and same-transaction fork PoC with repayment and liquid balance deltas',
  },
};
fs.mkdirSync(path.join(root, 'evidence'), { recursive: true });
const output = path.join(root, 'evidence', `linea-recon-${blockNumber}.json`);
fs.writeFileSync(output, `${JSON.stringify(evidence, jsonReplacer, 2)}\n`);
console.log(JSON.stringify({
  output,
  block: evidence.block,
  oracle: oracleAddress,
  activeOracleMatchesArtifactAddress: evidence.activeOracleMatchesArtifactAddress,
  markets: Object.fromEntries(Object.entries(markets).map(([symbol, item]) => [symbol, {
    collateralFactor: item.collateralFactor,
    supplyCap: item.supplyCap,
    borrowCap: item.borrowCap,
    mintPaused: item.mintPaused,
    borrowPaused: item.borrowPaused,
    deprecated: item.deprecated,
    cash: item.cash,
    oraclePriceResult: item.oraclePriceResult,
    collateralStops: item.collateralStops,
    debtStops: item.debtStops,
  }])),
  feeds: Object.fromEntries(Object.entries(feeds).map(([id, item]) => [id, {
    ageSeconds: item.ageSeconds,
    answerResult: item.answerResult,
    roundResult: item.roundResult,
    priceResult: item.priceResult,
    descriptionResult: item.descriptionResult,
  }])),
}, jsonReplacer, 2));
