#!/usr/bin/env bash
# SomniaLend pinned-fork runner.
#
# Hard requirement: Forge <= 1.7.x. The Somnia RPC rejects EIP-1898 block objects, which
# Forge 1.8+ sends on every fork state read, so the fork dies with
#   "failed to get account for 0x0000...0000: -32602 invalid parameters"
# Install the pinned toolchain with:  foundryup -v 1.7.1
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

: "${SOMNIA_RPC_URL:?export SOMNIA_RPC_URL=https://api.infra.mainnet.somnia.network}"
: "${SOMNIA_FORK_BLOCK:?export SOMNIA_FORK_BLOCK=<block; use: cast block-number --rpc-url \$SOMNIA_RPC_URL>}"

FORGE="${FORGE:-forge}"
if ! command -v "$FORGE" >/dev/null 2>&1; then
  echo "forge not found on PATH. Install the pinned version: foundryup -v 1.7.1" >&2
  exit 127
fi

if ! "$FORGE" --version | grep -qE 'Version: 1\.[0-7]\.'; then
  echo "WARNING: $("$FORGE" --version | head -1) is not in the 1.x <= 1.7 range." >&2
  echo "         Somnia rejects EIP-1898 block objects; Forge 1.8+ cannot fork it." >&2
fi

MODE="${1:-sweep}"
mkdir -p results evidence
LOG="evidence/${MODE}-${SOMNIA_FORK_BLOCK}.log"

case "$MODE" in
  recon)
    "$FORGE" test --match-test test_recon_exact_live_configuration -vv 2>&1 | tee "$LOG"
    ;;
  control)
    "$FORGE" test --match-test test_control_no_trade_no_oracle_delta -vvv 2>&1 | tee "$LOG"
    ;;
  sweep)
    "$FORGE" test --match-test test_sweep_atomic_directions -vv 2>&1 | tee "$LOG"
    ;;
  all)
    "$0" recon
    "$0" control
    "$0" sweep
    ;;
  unit)
    "$FORGE" test --match-contract SomniaLendHarnessUnitTest -vv 2>&1 | tee "$LOG"
    ;;
  *)
    echo "usage: $0 [recon|control|sweep|all|unit]" >&2
    exit 2
    ;;
esac
