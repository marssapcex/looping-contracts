#!/usr/bin/env python3
"""Conditional FeeDepositV2 lock-incentive trapping PoC on production bytecode."""
import json
from pathlib import Path
from eth_utils import to_canonical_address
from eth_tester.exceptions import TransactionFailed
from stateful_rewards import Local, artifact, E18

ROOT = Path(__file__).resolve().parents[1]
FXS = '0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0'
CVXFXS = '0xFEEf77d3f69374f66429C91d732A244f074bdf74'
FXS_DEPOSIT = '0x8f55d7c21bDFf1A51AFAa60f3De7590222A3181e'
FEE_REGISTRY = '0xC9aCB83ADa68413a6Aa57007BC720EE2E2b3C46D'
VLCVX = '0x72a19342e8F1838460eBFCCEf09F6585e32db86E'


def set_storage(local, address, slot, value):
    chain = local.tester.backend.chain
    vm = chain.get_vm()
    vm.state.set_storage(to_canonical_address(address), slot, value)
    vm.state.persist()
    chain.header = chain.header.copy(state_root=vm.state.state_root)


def main():
    l = Local()
    user = l.users[0]
    receiver = l.accounts[1]

    # External-token and registry mocks at production hardcoded addresses.
    fxs_impl = l.deploy('MockToken', 'FXS', 'FXS')
    l.etch('MockToken', FXS)
    fxs = l.w3.eth.contract(address=FXS, abi=fxs_impl.abi)

    registry_impl = l.deploy('MockFeeRegistry')
    l.etch('MockFeeRegistry', FEE_REGISTRY)
    registry = l.w3.eth.contract(address=FEE_REGISTRY, abi=registry_impl.abi)
    l.tx(registry.functions.setFees(1700, 700, 0))

    sink_impl = l.deploy('MockRewardSink')
    l.etch('MockRewardSink', VLCVX)
    sink = l.w3.eth.contract(address=VLCVX, abi=sink_impl.abi)

    # Production cvxFxsToken runtime; only its operator storage is initialized locally.
    cvx_impl = l.deploy('cvxFxsToken')
    l.etch('cvxFxsToken', CVXFXS)
    cvx = l.w3.eth.contract(address=CVXFXS, abi=cvx_impl.abi)
    # ERC20 occupies slots 0..4; cvxFxsToken.operator is slot 5.
    set_storage(l, CVXFXS, 5, int(l.deployer, 16))
    l.tx(cvx.functions.setOperator(FXS_DEPOSIT))

    # Production FxsDepositor runtime with immutable mock staker and production minter.
    staker = l.deploy('MockLockStaker')
    depositor_impl = l.deploy('FxsDepositor', staker.address, CVXFXS)
    l.etch('FxsDepositor', FXS_DEPOSIT, depositor_impl.address)
    depositor = l.w3.eth.contract(address=FXS_DEPOSIT, abi=depositor_impl.abi)
    # FxsDepositor storage slot 1 is feeManager; constructor is not rerun after etch.
    set_storage(l, FXS_DEPOSIT, 1, int(l.deployer, 16))
    l.tx(depositor.functions.setFees(30))  # valid 0.30% lock incentive

    # Generate 3 FXS-denominated incentive through the real no-lock deposit path.
    l.tx(fxs.functions.mint(user, 1000 * E18))
    l.tx(fxs.functions.approve(FXS_DEPOSIT, 1000 * E18), user)
    l.tx(depositor.functions.deposit(1000 * E18, False), user)
    assert depositor.functions.incentiveFxs().call() == 3 * E18
    assert cvx.functions.balanceOf(user).call() == 997 * E18

    # Production FeeDepositV2. Constructor runs normally and records deployer as distributor.
    fee_deposit = l.deploy('FeeDepositV2')
    # Owner-only configuration is represented by tagged local storage overrides.
    # Compiler storageLayout: convertVlcvxRewards is slot 2 offset 20 (bit 160);
    # cvxfxsReceiver is slot 3 offset 0. vlcvxReceiver remains zero in this branch.
    set_storage(l, fee_deposit.address, 2, 1 << 160)
    set_storage(l, fee_deposit.address, 3, int(receiver, 16))
    set_storage(l, fee_deposit.address, 6, 0)  # UseDistributors=false: permissionless distribution mode

    l.tx(fxs.functions.mint(fee_deposit.address, 1000 * E18))
    caller = l.accounts[3]  # neither FeeDepositV2 owner nor cvxFxs receiver
    caller_fxs_before = fxs.functions.balanceOf(caller).call()
    l.tx(fee_deposit.functions.distribute(), caller)

    # 1% caller incentive, then 700/1700 of the remaining 990 FXS to vlCVX conversion.
    remaining = 990 * E18
    cvx_rewards = remaining * 700 // 1700
    incentive = 3 * E18
    notified = sink.functions.notified(CVXFXS).call()
    trapped = cvx.functions.balanceOf(fee_deposit.address).call()
    assert notified == cvx_rewards, (notified, cvx_rewards)
    assert trapped == incentive, (trapped, incentive)
    caller_fxs_delta = fxs.functions.balanceOf(caller).call() - caller_fxs_before
    assert caller_fxs_delta == 10 * E18
    assert depositor.functions.incentiveFxs().call() == 0

    # No public or owner rescue path can recover cvxFXS from FeeDepositV2:
    # rescueToken explicitly rejects it, and later conversions notify only new cvxRewards.
    owner = '0xa3C5A1e09150B75ff251c1a7815A07182c3de2FB'
    fund_hash = l.w3.eth.send_transaction({'from': l.deployer, 'to': owner, 'value': E18, 'gas': 21000, 'gasPrice': 1_000_000_000})
    assert l.w3.eth.wait_for_transaction_receipt(fund_hash).status == 1
    l.actions += 1
    try:
        fee_deposit.functions.rescueToken(CVXFXS, l.accounts[4]).call({'from': owner})
        rescue_rejected = False
    except TransactionFailed:
        rescue_rejected = True
    assert rescue_rejected
    l.tx(fee_deposit.functions.distribute(), caller)
    assert cvx.functions.balanceOf(fee_deposit.address).call() == trapped
    assert sink.functions.notified(CVXFXS).call() == notified

    # Differential control: legacy FeeDeposit sweeps its full cvxFXS balance.
    # Recreate the same 3-FXS incentive through the real no-lock deposit path.
    l.tx(fxs.functions.mint(user, 1000 * E18))
    l.tx(fxs.functions.approve(FXS_DEPOSIT, 1000 * E18), user)
    l.tx(depositor.functions.deposit(1000 * E18, False), user)
    assert depositor.functions.incentiveFxs().call() == incentive
    legacy = l.deploy('FeeDeposit')
    l.tx(fxs.functions.mint(legacy.address, 1000 * E18))
    legacy_sink_before = sink.functions.notified(CVXFXS).call()
    l.tx(legacy.functions.distribute())  # deployer is a constructor-authorized distributor
    legacy_notified_delta = sink.functions.notified(CVXFXS).call() - legacy_sink_before
    legacy_trapped = cvx.functions.balanceOf(legacy.address).call()
    assert legacy_notified_delta == cvx_rewards + incentive
    assert legacy_trapped == 0

    result = {
        'mode': 'LOCAL_PRODUCTION_BYTECODE_CONDITIONAL_CONFIG_POC',
        'production_contracts': ['FeeDepositV2', 'FeeDeposit (differential control)', 'FxsDepositor', 'cvxFxsToken'],
        'mocked_external_dependencies': ['FXS token', 'FeeRegistry', 'vlCVX reward sink', 'lock staker'],
        'configuration': {
            'lockIncentive_bps': 30,
            'convertVlcvxRewards': True,
            'UseDistributors': False,
            'feeDeposit_fxs_raw': str(1000 * E18),
            'callerIncentive_bps': 100,
            'feeRegistry': {'totalFees': 1700, 'cvxIncentive': 700, 'platformIncentive': 0}
        },
        'no_lock_deposit_fxs_raw': str(1000 * E18),
        'accrued_lock_incentive_raw': str(incentive),
        'converted_cvx_rewards_raw': str(cvx_rewards),
        'reward_sink_notified_cvxfxs_raw': str(notified),
        'fee_deposit_trapped_cvxfxs_raw': str(trapped),
        'trapped_equals_accrued_incentive': trapped == incentive,
        'permissionless_caller': caller,
        'caller_fxs_delta_raw': str(caller_fxs_delta),
        'caller_delta_is_designed_distribution_incentive_not_exploit_pnl': True,
        'owner_rescue_cvxfxs_rejected': rescue_rejected,
        'repeat_distribution_trapped_delta_raw': '0',
        'rescue_path': 'None: rescueToken rejects cvxFxs and conversion notifies only new cvxRewards.',
        'legacy_fee_deposit_control': {
            'additional_reward_sink_notified_cvxfxs_raw': str(legacy_notified_delta),
            'expected_cvx_rewards_plus_incentive_raw': str(cvx_rewards + incentive),
            'remaining_cvxfxs_raw': str(legacy_trapped),
            'status': 'PASS_NO_TRAPPING_IN_LEGACY_FULL_BALANCE_SWEEP'
        },
        'impact_scope': 'Conditional protocol reward/yield trapping, not permissionless attacker profit.',
        'successful_transactions': l.actions,
        'status': 'PASS_COUNTEREXAMPLE_REPRODUCED'
    }
    out = ROOT / 'evidence/fee-conversion-poc.json'
    out.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
