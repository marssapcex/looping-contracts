#!/usr/bin/env bash
# Empirical pre-check: real bytecode, scripted adversarial sequences.
set -euo pipefail
cd "$(dirname "$0")/.."
node scripts/compile.js
node scripts/audit.js
node scripts/audit2.js
node scripts/audit3.js
