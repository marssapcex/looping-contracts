# Provenance and assurance levels

## 1. User-supplied text

`reference/` is a transcription of the user-supplied `ResilientOracle`, `Transient`, and interfaces. It is **USER_SUPPLIED_TEXT_NOT_CHAIN_VERIFIED**. It is not represented as deployed Venus bytecode.

The exact supplied `ResilientOracle` does not compile with solc 0.8.25. `scripts/check-supplied.sh` preserves the expected compiler failure in `evidence/supplied-compile.log`.

`contracts/ResilientOracle.sol` is a **test-only minimal reconstruction**. `TESTABLE_SOURCE_DIFF.patch` records every change:

1. Add the missing `PausableUpgradeable` import/inheritance.
2. Make internally called `updateAssetPrice` and `getPrice` `public`, not `external`.
3. Consume both `_getMainOraclePrice` return values and convert `validated == false` to an invalid price.
4. Move snapshot updating out of the view read path and into the uncached update path.
5. Make price helpers `view`.

These changes are necessary to obtain a valid executable model. They are not claimed to be fixes to a live deployment.

## 2. Venus upstream and deployment artifacts

- Repository: `https://github.com/VenusProtocol/oracle`
- Current upstream snapshot used for comparison: `590123b6ead459e570acc9f4a52ae359b02708a9` (`UPSTREAM_COMMIT`).
- Exact source revision matching the BSC ResilientOracle implementation artifact: `edb889bd094d11e3c828e0d0e4f752d1bf005f4b` (`DEPLOYED_SOURCE_COMMIT`).
- `deployed-source/` contains that exact revision and is what `upstream-poc/` tests.
- `upstream/deployments/bscmainnet/` contains Venus's GitHub deployment artifacts.

The implementation metadata's expected `ResilientOracle.sol` keccak was checked against 130 Git revisions. Exactly one matched: `edb889b…`. See `evidence/deployment-source-match.json`. The diff to the current upstream snapshot is comment-only (`DEPLOYED_TO_DEVELOP.diff`).

Artifact addresses recorded by Venus:

| Contract | Address | Artifact deployment block |
|---|---:|---:|
| ResilientOracle proxy | `0x6592b5DE802159F3E74B2486b091D11a8256ab8A` | 28,525,796 |
| ResilientOracle implementation | `0x90d840f463c4E341e37B1D51b1aB16Bc5b34865C` | 51,270,703 |
| BoundValidator proxy | `0x6E332fF0bB52475304494E4AE5063c1051c7d735` | 28,525,784 |
| BoundValidator implementation | `0xbE4176749a74320641e24102B2Af2Ca37FAF2DF1` | 51,270,638 |

The proxy address matches the address visible in the user's screenshot. This is an artifact/address match, not proof of the proxy's implementation at a user-selected live block.

## 3. Source and bytecode verification result

`node scripts/verify-artifacts.mjs` checks local source keccak values against deployment metadata and compares locally compiled runtime bytecode with the artifacts.

Results in `evidence/source-integrity.json`:

- ResilientOracle: all locally checked source hashes match; 8,678 runtime bytes; executable bytecode matches the artifact; exactly the 32-byte IPFS metadata digest differs.
- BoundValidator: all locally checked source hashes match; 3,537 runtime bytes; executable bytecode matches the artifact; exactly the 32-byte IPFS metadata digest differs.
- The metadata-only difference results from harness source paths/remappings. Compiler is solc `0.8.25+commit.b61c2a91`, EVM Cancun, optimizer 200, no via-IR.

Assurance level: **SOURCE_AND_EXECUTABLE_BYTECODE_MATCH_TO_GITHUB_DEPLOYMENT_ARTIFACTS_NOT_LIVE_CHAIN_VERIFIED**.

A pinned-block RPC check is still required for the EIP-1967 implementation slots and on-chain code hashes. No live pool configuration or mainnet exploit is asserted here.

## 4. Test dependencies

- Forge/Anvil 1.7.1
- solc 0.8.25
- `@openzeppelin/contracts` and `@openzeppelin/contracts-upgradeable` 4.9.6
- `@venusprotocol/governance-contracts` 2.15.0
- ethers 6.15.0 for local JSON-RPC evidence

All oracle price sources other than the artifact-matched BoundValidator are explicit test mocks. Mock acceptance, mock liquidity, and local Anvil transactions are not mainnet exploit evidence.

## 5. Economic evidence boundary

No permissionless withdrawal, flash-loan repayment, available-liquidity check, collateral/borrow-cap check, exit simulation, or signed net P&L has been performed for a live pool. Gross borrow, protocol bad debt, cached notional, and attacker proceeds must remain separate in any subsequent pool review.
