# Candidate Triage

Promotion requires a permissionless withdrawal and positive P&L. FINDING-001 additionally has exact historical transaction/pinned-fork evidence. “Rejected” here means not independently promoted; it does not certify every possible external integration.

| ID | Candidate | Disposition |
|---|---|---|
| C-01 | Pre-trade spot credit → own large swap → liquid inviter sale — `FoxLpBondsPool.sol:124-169`, `Treasury.sol:176-185` | **FINDING-001.** Historical original-calldata incident evidence plus exact-source local profit `+530941.023056701789655683 USDT`, pair delta `−530941.023056701789655683` (`run.log:20-26,157-160`). |
| C-02 | Supplied narrative: attacker pre-inflates FOX, causing larger FOX credit | **REJECTED as the incident mechanism.** Credit is inversely proportional to USDT/FOX quote. Confirmed path quotes first, then the protocol's own buy raises FOX price. The liquid reward—not the whole locked bond—is sold. |
| C-03 | Alternative pre-depress FOX quote before stake | **SUBSUMED / not separately promoted.** Lower pre-quote increases FOX units but requires cost-bearing FOX inventory/loan and repayment accounting. Campaign strategy D includes acquisition cost and tax; no distinct live incident or stronger profit is claimed. |
| C-04 | `amountOutMin=0`, liquidity minimums zero, caller max-price bypass | **NOT A STANDALONE FINDING.** Real weaknesses and defense-in-depth fixes, but generic sandwich/MEV claims are excluded. The confirmed attack needs no third-party ordering. |
| C-05 | `_usdtAmount = USDT.balanceOf(pool)` captures donations — line 142 | **UNPROVEN independently.** It includes existing USDT in credit and swap scale. Campaign strategy E charges the attacker's donation cost; free capital cannot be assumed. An accidental victim transfer could be captured, but no such balance or attacker profit is shown. |
| C-06 | `foxBalance = FOX.balanceOf(pool)` captures donated/residual FOX — lines 155-157 | **UNPROVEN independently.** Existing FOX increases LP added/burned, not a direct FOX payout. Campaign strategy F includes FOX acquisition cost; no extra free withdrawal is established. |
| C-07 | Residual FOX after `addLiquidity` is not refunded | **ACCOUNTING CONCERN, NOT PROFIT.** Residual FOX can be used by a later stake's liquidity addition, but LP is sent to DEAD and only the later stake's own 3% reward is liquid. No separate positive path demonstrated. |
| C-08 | Reentrancy through router, token, treasury, referral, or log calls | **REJECTED on supplied contracts.** No `nonReentrant` modifier, but supplied USDT/FOX/LP do not call attacker code and router/treasury/log are fixed configuration. No callback withdrawal or P&L was found. |
| C-09 | Direct call to `Treasury.lpBonds` to mint arbitrary FOX | **REJECTED.** `onlyStakingPool` checks `stakingPoolMap[msg.sender]`. Campaign has 240 explicit authorization rejections (`run.log:145`). |
| C-10 | Referral requirement is an admin gate / owner binding proves privilege exploit | **REJECTED.** Actual attack used a pre-existing referral binding and no owner call in the attack transaction. Owner binding in the registry replay is tagged setup for a fresh helper, not a mainnet privilege claim. |
| C-11 | Screenshots show zero owner/token/config, therefore uninitialized proxy takeover | **REJECTED.** Screenshots are from the implementation tab. Implementation constructors disable initializers; initialized state belongs to proxies. Exact proxy initialization works locally; no uninitialized proxy evidence. |
| C-12 | Eight-hour reward compounding loop can exceed gas | **GAS-ONLY DOS / excluded from money-loss findings.** Long histories may make views/actions expensive, but no solvent attacker withdrawal or positive P&L follows. |
| C-13 | `rewardRateTo - rewardRateFrom` underflow | **ADMIN CONFIGURATION / view-action revert.** Descending rates can revert; no attacker-controlled setter or profit path. |
| C-14 | `BASE_100 - getDiscountRate()` underflow or zero quote division | **ADMIN/CONFIGURATION REVERT.** Discount >10000 underflows; zero quote can make stake revert. No profitable withdrawal. Local fixed299 only reproduces pinned quote, not live endpoint storage. |
| C-15 | `redeem` calls treasury/token before updating `amountRedeemed`, enabling repeat principal | **REJECTED on supplied token path.** FOX/sFOX have no callbacks, stake ownership is checked, and the state update occurs in the same transaction. Linear principal arithmetic prevents cumulative redemption above stake absent a callback. |
| C-16 | Principal/reward integer truncation | **DUST-ONLY / out of scope.** No non-dust rounding drain was found. FOX sell-tax rounding is modeled exactly because it changes the canonical output by one raw unit. |
| C-17 | FOX `transferStatus` and whitelist can disable user transfers | **ADMIN CONTROL, not permissionless exploit.** No timelock; activation is immediate. Historical activation is documented in `reference/l2beat-incident.json`; current state unverified. |
| C-18 | Flash loans are themselves the vulnerability / gross 677.5K equals net profit | **REJECTED accounting claim.** Flash liquidity supplies scale; the defect is quote/trade/mint/settlement composition. Live net is about112,976.12 USDT, L2Beat gross pair loss677,549.05 USDT, and local 450M model profit530,941.02 USDT—three different measures (`run.log:157-161`). |

## Static-tool status

Slither installed but could not compile this scope: Foundry auto-detection lacked `forge`, and forced npm solc-js does not support native `--combined-json` (`run.log:4`, `evidence/slither.log`). Manual source triage and exact EVM replay were used; no detector output is fabricated.

## Mechanism-matched corpus comparison

- Canonical DeFiHackLabs PR #1209 supplies the exact original calldata and block-1 replay (`reference/FoxLpBondsPool_exp.canonical.sol`).
- Registry output independently reaches real deployed contracts at block 116169048 and matches this session's local raw profit (`reference/registry-pinned-fork-output.txt`, `run.log:157`).
- L2Beat's record confirms the same pair-depletion mechanism and identifies FOX transfer enablement as a historical precondition (`reference/l2beat-incident.json`).
- The independent article explains the post-swap reserve distortion but calls roughly677.5K an instant profit before full fee accounting; this report uses the canonical attacker-net figure for live net P&L.
