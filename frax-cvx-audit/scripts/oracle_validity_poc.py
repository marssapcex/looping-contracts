#!/usr/bin/env python3
"""Conditional cvxFXBSwapper oracle-validity flag PoC.

Runs unmodified production cvxFXBSwapper bytecode. The lender, tokens, and Curve
exchange are local mocks. One scenario explicitly returns isBorrowAllowed=False;
this is not a deployed-mainnet configuration or an attacker-profit claim.
"""
import json
from stateful_rewards import Local, E18

ROOT = __import__('pathlib').Path(__file__).resolve().parents[1]


def run_scenario(allowed):
    l = Local()
    attacker, cvxfxb_receiver, _ = l.users
    frax = l.deploy('OracleFlagToken', 'FRAX', 'FRAX')
    fxb = l.deploy('OracleFlagToken', 'FXB', 'FXB')
    lender = l.deploy('OracleFlagLender', allowed, E18 // 2)
    exchange = l.deploy('OracleFlagExchange', frax.address, fxb.address, E18)
    swapper = l.deploy(
        'cvxFXBSwapper', cvxfxb_receiver, fxb.address, frax.address,
        lender.address, exchange.address,
    )

    amount = 100 * E18
    l.tx(frax.functions.mint(swapper.address, amount))
    attacker_frax_before = frax.functions.balanceOf(attacker).call()
    attacker_fxb_before = fxb.functions.balanceOf(attacker).call()
    receipt = l.tx(swapper.functions.processRewards(), attacker)

    expected_min_out = amount * (E18 // 2) // E18 * (990 * 10**15) // E18
    assert lender.functions.updateCalls().call() == 1
    assert exchange.functions.calls().call() == 1
    assert exchange.functions.lastAmountIn().call() == amount
    assert exchange.functions.lastMinOut().call() == expected_min_out
    assert frax.functions.balanceOf(swapper.address).call() == 0
    assert fxb.functions.balanceOf(cvxfxb_receiver).call() == amount
    assert frax.functions.balanceOf(attacker).call() == attacker_frax_before
    assert fxb.functions.balanceOf(attacker).call() == attacker_fxb_before

    return {
        'isBorrowAllowed_returned_by_mock': allowed,
        'oracle_rate_raw': str(E18 // 2),
        'actual_mock_exchange_output_rate_raw': str(E18),
        'process_rewards_caller': attacker,
        'lender_update_calls': 1,
        'exchange_calls_despite_returned_flag': 1,
        'frax_pulled_raw': str(amount),
        'minimum_out_raw': str(expected_min_out),
        'fxb_delivered_to_cvxfxb_raw': str(amount),
        'attacker_frax_delta_raw': '0',
        'attacker_fxb_delta_raw': '0',
        'gas_used': receipt.gasUsed,
        'attacker_profit': False,
    }


def main():
    false_case = run_scenario(False)
    true_control = run_scenario(True)
    result = {
        'mode': 'LOCAL_PRODUCTION_BYTECODE_CONDITIONAL_ORACLE_VALIDITY',
        'production_contract': 'cvxFXBSwapper',
        'source_behavior': 'processRewards ignores the boolean returned by IFraxLend.updateExchangeRate and executes exchange regardless.',
        'mocked_external_dependencies': ['Fraxlend oracle validity/rate', 'FRAX', 'FXB', 'Curve exchange'],
        'false_validity_scenario': false_case,
        'true_validity_control': true_control,
        'status': 'PASS_CONDITIONAL_FALSE_FLAG_STILL_SWAPS_AND_TRUE_CONTROL',
        'promotion_status': 'LEAD_ONLY_NOT_A_CURRENT_MAINNET_FINDING: no deployed oracle state, stale price, sandwich/MEV proceeds, or positive attacker net P&L established.',
        'required_mainnet_conditions': [
            'Pinned deployment and exchange identity.',
            'A permissionless call while updateExchangeRate returns false or a stale/manipulable rate.',
            'Actual executable output and MEV/sandwich loss measured against a correct-validity control.',
            'Signed protocol and attacker deltas including gas and swap costs.',
        ],
    }
    out = ROOT / 'evidence/oracle-validity-poc.json'
    out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
