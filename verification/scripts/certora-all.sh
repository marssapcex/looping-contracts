#!/usr/bin/env bash
# Chạy TẤT CẢ spec. Gọi từ đâu cũng được:
#   CERTORAKEY=xxx bash verification/scripts/certora-all.sh
# hoặc chạy 1 spec:
#   bash verification/scripts/certora-all.sh ghost
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER_DIR="$(dirname "$SELF_DIR")"
cd "$VER_DIR" || exit 1

# --- kiểm tra môi trường trước khi đốt credit ------------------------------
if ! command -v certoraRun >/dev/null; then
  # most common cause: installed already, but the venv is not active in this shell
  for cand in "$HOME/certora-env/bin/certoraRun" "$HOME/.local/bin/certoraRun"; do
    if [ -x "$cand" ]; then
      echo "!! certoraRun có ở $cand nhưng chưa activate. Chạy:"
      echo "   source $(dirname "$(dirname "$cand")")/bin/activate"
      echo "   bash verification/scripts/certora-all.sh"
      exit 1
    fi
  done
  echo "!! chưa cài certora-cli. Chạy:"
  echo "   python3 -m venv ~/certora-env && source ~/certora-env/bin/activate"
  echo "   pip install certora-cli solc-select"
  exit 1
fi
[ -n "${CERTORAKEY:-}" ] || { echo "!! thiếu CERTORAKEY (export CERTORAKEY=...)"; exit 1; }
[ -d node_modules ] || { echo "!! thiếu node_modules. Chạy: bash verification/scripts/bootstrap.sh"; exit 1; }
command -v solc >/dev/null && echo "==> solc: $(solc --version | tail -1)"

# --- chọn spec -------------------------------------------------------------
ALL="ghost withdrawal winddown accounting transitions params"
if [ $# -gt 0 ]; then SET="$*"; else SET="$ALL"; fi

for name in $SET; do
  conf="certora/conf/${name}.conf"
  if [ ! -f "$conf" ]; then
    echo "!! không thấy $conf — tên đúng: $ALL"
    continue
  fi
  echo
  echo "==============================================================="
  echo "==> $conf"
  echo "==============================================================="
  certoraRun "$conf"
  rc=$?
  # 0 = VERIFIED hết, 1 = có VIOLATED/TIMEOUT, khác = lỗi cấu hình
  echo "--- $name exit=$rc (0=VERIFIED, 1=VIOLATED/TIMEOUT)"
done
