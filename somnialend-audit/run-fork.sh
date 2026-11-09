#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
: "${SOMNIA_RPC_URL:?set SOMNIA_RPC_URL}"
: "${SOMNIA_FORK_BLOCK:?set an explicit SOMNIA_FORK_BLOCK}"
MODE="${1:-measured}"
if command -v forge >/dev/null 2>&1; then
  FORGE=forge
else
  FORGE="$PWD/tools/node_modules/@foundry-rs/forge-linux-amd64/bin/forge"
fi
mkdir -p results evidence
case "$MODE" in
  recon)
    "$FORGE" test --match-test test_recon_exact_live_configuration -vvvv 2>&1 | tee "evidence/recon-${SOMNIA_FORK_BLOCK}.log"
    ;;
  control)
    "$FORGE" test --match-test test_control_no_trade_no_oracle_delta -vvvv 2>&1 | tee "evidence/control-${SOMNIA_FORK_BLOCK}.log"
    ;;
  measured)
    "$FORGE" test --match-test 'test_(somi|usdso)_instrumented_with_loss_coverage' -vvvv 2>&1 | tee "evidence/measured-${SOMNIA_FORK_BLOCK}.log"
    ;;
  zero-seed)
    "$FORGE" test --match-test 'test_(somi|usdso)_atomic_zero_seed' -vvvv 2>&1 | tee "evidence/zero-seed-${SOMNIA_FORK_BLOCK}.log"
    ;;
  all)
    "$0" recon
    "$0" control
    "$0" measured
    "$0" zero-seed
    ;;
  *)
    echo "usage: $0 [recon|control|measured|zero-seed|all]" >&2
    exit 2
    ;;
esac
