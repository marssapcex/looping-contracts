const fs = require('fs');
const path = require('path');
const solc = require('solc');
const root = path.resolve(__dirname, '..');
const files = [];
for (const dir of ['contracts', 'poc']) {
  for (const name of fs.readdirSync(path.join(root, dir))) {
    if (name.endsWith('.sol')) files.push(`${dir}/${name}`);
  }
}
const sources = {};
for (const file of files) sources[file] = {content: fs.readFileSync(path.join(root, file), 'utf8')};
const input = {
  language: 'Solidity', sources,
  settings: {
    optimizer: {enabled: true, runs: 200}, viaIR: true, evmVersion: 'cancun',
    outputSelection: {'*': {'*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object']}}
  }
};
function resolveImport(importPath) {
  const candidate = path.join(root, importPath.startsWith('@openzeppelin/') ? `node_modules/${importPath}` : importPath);
  try { return {contents: fs.readFileSync(candidate, 'utf8')}; }
  catch (error) { return {error: `${candidate}: ${error.message}`}; }
}
const output = JSON.parse(solc.compile(JSON.stringify(input), {import: resolveImport}));
let errors = 0;
for (const error of output.errors || []) {
  console.log(error.formattedMessage);
  if (error.severity === 'error') errors++;
}
if (errors) process.exit(1);
fs.writeFileSync(path.join(root, 'evidence/compiled.json'), JSON.stringify(output));
const artifacts = {};
for (const [file, contracts] of Object.entries(output.contracts)) {
  for (const [name, artifact] of Object.entries(contracts)) {
    artifacts[name] = {source: file, abi: artifact.abi, bytecode: artifact.evm.bytecode.object, runtime: artifact.evm.deployedBytecode.object};
  }
}
fs.writeFileSync(path.join(root, 'evidence/artifacts.json'), JSON.stringify(artifacts));
console.log(`solc ${solc.version()}; compiled ${Object.keys(artifacts).length} contracts; optimizer 200; cancun`);
