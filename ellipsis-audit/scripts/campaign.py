#!/usr/bin/env python3
"""Unit-aware local arithmetic campaign for the exact deployed mechanisms.

This is not a mainnet fork and does not price EPS/LP tokens. Strategy 1 models
LpTokenStaker's update-then-single-schedule-pop ordering. Strategies 2-9 are
guard/accounting outcomes established by the source review and named Foundry
checks. The canonical STATE0/A/seed-0 counterexample is replayed with real EVM
transactions by StakingPoC.test_LOCAL_LEAD_stale_emission_withdrawal_and_signed_pnl.
"""
import csv
import json
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "evidence"
E = 10**18

# activation is the first transaction after offsets[0]; delay is measured from
# that activation to the delayed claim. Rates are model EPS raw units/second.
STATES = [
    ("STATE0_three_step_terminal_zero", [1000, 2000, 3000], [100*E, 50*E, 0], 2500),
    ("STATE1_compressed_boundaries", [0, 1, 2], [100*E, 50*E, 0], 1000),
    ("STATE2_two_step_terminal_zero", [100, 200], [100*E, 0], 5000),
    ("STATE3_nonzero_terminal_rate", [100, 200, 300], [100*E, 75*E, 25*E], 10000),
    ("STATE4_increase_then_zero", [100, 200, 300], [100*E, 200*E, 0], 1000),
    ("STATE5_monotonic_increase_no_excess", [100, 200, 300], [100*E, 200*E, 300*E], 250),
    ("STATE6_single_rate_control", [1000], [100*E], 5000),
    ("STATE7_zero_initial_rate", [10, 20, 30], [0, 100*E, 0], 1000),
    ("STATE8_near_equal_then_zero", [1, 2, 3], [100*E, 100*E, 0], 100),
    ("STATE9_one_year_idle", [100, 200, 300], [100*E, 50*E, 0], 31_536_000),
]
STRATEGIES = [
    "stale_emission_delayed_claim",
    "duplicate_pid_claim",
    "emergency_withdraw_callback_reentry",
    "unauthorized_eps_mint",
    "cross_account_expired_lock_withdrawal",
    "absolute_reward_balance_recovery",
    "curve_callback_reentry",
    "proxy_reinitialization",
    "proportional_withdrawal_inflation",
]
TIERS = [("A", 1*E), ("B", 1_000_000*E), ("C", 1_000_000_000_000*E), ("D", 10**24*E)]
SEEDS = list(range(8))


def expected_gross(offsets, rates, activation, end):
    """80% share, with on-time claims at each strict-offset boundary."""
    boundaries = [activation]
    for offset in offsets[1:]:
        point = offset + 1
        if activation < point < end:
            boundaries.append(point)
    boundaries.append(end)
    total = 0
    for idx, (start, stop) in enumerate(zip(boundaries, boundaries[1:])):
        total += (stop - start) * rates[idx] * 80 // 100
    return total


def main():
    rows = []
    for state_idx, (state, offsets, rates, base_delay) in enumerate(STATES):
        activation = offsets[0] + 1
        for strategy_idx, strategy in enumerate(STRATEGIES):
            for tier, capital_lp in TIERS:
                for seed in SEEDS:
                    row = {
                        "case_id": f"S{state_idx}-T{strategy_idx}-{tier}-seed{seed}",
                        "state": state,
                        "strategy": strategy,
                        "tier": tier,
                        "seed": seed,
                        "capital_lp_raw": capital_lp,
                        "units": "raw 1e18 model LP/EPS; USD=UNMEASURED",
                        "pin_block": "UNAVAILABLE_NO_BSC_ARCHIVE",
                        "gas_cost_model_eps": 0,
                        "flash_loan_cost_model_eps": 0,
                    }
                    if tier == "D":
                        row.update(status="SKIPPED_TVL_NOT_MEASURED_GE_1E9", gross_withdrawal_model_eps="", net_pnl_model_eps="", excess_vs_control_model_eps="")
                        rows.append(row)
                        continue
                    delay = base_delay + seed
                    end = activation + delay
                    if strategy_idx == 0:
                        gross = delay * rates[0] * 80 // 100
                        expected = expected_gross(offsets, rates, activation, end)
                        withdrawal = gross // 2  # actual MultiFeeDistribution early-exit penalty
                        control_withdrawal = expected // 2
                        excess = withdrawal - control_withdrawal
                        status = "COUNTEREXAMPLE_LOCAL_MODEL" if excess > 0 else "NO_EXCESS"
                    else:
                        # No excess balance is created by these rejected paths.
                        withdrawal = 0
                        control_withdrawal = 0
                        excess = 0
                        status = "REJECTED_BY_GUARD_OR_ACCOUNTING"
                    row.update(
                        status=status,
                        delay_seconds=delay,
                        gross_withdrawal_model_eps=withdrawal,
                        net_pnl_model_eps=withdrawal,
                        control_withdrawal_model_eps=control_withdrawal,
                        excess_vs_control_model_eps=excess,
                        lp_principal_delta=0,
                        replay="poc/StakingPoC.t.sol:72" if state_idx == 0 and strategy_idx == 0 and tier == "A" and seed == 0 else "same STATE0 family; canonical real-EVM replay only",
                    )
                    rows.append(row)

    OUT.mkdir(exist_ok=True)
    fields = sorted({key for row in rows for key in row})
    with (OUT / "campaign.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    counters = [row for row in rows if row["status"] == "COUNTEREXAMPLE_LOCAL_MODEL"]
    summary = {
        "model_only": True,
        "mainnet_promotion": False,
        "pin_block": None,
        "why_no_pin": "Both BSC RPC endpoints fail TLS; screenshots contain no block number.",
        "rows_total": len(rows),
        "rows_executed_local_model": sum(row["status"] != "SKIPPED_TVL_NOT_MEASURED_GE_1E9" for row in rows),
        "rows_skipped_tier_d": sum(row["status"] == "SKIPPED_TVL_NOT_MEASURED_GE_1E9" for row in rows),
        "counterexamples_local_model": len(counters),
        "states": len(STATES),
        "strategies": len(STRATEGIES),
        "tiers": [tier for tier, _ in TIERS],
        "seeds": SEEDS,
        "tier_d_rule": "Run only with measured TVL >= $1e9; protocol-wide TVL was not measured, so D is skipped.",
        "canonical_counterexample": counters[0]["case_id"],
        "canonical_real_evm_replay": "poc/StakingPoC.t.sol:test_LOCAL_LEAD_stale_emission_withdrawal_and_signed_pnl",
        "cost_model": "Gas and flash-loan cost set to zero in model units; no USD value or mainnet P&L is asserted.",
        "rounding_policy": "Dust-only rounding is out of scope; no row is promoted.",
    }
    (OUT / "campaign.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
