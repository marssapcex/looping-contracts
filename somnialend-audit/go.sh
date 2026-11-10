#!/usr/bin/env bash
# One-command runner for the SomniaLend PoC.
#
#   ./go.sh            # resolves the fork block, starts the proxy, runs the test
#   ./go.sh -vvvv      # extra args go straight to forge test
#
# It handles the three things that are easy to get wrong by hand:
#   1. SOMNIA_FORK_BLOCK empty (a new shell loses the export) -> fetch it from the RPC
#   2. port 8546 already held by an older proxy           -> reuse it, or free it
#   3. Somnia rejects EIP-1898 block objects, forge >= 1.8 sends them -> run the proxy
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PORT="${SOMNIA_PROXY_PORT:-8546}"
: "${SOMNIA_RPC_URL:=https://api.infra.mainnet.somnia.network}"
export SOMNIA_RPC_URL
: "${FORGE:=forge}"

# whichever name the proxy has in this folder
PROXY_JS=""
for f in proxy.mjs eip1898-proxy.mjs; do [ -f "$f" ] && { PROXY_JS=$f; break; }; done
[ -n "$PROXY_JS" ] || { echo "!! neither proxy.mjs nor eip1898-proxy.mjs found here" >&2; exit 1; }

post() { # url payload
  curl -s --max-time "${3:-20}" -H 'content-type: application/json' --data "$2" "$1" 2>/dev/null || true
}

rpc_upstream() { post "$SOMNIA_RPC_URL" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}"; }

# Is something already answering JSON-RPC on the local port?
proxy_alive() {
  post "http://127.0.0.1:$PORT" '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' 2 \
    | grep -q '"result"'
}

if [ -z "${SOMNIA_FORK_BLOCK:-}" ]; then
  echo "== SOMNIA_FORK_BLOCK not set, asking $SOMNIA_RPC_URL ..."
  hex=$(rpc_upstream eth_blockNumber | sed -n 's/.*"result":"\(0x[0-9a-fA-F]*\)".*/\1/p')
  [ -n "$hex" ] && SOMNIA_FORK_BLOCK=$(printf '%d' "$hex")
fi
if [ -z "${SOMNIA_FORK_BLOCK:-}" ]; then
  echo "!! could not read a block number from $SOMNIA_RPC_URL" >&2
  echo "   set it by hand:  export SOMNIA_FORK_BLOCK=<block>" >&2
  exit 2
fi
export SOMNIA_FORK_BLOCK
echo "== fork block $SOMNIA_FORK_BLOCK"

PROXY=""
if proxy_alive; then
  echo "== proxy already listening on :$PORT, reusing it"
else
  # port taken but not answering: a stale proxy. Free it before we bind.
  if command -v lsof >/dev/null 2>&1; then
    STALE=$(lsof -ti "tcp:$PORT" 2>/dev/null | tr '\n' ' ')
    if [ -n "${STALE// /}" ]; then
      echo "== freeing port :$PORT (pid ${STALE% })"
      kill $STALE 2>/dev/null || true
      sleep 0.7
    fi
  fi
  echo "== starting $PROXY_JS :$PORT -> $SOMNIA_RPC_URL"
  node "$PROXY_JS" --upstream "$SOMNIA_RPC_URL" --port "$PORT" &
  PROXY=$!
  for _ in $(seq 1 40); do proxy_alive && break; sleep 0.25; done
  if ! proxy_alive; then
    echo "!! proxy did not come up on :$PORT" >&2
    kill "$PROXY" 2>/dev/null || true
    exit 3
  fi
fi

cleanup() { [ -n "$PROXY" ] && kill "$PROXY" 2>/dev/null || true; }
trap cleanup EXIT

"$FORGE" test \
  --fork-url "http://127.0.0.1:$PORT" \
  --fork-block-number "$SOMNIA_FORK_BLOCK" \
  --match-test test_attack "$@"
