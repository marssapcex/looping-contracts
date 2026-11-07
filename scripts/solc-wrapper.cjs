#!/usr/bin/env node
// Exact-solc standard-JSON adapter for Foundry in environments where the
// native Solidity binary download is unavailable. Requires the declared npm
// devDependency solc@0.8.24; it does not download or select another version.
const solc = require("../node_modules/solc");

if (process.argv.includes("--version")) {
  console.log("solc, the solidity compiler commandline interface");
  console.log("Version: " + solc.version());
  process.exit(0);
}

if (!process.argv.includes("--standard-json")) {
  console.error("audit solc wrapper supports --standard-json only");
  process.exit(2);
}

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => (input += chunk));
process.stdin.on("end", () => {
  try {
    process.stdout.write(solc.compile(input));
  } catch (error) {
    console.error(error.stack || error);
    process.exit(1);
  }
});
