#!/usr/bin/env bash
# Creates a standalone folder that can run the SomniaLend PoC with no other setup.
#
#   ./bootstrap-poc.sh ~/my-poc
#   cd ~/my-poc && ./go.sh
set -euo pipefail
DEST="${1:-$HOME/somnialend-poc}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$DEST/test" "$DEST/lib"

cp "$HERE/test/SingleFile.t.sol" "$DEST/test/"
cp "$HERE/eip1898-proxy.mjs" "$DEST/"

# forge-std: reuse the repo copy if present, otherwise fetch the pinned commit.
if [ -f "$HERE/../lib/forge-std/src/Test.sol" ]; then
  rm -rf "$DEST/lib/forge-std"
  cp -r "$HERE/../lib/forge-std" "$DEST/lib/forge-std"
else
  git clone --depth 1 https://github.com/foundry-rs/forge-std "$DEST/lib/forge-std"
fi

cat > "$DEST/foundry.toml" <<'TOML'
[profile.default]
src = "src"
test = "test"
out = "out"
libs = ["lib"]
solc = "0.8.24"
optimizer = true
optimizer_runs = 200
TOML

mkdir -p "$DEST/src"
printf '// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n' > "$DEST/src/Empty.sol"

cat > "$DEST/go.sh" <<'GO'
#!/usr/bin/env bash
# Runs the PoC against Somnia. Works with ANY forge version: the fork goes through the local
# proxy, which rewrites the EIP-1898 block objects that Somnia's RPC rejects.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
: "${SOMNIA_RPC_URL:=https://api.infra.mainnet.somnia.network}"
: "${SOMNIA_FORK_BLOCK:?export SOMNIA_FORK_BLOCK=<block>   (get it: cast block-number --rpc-url \$SOMNIA_RPC_URL)}"

node eip1898-proxy.mjs --upstream "$SOMNIA_RPC_URL" --port 8546 & PROXY=$!
trap 'kill $PROXY 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -sf http://127.0.0.1:8546 >/dev/null && break; sleep 0.3; done

forge test --fork-url http://127.0.0.1:8546 --fork-block-number "$SOMNIA_FORK_BLOCK" \
  --match-test test_attack -vv
GO
chmod +x "$DEST/go.sh"

echo "created $DEST"
echo "next:  export SOMNIA_FORK_BLOCK=\$(cast block-number --rpc-url https://api.infra.mainnet.somnia.network)"
echo "       cd $DEST && ./go.sh"
