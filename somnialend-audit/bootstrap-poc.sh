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
cp "$HERE/eip1898-proxy.mjs" "$HERE/go.sh" "$DEST/"

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

chmod +x "$DEST/go.sh"
chmod +x "$DEST/eip1898-proxy.mjs"

echo "created $DEST"
echo "next:  export SOMNIA_FORK_BLOCK=\$(cast block-number --rpc-url https://api.infra.mainnet.somnia.network)"
echo "       cd $DEST && ./go.sh"
