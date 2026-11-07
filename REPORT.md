# FINDING

No item is promoted to a finding under the requested proof bar. The passing PoCs below are explicitly local models with etched external integrations; the mandatory pinned HyperEVM fork, real residual balance, deployed bytecode comparison, and actual router behavior could not be verified because RPC access fails. Mainnet impact is therefore not asserted. The supplied checkout contains no `vulnchain` corpus (`SIGNATURE.md`). A separate sourced incident corpus has since been added under `oracle-accounting-research/`; it is differential-test context, not a substitute for deployment evidence.

**2026-11-07 addendum:** a Rhea-derived route-endpoint recheck found no explicit binding between declared assets and `path[0]`/terminal in `Looping._swap`. A new exact-source negative control shows correct endpoints executing for the caller only and a wrong terminal reverting under a real-pull, post-action-health pool model; all victim deltas are zero. This is retained as C10 route-validation robustness LEAD, not a finding and not a Rhea replay. Seven corpus-derived boundary tests pass (`oracle-accounting-research/boundary-tests.log`).

# LEAD

1. **Absolute `tokenOut` balance lets a zero-input caller extract any adapter residual.**
   - **module:** `contracts/periphery/GluexAdapter.sol:78-93`; `contracts/periphery/HypertradeAdapter.sol:86-98`; `contracts/periphery/LiquidSwapAdapter.sol:59-80` (one root cause, three locations).
   - **path:** arbitrary caller sets a current-transaction route → calls the swap with `amountIn = 0` → fixed router returns success with no new output → adapter reads its entire `tokenOut.balanceOf(address(this))` → transfers that absolute balance to caller-selected `to`. Sequence and signed P&L expression are in `CANDIDATES.md` C1.
   - **proof (local model only):** HyperTrade `delta_attacker = +1,000,000 token units`, `delta_protocol = -1,000,000`, `delta_victim_LP = -1,000,000`, `PnL_attacker = +1,000,000` before native gas (`run.log:48-57`); GlueX same deltas (`run.log:33-42`); LiquidSwap same deltas (`run.log:59-68`). The self-donation control has zero net P&L and is rejected (`run.log:77-79`). Expanded model fuzz: 200,000 / 500,000 / 1,000,000 passing runs (`run.log:291,300,309`).
   - **ordinary residual-source model:** a router-native refund is wrapped into WHYPE while another `tokenOut` was requested; the resulting `1e18 WHYPE units` residual is then swept, with attacker `+1e18`, protocol `-1e18`, and P&L `+1e18` before native gas (`run.log:70-75`). This proves a possible lifecycle in the model, not that the deployed router emits such a refund.
   - **impact:** if a deployed adapter holds `B > 0` units of a valuable token at pin block N, anyone can extract `B`; maximum direct loss is the adapter's residual token/native-derived WHYPE balance. USD value at N is **unmeasured**; token price feed address/decimals are not known from this repository and are not fabricated. No mainnet victim LP delta is claimed.
   - **precondition:** an actual residual not supplied by the attacker; a successful zero-input/no-output router route; token value greater than gas and any router cost.
   - **blocked_by / why_unproven:** no deployment address/balance or router bytecode is available at a pinned block. HyperEVM RPC fails with TLS/connect error. Direct donations alone are not proof of impact.
   - **next check:** set the variables documented in `poc/MainnetReplay.sol`, first verify `cast call $TOKEN 'balanceOf(address)(uint256)' $ADAPTER --block $PIN --rpc-url $RPC`, then run `forge test --match-path poc/MainnetReplay.sol -vvv`. The harness seeds no tokens and asserts an actual-balance withdrawal.
   - **fix:** snapshot `tokenOut` immediately before the router call and transfer only `balanceAfter - balanceBefore`; snapshot native balance and wrap only the router-produced native delta. Use checked SafeERC20 transfers and consider clearing residual router allowance after the swap.
   - **corpus:** unavailable; no incident analogy or loss number is used.

2. **`wHlpZapper.zapIn` credits the entire USDT0 residual to the caller.**
   - **module:** `contracts/periphery/wHlpZapper.sol:84-124`, especially absolute balance read at `:110` and deposit at `:116-122`.
   - **path:** arbitrary caller executes a zero-input/no-output LiquidSwap route → zapper reads all USDT0 held by the contract → approves the depositor for that absolute balance → depositor mints wHLP shares to `msg.sender`. Signed P&L expression is in `CANDIDATES.md` C2.
   - **proof (local model only):** the attacker redeemed model shares 1:1 to make units comparable: `delta_attacker = +1,000,000 USDT0-model units`, `delta_protocol = -1,000,000`, `delta_victim_LP = -1,000,000`, `PnL_attacker = +1,000,000` before native gas (`run.log:81-90`). The HyperTrade zapper's delta accounting is a passing negative control: attacker shares `0`, residual unchanged (`run.log:44-46`).
   - **impact:** if the deployed zapper holds `B > 0` USDT0 units, a caller can deposit that residual and receive the corresponding wHLP mint. USD value and real wHLP redemption value at block N are **unmeasured**; the mock 1:1 redemption is not a mainnet valuation.
   - **precondition:** actual non-attacker USDT0 residual; zero-input/no-output LiquidSwap route succeeds; depositor accepts the deposit and mint has positive redeemable value after fees/gas.
   - **blocked_by / why_unproven:** actual zapper address/balance, deployed LiquidSwap behavior, depositor behavior, and pinned wHLP redemption value are unavailable.
   - **next check:** `cast call 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb 'balanceOf(address)(uint256)' $ZAPPER --block $PIN --rpc-url $RPC`; replay the zero-input zap on that fork without seeding, record actual share mint, then value it using the real depositor redemption path rather than the model's 1:1 redemption.
   - **fix:** measure `receivedUSDT0 = balanceAfter - balanceBefore` around `executeSwaps`, and deposit only `receivedUSDT0`, matching the existing HyperTrade implementation at `wHlpZapper.sol:161-181`. Replace raw token transfers/approvals with SafeERC20 equivalents.
   - **corpus:** unavailable; no incident analogy or loss number is used.

3. **Residual router allowance may be spendable through attacker-selected aggregator calldata.**
   - **module:** `contracts/periphery/GluexAdapter.sol:78-81`; `contracts/periphery/HypertradeAdapter.sol:86-89`; `contracts/periphery/LiquidSwapAdapter.sol:59-68`.
   - **path hypothesis:** a previous router pulls less than `amountIn` → adapter retains token balance and nonzero router allowance → caller supplies router calldata that exercises a spending function → residual token is pulled or swept.
   - **proof:** no profitable PoC; deliberately not included in the positive local sweep count.
   - **impact:** capped by actual residual allowance/balance; USD value unmeasured.
   - **precondition:** nonzero residual allowance and a permissionless router function capable of spending it for the attacker's benefit.
   - **blocked_by / why_unproven:** actual router ABI/bytecode and residual allowance at pin N are unknown; manufacturing either with a mock would prove nothing about deployment.
   - **next check:** `cast call $TOKEN 'allowance(address,address)(uint256)' $ADAPTER $ROUTER --block $PIN --rpc-url $RPC`, `cast code $ROUTER --block $PIN --rpc-url $RPC`, then enumerate router functions that call `transferFrom` on the adapter.
   - **fix:** use `forceApprove` for nonstandard ERC20s, reset allowance to zero after successful router execution, and minimize/validate calldata to the expected router selector and recipient.
   - **corpus:** unavailable; no incident analogy or loss number is used.

# RESCUE

- **Looping integration disable:** the owner can call `Looping.setSwapper(adapter,false)` (`contracts/Looping.sol:292-294`) or `setPool(pool,false)` (`:287-289`). Delay is **0 blocks** after an owner transaction is included; there is no timelock. This protects new Looping flows but does **not** prevent direct calls to an adapter. Mainnet owner, inclusion cost, and block cost at N are unmeasured.
- **HyperTrade router replacement:** the owner can call `HypertradeAdapter.setHyperTradeRouter` (`contracts/periphery/HypertradeAdapter.sol:40-44`) or `wHlpZapper.setHyperTradeRouter` (`contracts/periphery/wHlpZapper.sol:70-73`) with **0 blocks** of enforced delay. This does not pause absolute-balance transfers and is not a complete rescue.
- **Zapper residual recovery:** the owner can call `wHlpZapper.rescueTokens(USDT0,amount)` (`contracts/periphery/wHlpZapper.sol:186-194`) with **0 blocks** of enforced delay. This can recover an existing residual to the owner but does not fix future crediting; a patched redeployment/migration is required. GlueX and LiquidSwap adapters expose no owner rescue/pause, and HyperTrade exposes no token rescue/pause.
- **Permanent mitigation:** deploy adapters/zapper with delta accounting, then update Looping's swapper whitelist and user/router integrations. Until migration, direct adapter calls remain permissionless. No on-chain rescue transaction was sent; all delay statements come from direct setter/rescue code, while real block inclusion cost remains unmeasured.
