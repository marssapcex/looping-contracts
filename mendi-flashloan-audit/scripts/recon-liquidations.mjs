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

const UNITROLLER = base.unitroller;
const comptrollerArtifact = JSON.parse(fs.readFileSync(path.join(root, 'upstream/deployments/linea/Comptroller.json'), 'utf8'));
const cTokenArtifact = JSON.parse(fs.readFileSync(path.join(root, 'upstream/deployments/linea/CErc20Upgradable_WETH_Implementation.json'), 'utf8'));
const comptroller = new ethers.Contract(UNITROLLER, comptrollerArtifact.abi, provider);
const markets = Object.values(base.markets);
const marketAddresses = markets.map(item => item.cToken);
const borrowInterface = new ethers.Interface([
  'event Borrow(address borrower,uint256 borrowAmount,uint256 accountBorrows,uint256 totalBorrows)',
]);
const borrowTopic = borrowInterface.getEvent('Borrow').topicHash;
const span = Number(process.env.LOG_SPAN ?? 2_000_000);
const initialChunk = Number(process.env.LOG_CHUNK ?? 50_000);
const fromBlock = process.env.LOG_FROM_BLOCK ? Number(process.env.LOG_FROM_BLOCK) : Math.max(0, blockNumber - span);
if (!Number.isSafeInteger(fromBlock) || fromBlock < 0 || fromBlock > blockNumber) throw new Error('Invalid LOG_FROM_BLOCK/LOG_SPAN');
if (!Number.isSafeInteger(initialChunk) || initialChunk <= 0) throw new Error('Invalid LOG_CHUNK');

function jsonReplacer(_key, value) { return typeof value === 'bigint' ? value.toString() : value; }
async function capture(fn) {
  try { return { ok: true, value: await fn() }; }
  catch (error) { return { ok: false, error: error.shortMessage || error.message }; }
}
async function read(contract, signature, args = []) {
  return contract.getFunction(signature)(...args, { blockTag });
}
function usdValue(amount, _underlyingDecimals, underlyingPriceMantissa) {
  // MixedPriceOracleV3.getUnderlyingPrice already incorporates underlying decimals.
  return (amount * underlyingPriceMantissa) / 10n ** 18n;
}
function price(item) { return BigInt(item.oraclePriceResult.value); }

const logs = [];
const logErrors = [];
async function scanRange(start, end) {
  try {
    const result = await provider.getLogs({
      address: marketAddresses,
      topics: [borrowTopic],
      fromBlock: start,
      toBlock: end,
    });
    logs.push(...result);
  } catch (error) {
    if (end - start <= 1_000) {
      logErrors.push({ fromBlock: start, toBlock: end, error: error.shortMessage || error.message });
      return;
    }
    const middle = start + Math.floor((end - start) / 2);
    await scanRange(start, middle);
    await scanRange(middle + 1, end);
  }
}
for (let start = fromBlock; start <= blockNumber; start += initialChunk) {
  await scanRange(start, Math.min(blockNumber, start + initialChunk - 1));
}

const borrowers = new Set();
const borrowEvents = [];
for (const log of logs) {
  try {
    const parsed = borrowInterface.parseLog(log);
    const borrower = parsed.args.borrower;
    borrowers.add(borrower);
    borrowEvents.push({
      market: log.address,
      borrower,
      borrowAmount: parsed.args.borrowAmount,
      accountBorrowsAtEvent: parsed.args.accountBorrows,
      totalBorrowsAtEvent: parsed.args.totalBorrows,
      blockNumber: log.blockNumber,
      transactionHash: log.transactionHash,
      logIndex: log.index,
    });
  } catch (error) {
    logErrors.push({ blockNumber: log.blockNumber, transactionHash: log.transactionHash, error: error.message });
  }
}

const accounts = [];
const liquidatable = [];
for (const account of [...borrowers].sort()) {
  const liquidityResult = await capture(() => read(comptroller, 'getAccountLiquidity(address)', [account]));
  const item = { account, liquidityResult };
  accounts.push(item);
  if (!liquidityResult.ok) continue;
  const [errorCode, liquidity, shortfall] = liquidityResult.value;
  if (errorCode !== 0n || shortfall === 0n) continue;

  const positions = [];
  const pairs = [];
  for (const debt of markets) {
    const debtToken = new ethers.Contract(debt.cToken, cTokenArtifact.abi, provider);
    const borrowResult = await capture(() => read(debtToken, 'borrowBalanceStored(address)', [account]));
    const borrowBalance = borrowResult.ok ? borrowResult.value : 0n;
    if (borrowBalance === 0n) continue;
    const maxRepay = (borrowBalance * BigInt(base.closeFactor)) / 10n ** 18n;
    for (const collateral of markets) {
      const collateralToken = new ethers.Contract(collateral.cToken, cTokenArtifact.abi, provider);
      const [cTokenBalanceResult, exchangeRateResult] = await Promise.all([
        capture(() => read(collateralToken, 'balanceOf(address)', [account])),
        capture(() => read(collateralToken, 'exchangeRateStored()')),
      ]);
      const cTokenBalance = cTokenBalanceResult.ok ? cTokenBalanceResult.value : 0n;
      if (cTokenBalance === 0n || !exchangeRateResult.ok) continue;
      const collateralUnderlying = (cTokenBalance * exchangeRateResult.value) / 10n ** 18n;
      const seizeResult = await capture(() => read(comptroller, 'liquidateCalculateSeizeTokens(address,address,uint256)', [debt.cToken, collateral.cToken, maxRepay]));
      const seizedCTokens = seizeResult.ok ? seizeResult.value[1] : undefined;
      const seizedUnderlying = seizedUnderlyingValue(seizedCTokens, exchangeRateResult.value);
      const repayUsd = usdValue(maxRepay, debt.underlyingDecimals, price(debt));
      const seizedUsd = seizedUnderlying === undefined ? undefined : usdValue(seizedUnderlying, collateral.underlyingDecimals, price(collateral));
      pairs.push({
        debtMarket: debt.symbol,
        collateralMarket: collateral.symbol,
        borrowBalance,
        maxRepay,
        repayUsd,
        collateralCTokenBalance: cTokenBalance,
        collateralUnderlying,
        seizeResult,
        seizedCTokens,
        seizedUnderlying,
        seizedUsd,
        grossLiquidationEdgeUsdBeforeFlashExitAndGas: seizedUsd === undefined ? undefined : seizedUsd - repayUsd,
      });
    }
    positions.push({ market: debt.symbol, borrowBalance, maxRepay });
  }
  const detail = { account, errorCode, liquidity, shortfall, positions, pairs };
  liquidatable.push(detail);
  item.detail = detail;
}

function seizedUnderlyingValue(seizedCTokens, exchangeRate) {
  return seizedCTokens === undefined ? undefined : (seizedCTokens * exchangeRate) / 10n ** 18n;
}

const evidence = {
  provenance: 'PINNED_LINEA_BORROWER_AND_LIQUIDATION_RECON_NOT_AN_EXPLOIT',
  rpcHost: new URL(RPC_URL).host,
  block: base.block,
  scan: {
    fromBlock,
    toBlock: blockNumber,
    initialChunk,
    completeWithoutChunkErrors: logErrors.length === 0,
    limitation: 'Only accounts with a Borrow event in this range are screened; older dormant borrowers are not enumerated.',
  },
  borrowEventCount: borrowEvents.length,
  uniqueBorrowerCount: borrowers.size,
  borrowEvents,
  logErrors,
  accounts,
  liquidatable,
  closeFactor: base.closeFactor,
  liquidationIncentive: base.liquidationIncentive,
  interpretation: {
    shortfallUsesActiveUnitrollerAndPinnedOracle: true,
    grossEdgeIsNotNetProfit: true,
    requiresFlashLiquidityRealExitRepaymentAndGas: true,
    noMainnetTransactionOrProfit: true,
  },
};
const output = path.join(root, 'evidence', `linea-liquidations-${blockNumber}.json`);
fs.writeFileSync(output, `${JSON.stringify(evidence, jsonReplacer, 2)}\n`);
console.log(JSON.stringify({
  output,
  block: evidence.block,
  scan: evidence.scan,
  borrowEventCount: evidence.borrowEventCount,
  uniqueBorrowerCount: evidence.uniqueBorrowerCount,
  logErrors,
  liquidatable: liquidatable.map(item => ({ account: item.account, shortfall: item.shortfall, positions: item.positions, pairs: item.pairs })),
}, jsonReplacer, 2));
