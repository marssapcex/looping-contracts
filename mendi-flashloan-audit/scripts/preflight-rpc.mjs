const rpc = process.env.RPC_URL;
const blockNumber = Number(process.env.BLOCK ?? 32540628);
if (!rpc) throw new Error('Set RPC_URL');
if (!Number.isSafeInteger(blockNumber) || blockNumber <= 0) throw new Error('Invalid BLOCK');

const tag = `0x${blockNumber.toString(16)}`;
const unitroller = '0x1b4d3b0421dDc1eB216D230Bc01527422Fb93103';
const calls = [
  { jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] },
  { jsonrpc: '2.0', id: 2, method: 'eth_getBlockByNumber', params: [tag, false] },
  { jsonrpc: '2.0', id: 3, method: 'eth_getCode', params: [unitroller, tag] },
  { jsonrpc: '2.0', id: 4, method: 'eth_call', params: [{ to: unitroller, data: '0x7dc0d1d0' }, tag] },
];

const response = await fetch(rpc, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(calls),
  signal: AbortSignal.timeout(25_000),
});
if (!response.ok) throw new Error(`HTTP ${response.status}`);
const body = await response.json();
if (!Array.isArray(body) || body.length !== calls.length) throw new Error('RPC does not support the required JSON-RPC batch');
const byId = new Map(body.map(item => [item.id, item]));
for (const item of body) if (item.error) throw new Error(`RPC id ${item.id}: ${JSON.stringify(item.error)}`);
if (byId.get(1)?.result !== '0xe708') throw new Error(`Wrong chain: ${byId.get(1)?.result}`);
const block = byId.get(2)?.result;
if (!block?.hash || Number.parseInt(block.number, 16) !== blockNumber) throw new Error('Pinned block unavailable');
if (!byId.get(3)?.result || byId.get(3).result === '0x') throw new Error('Unitroller bytecode unavailable at pinned block');
const oracleWord = byId.get(4)?.result;
if (!oracleWord || oracleWord === '0x' || BigInt(oracleWord) === 0n) throw new Error('Pinned eth_call(oracle()) failed or returned zero');
console.log(JSON.stringify({ rpc, chainId: 59144, block: { number: blockNumber, tag, hash: block.hash, timestamp: Number.parseInt(block.timestamp, 16) }, oracle: `0x${oracleWord.slice(-40)}` }, null, 2));
