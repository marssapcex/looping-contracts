#!/usr/bin/env python3
"""Unit-aware extreme-state campaign for the exact stake/lpBonds arithmetic."""
import csv, json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
E18 = 10**18
U0 = 2786697198864505157273333
F0 = 496041716814196640205248
TIERS = {'A': E18, 'B': 1_000_000*E18, 'C': 450_000_000*E18, 'D': 10**15*E18}
STRATEGIES = {
 'A': 'stake_sell_inviter', 'B': 'stake_no_sale', 'C': 'prebuy_fox_10pct',
 'D': 'presell_fox_1pct_reserve', 'E': 'usdt_donation_1pct', 'F': 'fox_donation_1pct_reserve',
 'G': 'no_discount_stake_sell', 'H': 'stakeDays179_no_inviter', 'I': 'direct_treasury_unauthorized'
}
STATES = {
 'S0': (U0, F0), 'S1': (U0//100, F0//100), 'S2': (U0*100, F0*100),
 'S3': (U0, F0//1000), 'S4': (U0//1000, F0), 'S5': (U0, 0), 'S6': (0, F0),
 'S7': (10**30, 10**30), 'S8': (1000*E18, 1000*E18), 'S9': (F0, U0)
}

def amount_out(amount_in, reserve_in, reserve_out):
    if amount_in <= 0 or reserve_in <= 0 or reserve_out <= 0: return 0
    fee = amount_in * 9975
    return fee * reserve_out // (reserve_in * 10000 + fee)

def quote(U, F, discount_factor=9701):
    raw = amount_out(E18, F, U)
    return raw * discount_factor // 10000

def execute(U, F, W, strategy):
    initial_U, initial_F = U, F
    if U <= 0 or F <= 0: return {'status': 'SKIPPED_ZERO_RESERVE', 'profit': 0}
    capital = W
    attacker_fox = 0
    usdt_from_pre = 0
    donation_u = donation_f = 0
    if strategy == 'prebuy_fox_10pct':
        pre = W // 10
        attacker_fox = amount_out(pre, U, F)
        U, F, W = U + pre, F - attacker_fox, W - pre
    elif strategy == 'presell_fox_1pct_reserve':
        fox = F // 100
        capital += fox * quote(U, F, 10000) // E18
        received = fox - fox * 250 // 10000
        usdt_from_pre = amount_out(received, F, U)
        U, F = U - usdt_from_pre, F + received
    elif strategy == 'usdt_donation_1pct':
        donation_u = W // 100
        capital += donation_u
    elif strategy == 'fox_donation_1pct_reserve':
        donation_f = F // 100
        capital += donation_f * quote(U, F, 10000) // E18
    discounted = 10000 if strategy == 'no_discount_stake_sell' else 9701
    swap_price = quote(U, F, discounted)
    if swap_price == 0: return {'status': 'REJECTED_ZERO_QUOTE', 'profit': 0}
    effective_w = W + donation_u
    stake_amount = effective_w * E18 // swap_price
    # Protocol's own USDT -> FOX swap.
    half = effective_w // 2
    fox_out = amount_out(half, U, F)
    U, F = U + half, F - fox_out
    fox_balance = fox_out + donation_f
    remaining_u = effective_w - half
    # Optimal addLiquidity at the post-swap ratio; excess USDT is refunded.
    optimal_f = remaining_u * F // U
    if optimal_f <= fox_balance:
        used_u, used_f = remaining_u, optimal_f
    else:
        used_u, used_f = fox_balance * U // F, fox_balance
    U, F = U + used_u, F + used_f
    leftover_u = effective_w - half - used_u
    inviter = 0 if strategy == 'stakeDays179_no_inviter' else stake_amount * 300 // 10000
    sold = 0 if strategy in ('stake_no_sale', 'stakeDays179_no_inviter') else attacker_fox + inviter
    received_fox = sold - sold * 250 // 10000
    usdt_out = amount_out(received_fox, F, U) if sold else 0
    if sold: U, F = U - usdt_out, F + received_fox
    final = usdt_from_pre + leftover_u + usdt_out
    return {
        'status': 'EXECUTED_LOCAL_MODEL', 'profit': final - capital,
        'pair_usdt_delta': U - initial_U, 'pair_fox_delta': F - initial_F,
        'stake_amount': stake_amount, 'inviter': inviter, 'usdt_after': final,
        'capital': capital, 'pretrade_quote': swap_price,
        'note': '18-decimal integer model; gas=0; flash-loan fees=0; FOX sell tax=2.5%; discount factor=9701 unless no-discount strategy'
    }

def main():
    rows = []
    for state, (baseU, baseF) in STATES.items():
        for tier, W in TIERS.items():
            for sid, strategy in STRATEGIES.items():
                for seed in range(8):
                    rowid = f'{state}-{tier}-{sid}-seed{seed}'
                    base = {'row_id': rowid, 'state': state, 'tier': tier, 'strategy': sid,
                            'strategy_name': strategy, 'seed': seed, 'capital_tier_usdt_raw': str(W)}
                    if tier == 'D':
                        base.update(status='SKIPPED_TVL_NOT_MEASURED_GE_1E9', profit_usdt_raw='0',
                                    note='Screenshot GeckoTerminal liquidity is about $1.6M, not protocol-wide TVL >= $1e9')
                    elif sid == 'I':
                        base.update(status='REJECTED_ONLY_STAKING_POOL', profit_usdt_raw='0',
                                    note='Treasury.lpBonds requires stakingPoolMap[msg.sender]')
                    else:
                        U = baseU * (10000 + seed) // 10000 if baseU else 0
                        F = baseF * (10000 + 2*seed) // 10000 if baseF else 0
                        r = execute(U, F, W, strategy)
                        base.update(status=r['status'], profit_usdt_raw=str(r.get('profit', 0)),
                                    pair_usdt_delta_raw=str(r.get('pair_usdt_delta', 0)),
                                    pair_fox_delta_raw=str(r.get('pair_fox_delta', 0)),
                                    stake_amount_fox_raw=str(r.get('stake_amount', 0)),
                                    inviter_fox_raw=str(r.get('inviter', 0)),
                                    attacker_usdt_after_raw=str(r.get('usdt_after', 0)),
                                    capital_including_donations_raw=str(r.get('capital', W)),
                                    pretrade_quote_raw=str(r.get('pretrade_quote', 0)), note=r.get('note', ''))
                    rows.append(base)
    fields = sorted({k for row in rows for k in row})
    with (ROOT/'evidence/campaign.csv').open('w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=fields); w.writeheader(); w.writerows(rows)
    counts = {}
    for row in rows: counts[row['status']] = counts.get(row['status'], 0) + 1
    positives = [r for r in rows if r['status'] == 'EXECUTED_LOCAL_MODEL' and int(r['profit_usdt_raw']) > 0]
    canonical = next(r for r in rows if r['row_id'] == 'S0-C-A-seed0')
    assert canonical['profit_usdt_raw'] == '530941023056701789655683', canonical
    assert canonical['pair_usdt_delta_raw'] == '-530941023056701789655683', canonical
    summary = {
        'mode': 'LOCAL_INTEGER_MODEL_NOT_MAINNET_REPLAY', 'rows': len(rows), 'counts': counts,
        'positive_local_counterexamples': len(positives),
        'canonical_row': 'S0-C-A-seed0',
        'canonical_real_evm_replay': 'scripts/replay.py --case canonical; evidence/canonical-replay.json',
        'canonical_profit_usdt_raw': canonical['profit_usdt_raw'],
        'gas': '0 model USDT; real EVM native gas reported separately',
        'flash_loan_cost': '0 model USDT; live incident net is sourced separately',
        'tier_D': 'SKIPPED_TVL_NOT_MEASURED_GE_1E9'
    }
    (ROOT/'evidence/campaign.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps(summary, indent=2))

if __name__ == '__main__': main()
