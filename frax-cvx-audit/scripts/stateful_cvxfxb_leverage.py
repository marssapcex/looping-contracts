#!/usr/bin/env python3
"""Leveraged cvxFXB stateful model with a real-debt mock lender.

Production cvxFXB bytecode is unchanged. External FXB/FRAX/sFRAX, oracle, lender,
and sFRAX vault are deterministic local mocks. The lender uses 1:1 debt shares,
unrestricted FRAX liquidity, and no interest/liquidations; the sFRAX vault is 1:1.
"""
import argparse
import json
import random
from pathlib import Path
from stateful_rewards import Local, E18, MAX
from stateful_cvxfxb import floor_shares, floor_assets, ceil_shares, ceil_assets

ROOT = Path(__file__).resolve().parents[1]


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
        self.oracle = l.deploy('MockDualOracle')
        self.lender = l.deploy('MockFraxLendLevered', self.fxb.address, self.frax.address, self.oracle.address)
        self.sfrax_vault = l.deploy('MockSfraxVault', self.frax.address, self.sfrax.address)
        self.vault = l.deploy(
            'cvxFXB', self.fxb.address, self.lender.address, self.frax.address,
            self.sfrax.address, self.sfrax_vault.address, l.deployer
        )
        l.tx(self.fxb.functions.mint(l.deployer, E18))
        l.tx(self.fxb.functions.transfer(self.vault.address, E18))
        l.tx(self.vault.functions.updateBalances())
        assert self.vault.functions.isPaused().call() is False
        assert self.lender.functions.debtShares().call() > 0
        assert self.lender.functions.collateral().call() == E18
        for user in l.users:
            l.tx(self.fxb.functions.mint(user, 10**12 * E18))
            l.tx(self.fxb.functions.approve(self.vault.address, MAX), user)
        self.model = Model()

    def check(self, sequence, step):
        l, m = self.local, self.model
        local_fxb = self.fxb.functions.balanceOf(self.vault.address).call()
        collateral = self.lender.functions.userCollateralBalance(self.vault.address).call()
        debt = self.lender.functions.userBorrowShares(self.vault.address).call()
        sfrax_balance = self.sfrax.functions.balanceOf(self.vault.address).call()
        vault_frax = self.frax.functions.balanceOf(self.vault.address).call()
        assert self.vault.functions.totalSupply().call() == m.supply, ('supply', sequence, step)
        assert self.vault.functions.totalAssets().call() == m.assets, ('assets', sequence, step)
        assert local_fxb + collateral == m.assets, ('collateral-solvency', sequence, step)
        assert self.lender.functions.collateral().call() == collateral
        assert self.lender.functions.debtShares().call() == debt
        assert self.lender.functions.toBorrowAmount(debt, True, True).call() == debt
        # Mock redeem retains redeemed sFRAX in the vault rather than burning it;
        # only shares held outside that vault remain claims on its FRAX balance.
        assert sfrax_balance == self.frax.functions.balanceOf(self.sfrax_vault.address).call(), ('sfrax-backing', sequence, step)
        assert self.vault.functions.getProfit().call() == sfrax_balance - debt, ('profit-view', sequence, step)
        # updateBalances deposits all loose FRAX outside internal repay transitions.
        assert vault_frax == 0, ('loose-frax', sequence, step, vault_frax)
        assert self.vault.functions.isPaused().call() is False
        for i, user in enumerate(l.users):
            assert self.vault.functions.balanceOf(user).call() == m.shares[i], ('shares', sequence, step, i)
        assert sum(m.shares.values()) + E18 == m.supply, ('share-sum', sequence, step)

    def run(self, sequence):
        self.setup()
        l, m = self.local, self.model
        names = ('deposit', 'mint', 'redeem', 'withdraw', 'donate', 'transfer',
                 'delegated_redeem', 'oracle_rebalance', 'explicit_rebalance')
        stats = {k: 0 for k in names}
        for step in range(self.steps):
            action = self.rng.randrange(110)
            i = self.rng.randrange(3)
            user = l.users[i]
            if action < 17:
                amount = self.rng.randrange(1, 100_001) * E18
                shares = floor_shares(amount, m.supply, m.assets)
                l.tx(self.vault.functions.deposit(amount, user), user)
                if shares > 0:
                    m.shares[i] += shares
                    m.supply += shares
                    m.assets += amount
                kind = 'deposit'
            elif action < 30:
                shares = self.rng.randrange(1, 100_001) * E18
                assets = ceil_assets(shares, m.supply, m.assets)
                l.tx(self.vault.functions.mint(shares, user), user)
                if assets > 0:
                    m.shares[i] += shares
                    m.supply += shares
                    m.assets += assets
                kind = 'mint'
            elif action < 43:
                shares = self.rng.randrange(0, m.shares[i] + 1) if m.shares[i] else 0
                assets = floor_assets(shares, m.supply, m.assets)
                if shares > 0 and assets > 0:
                    l.tx(self.vault.functions.redeem(shares, user, user), user)
                    m.shares[i] -= shares
                    m.supply -= shares
                    m.assets -= assets
                kind = 'redeem'
            elif action < 56:
                max_assets = floor_assets(m.shares[i], m.supply, m.assets)
                amount = self.rng.randrange(0, max_assets + 1) if max_assets else 0
                if amount > 0:
                    shares = ceil_shares(amount, m.supply, m.assets)
                    l.tx(self.vault.functions.withdraw(amount, user, user), user)
                    m.shares[i] -= shares
                    m.supply -= shares
                    m.assets -= amount
                kind = 'withdraw'
            elif action < 65:
                amount = self.rng.randrange(1, 100_001) * E18
                l.tx(self.fxb.functions.mint(l.deployer, amount))
                l.tx(self.fxb.functions.transfer(self.vault.address, amount))
                m.assets += amount
                kind = 'donate'
            elif action < 77:
                j = self.rng.randrange(3)
                amount = self.rng.randrange(0, m.shares[i] + 1) if m.shares[i] else 0
                if amount:
                    l.tx(self.vault.functions.transfer(l.users[j], amount), user)
                    m.shares[i] -= amount
                    m.shares[j] += amount
                kind = 'transfer'
            elif action < 88:
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
            elif action < 99:
                rate = self.rng.randrange(800_000, 1_200_001) * 10**12
                l.tx(self.oracle.functions.setRate(rate))
                l.tx(self.vault.functions.updateBalances(), user)
                kind = 'oracle_rebalance'
            else:
                l.tx(self.vault.functions.updateBalances(), user)
                kind = 'explicit_rebalance'
            stats[kind] += 1
            self.check(sequence, step)
        self.results.append(stats)
        return stats


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--seed', type=int, default=0xF0B1)
    p.add_argument('--sequences', type=int, default=2)
    p.add_argument('--steps', type=int, default=8)
    p.add_argument('--output', default=str(ROOT / 'evidence/stateful-cvxfxb-leverage.json'))
    args = p.parse_args()
    c = Campaign(args.seed, args.sequences, args.steps)
    for sequence in range(args.sequences):
        c.run(sequence)
    totals = {k: sum(x[k] for x in c.results) for k in c.results[0]}
    result = {
        'mode': 'EXACT_PRODUCTION_BYTECODE_LEVERAGE_STATEFUL_WITH_MOCK_DEBT',
        'seed': args.seed,
        'sequences': args.sequences,
        'steps_per_sequence': args.steps,
        'successful_transactions_including_setup': c.local.actions,
        'action_totals': totals,
        'status': 'PASS',
        'scope': 'Leverage call paths and accounting only. 1:1 debt/sFRAX, unrestricted liquidity, no interest/liquidations/yield; no current-mainnet claim.'
    }
    Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
