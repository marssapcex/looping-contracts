#!/usr/bin/env bash
# SomniaLend pinned-fork runner.
#
# THE ONE THING THAT MATTERS: the forge binary must send plain hex block numbers, not EIP-1898
# block objects. Somnia rejects the object form with -32602 and the fork dies on the first
# account read with "failed to get account for 0x0000...0000".
#
# Two ways to satisfy that:
#   1. use forge <= 1.7.x            (this script checks the version and refuses to guess)
#   2. keep any forge version and run the bundled proxy:
#          node eip1898-proxy.mjs &
#          FORK_URL=http://127.0.0.1:8546 ./run-fork.sh sweep
#
# NOTE ON foundryup: modern foundryup (2.x) does NOT install old versions with `-v`. It only
# knows stable/nightly. Use the exact-version release tarball instead, or the proxy.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

: "${SOMNIA_FORK_BLOCK:?export SOMNIA_FORK_BLOCK=<block; get it with: cast block-number --rpc-url \$SOMNIA_RPC_URL>}"
: "${SOMNIA_RPC_URL:=https://api.infra.mainnet.somnia.network}"
FORK_URL="${FORK_URL:-$SOMNIA_RPC_URL}"

FORGE="${FORGE:-forge}"
if ! command -v "$FORGE" >/dev/null 2>&1; then
  echo "forge not found on PATH." >&2
  exit 127
fi

VERSION_LINE="$("$FORGE" --version | head -1)"
VERSION="$(printf '%s' "$VERSION_LINE" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
MAJOR="${VERSION%%.*}"
MINOR="$(printf '%s' "$VERSION" | cut -d. -f2)"

if [ -z "$VERSION" ]; then
  echo "could not parse forge version from: $VERSION_LINE" >&2
  exit 1
fi

USING_PROXY=0
case "$FORK_URL" in
  http://127.0.0.1*|http://localhost*) USING_PROXY=1 ;;
esac

if [ "$MAJOR" -gt 1 ] || { [ "$MAJOR" -eq 1 ] && [ "$MINOR" -ge 8 ]; }; then
  if [ "$USING_PROXY" -eq 0 ]; then
    cat >&2 <<EOF
ERROR: forge $VERSION sends EIP-1898 block objects, which the Somnia RPC rejects (-32602).
       The fork will fail on the first account read. You have two options:

  A) Serve the fork through the bundled rewriting proxy (keeps forge $VERSION):
       node eip1898-proxy.mjs --port 8546 &
       FORK_URL=http://127.0.0.1:8546 ./run-fork.sh ${1:-sweep}

  B) Install the exact 1.7.1 release (foundryup 2.x cannot do this, it only has stable/nightly):
       curl -L -o f.tar.gz https://github.com/foundry-rs/foundry/releases/download/v1.7.1/foundry_v1.7.1_darwin_arm64.tar.gz
       mkdir -p ~/.foundry/v1.7.1 && tar xzf f.tar.gz -C ~/.foundry/v1.7.1
       FORGE=~/.foundry/v1.7.1/forge ./run-fork.sh ${1:-sweep}
     (use darwin_amd64 / linux_amd64 / linux_arm64 to match your machine)

EOF
    exit 3
  fi
  echo "warning: forge $VERSION with the rewriting proxy — ok, the proxy strips the object form." >&2
fi

MODE="${1:-sweep}"
mkdir -p results evidence
LOG="evidence/${MODE}-${SOMNIA_FORK_BLOCK}.log"

FORK_ARGS=(--fork-url "$FORK_URL" --fork-block-number "$SOMNIA_FORK_BLOCK")

run() {
  # The fork is created from the CLI. The test's setUp only asserts that a fork exists, so the
  # block number has exactly one source of truth and cannot drift between the two.
  "$FORGE" test "${FORK_ARGS[@]}" --match-test "$1" -vv 2>&1 | tee "$LOG"
}

case "$MODE" in
  recon)   run test_recon_exact_live_configuration ;;
  control) run test_control_no_trade_no_oracle_delta ;;
  sweep)   run test_sweep_atomic_directions ;;
  poc)     run test_attack ;;
  unit)    "$FORGE" test --match-contract "SomniaLendHarnessUnitTest|RehearsalTest|EconomicsTest" -vv 2>&1 | tee "$LOG" ;;
  all)
    ./run-fork.sh recon
    ./run-fork.sh control
    ./run-fork.sh sweep
    ;;
  *)
    echo "usage: $0 [recon|control|sweep|poc|all|unit]" >&2
    exit 2
    ;;
esac
