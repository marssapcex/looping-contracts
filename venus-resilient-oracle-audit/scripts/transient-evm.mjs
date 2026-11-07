import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { ethers } = require(path.resolve(process.cwd(), '../.audit-tools/venus-oracle-build/node_modules/ethers'));
const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const provider = new ethers.JsonRpcProvider(process.env.RPC_URL || 'http://127.0.0.1:8546');
const owner = await provider.getSigner(0);
const permissionlessCaller = await provider.getSigner(1);

function artifact(source, name) {
  const value = JSON.parse(fs.readFileSync(path.join(root, 'out', source, `${name}.json`), 'utf8'));
  return new ethers.ContractFactory(value.abi, value.bytecode.object, owner);
}

async function deployed(factory, ...args) {
  const contract = await factory.deploy(...args);
  await contract.waitForDeployment();
  return contract;
}

const acm = await deployed(artifact('AuditMocks.sol', 'AllowAllAccessManager'));
const main = await deployed(artifact('AuditMocks.sol', 'MutableOracle'), 18);
const validator = await deployed(artifact('AuditMocks.sol', 'ConfigurableBoundValidator'));
const implementation = await deployed(artifact('ResilientOracle.sol', 'ResilientOracle'));
const asset = '0x000000000000000000000000000000000000A557';
const init = implementation.interface.encodeFunctionData('initialize', [acm.target, validator.target, true]);
const proxy = await deployed(artifact('AuditMocks.sol', 'DelegateProxy'), implementation.target, init);
const oracle = new ethers.Contract(proxy.target, implementation.interface, owner);
const consumer = await deployed(artifact('AuditMocks.sol', 'SameTransactionConsumer'), oracle.target, main.target);

await (await main.setPrice(asset, 100)).wait();
await (await oracle.setTokenConfig([asset, [main.target, ethers.ZeroAddress, ethers.ZeroAddress], [true, false, false]])).wait();

const sameTransaction = await consumer.cacheMutateAndRead.staticCall(asset, 200);
const sameTransactionResult = {
  firstRead: sameTransaction[0].toString(),
  sourceAfterMutation: sameTransaction[1].toString(),
  secondRead: sameTransaction[2].toString(),
};

const cacheTx = await oracle.connect(permissionlessCaller).updateAssetPrice(asset);
const cacheReceipt = await cacheTx.wait();
const cachedRead = await oracle.getPrice(asset);
const mutateTx = await main.setPrice(asset, 200);
const mutateReceipt = await mutateTx.wait();
const nextTransactionRead = await oracle.getPrice(asset);

const evidence = {
  provenance: 'TESTABLE_RECONSTRUCTION_NOT_CHAIN_VERIFIED',
  chainId: (await provider.getNetwork()).chainId.toString(),
  permissionlessCaller: await permissionlessCaller.getAddress(),
  oracle: oracle.target,
  mainOracle: main.target,
  validatorMode: 'REJECT_ALL; no Pivot is configured, so acceptance proves validator is not consulted',
  sameTransaction: sameTransactionResult,
  separateTransactions: {
    cacheTransaction: cacheReceipt.hash,
    cacheBlock: cacheReceipt.blockNumber,
    readAfterCacheTransaction: cachedRead.toString(),
    sourceMutationTransaction: mutateReceipt.hash,
    sourceMutationBlock: mutateReceipt.blockNumber,
    readAfterSourceMutationTransaction: nextTransactionRead.toString(),
  },
  assertions: {
    sameTransactionFirstValidPriceWins: sameTransactionResult.firstRead === '100' && sameTransactionResult.sourceAfterMutation === '200' && sameTransactionResult.secondRead === '100',
    separateTransactionCacheCleared: cachedRead.toString() === '100' && nextTransactionRead.toString() === '200',
  },
};

if (!Object.values(evidence.assertions).every(Boolean)) {
  throw new Error(`Transient storage assertion failed: ${JSON.stringify(evidence)}`);
}
fs.mkdirSync(path.join(root, 'evidence'), { recursive: true });
fs.writeFileSync(path.join(root, 'evidence', 'transient-evm.json'), `${JSON.stringify(evidence, null, 2)}\n`);
console.log(JSON.stringify(evidence, null, 2));
