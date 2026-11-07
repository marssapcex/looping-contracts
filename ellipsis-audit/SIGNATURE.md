# Ellipsis / BSC Audit Signature

Date: 2026-11-06 (Asia/Ho_Chi_Minh)  
Chain: BNB Smart Chain (expected chain ID 56)  
Audit mode: permissionless loss paths only; local exact-source models  
Mainnet pin: **UNAVAILABLE — no defensible block number**  
Mainnet promotion: **blocked until a pinned-fork withdrawal and positive all-cost P&L**

This directory is independent of the completed HyperLend artifacts in the repository root. No Ellipsis result is applied to HyperLend, and no HyperLend TVL or RPC result is used here.

## 1. Deployed identities and exact source

| Component | Address | Exact source used | Compiler |
|---|---|---|---|
| EPS / Curve LP token | `0xA7f552078dcC247C2684336020c03648500C6d9F` | `vyper/EllipsisToken.vy`; flattened reference `reference/EllipsisToken.deployed.vy` | Vyper `0.2.11+commit.5db35ef` |
| EPS staker / `MultiFeeDistribution` | `0x4076CC26EFeE47825917D0feC3A79d0bB9a6bB5c` | `contracts/MultiFeeDistribution.sol`; flattened reference `reference/MultiFeeDistribution.deployed.sol` | Solidity `0.7.6+commit.7338295f`, optimizer on, 200 runs, default EVM |
| `LpTokenStaker` | `0xcce949De564fE60e7f96C85e55177F8B9E4CF61b` | `contracts/LpTokenStaker.sol`; flattened reference `reference/LpTokenStaker.deployed.sol` | Solidity 0.7.6 family; deployed body is authoritative |
| Two-asset CryptoSwap proxy | `0xFD4afeAc39DA03a05f61844095A75c4fB7D766DA` | `vyper/CurveCryptoSwap2ETH.vy`; flattened reference `reference/CurveCryptoSwap2ETH.deployed.vy` | Vyper `0.3.4+commit.f31f0ec` |
| CryptoSwap implementation | `0x1E97685aa5b1F9c6Dc44aF52a1BBa8049F43226c` | Same supplied implementation source; runtime must be read back before any deployment claim | Vyper 0.3.4 |

Source provenance:

- Ellipsis deployed Solidity matches initial repository commit [`0e22a202e52bbf6d439e296e0cbe4da307720df0`](https://github.com/ellipsis-finance/ellipsis/commit/0e22a202e52bbf6d439e296e0cbe4da307720df0).
- Upstream HEAD `6bdf7788020695b72034f5c9f1fda11c5e3cefb7` was reviewed only to identify later deltas; it is **not** silently substituted for deployed code. Later Solidity commits include `5b2b4d7` (immutable), `0e56409` (private mappings), `ea9799a` (`addReward` period finish), `a59887e` (zero allocation guard), and `7242419` (oracle array size).
- Flattened BscScan source was obtained from `tangtj/bsc-contract-database` commit [`7f04f769d370ea91c581748a74896497ea919a9c`](https://github.com/tangtj/bsc-contract-database/tree/7f04f769d370ea91c581748a74896497ea919a9c/source).
- `evidence/source-integrity.json` records file hashes and target-body comparisons. All four target bodies match; the Vyper token differs only by final newline, and CryptoSwap is byte-identical.
- OpenZeppelin imports are exactly `3.4.0`; `package-lock.json` pins npm solc 0.7.6 and that dependency.

## 2. Screenshot transcription and Anvil read-back status

All eight originals are preserved under `evidence/images/`; `evidence/images/SHA256SUMS` pins their hashes. The browser clock shows 17:34–17:36 on 2026-11-06 local time. **No screenshot shows a block number.** Displayed values below are screenshots/live-web observations, not archive state and not Anvil state.

| Image | Meaningful displayed values | Required Anvil read-back | Status |
|---|---|---|---|
| 1 — EPS staker overview | Address `0x4076…bB5c`; `0 BNB`; token holdings `>$1,789,802.60`; `118,478,579.571097 EPS` at `$0.0144`; `87,853.80128908 BUSD` at `$0.9996`; about `0.269938 ETH` shown in the corresponding live holdings | `balanceOf(staker)` for EPS/BUSD/ETH and native balance | **NOT RUN — archive RPC unavailable; values unverified by Anvil** |
| 2 — EPS staker verified code | Contract `MultiFeeDistribution`; Exact Match; solc `v0.7.6+commit.7338295f`; optimizer `Yes with 200 runs`; `default evmVersion`; license `None` | Compile exact source/settings and compare deployed runtime at a pin | Exact source compiled locally; **runtime comparison NOT RUN** |
| 3 — EPS read contract | `decimals=18`; `name=Ellipsis`; `symbol=EPS`; raw `totalSupply=723701571799788763488815703`; `minter=0x4076CC26EFeE47825917D0feC3A79d0bB9a6bB5c` | `decimals()`, `name()`, `symbol()`, `totalSupply()`, `minter()` | **NOT RUN — no pin/RPC** |
| 4 — EPS token overview | Token address `0xA7f5…6d9F`; `0 BNB`; holdings `>$6,722.14`; `5,131.71 BUSD`; `908.8588762 BSC-USD`; `36,003.8437218 EPS`; EPS price `$0.0144` | Native/token balances and token metadata | **NOT RUN; spam/other token holdings excluded from P&L** |
| 5 — LP staker reads | `poolLength=12`; `rewardMinter=0x4076…bB5c`; raw `rewardsPerSecond=0`; `startTime=1616532028` (`2021-03-23T20:40:28Z`); raw `totalAllocPoint=560382448701586517805099` | `poolLength()`, `rewardMinter()`, `rewardsPerSecond()`, `startTime()`, `totalAllocPoint()` | **NOT RUN; zero rate is screenshot-only** |
| 6 — EPS staker reads I | `lockDuration=7862400 s`; raw `lockedSupply=9423897111197939036477641`; `owner=0x6fcb98bA1badb5F334572f9F7Ef63BB42D356CFd` | Constants, supplies, `owner()` | **NOT RUN** |
| 7 — EPS staker reads II | `rewardsDuration=604800 s`; `stakingToken=0xA7f5…6d9F`; raw staker `totalSupply=114072429165525786343320116` | Constants, staking token, `totalSupply()` | **NOT RUN** |
| 8 — CryptoSwap proxy overview | Proxy `0xFD4afeAc39DA03a05f61844095A75c4fB7D766DA`; implementation `0x1E97685aa5b1F9c6Dc44aF52a1BBa8049F43226c`; native `0.000005168676486611 BNB`; token holdings `>$3,558.44`; `3.71562201 BNBx` at `$769.40`; `700.07077129 BSC-USD` at `$0.999`; `0.00000333 BTCB` at `$75,992.3613`; `0.08920204 STG` at `$0.1421`; default EVM, license None | Proxy/implementation code, `mid_fee`, token/coins, balances, D and virtual price | Full addresses confirmed by live BscScan; **no archive/Anvil verification** |

Additional unit notes:

- EPS uses 18 decimals. Raw EPS staker `totalSupply` and `lockedSupply` are not the token's global `totalSupply`; they are separate accounting values.
- `totalAllocPoint` aggregates raw LP amounts and must not be assigned a single token/USD unit without reading each pool.
- Screenshot BNB prices vary between `$693.56` and `$694.18`; they are not a block-correlated price oracle and are not used to claim P&L.
- The screenshot portfolio totals are not protocol-wide TVL. They do not satisfy the tier-D requirement of measured TVL ≥ `$1e9`.

### Required fork read-back

`scripts/fork-readback.sh` is the immediate next check. It refuses missing/non-numeric pins and never substitutes `latest`:

```sh
BSC_ARCHIVE_RPC='https://your-archive-endpoint' PIN=12345678 \
  ./scripts/fork-readback.sh
```

It performs only `eth_chainId`, `eth_getCode`, and `eth_call` reads for every identity above, including the LP emission schedule and Curve initialization/pool state. It uses no keys and broadcasts nothing.

## 3. RPC and tool record

- `https://bsc-dataseed.binance.org`: `eth_chainId` attempt failed before a response with curl 35 / `SSL_ERROR_SYSCALL` (TLS handshake EOF).
- `https://bsc-rpc.publicnode.com`: same failure.
- Consequently there is no verified chain ID response, archive block, deployed bytecode, storage, oracle value, token balance, or mainnet P&L. `latest` was not substituted.
- Foundry 1.7.1: available. Exact npm solc wrapper: `scripts/solc`, no compiler fallback.
- Vyper 0.2.11 and 0.3.4: both compiled successfully under Python 3.11 using pip's `--ignore-requires-python`; exact compiler versions are recorded above and in `run.log:3`.
- Slither 0.11.6 / Crytic Compile: ran on exact Solidity; 94 outputs are logged in `evidence/slither.log` and triaged in `CANDIDATES.md`.
- `tool_unavailable: vulnchain corpus absent`; no corpus IDs, mechanism-matched incident claims, or historical loss figures are asserted (`run.log:6`).
- Foundry Solar lint supports Solidity ≥0.8 only; this is a tool limitation, not a source finding (`run.log:7`).
- `tool_unavailable: echidna — binary unavailable and no supported reachable release source; continued with Foundry fuzzing`.
- `tool_unavailable: medusa — binary unavailable and no supported reachable release source; continued with Foundry fuzzing`.
- `tool_unavailable: aderyn — the earlier GitHub release download failed certificate verification; exact solc, Slither, and Foundry were used instead`.

## 4. Prior-audit provenance and scope matching

The supplied PDFs were read from raw GitHub content:

- Hacken, Ellipsis v1, 2021-04-01: [`010421_Hacken_Ellipsis_SC_Audit_Report.pdf`](https://github.com/ellipsis-finance/ellipsis-audits/blob/d25ccf060be7cd92b2293317ebb619f93e078aa2/010421_Hacken_Ellipsis_SC_Audit_Report.pdf), blob `e850391c1a38fecf51c635d39c0cef961b34f940`. Its duplicate-LP, malicious-token, and oracle findings depend on owner-added assets/configuration; those admin-rug paths are excluded here.
- PeckShield, Ellipsis **V2 staking**, 2022-03-26: [`PeckShield-Audit-Report-EllipsisV2Staking-v1.0.pdf`](https://github.com/ellipsis-finance/ellipsis-audits/blob/2e611d9fed351a3fddc26c70eb5a182b04bfc4c6/PeckShield-Audit-Report-EllipsisV2Staking-v1.0.pdf), blob `b0808ed681f3d331f523b01649da08079c2a0581`. It reviews a different `LPStaking` implementation. Its `adjustedSupply` emergency-withdrawal issue is not copied to this v1 `LpTokenStaker`, which does reduce `allocPoint`/`totalAllocPoint`.

No statement in this audit relies on an unverified incident loss amount.
