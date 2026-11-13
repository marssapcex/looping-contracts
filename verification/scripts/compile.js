// Minimal replacement for `forge build` when Foundry/its RPC is unavailable:
// resolves imports through node_modules, compiles with solc 0.8.35, writes artifacts.
const fs = require("fs");
const path = require("path");
const solc = require("solc");

const root = path.resolve(__dirname, "..");
const srcDir = path.join(root, "src");
const outDir = path.join(root, "out");

function walk(dir, acc = []) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, acc);
    else if (e.name.endsWith(".sol")) acc.push(p);
  }
  return acc;
}

const HARNESS_DIRS = [path.join(root, "certora", "harness")];
const sources = {};
for (const f of walk(srcDir)) {
  sources[path.relative(root, f).split(path.sep).join("/")] = { content: fs.readFileSync(f, "utf8") };
}
for (const d of HARNESS_DIRS) {
  for (const f of walk(d)) {
    sources[path.relative(root, f).split(path.sep).join("/")] = { content: fs.readFileSync(f, "utf8") };
  }
}

function findImport(importPath) {
  if (importPath.startsWith("@")) {
    const p = path.join(root, "node_modules", importPath);
    return { contents: fs.readFileSync(p, "utf8") };
  }
  const p = path.join(root, importPath);
  if (fs.existsSync(p)) return { contents: fs.readFileSync(p, "utf8") };
  return { error: "not found: " + importPath };
}

const input = {
  language: "Solidity",
  sources,
  settings: {
    optimizer: { enabled: true, runs: 1 },
    // Legacy pipeline: keeps the harness deployable under EIP-170 so the local audit
    // rig can actually run it. The Certora confs use `solc_via_ir: true` instead,
    // because *their* output selection (evm.assembly / functionDebugData /
    // transientStorageLayout) pushes LoanVaultDeposits.sol:407 into "stack too deep"
    // on the legacy pipeline. The Prover never deploys, so it does not care about
    // code size. Force viaIR here only if you want byte-identical artifacts.
    viaIR: process.env.VIA_IR === "1",
    evmVersion: "cancun",
    outputSelection: { "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object", "metadata"] } },
  },
};

const out = JSON.parse(solc.compile(JSON.stringify(input), { import: findImport }));
let errors = (out.errors || []).filter((e) => e.severity === "error");
for (const e of out.errors || []) {
  if (e.severity === "error") console.error(e.formattedMessage);
}
if (errors.length) {
  console.error(`\nFAILED: ${errors.length} error(s)`);
  process.exit(1);
}

fs.mkdirSync(outDir, { recursive: true });
const idx = {};
for (const [file, contracts] of Object.entries(out.contracts || {})) {
  for (const [name, c] of Object.entries(contracts)) {
    idx[`${file}:${name}`] = { abi: c.abi, bytecode: c.evm.bytecode.object, deployed: c.evm.deployedBytecode.object };
  }
}
fs.writeFileSync(path.join(outDir, "artifacts.json"), JSON.stringify(idx, null, 1));
const size = fs.statSync(path.join(outDir, "artifacts.json")).size;
console.log(`OK: compiled ${Object.keys(sources).length} sources -> ${Object.keys(idx).length} contracts (${(size/1024/1024).toFixed(2)} MB)`);
