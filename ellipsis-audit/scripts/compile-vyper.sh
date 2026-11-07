#!/bin/sh
# Reproduce exact token/pool artifacts without Foundry auto-detection.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
V0211=${VYPER_0211:-"$ROOT/../.audit-tools/vyper-0.2.11/bin/vyper"}
V034=${VYPER_034:-"$ROOT/../.audit-tools/vyper-0.3.4/bin/vyper"}
"$V0211" --version
"$V034" --version
"$V0211" -f combined_json "$ROOT/vyper/EllipsisToken.vy" > "$ROOT/evidence/token-compile.json"
"$V034" -f combined_json "$ROOT/vyper/CurveCryptoSwap2ETH.vy" > "$ROOT/evidence/curve-compile.json"
V0211="$V0211" V034="$V034" ROOT="$ROOT" python3 - <<'PY'
import os, subprocess
from pathlib import Path
root = Path(os.environ['ROOT'])
for compiler, stem in [(os.environ['V0211'], 'token'), (os.environ['V034'], 'curve')]:
    source = root / 'vyper' / ('EllipsisToken.vy' if stem == 'token' else 'CurveCryptoSwap2ETH.vy')
    for fmt, suffix in [('bytecode', 'bytecode'), ('bytecode_runtime', 'runtime')]:
        # Strip only compiler output whitespace so Foundry vm.parseBytes accepts the file.
        output = subprocess.check_output([compiler, '-f', fmt, str(source)], text=True).strip()
        (root / 'evidence' / f'{stem}.{suffix}').write_text(output)
PY
