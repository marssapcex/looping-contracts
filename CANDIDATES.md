# Money map and candidate queue

## Money map

Arrows show custody, not a claim that the external protocol is vulnerable.

### Looping

```text
user debtAsset or yieldAsset
  -- safeTransferFrom (Looping.sol:75,80) --> Looping
whitelisted pool -- flashLoanSimple debtAsset (Looping.sol:88,119) --> Looping
Looping -- allowance + whitelisted swapper (Looping.sol:232-248) --> adapter/router
adapter/router -- path output --> Looping
Looping -- supply(yieldAsset,…,user) (Looping.sol:179-180) --> pool / user's aToken position
pool -- borrow(...,user) (Looping.sol:183) --> Looping debtAsset + user's variable debt
Looping -- amount+premium allowance (Looping.sol:151) --> pool flash-loan repayment [SINK]
Looping -- _refund leftovers (Looping.sol:147-148,256-266) --> initiating user [SINK]
user aTokens -- safeTransferFrom (Looping.sol:214) --> Looping
Looping -- withdraw (Looping.sol:217) --> pool; underlying returns to Looping
Looping -- swap output and refund --> user [SINK]
```

The only debt/collateral owner in open/close is the decoded `user`, originally `msg.sender` (`Looping.sol:87,118`). Callback authentication is pool whitelist plus `initiator == address(this)` (`Looping.sol:135-136`).

### Swap adapters

```text
caller tokenIn -- transferFrom --> adapter
adapter -- amountIn allowance --> fixed/owner-selected router
router -- tokenOut and possibly native wei --> adapter
adapter -- WHYPE.deposit{value: entire native balance} --> WHYPE
adapter -- entire tokenOut balanceOf(adapter) --> `to` [SINK]
```

Relevant sink lines: `GluexAdapter.sol:85-93`, `HypertradeAdapter.sol:89-98`, `LiquidSwapAdapter.sol:70-80`. None measures a pre-swap `tokenOut` balance. Native wrapping also uses the entire native balance, not a delta.

### wHLP zapper

```text
caller tokenIn/native --> zapper --> router --> USDT0 balance at zapper
zapper -- USDT0 allowance --> hard-coded depositor
zapper -- deposit(USDT0, amount, minimumMint, msg.sender,…) --> wHLP shares to caller [SINK]
```

`zapIn` deposits the entire USDT0 balance (`wHlpZapper.sol:110-122`); `zapInHypertrade` deposits only `balanceAfter − balanceBefore` (`wHlpZapper.sol:161-181`).

### Strategy managers

Owner-authorized calls move tokens/native from each user's manager (`StrategyManager.sol:43-73`). The factory assigns ownership to `msg.sender` (`StrategyManagerFactory.sol:25-29`). No permissionless value sink was identified in this module.

## Corpus comparison status

`vulnchain/data/corpus.json` and `vulnchain/incidents/` are absent. Consequently the required 3–5 same-custody/same-price-source incident comparisons cannot be produced with valid corpus paths. No incident names, CVEs, losses, or “similar hack” claims are substituted from memory. Static tool output is only a lead: Slither flags unchecked transfers and balance/reentrancy concerns in `leads/slither-detectors.txt`; it does not prove a loss.

## Candidate sequences and signed P&L

### C1 — Adapter absolute-balance sweep (all three adapters)

```text
step 1 needs: adapter holds B > 0 units of tokenOut; source of B must be established
→ step 2 needs: arbitrary caller sets a current-transaction route for (tokenIn,tokenOut)
  (GluexAdapter.sol:29-52; HypertradeAdapter.sol:47-68; LiquidSwapAdapter.sol:24-37)
→ step 3 needs: amountIn = 0 and the fixed router accepts the route/calldata without producing output
→ step 4 needs: balanceOut = B >= amountOutMin; adapter transfers B to attacker
  (GluexAdapter.sol:85-93; HypertradeAdapter.sol:95-98; LiquidSwapAdapter.sol:75-80)
sink: B tokenOut units leave the adapter for attacker
P&L = +B − attackerInput(0) − routerFee − gas − any required route payment
```

Local model: expected positive for all three with a no-op router. Mainnet unknowns: actual adapter address/balance and whether its fixed router has a successful zero-input route. A direct donation used only to manufacture B is **not** a profitable attack and is rejected as proof of impact.

### C2 — `wHlpZapper.zapIn` absolute-balance credit

```text
step 1 needs: zapper holds B > 0 USDT0 units
→ step 2 needs: caller executes a zero-input/no-output LiquidSwap route (wHlpZapper.sol:84-108)
→ step 3 needs: balanceOut = B passes amountOutMin (wHlpZapper.sol:110-114)
→ step 4 needs: depositor accepts B and mints shares to caller (wHlpZapper.sol:116-122)
sink: B USDT0 units leave the zapper; caller receives wHLP shares
P&L = redeemableValue(wHLP shares) − callerInput − swapFee − gas
```

`zapInHypertrade` is the negative control because it uses a balance delta. Mainnet unknowns are the zapper balance and empty/zero-input router behavior.

### C3 — Native residual / WHYPE confusion

All adapters wrap their entire native balance (`GluexAdapter.sol:85-87`, `HypertradeAdapter.sol:89-91`, `LiquidSwapAdapter.sol:70-72`). If `tokenOut != WHYPE`, newly wrapped WHYPE can remain in the adapter and later become C1's B. A donor who simply sends native wei loses money; that self-harm case is discarded. A profitable branch requires residual native value arising from a router refund or another user's flow.

### C4 — Looping callback forgery / cross-user close

```text
candidate: attacker invokes executeOperation or closePosition against victim
required checks: pools[msg.sender] and initiator == Looping (Looping.sol:135-136);
user = original msg.sender (Looping.sol:87,118); victim aToken transferFrom allowance (Looping.sol:214)
P&L = victimRefund − flashPrincipal − premium − ownCollateralAtRisk − gas
```

Expected dead branch: direct callback forgery fails both caller/initiator checks, and `closePosition` decodes the caller as `user`. Tests must prove victim deltas remain zero rather than infer this from Slither's arbitrary-`from` warning.

### C5 — Unchecked ERC20 return values

`LiquidSwapAdapter.sol:59-61,75-80` and `wHlpZapper.sol:97` use raw `transferFrom`/`transfer`; `StrategyManager.sol:64` uses raw `transfer`. A false-return token could turn a failed pull into accounting based on pre-existing balances. Profitable only if C1/C2 supplies a balance or an owner voluntarily uses a false-return token in a manager; otherwise this is robustness, not an independent money-losing finding.

### C6 — Approval residue / router-calldata abuse

Adapters approve exactly `amountIn` but do not reset allowance (`GluexAdapter.sol:78-81`, `HypertradeAdapter.sol:86-89`, `LiquidSwapAdapter.sol:59-68`). If a router pulls less than `amountIn`, residue remains. Attacker-controlled GlueX/HyperTrade calldata might invoke a router function that spends residual allowance. This needs the actual router ABI/bytecode and an on-chain residual allowance; it is not proven by mocks.

### C7 — Reentrancy between balance reads

Adapters and `zapInHypertrade` are `nonReentrant`; `Looping.executeOperation` is not, but only a whitelisted pool can call it and the initiator must be Looping (`Looping.sol:128-153`). A malicious whitelisted router/pool is an admin/integration compromise and is excluded unless a permissionless callback path is demonstrated. `zapIn` lacks `nonReentrant`, so a router/depositor callback is a local test lead only.

### C8 — Route freshness / transient storage collision

Routes are keyed by `(tokenIn,tokenOut)` and `block.number` (`GluexAdapter.sol:32-50,100-129`, `HypertradeAdapter.sol:51-66,101-117`, `LiquidSwapAdapter.sol:29-37,49-56`). Transient storage clears per transaction. Tests cover empty routes, cross-block reuse, non-32-byte calldata, and same-pair route replacement. No cross-block residual is expected.

### C9 — Rounding/dust/flash-loan amplification

There is no share mint or AMM pricing code in scope. Looping computes `repaymentAmount = flashloanAmount − initialAmount` (`Looping.sol:83-88`) and borrows `repaymentAmount + premium` (`Looping.sol:183`). Extreme tiers can expose underflow/insufficient repayment, but a revert or loss limited to the caller is discarded. Positive P&L requires a separate victim/source of residual tokens.

### C10 — Declared assets are not explicitly bound to route endpoints

`Looping._swap` approves `path[0]` and measures `path[path.length-1]`, while `_executeOpenPosition` separately supplies `_yieldAsset` (`contracts/Looping.sol:162-184,232-248`). There is no explicit `path[0] == debtAsset` / terminal `== yieldAsset` require. This is a route-validation robustness lead derived from output-accounting research, not a Rhea reproduction: Looping does not sum intermediate declared outputs or use user-declared output for solvency.

The exact-source negative control in `poc/OracleAccountingBoundaries.t.sol` uses a pool that really pulls collateral, creates debt, enforces 1:1 health, and repays flash liquidity. Correct endpoints create 100 supply/100 debt for the caller only. A wrong terminal produces zero declared-yield supply and reverts the borrow under that health model; victim supply/debt/token deltas remain zero. No victim loss, actual-router acceptance, or positive attacker P&L is established. Retain as **LEAD only**; add endpoint checks as defense in depth and validate actual terminal balance delta. Mainnet pool/router code remains required for any promotion.

## Campaign accounting

Requested upper-bound campaign: tiers A/B/C = 200,000 / 500,000 / 1,000,000 runs × 8 seeds, plus D only with at least $1e9 measured TVL. D is disqualified because no on-chain TVL measurement is available and the supplied Delpho TVL is a different protocol.

The executable local campaign uses real local EVM transactions/calls and records seed, tier, state, selector sequence, and signed deltas. It does **not** relabel local mock executions as mainnet fork coverage.

### Executed local-model coverage

| campaign | result | evidence |
|---|---|---|
| 16 functional/model tests | 16 passed, including adapter/zapper sweeps, native-refund residual, negative controls, callback and owner guards | `run.log:33-110,285` |
| CI fuzz | 1,000 runs passed | `run.log:111` |
| model capital matrix | 3 notional tiers × 8 seeds = 24 passing sequences; each logs signed attacker/protocol/source deltas and P&L | `run.log:112-282` |
| expanded fuzz, seed `0xA11CE` | 200,000 runs passed | `run.log:287-294` |
| expanded fuzz, seed `0xB` | 500,000 runs passed | `run.log:296-303` |
| expanded fuzz, seed `0xC` | 1,000,000 runs passed | `run.log:305-312` |
| total model fuzz | **1,701,000 passing runs**; one residual-drain family, not nine independent bug classes | lines above |
| tier D | not run; no qualifying on-chain TVL measurement | `SIGNATURE.md` fork status |
| separate-transaction Anvil checks | route and swap revert on stale transient data; payable fallback accepted 1 wei | `leads/anvil-verification.txt` |

The 200k/500k/1m runs use different seeds but are **not** represented as the requested full eight-seed campaign at every tier and ten extreme states. The requested 9 strategies × 4 tiers × 8 seeds mainnet drain loop is not exhausted: no pinned RPC, deployment balances, router bytecode, or real price source is available. This is an explicit coverage limitation, not a claim of safety.

### Dead / blocked branches and immediate next checks

| branch | disposition | why_unproven or disproving observation | immediate next check |
|---|---|---|---|
| reentrancy / nested callback | blocked, no independent profit | adapters and HyperTrade zap are guarded; Looping callback requires pool and initiator. No arbitrary callback victim found | on a pinned fork, enumerate actual router/pool ABI selectors and attempt a callback from each; run `FOUNDRY_PROFILE=ci forge test --match-path poc/Guards.t.sol -vvv` for local guard regression |
| oracle skew / stale round | not applicable to in-scope implementation; external-pool lead unexamined | no oracle/round read exists in these contracts; external HyperLend pool source is absent | `cast call $POOL 'ADDRESSES_PROVIDER()(address)' --rpc-url $RPC --block $PIN`, then `getPriceOracle` and `getSourceOfAsset` before testing borrow/withdraw |
| share inflation / first depositor | not applicable in scope | no share mint/redeem implementation; mock wHLP shares are test-only | audit the actual depositor at `0x340C…41c1` with its source and pinned state |
| direct donation / absolute balance | **local PoC works; mainnet unproven** | all three adapters and `zapIn` sweep a modeled residual; self-donation net P&L is zero and rejected | run `poc/MainnetReplay.sol` with actual addresses and a pin; first `cast call $TOKEN 'balanceOf(address)(uint256)' $ADAPTER --block $PIN --rpc-url $RPC` |
| rounding / dust amplification | discarded as independent finding | sweep works at one unit but dust alone is excluded; no victimless share/rounding sink found | use the existing fuzz harness with residual bound `1..1e4`; only promote if a non-donor victim and net P&L after gas are measured |
| flash-loan amplification | no independent source found | C1 needs no capital; Looping repayment math otherwise returns leftovers to the caller and victim deltas stayed zero | run a full mock-pool open/close economic test, then replay the same sequence against the pinned pool |
| callback/self-call abuse | local guards passed | non-pool and wrong initiator revert; strategy managers reject non-owner; factory assigns caller as owner | `FOUNDRY_PROFILE=ci forge test --match-path poc/Guards.t.sol -vvv` |
| approval residue | lead only | actual router pull behavior and residual allowance are unknown; a mock could manufacture any result | `cast call $TOKEN 'allowance(address,address)(uint256)' $ADAPTER $ROUTER --block $PIN --rpc-url $RPC` and inspect the exact router's spend paths |
| proxy/implementation mismatch | not applicable in scope | contracts are direct deployments, no proxy code; deployed bytecode could not be compared | `cast code $DEPLOYMENT --block $PIN --rpc-url $RPC` and compare with the exact-commit artifact |
| extreme AMM ticks / `k` / utilization / oracle deviation | not applicable to this repository's code | no AMM or lending-pool implementation is present | obtain and pin the external router/pool sources rather than infer behavior from interfaces |

Every positive local sweep remains a **LEAD**, not a promoted finding, until the actual-residual replay in `poc/MainnetReplay.sol` passes against a pinned fork without seeding value.
