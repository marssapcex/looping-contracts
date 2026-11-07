import fs from 'node:fs';
import { Contract, JsonRpcProvider, Network, formatUnits } from 'ethers';

const CORE = '0xCFa5aE7c2CE8Fadc6426C1ff872cA45378Fb7cF3';
const POOLS = {
  core: CORE,
  'mETH/WETH': '0x85def7bcff3a0b73f88429a70b73b412bf204cf7',
  'cmETH/WETH': '0x84dc9d0a07498e89bab967b6bace21ade19cfd1b',
  'FBTC/WETH': '0x7d8e5801de97cc8c1b163168ba2bd0732263d6d5',
  'MNT/WETH': '0x2044b8059533a7d45fc3f70c0e8dfa8555bb10ba',
  'sUSDe/USDe': '0x1244f36e812776390b3401e2391bdeb330db97fc',
  'mETH/USDe': '0x15e983ef3940ef77eb2c645cd51559f8ff233011',
  'cmETH/USDe': '0x553265ff16efb2e7590941d138273f1649132265',
  'FBTC/USDe': '0x6d15d979e3f99e9bd74a6ba47f7c53c118df217c',
  'MNT/USDe': '0xd5a52533e982883ff4186b311218f9efea7b04b1',
};
const POOL_ABI = [
  'function paused() view returns (bool)',
  'function getReservesList() view returns (address[])',
  'function getReserveData(address) view returns (tuple(uint256 data) configuration,uint128 liquidityIndex,uint128 variableBorrowIndex,uint128 currentLiquidityRate,uint128 currentVariableBorrowRate,uint128 currentStableBorrowRate,uint40 lastUpdateTimestamp,address aTokenAddress,address stableDebtTokenAddress,address variableDebtTokenAddress,address interestRateStrategyAddress,uint8 id)',
  'function getAddressesProvider() view returns (address)',
  'function getUserAccountData(address) view returns (uint256 totalCollateral,uint256 totalDebt,uint256 availableBorrows,uint256 currentLiquidationThreshold,uint256 ltv,uint256 healthFactor)',
  'event Borrow(address indexed reserve,address user,address indexed onBehalfOf,uint256 amount,uint256 borrowRateMode,uint256 borrowRate,uint16 indexed referralCode)',
];
const PROVIDER_ABI = ['function getPriceOracle() view returns (address)'];
const ORACLE_ABI = [
  'function getAssetPrice(address) view returns (uint256)',
  'function getSourceOfAsset(address) view returns (address)',
  'function BASE_CURRENCY() view returns (address)',
  'function BASE_CURRENCY_UNIT() view returns (uint256)',
];
const TOKEN_ABI = [
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function balanceOf(address) view returns (uint256)',
  'function totalSupply() view returns (uint256)',
];
const SOURCE_ABI = [
  'function latestAnswer() view returns (int256)',
  'function latestTimestamp() view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function description() view returns (string)',
];
const urls = (process.env.MANTLE_RPCS || [
  'https://rpc.mantle.xyz',
  'https://mantle-rpc.publicnode.com',
  'https://mantle.publicnode.com',
  'https://1rpc.io/mantle',
].join(',')).split(',');
let provider;
let rpcHost;
for (const url of urls) {
  try {
    const candidate = new JsonRpcProvider(url, Network.from({ name: 'mantle', chainId: 5000 }), { staticNetwork: true, batchMaxCount: 1 });
    await Promise.race([
      candidate.getBlockNumber(),
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 15000)),
    ]);
    provider = candidate;
    rpcHost = new URL(url).host;
    break;
  } catch (error) {
    console.error('RPC rejected', new URL(url).host, String(error).slice(0, 300));
  }
}
if (!provider) throw new Error('No usable Mantle RPC');
const blockNumber = await provider.getBlockNumber();
const block = await provider.getBlock(blockNumber);
const out = {
  provenance: 'LENDLE_MANTLE_CURRENT_READ_ONLY_TRIAGE_NOT_AN_EXPLOIT',
  rpcHost,
  block: { number: blockNumber, hash: block.hash, timestamp: block.timestamp },
  targetNetLiquidProfitUsd: 10000,
  pools: {},
  limitations: [
    'Read-only current-state triage; no profitable execution is implied.',
    'Borrower enumeration is range-limited and cannot prove that no dormant liquidatable account exists.',
    'Cash is not profit; DEX exit, flash premium and gas are not included in raw cash values.',
  ],
};
const safe = async (fn, fallback = null) => { try { return await fn(); } catch { return fallback; } };
const str = (value) => value == null ? null : value.toString();
const flag = (data, bit) => ((data >> BigInt(bit)) & 1n) === 1n;
const sourceCache = new Map();
async function sourceInfo(address) {
  if (!address || address === '0x0000000000000000000000000000000000000000') return null;
  if (sourceCache.has(address)) return sourceCache.get(address);
  const source = new Contract(address, SOURCE_ABI, provider);
  const value = {
    address,
    latestAnswer: str(await safe(() => source.latestAnswer())),
    latestTimestamp: str(await safe(() => source.latestTimestamp())),
    decimals: str(await safe(() => source.decimals())),
    description: await safe(() => source.description()),
  };
  sourceCache.set(address, value);
  return value;
}
for (const [name, address] of Object.entries(POOLS)) {
  const pool = new Contract(address, POOL_ABI, provider);
  const result = { address, paused: await safe(() => pool.paused()), reserves: [], borrowers: { scanned: [], liquidatable: [] } };
  const assets = await safe(() => pool.getReservesList(), []);
  let oracleAddress = null;
  const addressesProvider = await safe(() => pool.getAddressesProvider());
  if (addressesProvider) {
    oracleAddress = await safe(() => new Contract(addressesProvider, PROVIDER_ABI, provider).getPriceOracle());
  }
  if (!oracleAddress && name === 'core') oracleAddress = '0x870c9692Ab04944C86ec6FEeF63F261226506EfC';
  result.oracle = oracleAddress;
  if (oracleAddress) {
    const oracle = new Contract(oracleAddress, ORACLE_ABI, provider);
    result.baseCurrency = await safe(() => oracle.BASE_CURRENCY());
    result.baseCurrencyUnit = str(await safe(() => oracle.BASE_CURRENCY_UNIT()));
  }
  for (const asset of assets) {
    const data = await safe(() => pool.getReserveData(asset));
    if (!data) continue;
    const token = new Contract(asset, TOKEN_ABI, provider);
    const decimals = Number(await safe(() => token.decimals(), 18));
    const aToken = data.aTokenAddress;
    const cash = await safe(() => token.balanceOf(aToken), 0n);
    const totalAToken = await safe(() => new Contract(aToken, TOKEN_ABI, provider).totalSupply(), 0n);
    const stableDebt = data.stableDebtTokenAddress === '0x0000000000000000000000000000000000000000' ? 0n : await safe(() => new Contract(data.stableDebtTokenAddress, TOKEN_ABI, provider).totalSupply(), 0n);
    const variableDebt = data.variableDebtTokenAddress === '0x0000000000000000000000000000000000000000' ? 0n : await safe(() => new Contract(data.variableDebtTokenAddress, TOKEN_ABI, provider).totalSupply(), 0n);
    let price = null;
    let source = null;
    if (oracleAddress) {
      const oracle = new Contract(oracleAddress, ORACLE_ABI, provider);
      price = await safe(() => oracle.getAssetPrice(asset));
      source = await sourceInfo(await safe(() => oracle.getSourceOfAsset(asset)));
    }
    const config = data.configuration.data;
    result.reserves.push({
      asset,
      symbol: await safe(() => token.symbol(), asset),
      decimals,
      active: flag(config, 56),
      frozen: flag(config, 57),
      borrowingEnabled: flag(config, 58),
      ltvBps: str((config & 0xffffn) * 1n),
      liquidationThresholdBps: str(((config >> 16n) & 0xffffn) * 1n),
      liquidationBonusBps: str(((config >> 32n) & 0xffffn) * 1n),
      aToken,
      cash: str(cash),
      cashFormatted: formatUnits(cash, decimals),
      aTokenTotalSupply: str(totalAToken),
      stableDebtTotalSupply: str(stableDebt),
      variableDebtTotalSupply: str(variableDebt),
      oraclePrice: str(price),
      source,
    });
  }
  out.pools[name] = result;
  console.log('POOL', name, 'paused', result.paused, 'reserves', result.reserves.length);
  for (const reserve of result.reserves) {
    console.log('RESERVE', name, reserve.symbol, 'active', reserve.active, 'frozen', reserve.frozen, 'cash', reserve.cashFormatted, 'debt', (BigInt(reserve.stableDebtTotalSupply) + BigInt(reserve.variableDebtTotalSupply)).toString(), 'price', reserve.oraclePrice);
  }
}
const scanRange = BigInt(process.env.SCAN_RANGE || '500000');
const scanBorrowers = process.env.SCAN_BORROWERS !== '0';
if (scanBorrowers) {
  for (const [name, address] of Object.entries(POOLS)) {
    const result = out.pools[name];
    if (!result.reserves.some((r) => BigInt(r.stableDebtTotalSupply) + BigInt(r.variableDebtTotalSupply) > 0n)) continue;
    const pool = new Contract(address, POOL_ABI, provider);
    const borrowers = new Set();
    const to = BigInt(blockNumber);
    const from = to > scanRange ? to - scanRange : 0n;
    let chunk = 10000n;
    let cursor = from;
    let complete = true;
    while (cursor <= to) {
      const end = cursor + chunk - 1n > to ? to : cursor + chunk - 1n;
      try {
        const logs = await pool.queryFilter(pool.filters.Borrow(), Number(cursor), Number(end));
        for (const log of logs) borrowers.add(log.args.user);
        cursor = end + 1n;
      } catch (error) {
        if (chunk > 500n) chunk /= 2n;
        else { complete = false; console.error('Borrow log scan incomplete', name, cursor.toString(), String(error).slice(0, 200)); cursor = end + 1n; }
      }
    }
    result.borrowers = {
      fromBlock: str(from), toBlock: str(to), complete,
      uniqueBorrowerCount: borrowers.size, scanned: [], liquidatable: [],
    };
    for (const borrower of [...borrowers].slice(0, 100)) {
      const account = await safe(() => pool.getUserAccountData(borrower));
      if (!account) continue;
      const item = {
        account: borrower,
        totalCollateral: str(account[0]), totalDebt: str(account[1]),
        currentLiquidationThreshold: str(account[3]), healthFactor: str(account[5]),
      };
      result.borrowers.scanned.push(item);
      if (account[1] > 0n && account[5] < 1000000000000000000n) result.borrowers.liquidatable.push(item);
    }
    console.log('BORROWERS', name, borrowers.size, 'liquidatable', result.borrowers.liquidatable.length);
  }
}
fs.mkdirSync(new URL('../evidence/', import.meta.url), { recursive: true });
const output = new URL(`../evidence/triage-${blockNumber}.json`, import.meta.url);
fs.writeFileSync(output, JSON.stringify(out, null, 2) + '\n');
console.log('EVIDENCE', output.pathname);
