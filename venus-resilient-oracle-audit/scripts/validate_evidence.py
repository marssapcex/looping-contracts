#!/usr/bin/env python3
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def load(name):
    return json.loads((ROOT / "evidence" / name).read_text())

def test_count(name):
    text = (ROOT / "evidence" / name).read_text()
    match = re.search(r"Suite result: ok\. (\d+) passed; 0 failed; 0 skipped", text)
    assert match, f"missing successful suite result in {name}"
    return int(match.group(1))

supplied = test_count("supplied-tests.log")
deployed = test_count("deployed-source-tests.log")
assert supplied == 29, supplied
assert deployed == 18, deployed
assert "whenNotPaused" in (ROOT / "evidence/supplied-compile.log").read_text()

integrity = load("source-integrity.json")
for name in ("resilientOracle", "boundValidator"):
    item = integrity[name]
    assert item["bytecode"]["executableMatch"] is True
    assert item["bytecode"]["metadataOnlyDifference"] is True
    assert item["sourceHashes"] and all(entry["match"] for entry in item["sourceHashes"])

transients = {}
for name in ("transient-evm.json", "upstream-transient-evm.json"):
    item = load(name)
    assert all(item["assertions"].values()), name
    assert item["sameTransaction"]["secondRead"] == "100"
    assert item["separateTransactions"]["readAfterSourceMutationTransaction"] == "200"
    transients[name] = item["assertions"]

result = {
    "status": "PASS",
    "suppliedReconstructionTests": supplied,
    "deploymentArtifactMatchedTests": deployed,
    "exactSuppliedSourceExpectedCompileFailure": True,
    "executableBytecodeMatchesDeploymentArtifacts": True,
    "transientAssertions": transients,
    "livePoolOrProfitClaim": False,
}
(ROOT / "evidence/validation.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
