const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..');
const deps = path.resolve(root, '../.audit-tools/frax-cvx-build/node_modules');
const solc = require(path.join(deps, 'solc'));

function walk(dir, prefix) {
  const result = [];
  for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
    const absolute = path.join(dir, entry.name);
    const relative = `${prefix}/${entry.name}`;
    if (entry.isDirectory()) result.push(...walk(absolute, relative));
    else if (entry.name.endsWith('.sol')) result.push(relative);
  }
  return result;
}
const files = [
  ...walk(path.join(root, 'contracts'), 'contracts'),
  ...(fs.existsSync(path.join(root, 'poc')) ? walk(path.join(root, 'poc'), 'poc') : [])
];
const sources = {};
for (const file of files) sources[file] = {content: fs.readFileSync(path.join(root, file), 'utf8')};
const input = {
  language: 'Solidity', sources,
  settings: {
    optimizer: {enabled: true, runs: 200},
    outputSelection: {'*': {'*': [
      'abi', 'storageLayout', 'evm.bytecode.object', 'evm.deployedBytecode.object',
      'evm.bytecode.srcmap', 'evm.deployedBytecode.srcmap'
    ], '': ['ast']}}
  }
};
function resolveImport(importPath) {
  const candidates = importPath.startsWith('@')
    ? [path.join(deps, importPath)]
    : [path.join(root, importPath), path.join(root, 'contracts', importPath)];
  for (const candidate of candidates) {
    try { return {contents: fs.readFileSync(candidate, 'utf8')}; } catch (_) {}
  }
  return {error: `Unable to resolve ${importPath}; tried ${candidates.join(', ')}`};
}
const output = JSON.parse(solc.compile(JSON.stringify(input), {import: resolveImport}));
let errors = 0;
let log = '';
for (const error of output.errors || []) {
  log += `${error.formattedMessage}\n`;
  if (error.severity === 'error') errors++;
}
fs.writeFileSync(path.join(root, 'evidence/build.log'), log);
if (errors) {
  console.error(log);
  process.exit(1);
}
fs.writeFileSync(path.join(root, 'evidence/compiled.json'), JSON.stringify(output));
const artifacts = {};
for (const [file, contracts] of Object.entries(output.contracts)) {
  for (const [name, artifact] of Object.entries(contracts)) {
    artifacts[`${file}:${name}`] = {
      source: file,
      abi: artifact.abi,
      bytecode: artifact.evm.bytecode.object,
      runtime: artifact.evm.deployedBytecode.object
    };
  }
}
fs.writeFileSync(path.join(root, 'evidence/artifacts.json'), JSON.stringify(artifacts));

// Crytic-compile legacy standard export: lets Slither consume this exact solc-js
// build without invoking an unavailable native solc or a different framework.
const filenames = Object.keys(output.sources).map(file => {
  const absolute = file.startsWith('@') ? path.join(deps, file) : path.join(root, file);
  return {absolute, relative: file, short: file, used: file};
});
const filenameFor = file => filenames.find(f => f.relative === file);
const standard = {
  compiler: {compiler: 'solc', version: '0.8.10', optimized: true},
  filenames,
  asts: Object.fromEntries(Object.entries(output.sources).map(([file, source]) => [file, source.ast])),
  contracts: {},
  working_dir: root,
  type: 1,
  unit_tests: []
};
for (const [file, contracts] of Object.entries(output.contracts)) {
  for (const [name, artifact] of Object.entries(contracts)) {
    standard.contracts[name] = {
      abi: artifact.abi,
      bin: artifact.evm.bytecode.object,
      'bin-runtime': artifact.evm.deployedBytecode.object,
      srcmap: artifact.evm.bytecode.srcmap || '',
      'srcmap-runtime': artifact.evm.deployedBytecode.srcmap || '',
      libraries: {},
      filenames: filenameFor(file),
      is_dependency: file.startsWith('@')
    };
  }
}
fs.writeFileSync(path.join(root, 'evidence/crytic-export.json'), JSON.stringify(standard));

const summary = `solc ${solc.version()}; compiled ${Object.keys(artifacts).length} contracts from ${files.length} source files; optimizer 200\n`;
fs.appendFileSync(path.join(root, 'evidence/build.log'), summary);
console.log(summary.trim());
