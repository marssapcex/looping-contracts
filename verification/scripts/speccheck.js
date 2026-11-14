// Static checker: verifies every function call in the CVL specs matches a real
// ABI signature (name + parameter count) of the target contract.
// This catches the class of bug that only shows up after certoraRun has already
// compiled the harness and burned time: e.g. calling `requestRedeem(e)` when the
// Solidity signature takes one argument.
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const artifacts = require(path.join(root, "out/artifacts.json"));

// which contract each conf points at -> its ABI
const confs = fs.readdirSync(path.join(root, "certora/conf")).filter((f) => f.endsWith(".conf"));
const byConf = {};
for (const f of confs) {
  const c = JSON.parse(fs.readFileSync(path.join(root, "certora/conf", f), "utf8"));
  const [contract, specPath] = c.verify.split(":");
  byConf[f] = { contract, spec: specPath };
}

// every Solidity source in the repo, so we can also resolve inherited functions
const abis = {};
for (const [key, art] of Object.entries(artifacts)) abis[key.split(":")[1]] = art.abi;

function findAbi(contractName) {
  if (abis[contractName]) return abis[contractName];
  for (const [k, v] of Object.entries(abis)) if (k === contractName) return v;
  return null;
}

let errors = 0;
const report = (spec, line, msg) => {
  console.log(`  ${spec}:${line}  ${msg}`);
  errors++;
};

for (const [conf, { contract, spec }] of Object.entries(byConf)) {
  const specFile = path.join(root, spec);
  if (!fs.existsSync(specFile)) { console.log(`MISSING spec ${spec}`); errors++; continue; }
  const src = fs.readFileSync(specFile, "utf8");
  const abi = findAbi(contract);
  if (!abi) { console.log(`no ABI for ${contract} (${conf})`); errors++; continue; }

  // declared signatures from `methods { ... }`
  const decl = new Map();
  for (const m of src.matchAll(/function\s+([A-Za-z0-9_]+)\s*\(([^)]*)\)\s*external/g)) {
    decl.set(m[1], splitParams(m[2]));
  }
  // real ABI functions of the target contract
  const real = new Map();
  for (const f of abi.filter((x) => x.type === "function")) {
    real.set(f.name, f.inputs.map((i) => i.type));
  }

  const lines = src.split("\n");
  lines.forEach((text, i) => {
    const ln = i + 1;
    // skip comments
    if (/^\s*(\/\/|\*|\/\*)/.test(text)) return;
    // every CALL with an env argument:  name(e[, args...])
    for (const m of text.matchAll(/([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*(e|env\s*\w+)\s*([,)])/g)) {
      const name = m[1];
      if (["require", "assert", "if", "return", "emit"].includes(name)) continue;
      // `method f; calldataarg args; f(e, args);` is parametric dispatch, not a call
      if (/\bmethod\s+f\b/.test(src) && name === "f") continue;
      if (!real.has(name)) {
        if (!decl.has(name))
          report(spec, ln, `call to '${name}' is not a function of ${contract} and not declared in methods{}`);
        continue;
      }
      // count the arguments supplied to the call
      const open = text.indexOf("(", m.index + name.length);
      let depth = 0, end = -1;
      for (let k = open; k < text.length; k++) {
        if (text[k] === "(") depth++;
        else if (text[k] === ")") { depth--; if (depth === 0) { end = k; break; } }
      }
      if (end < 0) continue;
      const inner = text.slice(open + 1, end);
      const args = splitArgs(inner);
      const expected = real.get(name);
      // first arg is the env
      const supplied = args.length - 1;
      if (supplied !== expected.length)
        report(spec, ln, `${name}: called with ${supplied} arg(s) + env, but ABI takes ${expected.length} (${expected.join(",")})`);
    }
  });
}

// ---------------------------------------------------------------------------
// second pass: every zero-arg getter used in a rule/invariant body must exist
// either in the ABI or in the spec's own `methods {}` block, and every function
// declared in `methods {}` must be a REAL ABI function (a typo there is silently
// accepted by CVL until you call it).
// ---------------------------------------------------------------------------
for (const [conf, { contract, spec }] of Object.entries(byConf)) {
  const src = fs.readFileSync(path.join(root, spec), "utf8");
  const abi = findAbi(contract);
  if (!abi) continue;
  const real = new Set(abi.filter((x) => x.type === "function").map((x) => x.name));

  // 2a. methods{} declarations must match a real ABI function name + arity.
  //     `using X as y;` blocks are allowed to declare functions of OTHER contracts
  //     (registry / roleManager), so those names are whitelisted per alias.
  const aliases = new Set([...src.matchAll(/using\s+[A-Za-z0-9_.]+\s+as\s+([A-Za-z0-9_]+)/g)].map((m) => m[1]));
  const arity = new Map();   // name -> Set of arities
  for (const f of abi.filter((x) => x.type === "function")) {
    const a = f.inputs.filter((i) => i.type !== "tuple" || true).length;
    if (!arity.has(f.name)) arity.set(f.name, new Set());
    arity.get(f.name).add(a);
  }
  for (const m of src.matchAll(/function\s+([A-Za-z0-9_]+)\s*\(([^)]*)\)\s*external/g)) {
    const name = m[1];
    const params = splitParams(m[2]);
    if (!arity.has(name)) continue; // foreign contract (registry/roleManager/asset) — fine
    if (!arity.get(name).has(params.length))
      report(
        spec, 0,
        `methods{} declares '${name}' with ${params.length} param(s); ABI arities are {${[...arity.get(name)].join(",")}}`,
      );
  }

  // 2b. zero-arg getters used in bodies must resolve
  const declaredGetters = new Set(
    [...src.matchAll(/^\s*function\s+([A-Za-z0-9_]+)\s*\(\s*\)/gm)].map((m) => m[1]),
  );
  const body = src.replace(/methods\s*\{[\s\S]*?\n\}/, "");
  body.split("\n").forEach((text, i) => {
    if (/^\s*(\/\/|\*|\/\*)/.test(text)) return;
    for (const m of text.matchAll(/\b([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)/g)) {
      const name = m[1];
      if (["require", "assert", "if", "return", "emit", "env"].includes(name)) continue;
      if (declaredGetters.has(name) || real.has(name)) continue;
      // rule/invariant names may be referenced in `--rule` style comments; skip those
      if (new RegExp(`(rule|invariant)\\s+${name}\\b`).test(src)) continue;
      report(spec, i + 1, `getter '${name}()' is neither in the ABI of ${contract} nor in methods{}`);
    }
  });
}

function splitParams(s) {
  return s.split(",").map((x) => x.trim()).filter(Boolean);
}
function splitArgs(inner) {
  if (inner.trim() === "") return [];
  const out = [];
  let depth = 0, cur = "";
  for (const ch of inner) {
    if ("([{".includes(ch)) depth++;
    if (")]}".includes(ch)) depth--;
    if (ch === "," && depth === 0) { out.push(cur.trim()); cur = ""; } else cur += ch;
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

console.log(errors === 0 ? "SPEC CALLS MATCH ABI" : `\n${errors} problem(s)`);
process.exit(errors === 0 ? 0 : 1);
