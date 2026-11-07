# FoxLpBondsPool / BSC Audit Signature

Date: 2026-11-06 (Asia/Ho_Chi_Minh)  
Chain: BNB Smart Chain (56)  
Historical incident block: **116169049**  
Pinned pre-attack fork: **116169048**  
Current mainnet state: **unmeasured — this session's RPC handshake failed**  
Result: **FINDING-001, historical incident-backed and independently reproduced locally**

This scope is independent of the root HyperLend and `ellipsis-audit/` reports.

## 1. Identities and source provenance

| Component | Address | Source |
|---|---|---|
| `FoxLpBondsPool` proxy | `0x9fa6D8a13b35E051BFc145918db0111dEc13D1A0` | `contracts/FoxLpBondsPool.sol` + `FoxPoolBase.sol` |
| Pool implementation | `0x58E2A853BB14e46BefD3148bd4280370fEA4655A` | Same; user-supplied source matches registry body |
| Treasury proxy | `0x361d08ff43761E6a7E8Fcabe48048AE9010801cc` | `contracts/Treasury.sol` |
| Treasury implementation | `0x87614D97808DcDEcB069fe8489848fa1C001e04D` | Same |
| FOX | `0xdF81d50c6657487D19B66A1b5375E35A804Abb93` | `contracts/Fox.sol`; 18 decimals, 2.5% default sell tax |
| BSC USDT | `0x55d398326f99059fF775485246999027B3197955` | External 18-decimal token; local mock only for replay |
| Incident FOX/USDT pair | `0xAAb18bCDEe287AEA288c0560612cAadf7c328803` | Real reserves reproduced; `poc/AMM.sol` is a local 0.25%-fee surrogate |
| Pancake router | `0x10ED43C718714eb63d5aA57B78B54704E256024E` | External; local router implements the used V2 paths |
| Referral proxy / implementation | `0xAa237ABB282Ae5476c1D22dE7e84fa7cbeEeDC9F` / `0x6d4174E48e6a930d6acc2BE5139607b1eB08EE60` | `contracts/Referral.sol` |
| Log | `0xF9b59f62E4fE55C5851E3b947236cb5958446F84` | `contracts/Log.sol` |
| Staked FOX | `0x1ACfB89f020305EAf8c90493E76A846a4149C00A` | `contracts/StakedFox.sol` |
| Reward FOX | `0x0FF6a23CfaA850242ce50639243c999b5b693E65` | `contracts/RewardFox.sol` |
| Original caller EOA | `0x5670d36f00bc7F6860B6AfdDb288E3668efc0ef9` | Replayed as `msg.sender` and `tx.origin` in canonical PoC |
| Original attack contract | `0x3A82A2A77061017927e5331fFFd07c0308a1D2DA` | Exact original calldata in `poc/FoxLpBondsPoolFork.t.sol` |

Attack transaction: `0x8e1775cbfd44db29744cc6687ff1822d2c47321de6e94062f789ad6181ad5514` (`run.log:8`).

Exact source provenance:

- `sanbir/evm-hack-registry` commit `a35f3640aae29f3b1f40441dfa2ab350f04c0bce`, directory `2026-08-FoxMarket_exp/sources` (`run.log:6`).
- Canonical original-transaction PoC: [DeFiHackLabs PR #1209](https://github.com/SunWeb3Sec/DeFiHackLabs/pull/1209), merge `04a31c7c5c4dcb1b6ff75c283c9b9b6bf54ef988` (`run.log:7`). Preserved at `reference/FoxLpBondsPool_exp.canonical.sol`.
- Source metadata identifies `v0.8.28+commit.7893614a`, optimizer enabled, 200 runs. Local compilation additionally requires `viaIR: true`; this is recorded as a build requirement, not invented metadata (`run.log:9`).
- `evidence/source-integrity.json` records all source hashes and proxy/implementation identities. Deployed-bytecode comparison was **not run** because RPC failed before `eth_chainId`.
- Mechanism-matched incident corpus is present in `reference/`; no `vulnchain` statement is needed or invented.

## 2. Screenshot transcription and Anvil status

All six originals are preserved in `evidence/images/` with SHA-256 hashes. They show 18:43–18:47 local time on 2026-11-06, **no block number**, and no archive proof.

| Image | Meaningful displayed content | Required Anvil read-back | Status |
|---|---|---|---|
| 9 — source | BscScan Standard JSON source, `FoxPoolBase.sol` and `FoxLpBondsPool.sol`; lines 180–205 show `UserStake` storing precomputed `stakeAmount` | Compare implementation runtime and proxy implementation slot at incident pin | Exact source compiled locally; **runtime comparison NOT RUN** |
| 10 — reads I | `BASE_100=10000`; `INVITER_REWARD_MIN_AMOUNT=1000000000000000000000` (1,000e18); `INVITER_REWARD_RATIO=300`; `MIN_AMOUNT=100000000000000000000` (100e18); `TIME_BASE=28800`; `discountRateFrom=0` | Same getters on **proxy**, not zeroed implementation | **NOT RUN; constants match source** |
| 11 — reads II | `discountRateTo=0`; `discountRatioLogAddress=0`; `foxToken=0` | Initialized proxy values and discount log | **NOT RUN; these are implementation-tab zero values, not live proxy configuration** |
| 12 — reads III | `governance`, `logAddress`, `lpFoxToken`, `owner`, `referralAddress`, and `rewardRateFrom` all zero | Proxy owner/config and reward endpoints | **NOT RUN; zero implementation storage is expected and is not an initialization vulnerability** |
| 13 — GeckoTerminal | FOX/USD Pancake V2 (BSC), price `$0.8098`, MCAP `≈$2.31M`, liquidity `$1.6M`, 24h volume `$11.9K`, holders `7.3K`, age `1 month`; 2026-11-06 11:45:19 UTC | Current pair address/reserves, token supply, protocol-wide TVL | **NOT RUN; current displayed values are not incident-pin state or tier-D TVL proof** |
| 14 — current pair page | Contract `0xF3a57b805eE825F033465E79B4D0948A76c34aa1`; `0 BNB`; token holdings `$812,659.56`; `813,484.43514036 BSC-USD` at `$0.999`; created by `foxmarket: Deployer` about 41 days earlier | Native/token balances and identity at a current pin | **NOT RUN; this is not the incident pair `0xAAb18…8803` and its balances are not used for incident P&L** |

Additional units:

- Screenshot constants use raw 18-decimal amounts: minimum stake 100 USDT; inviter threshold 1,000 USDT; inviter ratio `300/10000 = 3%`; time base `28,800 seconds = 8 hours`.
- Incident reserves are 18-decimal USDT/FOX: `2,786,697.198864505157273333 USDT` and `496,041.716814196640205248 FOX`, obtained from the pinned registry trace, not screenshot 14 (`run.log:17-18` and registry output).
- The displayed current `$1.6M` liquidity does not establish protocol-wide TVL ≥ `$1e9`; tier D is skipped (`run.log:146,155`).
- Screenshot 13's current FOX price around `$0.81` differs materially from the incident quote around `$5.44`; no continuity or current exploitability is inferred.

### Immediate pinned read-back and original-transaction replay

```sh
BSC_ARCHIVE_RPC='https://your-bsc-archive' ./scripts/fork-readback.sh
BSC_ARCHIVE_RPC='https://your-bsc-archive' ./scripts/run-pinned-replay.sh
```

`fork-readback.sh` is fixed to block 116169048 and refuses other pins. It reads code, proxy configuration, reserves, treasury authorization, FOX tax state, attack balance, and transaction/receipt. `run-pinned-replay.sh` executes the exact original calldata with no capital/referral/storage override. Neither script has a `latest` fallback or broadcasts a transaction.

## 3. Evidence hierarchy and profit definitions

1. **Historical live trace / canonical PoC:** exact original calldata at block-1, asserting about 112,976 USDT gained by the original attack contract (`run.log:158-159`).
2. **Registry pinned fork:** real deployed proxy/implementation/treasury/pair at block 116169048, 450M USDT surrogate capital and explicitly fresh referral setup; logged 530,941.023056701789655683 USDT profit (`run.log:157`). This is third-party output, not this session's RPC run.
3. **This session's exact-source local EVM:** real deployed Solidity bodies via ERC1967 proxies, incident reserves, observed discounted quote and FOX sell tax; independently reaches the same raw 530,941.023056701789655683 USDT profit and inverse pair delta (`run.log:20-26`). The 450M minted balance and owner referral binding are tagged local setup surrogates; Pancake is a faithful model without `feeTo`, so LP token amounts may differ while reserves/P&L match.
4. **L2Beat gross victim loss:** 677,549.050517106599255604 USDT / `$676,520.83` (`run.log:160`). This is pair depletion, not attacker net.

The reported approximately `$118.7K` corresponds to the live attacker-focused net-loss account, not the 677.5K gross depletion and not the local 450M model. The independent article's roughly 677.5K figure is before the complete flash-loan fee stack and must not be called net profit.

## 4. Tool and RPC record

- Both RPC attempts failed with curl 35 / `SSL_ERROR_SYSCALL` before `eth_chainId` (`run.log:2`). No current code/storage/balance/oracle state is claimed.
- Foundry 1.7.1 release download reached the release-asset host and returned EOF. `tool_unavailable` is recorded at `run.log:3`; local execution used exact solc-js and PyEVM instead.
- Exact local versions: solc 0.8.28, web3 7.16.0, eth-tester 0.13.0b1, py-evm 0.12.1b1 (`run.log:5`).
- Slither 0.11.6 installed, but compilation could not run: Foundry auto-detection lacked `forge`; forced solc-js does not support native `--combined-json`. See `run.log:4` and `evidence/slither.log`. This tool failure is not a source finding.
- Exact source builds 57 contracts with optimizer 200/Cancun/viaIR (`run.log:9`). No compiler substitution was made.

## 5. Scope exclusions

Dust-only rounding, admin-rug claims, MEV/sandwich assertions, self-harm, and generic gas-only DoS are not promoted. The flash loans provide scale but are not themselves the vulnerability. The finding is the protocol's quote-then-trade accounting and same-transaction liquid mint, validated by the permissionless historical call chain.
