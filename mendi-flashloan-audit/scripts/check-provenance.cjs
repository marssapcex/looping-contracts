const fs = require('fs');
const path = require('path');
const { ethers } = require(path.resolve(__dirname, '../../.audit-tools/venus-oracle-build/node_modules/ethers'));
const root = path.resolve(__dirname, '..');
const deploymentRoot = path.join(root, 'upstream/deployments/linea');
const selected = [
  ['Comptroller.json', 'contracts/Comptroller.sol'],
  ['Unitroller.json', 'contracts/Unitroller.sol'],
  ['MixedPriceOracleV2.json', 'contracts/PriceOracle/MixedPriceOracleV2.sol'],
  ...fs.readdirSync(deploymentRoot)
    .filter(name => /^CErc20Upgradable_.*_Implementation\.json$/.test(name))
    .sort()
    .map(name => [name, 'contracts/CErc20Upgradable.sol']),
];
const checks = [];
for (const [name, mainSource] of selected) {
  const artifact = JSON.parse(fs.readFileSync(path.join(deploymentRoot, name), 'utf8'));
  const metadata = JSON.parse(artifact.metadata);
  const dependencies = [];
  for (const [sourcePath, info] of Object.entries(metadata.sources)) {
    if (!sourcePath.startsWith('contracts/')) continue;
    const localPath = path.join(root, 'upstream', sourcePath);
    if (!fs.existsSync(localPath)) {
      dependencies.push({ sourcePath, status: 'MISSING_LOCAL' });
      continue;
    }
    const localKeccak256 = ethers.keccak256(fs.readFileSync(localPath));
    dependencies.push({
      sourcePath,
      status: info.keccak256 === localKeccak256 ? 'MATCH' : 'MISMATCH',
      artifactKeccak256: info.keccak256,
      localKeccak256,
    });
  }
  const main = dependencies.find(item => item.sourcePath === mainSource);
  checks.push({
    artifact: name,
    address: artifact.address,
    transactionHash: artifact.transactionHash || artifact.receipt?.transactionHash,
    blockNumber: artifact.receipt?.blockNumber,
    compiler: metadata.compiler.version,
    mainSource,
    mainSourceMatches: main?.status === 'MATCH',
    dependencies,
  });
}
const ctokenClasses = Object.fromEntries(checks.filter(item => item.artifact.startsWith('CErc20Upgradable_')).map(item => {
  const dependency = item.dependencies.find(entry => entry.sourcePath === 'contracts/CToken.sol');
  return [item.artifact, { address: item.address, cTokenSourceStatus: dependency?.status, artifactKeccak256: dependency?.artifactKeccak256, localKeccak256: dependency?.localKeccak256 }];
}));
const output = {
  upstreamCommit: fs.readFileSync(path.join(root, 'UPSTREAM_COMMIT'), 'utf8').trim(),
  allMainSourcesMatch: checks.every(item => item.mainSourceMatches),
  checks,
  ctokenClasses,
};
fs.mkdirSync(path.join(root, 'evidence'), { recursive: true });
fs.writeFileSync(path.join(root, 'evidence/source-provenance.json'), `${JSON.stringify(output, null, 2)}\n`);
console.log(JSON.stringify({
  allMainSourcesMatch: output.allMainSourcesMatch,
  artifacts: checks.map(item => ({
    artifact: item.artifact,
    mainSourceMatches: item.mainSourceMatches,
    mismatchedDependencies: item.dependencies.filter(x => x.status !== 'MATCH'),
  })),
}, null, 2));
if (!output.allMainSourcesMatch || checks.some(item => item.dependencies.some(x => x.status === 'MISSING_LOCAL'))) process.exitCode = 1;
