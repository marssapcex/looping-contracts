#!/usr/bin/env node
// Local solc-js adapter. No compiler download or version selection is hidden here.
const fs = require("fs");
const path = require("path");
const solc = require("./node_modules/solc");

if (process.argv.includes("--version")) {
  console.log("solc, the solidity compiler commandline interface");
  console.log("Version: " + solc.version());
  process.exit(0);
}
if (!process.argv.includes("--standard-json")) {
  console.error("solc wrapper supports --standard-json only");
  process.exit(2);
}

const roots = [
  process.cwd(),
  path.resolve(process.cwd(), ".."),
  path.resolve(process.cwd(), "../lib/forge-std/src"),
];

function importFile(importPath) {
  for (const root of roots) {
    const candidate = path.resolve(root, importPath);
    try {
      if (fs.statSync(candidate).isFile()) {
        return { contents: fs.readFileSync(candidate, "utf8") };
      }
    } catch (_) {}
  }
  return { error: "File not found: " + importPath };
}

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => (input += chunk));
process.stdin.on("end", () => {
  try {
    const standardJson = JSON.parse(input);
    for (const [sourceName, source] of Object.entries(standardJson.sources || {})) {
      if (!path.isAbsolute(sourceName)) continue;
      const relativeName = path.relative(process.cwd(), sourceName);
      if (!standardJson.sources[relativeName]) standardJson.sources[relativeName] = source;
      delete standardJson.sources[sourceName];
    }
    process.stdout.write(solc.compile(JSON.stringify(standardJson), { import: importFile }));
  } catch (error) {
    console.error(error.stack || error);
    process.exit(1);
  }
});
