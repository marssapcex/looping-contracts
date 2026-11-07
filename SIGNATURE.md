# Audit signature

## Scope and provenance

| parameter | value | source / verification |
|---|---|---|
| audited repository | `marssapcex/looping-contracts` (upstream link supplied: `hyperlendx/looping-contracts`) | local Git remote |
| audited commit | `241867af5b14616539790d2b52f3fa4d3902db86` | `git rev-parse HEAD` |
| branch | `arena/ee2289ba-looping-contracts` | `git status --short --branch` |
| production sources | `contracts/**/*.sol` | 20 source contracts; interfaces included in compile |
| Solidity | exactly `0.8.24+commit.e11b9ed9.Emscripten.clang` | `scripts/solc --version`; every production implementation pins `pragma solidity 0.8.24` |
| code generation | `via_ir = true`, Cancun (required for transient storage) | `hardhat.config.js`; `foundry.toml` |
| OpenZeppelin | `^5.1.0`, installed by the lockfile | `package.json`, `package-lock.json` |
| image inputs | none supplied | no image-to-anvil parameters exist |
| supplied Delpho PDF | Delpho core commit `e3c0c863…`, final `a5398428…`; different repository and scope | supplied PDF, Introduction / Scope |
| supplied TVL context | Delpho TVL displayed as $578,627 on 2026-11-06 | supplied DefiLlama page; **not used as looping-contracts TVL or as a price feed** |

## Toolchain

The exact captured versions are in `leads/toolchain.txt`.

| tool | status |
|---|---|
| Forge / Cast / Anvil | `1.7.1`, commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`; installed from npm platform binaries after GitHub's release-asset redirect was blocked |
| solc | exact 0.8.24 npm Emscripten binary, invoked through the tracked `scripts/solc` standard-JSON wrapper |
| Node | `v22.22.3` |
| Hardhat | project version `2.22.16`; compiler download unavailable, so Foundry is used |
| Slither | `0.11.6`; output in `leads/slither.txt` and `leads/slither-detectors.txt` |
| crytic-compile | `0.4.2` |
| forge-std | repository-pinned submodule `3b20d60d14b343ee4f908cb8079495c07f5e8981` (`v1.9.6`); `.gitmodules` path corrected for initialization |
| Aderyn | `tool_unavailable: @cyfrin/aderyn 0.6.8 postinstall attempted GitHub release download and failed with unable to verify the first certificate; no detector output is claimed` |
| Echidna | `tool_unavailable: echidna not installed; GitHub release assets resolve to a blocked host` |
| Medusa | `tool_unavailable: medusa not installed; GitHub release assets resolve to a blocked host` |
| vulnchain corpus | `tool_unavailable: vulnchain/data/corpus.json and vulnchain/incidents are absent from the checkout`; no incident claims are invented |

## Fork / pin status

A real HyperEVM fork could not be created in this sandbox. Both the Foundry installer and Hardhat compiler attempted blocked hosts; separately, the required RPC check failed without sending a transaction:

```text
$ cast chain-id --rpc-url https://rpc.hyperliquid.xyz/evm
Error: error sending request for url (https://rpc.hyperliquid.xyz/evm)
... client error (Connect) ... tls handshake eof
```

Therefore:

- **mainnet pin block:** `UNAVAILABLE`; no block number is fabricated and no `latest` state is substituted.
- **chain ID expected from repository:** `999` (`hardhat.config.js`), not verified by RPC.
- **PoC execution state:** local EVM, block 1 unless a test explicitly rolls it; this is a unit/model harness, **not represented as a real fork**.
- **broadcasts / mainnet transactions / real private keys:** zero. All PoCs use Foundry's in-process local EVM.
- **mainnet impact and USD valuation:** unmeasured. No Chainlink feed address or decimals are asserted because this repository does not name one for the adapter balances and the RPC is unavailable.
- **tier D:** not run; the required on-chain TVL measurement is unavailable. The Delpho web TVL is a different protocol and cannot qualify tier D.

`STATE0` for the local model is each Foundry test's post-`setUp` snapshot. Tests use real local EVM calls for minting, approval, route setup, swaps, and sweeps. No `vm.store`, admin prank, or unpause is used. Fixed external routers, USDT0, WHYPE, and the depositor are replaced with explicitly tagged `vm.etch` mocks; the in-scope production contract code is not modified. These mocks are exactly why the results remain leads rather than fork findings.

## Build reproduction

```bash
npm ci
git submodule update --init --recursive
# Foundry 1.7.1 must be on PATH; scripts/solc supplies exact solc 0.8.24.
forge build --sizes
FOUNDRY_PROFILE=ci forge test --match-path 'poc/*.t.sol' -vvv
```

For the optional pinned-fork replay, provide the environment documented at the top of `poc/MainnetReplay.sol` and run `forge test --match-path poc/MainnetReplay.sol -vvv`. That file is intentionally outside the default `*.t.sol` glob so a missing mainnet environment cannot be mistaken for a passing proof.

The build uses the same exact compiler and `viaIR` setting as `hardhat.config.js`; it does not claim byte-for-byte equality with any deployed contract because no deployment address/bytecode was supplied or readable by RPC.
