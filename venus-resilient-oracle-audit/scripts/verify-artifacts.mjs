import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { ethers } = require(path.resolve(process.cwd(), '../.audit-tools/venus-oracle-build/node_modules/ethers'));
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const deployedSourceCommit = fs.readFileSync(path.join(root, 'DEPLOYED_SOURCE_COMMIT'), 'utf8').trim();
const revisionSearch = JSON.parse(fs.readFileSync(path.join(root, 'evidence/deployment-source-match.json'), 'utf8'));
if (!revisionSearch.matches.includes(deployedSourceCommit)) throw new Error('Selected source commit did not match deployment metadata');

function checkSourceHashes(deployment, contractName) {
  const metadata = JSON.parse(deployment.metadata);
  const checked = [];
  for (const [sourceName, entry] of Object.entries(metadata.sources)) {
    const localPath = path.join(root, 'deployed-source', sourceName);
    if (!fs.existsSync(localPath)) continue;
    const actual = ethers.keccak256(fs.readFileSync(localPath));
    checked.push({ sourceName, expected: entry.keccak256, actual, match: actual === entry.keccak256 });
  }
  if (!checked.length || checked.some(entry => !entry.match)) throw new Error(`Source hash mismatch for ${contractName}`);
  if (!checked.some(entry => entry.sourceName === `contracts/${contractName === 'ResilientOracle' ? 'ResilientOracle.sol' : 'oracles/BoundValidator.sol'}`)) {
    throw new Error(`Primary source was not checked for ${contractName}`);
  }
  return checked;
}

function compareBytecode(localArtifact, deployment) {
  const local = localArtifact.deployedBytecode.object;
  const reference = deployment.deployedBytecode;
  if (local.length !== reference.length) throw new Error('Bytecode length mismatch');
  const marker = 'a2646970667358221220';
  const markerHexOffset = local.indexOf(marker);
  if (markerHexOffset < 0 || markerHexOffset !== reference.indexOf(marker)) throw new Error('IPFS metadata marker not aligned');
  const digestStart = markerHexOffset + marker.length;
  const digestEnd = digestStart + 64;
  const differingHexOffsets = [];
  for (let i = 2; i < local.length; i += 2) {
    if (local.slice(i, i + 2) !== reference.slice(i, i + 2)) differingHexOffsets.push(i);
  }
  const metadataOnly = differingHexOffsets.every(offset => offset >= digestStart && offset < digestEnd);
  const localMasked = `${local.slice(0, digestStart)}${'0'.repeat(64)}${local.slice(digestEnd)}`;
  const referenceMasked = `${reference.slice(0, digestStart)}${'0'.repeat(64)}${reference.slice(digestEnd)}`;
  const executableMatch = localMasked === referenceMasked;
  if (!metadataOnly || !executableMatch) throw new Error('Executable bytecode mismatch');
  return {
    bytes: (local.length - 2) / 2,
    exactIncludingMetadata: local === reference,
    executableMatch,
    metadataOnlyDifference: metadataOnly,
    differingBytes: differingHexOffsets.length,
    ipfsDigestByteOffset: (digestStart - 2) / 2,
  };
}

function processContract(contractName, sourceFile, artifactFile) {
  const local = JSON.parse(fs.readFileSync(path.join(root, '../.audit-tools/venus-upstream-out', sourceFile, `${contractName}.json`), 'utf8'));
  const deployment = JSON.parse(fs.readFileSync(path.join(root, 'upstream/deployments/bscmainnet', artifactFile), 'utf8'));
  return {
    artifactAddress: deployment.address,
    artifactDeploymentBlock: deployment.receipt.blockNumber,
    artifactTransactionHash: deployment.transactionHash,
    compiler: JSON.parse(deployment.metadata).compiler.version,
    sourceHashes: checkSourceHashes(deployment, contractName),
    bytecode: compareBytecode(local, deployment),
  };
}

const evidence = {
  provenance: 'SOURCE_AND_EXECUTABLE_BYTECODE_MATCH_TO_GITHUB_DEPLOYMENT_ARTIFACTS_NOT_LIVE_CHAIN_VERIFIED',
  deployedSourceCommit,
  revisionSearch: {
    checkedRevisions: revisionSearch.checkedRevisions,
    matches: revisionSearch.matches,
  },
  resilientOracle: processContract('ResilientOracle', 'ResilientOracle.sol', 'ResilientOracle_Implementation.json'),
  boundValidator: processContract('BoundValidator', 'BoundValidator.sol', 'BoundValidator_Implementation.json'),
  liveChainCaveat: 'No pinned-block RPC check has yet proved the current proxy implementation slots or on-chain code hashes.',
};
fs.writeFileSync(path.join(root, 'evidence/source-integrity.json'), `${JSON.stringify(evidence, null, 2)}\n`);
console.log(JSON.stringify({
  resilientOracle: evidence.resilientOracle.bytecode,
  boundValidator: evidence.boundValidator.bytecode,
  deployedSourceCommit,
}, null, 2));
