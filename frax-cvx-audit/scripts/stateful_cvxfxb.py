#!/usr/bin/env python3
"""Paused/zero-debt cvxFXB ERC4626 stateful campaign on production bytecode."""
import argparse
import json
import random
from pathlib import Path
from stateful_rewards import Local, E18, MAX

ROOT = Path(__file__).resolve().parents[1]


def floor_shares(assets, supply, total_assets):
    return assets if supply == 0 else assets * supply // total_assets


def floor_assets(shares, supply, total_assets):
    return shares if supply == 0 else total_assets * shares // supply


def ceil_div(a, b):
    return (a + b - 1) // b


def ceil_shares(assets, supply, total_assets):
    return assets if supply == 0 else ceil_div(assets * supply, total_assets)


def ceil_assets(shares, supply, total_assets):
    return shares if supply == 0 else ceil_div(total_assets * shares, supply)


class Model:
    def __init__(self):
        self.supply = E18
        self.assets = E18
        self.shares = {i: 0 for i in range(3)}


class Campaign:
    def __init__(self, seed, sequences, steps):
        self.rng = random.Random(seed)
        self.sequences = sequences
        self.steps = steps
        self.local = Local()
        self.results = []

    def setup(self):
        l = self.local
        self.fxb = l.deploy('MockToken', 'FXB', 'FXB')
        self.frax = l.deploy('MockToken', 'FRAX', 'FRAX')
        self.sfrax = l.deploy('MockToken', 'sFRAX', 'sFRAX')
        lender = l.deploy('MockFraxLendZero')
        self.vault = l.deploy(
            'cvxFXB', self.fxb.address, lender.address, self.frax.address,
            self.sfrax.address, self.sfrax.address, l.deployer
        )
        # Required deployment seed for the constructor's one unbacked share.
        l.tx(self.fxb.functions.mint(l.deployer, E18))
        l.tx(self.fxb.functions.transfer(self.vault.address, E18))
        # Freeze all leverage so this campaign isolates share/asset accounting.
        l.tx(self.vault.functions.setPaused(True))
        for user in l.users:
            l.tx(self.fxb.functions.mint(user, 10**15 * E18))
            l.tx(self.fxb.functions.approve(self.vault.address, MAX), user)
        self.model = Model()

    def check(self, sequence, step):
        l, m = self.local, self.model
        assert self.vault.functions.totalSupply().call() == m.supply, ('supply', sequence, step)
        assert self.vault.functions.totalAssets().call() == m.assets, ('assets', sequence, step)
        assert self.fxb.functions.balanceOf(self.vault.address).call() == m.assets, ('solvency', sequence, step)
        assert self.vault.functions.isPaused().call() is True
        for i, user in enumerate(l.users):
            assert self.vault.functions.balanceOf(user).call() == m.shares[i], ('shares', sequence, step, i)
        assert sum(m.shares.values()) + E18 == m.supply, ('share-sum', sequence, step)

    def run(self, sequence):
        self.setup()
        l, m = self.local, self.model
        stats = {k: 0 for k in ('deposit', 'mint', 'redeem', 'withdraw', 'donate', 'transfer', 'delegated_redeem')}
        for step in range(self.steps):
            action = self.rng.randrange(100)
            i = self.rng.randrange(3)
            user = l.users[i]
            if action < 20:
                amount = self.rng.randrange(1, 1_000_001) * E18
                shares = floor_shares(amount, m.supply, m.assets)
                l.tx(self.vault.functions.deposit(amount, user), user)
                if shares > 0:
                    m.shares[i] += shares
                    m.supply += shares
                    m.assets += amount
                kind = 'deposit'
            elif action < 35:
                shares = self.rng.randrange(1, 1_000_001) * E18
                assets = ceil_assets(shares, m.supply, m.assets)
                l.tx(self.vault.functions.mint(shares, user), user)
                if assets > 0:
                    m.shares[i] += shares
                    m.supply += shares
                    m.assets += assets
                kind = 'mint'
            elif action < 50:
                shares = self.rng.randrange(0, m.shares[i] + 1) if m.shares[i] else 0
                assets = floor_assets(shares, m.supply, m.assets)
                if shares > 0 and assets > 0:
                    l.tx(self.vault.functions.redeem(shares, user, user), user)
                    m.shares[i] -= shares
                    m.supply -= shares
                    m.assets -= assets
                kind = 'redeem'
            elif action < 65:
                max_assets = floor_assets(m.shares[i], m.supply, m.assets)
                amount = self.rng.randrange(0, max_assets + 1) if max_assets else 0
                if amount > 0:
                    shares = ceil_shares(amount, m.supply, m.assets)
                    l.tx(self.vault.functions.withdraw(amount, user, user), user)
                    m.shares[i] -= shares
                    m.supply -= shares
                    m.assets -= amount
                kind = 'withdraw'
            elif action < 75:
                amount = self.rng.randrange(1, 1_000_001) * E18
                l.tx(self.fxb.functions.mint(l.deployer, amount))
                l.tx(self.fxb.functions.transfer(self.vault.address, amount))
                m.assets += amount
                kind = 'donate'
            elif action < 90:
                j = self.rng.randrange(3)
                amount = self.rng.randrange(0, m.shares[i] + 1) if m.shares[i] else 0
                if amount:
                    l.tx(self.vault.functions.transfer(l.users[j], amount), user)
                    m.shares[i] -= amount
                    m.shares[j] += amount
                kind = 'transfer'
            else:
                shares = self.rng.randrange(0, m.shares[i] + 1) if m.shares[i] else 0
                assets = floor_assets(shares, m.supply, m.assets)
                if shares > 0 and assets > 0:
                    spender = l.users[(i + 1) % 3]
                    l.tx(self.vault.functions.approve(spender, shares), user)
                    l.tx(self.vault.functions.redeem(shares, spender, user), spender)
                    assert self.vault.functions.allowance(user, spender).call() == 0
                    m.shares[i] -= shares
                    m.supply -= shares
                    m.assets -= assets
                kind = 'delegated_redeem'
            stats[kind] += 1
            self.check(sequence, step)
        self.results.append(stats)
        return stats


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--seed', type=int, default=0xF0B)
    p.add_argument('--sequences', type=int, default=16)
    p.add_argument('--steps', type=int, default=64)
    p.add_argument('--output', default=str(ROOT / 'evidence/stateful-cvxfxb.json'))
    args = p.parse_args()
    c = Campaign(args.seed, args.sequences, args.steps)
    for sequence in range(args.sequences):
        c.run(sequence)
    totals = {k: sum(x[k] for x in c.results) for k in c.results[0]}
    result = {
        'mode': 'EXACT_PRODUCTION_BYTECODE_PAUSED_ZERO_DEBT_ERC4626_STATEFUL',
        'seed': args.seed,
        'sequences': args.sequences,
        'steps_per_sequence': args.steps,
        'successful_transactions_including_setup': c.local.actions,
        'action_totals': totals,
        'status': 'PASS',
        'scope': 'Share/asset accounting only. No leverage, oracle, sFRAX-yield, or current-mainnet claim.'
    }
    Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
