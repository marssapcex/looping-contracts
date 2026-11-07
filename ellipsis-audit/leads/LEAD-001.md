# LEAD-001 — Elapsed rewards accrue at a stale emission rate before the schedule advances

Status: **LOCAL-MODEL LEAD; not a mainnet FINDING**  
Permissionless path: LP deposit → delayed `claim` → LP withdraw → MFD `exit`  
Affected source: `contracts/LpTokenStaker.sol:183-195,199-212`

## Mechanism

`_massUpdatePools` performs `_updatePool` for every pool before examining the emission schedule. `_updatePool` multiplies the entire `block.timestamp - pool.lastRewardTime` interval by the currently stored `rewardsPerSecond`. Only afterward does `_massUpdatePools` apply and pop one expired schedule entry. Therefore, after a rate has been activated, an idle interval crossing later schedule changes is initially accounted entirely at the stale rate. Additional same-timestamp calls can pop remaining entries without correcting the already-accrued interval.

This is not based on upstream HEAD or an incident report; the exact deployed Solidity body is used.

## Local withdrawal and P&L

The PoC uses offsets `[1000,2000,3000]`, rates `[100,50,0]` model EPS/second, one non-fixed LP pool (80% share), and 1 model LP token. It activates 100 EPS/s at second 1001, then makes no call until second 3501.

| Quantity | Delayed path | On-time control | Excess |
|---|---:|---:|---:|
| Gross credited EPS | 200,000 | 120,000 | 80,000 |
| EPS withdrawn after normal 50% early-exit penalty | 100,000 | 60,000 | 40,000 |
| Attacker LP principal delta | 0 | 0 | 0 |
| Gas/flash-loan cost | 0 model EPS | 0 model EPS | 0 model EPS |
| Attacker net P&L | **+100,000 model EPS** | +60,000 model EPS | **+40,000 model EPS** |
| Protocol retained EPS delta | +100,000 model EPS | +60,000 model EPS | +40,000 model EPS |
| Victim EPS/LP delta | 0 / 0 | 0 / 0 | 0 / 0 |

Evidence: `poc/StakingPoC.t.sol:77-127`; exact output at `run.log:44-60`. All values are raw 18-decimal model units; **USD value is unmeasured**. The positive local withdrawal is not represented as a BSC profit.

The arithmetic campaign has 168 local counterexamples across states/tiers/seeds (`evidence/campaign-run.log:6-11`). Canonical `S0-T0-A-seed0` is the real-EVM replay above. Eight CI Foundry seeds each pass 1,000 STATE0 fuzz cases; the whole suite totals 24,000 fuzz executions (`run.log:22,42-43` and corresponding later seeds).

## why_unproven

- No screenshot contains a block number; both available BSC RPC endpoints fail during TLS handshake. There is no pinned archive state or deployed-bytecode read-back.
- Screenshot `rewardsPerSecond = 0` is not Anvil-verified. Even if accurate for its viewing time, it does not establish historical emission-schedule state or whether a profitable idle interval existed.
- The local EPS and LP tokens are mocks. No deployed LP position, attacker share, EPS liquidity, sale route, victim delta, gas cost in a value-bearing asset, or realized stablecoin P&L is measured.
- The local `vm.warp` constructs the idle interval. It is a model input, not proof that such an interval occurred on BSC.
- Consequently this lead says nothing about current mainnet exploitability or historical losses.

## Immediately runnable next check

1. Obtain an archive endpoint and the screenshot-correlated numeric block, then run the read-only script (it has no `latest` fallback):

   ```sh
   BSC_ARCHIVE_RPC='https://your-archive-endpoint' PIN=12345678 \
     ./scripts/fork-readback.sh
   ```

2. Verify chain ID 56 and exact deployed code, then inspect `rewardsPerSecond`, every remaining `emissionSchedule` entry, `startTime`, each pool's `lastRewardTime`, LP supply, and MFD/EPS minter linkage.
3. If the pinned state has a zero rate and no remaining schedule, do not promote this lead. If a nonzero stale interval is available, start Anvil at that exact pin and replay an attacker's actual LP deposit/claim/withdraw/exit using real transactions.
4. Sweep the withdrawn EPS through a pinned, liquid route into a common numéraire; include LP opportunity cost, exit penalty, swap price impact/fees, flash-loan cost if any, and gas. Print attacker/protocol/victim deltas and assert `net_P&L > 0`.
5. Only then convert this LEAD into a FINDING with the pin and new `run.log` evidence.
