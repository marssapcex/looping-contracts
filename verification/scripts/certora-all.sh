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
[ -d node_modules/@openzeppelin/contracts-upgradeable ] || {
  echo "!! thiếu @openzeppelin/contracts-upgradeable. Chạy: bash verification/scripts/bootstrap.sh"; exit 1; }

# --- solc8.35 ---------------------------------------------------------------
# Certora resolves the `solc` conf value through shutil.which(), so the file must
# literally be named `solc8.35`. solc-select only ever installs a binary called
# `solc`, which is why "Cannot run solc8.35" shows up even after
# `solc-select install 0.8.35 && solc-select use 0.8.35`.
ensure_solc_shim() {
  if command -v solc8.35 >/dev/null 2>&1; then
    echo "==> solc8.35: $(command -v solc8.35)"
    return 0
  fi
  local real
  real="$(command -v solc 2>/dev/null || true)"
  if [ -z "$real" ]; then
    echo "!! không thấy solc. Chạy: solc-select install 0.8.35 && solc-select use 0.8.35"
    return 1
  fi
  local got
  got="$(solc --version 2>/dev/null | tail -1 | sed -E 's/^Version: ([0-9.]+).*/\1/')"
  if [ "$got" != "0.8.35" ]; then
    echo "!! solc đang là $got, project cần 0.8.35."
    echo "   Chạy: solc-select install 0.8.35 && solc-select use 0.8.35"
    return 1
  fi
  local dir="$HOME/.certora-bin"
  mkdir -p "$dir" && ln -sf "$real" "$dir/solc8.35" || return 1
  export PATH="$dir:$PATH"
  echo "==> tạo shim $dir/solc8.35 -> $real"
}

ensure_solc_shim || exit 1

# --- java -------------------------------------------------------------------
# certoraRun typechecks the CVL locally before uploading; without a JDK it aborts
# with "Cannot run local checks because of missing a suitable java installation".
# jdk4py ships a JRE inside a pip package, so no root/sudo is needed.
ensure_java() {
  if command -v java >/dev/null 2>&1; then
    echo "==> java: $(java -version 2>&1 | head -1)"
    return 0
  fi
  local jh
  jh="$(python3 -c 'import jdk4py,sys;print(jdk4py.JAVA_HOME)' 2>/dev/null || true)"
  if [ -n "$jh" ] && [ -x "$jh/bin/java" ]; then
    export JAVA_HOME="$jh"
    export PATH="$JAVA_HOME/bin:$PATH"
    echo "==> java (jdk4py): $($JAVA_HOME/bin/java -version 2>&1 | head -1)"
    return 0
  fi
  echo "!! chưa có java. Chọn 1 trong 2:"
  echo "   sudo apt-get install -y openjdk-21-jre-headless     # codespace/ubuntu"
  echo "   pip install jdk4py                                  # không cần sudo"
  return 1
}
ensure_java || exit 1


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
