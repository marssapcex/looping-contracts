#!/usr/bin/env python3
"""Stateful exact-bytecode reward tests with independent token-conservation checks.

Mocks replace only external ERC20/registry/booster dependencies. MultiRewards and
StakedCvxFxs execute the unmodified production bytecode compiled at solc 0.8.10.
"""
import argparse
import json
import random
from pathlib import Path
from eth_tester import EthereumTester
from eth_utils import to_canonical_address
from web3 import Web3
from web3.providers.eth_tester import EthereumTesterProvider

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = json.loads((ROOT / 'evidence/artifacts.json').read_text())
E18 = 10**18
DURATION = 7 * 86400
MAX = 2**256 - 1
VEFXS_PROXY = '0x59CFCD384746ec3035299D90782Be065e466800B'


def artifact(name):
    matches = [a for key, a in ARTIFACTS.items() if key.endswith(':' + name)]
    if len(matches) != 1:
        raise KeyError((name, len(matches)))
    return matches[0]


class Local:
    def __init__(self):
        self.tester = EthereumTester()
        self.w3 = Web3(EthereumTesterProvider(self.tester))
        self.accounts = self.w3.eth.accounts
        self.deployer = self.accounts[0]
        self.users = self.accounts[2:5]
        self.actions = 0
        self.last_time = None

    def tx(self, fn, sender=None):
        h = fn.transact({'from': sender or self.deployer, 'gas': 20_000_000, 'gasPrice': 1_000_000_000})
        receipt = self.w3.eth.wait_for_transaction_receipt(h)
        if receipt.status != 1:
            raise AssertionError(f'revert action={self.actions} tx={h.hex()}')
        self.last_time = self.w3.eth.get_block(receipt.blockNumber).timestamp
        self.actions += 1
        return receipt

    def deploy(self, name, *args):
        a = artifact(name)
        c = self.w3.eth.contract(abi=a['abi'], bytecode=a['bytecode'])
        address = self.tx(c.constructor(*args)).contractAddress
        return self.w3.eth.contract(address=address, abi=a['abi'])

    def warp(self, seconds):
        latest = self.tester.get_block_by_number('latest')['timestamp']
        self.tester.time_travel(latest + seconds)

    def etch(self, name, address, implementation=None):
        # Immutable values exist only in post-deployment bytecode; raw solc
        # deployedBytecode has zero placeholders for those values.
        runtime = self.w3.eth.get_code(implementation) if implementation else bytes.fromhex(artifact(name)['runtime'])
        chain = self.tester.backend.chain
        vm = chain.get_vm()
        vm.state.set_code(to_canonical_address(address), runtime)
        vm.state.persist()
        # Keep the pending block's state root aligned; otherwise the override is
        # discarded when the next transaction is applied/mined.
        chain.header = chain.header.copy(state_root=vm.state.state_root)


class MultiModel:
    def __init__(self, now):
        self.stored = 0
        # addReward initializes both timestamps to the current block.
        self.last = now
        self.finish = now
        self.rate = 0
        self.supply = 0
        self.balances = {u: 0 for u in range(3)}
        self.paid = {u: 0 for u in range(3)}
        self.pending = {u: 0 for u in range(3)}
        self.claimed = {u: 0 for u in range(3)}
        self.funded = 0
        self.contract_balance = 0

    def rpt(self, now):
        if self.supply == 0:
            return self.stored
        return self.stored + (min(now, self.finish) - self.last) * self.rate * E18 // self.supply

    def update(self, now, user=None):
        new_rpt = self.rpt(now)
        self.stored = new_rpt
        self.last = min(now, self.finish)
        if user is not None:
            self.pending[user] += self.balances[user] * (new_rpt - self.paid[user]) // E18
            self.paid[user] = new_rpt

    def deposit(self, now, user, amount):
        self.update(now, user)
        self.balances[user] += amount
        self.supply += amount

    def withdraw(self, now, user, amount):
        self.update(now, user)
        self.balances[user] -= amount
        self.supply -= amount

    def notify(self, now, amount):
        self.update(now)
        if now >= self.finish:
            self.rate = amount // DURATION
        else:
            self.rate = (amount + (self.finish - now) * self.rate) // DURATION
        self.last = now
        self.finish = now + DURATION
        self.funded += amount
        self.contract_balance += amount

    def claim(self, now, user):
        self.update(now, user)
        amount = self.pending[user]
        self.pending[user] = 0
        self.claimed[user] += amount
        self.contract_balance -= amount


class StakedModel:
    SCALE = 10**20

    def __init__(self):
        self.integral = 0
        self.remaining = 0
        self.supply = 0
        self.reward_balance = 0
        self.balances = {u: 0 for u in range(3)}
        self.user_i = {u: 0 for u in range(3)}
        self.claimable = {u: 0 for u in range(3)}
        self.claimed = {u: 0 for u in range(3)}
        self.donated = 0

    def checkpoint(self, account, claim=False):
        bal = self.reward_balance
        if self.supply > 0 and bal > self.remaining:
            self.integral += (bal - self.remaining) * self.SCALE // self.supply
        user_i = self.user_i[account]
        if claim or user_i < self.integral:
            accrued = self.claimable[account] + self.balances[account] * (self.integral - user_i) // self.SCALE
            if claim:
                if accrued > 0:
                    self.claimable[account] = 0
                    self.claimed[account] += accrued
                    self.reward_balance -= accrued
                    bal -= accrued
            else:
                self.claimable[account] = accrued
            self.user_i[account] = self.integral
        if bal != self.remaining:
            self.remaining = bal

    def stake(self, user, amount):
        self.checkpoint(user)
        self.balances[user] += amount
        self.supply += amount

    def withdraw(self, user, amount, claim):
        if claim:
            self.checkpoint(user, True)
        self.checkpoint(user)
        self.balances[user] -= amount
        self.supply -= amount

    def emergency(self, user, amount):
        self.balances[user] -= amount
        self.supply -= amount

    def transfer(self, source, destination, amount):
        self.checkpoint(source)
        self.checkpoint(destination)
        self.balances[source] -= amount
        self.balances[destination] += amount

    def donate(self, amount):
        self.reward_balance += amount
        self.donated += amount


class RewardCampaign:
    def __init__(self, seed, sequences, steps):
        self.rng = random.Random(seed)
        self.seed = seed
        self.sequences = sequences
        self.steps = steps
        self.local = Local()
        self.trace = []

    def now(self):
        return self.local.tester.get_block_by_number('latest')['timestamp']

    def setup_multi(self):
        l = self.local
        booster = l.deploy('MockBooster', l.deployer)
        voter_impl = l.deploy('MockVoterProxy', booster.address)
        l.etch('MockVoterProxy', VEFXS_PROXY)
        voter = l.w3.eth.contract(address=VEFXS_PROXY, abi=voter_impl.abi)
        l.tx(voter.functions.setOperator(booster.address))
        self.registry = l.deploy('MockPoolRegistry')
        self.reward = l.deploy('MockToken', 'Reward', 'RWD')
        self.multi = l.deploy('MultiRewards', self.registry.address)
        l.tx(self.multi.functions.initialize(0, True))
        l.tx(self.multi.functions.addReward(self.reward.address, l.deployer))
        reward_init_time = l.last_time
        for user in l.users:
            l.tx(self.registry.functions.setVault(0, user, user))
        self.model = MultiModel(reward_init_time)

    def check_multi(self, step):
        l, m = self.local, self.model
        for i, user in enumerate(l.users):
            assert self.multi.functions.balances(user).call() == m.balances[i], ('balance', step, i)
            assert self.multi.functions.rewards(user, self.reward.address).call() == m.pending[i], ('pending', step, i)
            assert self.multi.functions.userRewardPerTokenPaid(user, self.reward.address).call() == m.paid[i], ('paid', step, i)
            assert self.reward.functions.balanceOf(user).call() == m.claimed[i], ('claim', step, i)
        rd = self.multi.functions.rewardData(self.reward.address).call()
        expected = [m.finish, m.rate, m.last, m.stored]
        assert rd == expected, ('rewardData', step, rd, expected)
        assert self.multi.functions.totalSupply().call() == m.supply, ('supply', step)
        assert self.reward.functions.balanceOf(self.multi.address).call() == m.contract_balance, ('token-conservation', step)

    def run_multi_sequence(self, sequence):
        self.setup_multi()
        l, m = self.local, self.model
        for step in range(self.steps):
            action = self.rng.randrange(100)
            user_index = self.rng.randrange(3)
            user = l.users[user_index]
            if action < 24:
                amount = self.rng.randrange(1, 1_000_001) * E18
                l.tx(self.multi.functions.deposit(user, amount), user)
                m.deposit(l.last_time, user_index, amount)
                kind = 'deposit'
            elif action < 39:
                amount = self.rng.randrange(0, m.balances[user_index] + 1) if m.balances[user_index] else 0
                if amount:
                    l.tx(self.multi.functions.withdraw(user, amount), user)
                    m.withdraw(l.last_time, user_index, amount)
                kind = 'withdraw'
            elif action < 49:
                amount = self.rng.randrange(1, 100_001) * E18
                l.tx(self.reward.functions.mint(l.deployer, amount))
                l.tx(self.reward.functions.approve(self.multi.address, amount))
                l.tx(self.multi.functions.notifyRewardAmount(self.reward.address, amount))
                m.notify(l.last_time, amount)
                kind = 'notify'
            elif action < 69:
                l.tx(self.multi.functions.getReward(user), user)
                m.claim(l.last_time, user_index)
                kind = 'claim'
            else:
                seconds = self.rng.randrange(1, 3 * 86400)
                l.warp(seconds)
                kind = 'warp'
            self.check_multi(step)
            self.trace.append((sequence, step, kind))
        # Drain after all streaming has ended; every claim must remain solvent.
        l.warp(DURATION + 1)
        for i, user in enumerate(l.users):
            l.tx(self.multi.functions.getReward(user), user)
            m.claim(l.last_time, i)
            self.check_multi(self.steps + i)
        return {
            'funded': m.funded,
            'claimed': sum(m.claimed.values()),
            'contract_balance': m.contract_balance,
            'supply': m.supply
        }

    def setup_staked(self):
        l = self.local
        booster = l.deploy('MockBooster', l.deployer)
        voter = l.deploy('MockVoterProxy', booster.address)
        self.staking_token = l.deploy('MockToken', 'cvxFXS', 'cvxFXS')
        self.reward = l.deploy('MockToken', 'FXS', 'FXS')
        self.staked = l.deploy('StakedCvxFxs', self.staking_token.address, self.reward.address, voter.address)
        for user in l.users:
            l.tx(self.staking_token.functions.mint(user, 10_000_000 * E18), user if False else None)
            l.tx(self.staking_token.functions.approve(self.staked.address, MAX), user)
        self.model = StakedModel()

    def check_staked(self, step):
        l, m = self.local, self.model
        info = self.staked.functions.rewards(0).call()
        assert info[0] == self.reward.address
        assert info[1] == m.integral, ('integral', step, info[1], m.integral)
        assert info[2] == m.remaining, ('remaining', step, info[2], m.remaining)
        assert self.staked.functions.totalSupply().call() == m.supply, ('supply', step)
        assert self.reward.functions.balanceOf(self.staked.address).call() == m.reward_balance, ('reward-balance', step)
        for i, user in enumerate(l.users):
            assert self.staked.functions.balanceOf(user).call() == m.balances[i], ('balance', step, i)
            assert self.staked.functions.reward_integral_for(self.reward.address, user).call() == m.user_i[i], ('user-i', step, i)
            assert self.staked.functions.claimable_reward(self.reward.address, user).call() == m.claimable[i], ('claimable', step, i)
            assert self.reward.functions.balanceOf(user).call() == m.claimed[i], ('claimed', step, i)

    def run_staked_sequence(self, sequence):
        self.setup_staked()
        l, m = self.local, self.model
        for step in range(self.steps):
            action = self.rng.randrange(100)
            i = self.rng.randrange(3)
            user = l.users[i]
            if action < 24:
                amount = self.rng.randrange(1, 1_000_001) * E18
                l.tx(self.staked.functions.stake(amount, user), user)
                m.stake(i, amount)
                kind = 'stake'
            elif action < 39:
                amount = self.rng.randrange(0, m.balances[i] + 1) if m.balances[i] else 0
                claim = bool(self.rng.randrange(2))
                if amount:
                    l.tx(self.staked.functions.withdraw(amount, claim), user)
                    m.withdraw(i, amount, claim)
                kind = 'withdraw-claim' if claim else 'withdraw'
            elif action < 44:
                amount = self.rng.randrange(0, m.balances[i] + 1) if m.balances[i] else 0
                if amount:
                    l.tx(self.staked.functions.emergencyWithdraw(amount), user)
                    m.emergency(i, amount)
                kind = 'emergency'
            elif action < 59:
                j = self.rng.randrange(3)
                amount = self.rng.randrange(0, m.balances[i] + 1) if m.balances[i] else 0
                if amount:
                    l.tx(self.staked.functions.transfer(l.users[j], amount), user)
                    m.transfer(i, j, amount)
                kind = 'transfer'
            elif action < 69:
                l.tx(self.staked.functions.getReward(user), l.users[(i + 1) % 3])
                m.checkpoint(i, True)
                kind = 'claim'
            elif action < 79:
                l.tx(self.staked.functions.user_checkpoint(user), l.users[(i + 1) % 3])
                m.checkpoint(i)
                kind = 'checkpoint'
            else:
                amount = self.rng.randrange(1, 100_001) * E18
                l.tx(self.reward.functions.mint(l.deployer, amount))
                l.tx(self.reward.functions.transfer(self.staked.address, amount))
                m.donate(amount)
                kind = 'donate'
            self.check_staked(step)
            self.trace.append((sequence, step, kind))
        for i, user in enumerate(l.users):
            l.tx(self.staked.functions.getReward(user), user)
            m.checkpoint(i, True)
            self.check_staked(self.steps + i)
        return {
            'donated': m.donated,
            'claimed': sum(m.claimed.values()),
            'contract_balance': m.reward_balance,
            'supply': m.supply
        }

    def sandwich_control(self):
        self.setup_staked()
        l, m = self.local, self.model
        victim, attacker = l.users[0], l.users[1]
        l.tx(self.staked.functions.stake(100 * E18, victim), victim)
        m.stake(0, 100 * E18)
        l.tx(self.reward.functions.mint(l.deployer, 100 * E18))
        l.tx(self.reward.functions.transfer(self.staked.address, 100 * E18))
        m.donate(100 * E18)
        # Attacker arrives after the reward balance but before the next checkpoint.
        l.tx(self.staked.functions.stake(100 * E18, attacker), attacker)
        m.stake(1, 100 * E18)
        self.check_staked(0)
        # Victim accounting is lazy; checkpoint to materialize its pending amount.
        l.tx(self.staked.functions.user_checkpoint(victim), attacker)
        m.checkpoint(0)
        self.check_staked(1)
        assert m.claimable[0] == 100 * E18
        assert m.claimable[1] == 0
        return {'victim_pending': m.claimable[0], 'attacker_pending': m.claimable[1]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--seed', type=int, default=0xC0FFEE)
    parser.add_argument('--sequences', type=int, default=16)
    parser.add_argument('--steps', type=int, default=64)
    parser.add_argument('--output', default=str(ROOT / 'evidence/stateful-rewards.json'))
    args = parser.parse_args()
    campaign = RewardCampaign(args.seed, args.sequences, args.steps)
    control = campaign.sandwich_control()
    multi = [campaign.run_multi_sequence(i) for i in range(args.sequences)]
    staked = [campaign.run_staked_sequence(i) for i in range(args.sequences)]
    result = {
        'mode': 'EXACT_PRODUCTION_BYTECODE_STATEFUL_MODEL_AND_CONSERVATION',
        'compiler': '0.8.10+commit.fc410830; optimizer 200',
        'seed': args.seed,
        'sequences_per_contract': args.sequences,
        'steps_per_sequence': args.steps,
        'successful_transactions_including_setup': campaign.local.actions,
        'sandwich_negative_control': control,
        'multi_rewards': multi,
        'staked_cvx_fxs': staked,
        'status': 'PASS'
    }
    text = json.dumps(result, indent=2)
    Path(args.output).write_text(text + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('multi_rewards', 'staked_cvx_fxs')}, indent=2))
    print('Multi totals:', {k: sum(x[k] for x in multi) for k in ('funded', 'claimed', 'contract_balance')})
    print('Staked totals:', {k: sum(x[k] for x in staked) for k in ('donated', 'claimed', 'contract_balance')})


if __name__ == '__main__':
    main()
