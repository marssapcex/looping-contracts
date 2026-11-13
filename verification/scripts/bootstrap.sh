#!/usr/bin/env bash
# Chạy TỪ ROOT repo (looping-contracts), không phải trong verification/.
#   bash verification/scripts/bootstrap.sh
# Script tự cd vào đúng thư mục, cài deps, compile, chạy audit.
set -uo pipefail

# --- 1. luôn đứng ở verification/ bất kể gọi từ đâu -------------------------
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER_DIR="$(dirname "$SELF_DIR")"
cd "$VER_DIR" || { echo "!! không tìm thấy thư mục verification"; exit 1; }
echo "==> đang ở: $(pwd)"

# --- 2. kiểm tra đây có phải project verification không --------------------
if [ ! -f certora/conf/ghost.conf ]; then
  echo "!! certora/conf/ghost.conf không tồn tại."
  echo "   Mày đang ở nhánh cũ. Chạy: git pull origin master"
  exit 1
fi

# --- 3. node deps (KHÔNG phải package.json ở root) -------------------------
if [ ! -d node_modules/@openzeppelin/contracts-upgradeable ]; then
  echo "==> npm install (trong verification/)"
  npm install --no-audit --no-fund || exit 1
else
  echo "==> deps đã có, bỏ qua npm install"
fi

# --- 4. compile ------------------------------------------------------------
echo "==> compile"
node scripts/compile.js || exit 1

# --- 5. audit --------------------------------------------------------------
echo "==> audit"
node scripts/audit.js  | grep -E '^FAIL|=== '
node scripts/audit2.js | grep -E '^FAIL|=== '
node scripts/ghostcheck.js | tail -2

echo
echo "==> xong. Chạy Prover bằng: bash verification/scripts/certora-all.sh"
