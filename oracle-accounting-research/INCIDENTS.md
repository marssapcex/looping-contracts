# Incident synthesis

The machine-readable source of truth for individual rows is [`corpus.csv`](corpus.csv). This document explains how to reuse the corpus without collapsing distinct mechanisms or economic accounts.

## A. Raw balances, donations, and caps

### Moonwell MAMO and Venus THE — Compound-fork cash accounting

Both incidents combined direct token transfers with a mint-path supply cap. The transfer did not mint new supplier shares; it increased the assets represented by existing shares. Consequently, checking cap only during mint did not bound the collateral value of the pre-existing position. The external price feed is a second layer, not a substitute for internal-cash accounting.

- MAMO separates `$11,028,762` gross principal from `$8,729,454` CCTP outflow ([1](https://forum.moonwell.fi/t/post-mortem-mamo-market-incident-on-base/2208)).
- THE reached 53.23M effective supplied units against a 14.5M cap, approximately `$14.9M` borrowed, and just over `$2M` bad debt. Those are not interchangeable ([2](https://community.venus.io/t/the-market-incident-post-mortem/5712)).

**Audit invariant:** a donation must not increase cap-checked borrowing claims without passing the same cap transition. Test both the donation and an honest mint immediately before and after it.

### Silo soUSDC and Lazy Summer — cap-zero is not removal

These incidents move the same boundary into strategy/vault composition. An external transfer can credit a strategy position without passing the vault's allocation function. If `totalAssets()` counts that position and redemptions are funded from another liquid strategy, the donor can pre-acquire vault shares, inflate reported NAV, and exit against other depositors' liquidity.

Silo additionally relied on a wrapper/staking exchange rate while the underlying had depegged. Summer's report explicitly rejects the simplified “withdrawable versus total assets bug” narrative: the impaired Ark remained active and mispriced during offboarding ([3](https://blocksec.com/blog/weekly-web3-security-incident-roundup-mar-30-apr-5-2026), [4](https://blog.summer.fi/lazy-summer-usdc-vault-exploit-post-mortem-what-happened-and-what-comes-next/)).

**Audit invariant:** `cap=0` must not be treated as proof of zero exposure. Enumerate active-set membership, external credit paths, valuation, and withdrawal-queue funding separately.

### Resupply, Hundred, Sonne, Radiant, and Raft — donation is only one ingredient

Empty/near-empty markets combine donation with index initialization and integer rounding. Resupply's one-wei share state drove the lending exchange rate to zero; Radiant is an empty-market accounting incident, not an external-feed compromise. Raft is a critical accounting counterexample: the protocol/AMM lost value while the attacker likely lost money after burning most proceeds ([5](https://www.guardrail.ai/blog/resupplyfi-hack), [6](https://blocksec.com/blog/6-hundred-finance-incident-catalyzing-the-wave-of-precision-related-exploits-in-vulnerable-forked-protocols), [7](https://www.coindesk.com/tech/2023/11/10/defi-platform-raft-suffers-33m-exploit-but-hacker-likely-takes-a-loss-on-the-attack)).

**Audit invariant:** test zero supply, one wei, the first nonzero share mint, rounding in both directions, and repeated small operations versus one large operation. Require attacker net P&L; do not infer profit from protocol damage.

## B. Vault/wrapper PPS as an oracle input

Cream yUSD, Inverse yvcrv3crypto, Lodestar plvGLP, Venus wUSDM, Resupply cvcrvUSD, Curve sDOLA, Edel wGOOGLx, and Makina MachineShareOracle all show variants of a derived accounting ratio being treated as a stable market price.

The Curve case is especially useful because no single condition was sufficient: LLAMMA exchange, extreme collateral concentration, permissionless `stake()` donation, and instantaneous `convertToAssets()` composed. The report distinguishes approximately 822,475 crvUSD borrower loss, about `$245K` attacker profit, and a separate later liquidator profit ([8](https://gov.curve.finance/t/llamalend-sdola-long2-post-mortem/11020)).

**Audit invariant:** bound both upward and downward one-block changes in any PPS used for collateral or liquidation. A TWAP on one multiplicand does not smooth an instantaneous vault-PPS multiplicand.

## C. Source-market and aggregation capture

bZx, Harvest, Cheese Bank, Warp, Inverse INV, Mango, Moola, Polter, UwU Lend, Balance, LML, and Tectonic demonstrate spot pools, thin markets, correlated sources, reward-price mismatches, and missing deviation/floor controls.

Tectonic's final accounting supersedes early `$75M` estimates: `$120.4M` affected borrowing, about `$111.2M` reversed by rollback, and `$9.19M` unrecovered off-chain ([9](https://www.theblock.co/news/ecosystems/2026-09-08-cronos-post-mortem-413724)).

Venus THE also shows that a deviation guard can be correct yet temporary: the BoundValidator rejected divergence for about 37 minutes, then accepted after sources converged. The supply-cap and exchange-rate failure remained independently exploitable ([10](https://blocksec.com/blog/venus-thena-donation-attack)).

**Audit invariant:** calculate manipulation cost against borrow/liquidation capacity and guard delay. A median or pivot feed is not independent if an attacker can move enough constituent venues.

## D. Wrong data, stale data, and invalid composition

- Moonwell cbETH omitted ETH/USD composition, leaving cbETH near `$1.12`; 1,096.317 cbETH liquidations and `$1,779,044.83` bad debt are separate quantities ([11](https://www.theblock.co/post/390302/defi-lending-protocol-moonwell-hit-with-1-8-million-bad-debt-after-oracle-misconfiguration)).
- Ploutos used BTC/USD for USDC; 8 USDC collateral supported 187 ETH borrowed ([12](https://x.com/Phalcon_xyz/status/2026943448734114011)).
- Aave CAPO paired a partially updated ratio with an advanced timestamp. It caused user liquidations but **no protocol bad debt** ([13](https://governance.aave.com/t/post-mortem-exchange-rate-misallignment-on-wsteth-core-and-prime-instances/24269)).
- Ribbon/Aevo combined weak price-setting access control with an 8/18 decimal mismatch ([14](https://www.halborn.com/blog/post/explained-the-aevo-ribbon-finance-hack-december-2025)).
- Venus/Blizz LUNA illustrates a minimum-price circuit breaker plus a consumer that failed to pause, not generic corruption of every Chainlink feed ([15](https://medium.com/@blizzfinance/blizz-finance-post-mortem-2425a33fe28b)).

**Audit invariant:** bind asset, base, quote, decimals, round timestamp, validity flag, min/max, and configured feed address into one test. Never validate only a numeric answer.

## E. Authenticity, collateral admission, and route validation

Bonzo is an upstream verifier failure: an unsigned/invalid proof was accepted and stored before lending consumed it. Kelp is compromised verifier infrastructure and a 1-of-1 DVN, not a market-price exploit. Ionic is counterfeit collateral admission. Echo is an unbacked privileged mint whose `$76.7M` nominal face value must not replace the roughly `$867K` real extraction ([16](https://bonzo.finance/blog/bonzo-lend-incident-report-oracle-provider-exploit), [17](https://www.chainalysis.com/blog/kelpdao-bridge-exploit-april-2026/), [18](https://postmortem.s3.us-east-1.amazonaws.com/postmortem.pdf), [19](https://www.merklescience.com/blog/hack-track-the-echo-protocol-ebtc-incident)).

Rhea is a different and directly reusable boundary: `verify_token_out()` summed intermediate terminal-token outputs even when the next hop consumed them. Fake circular pools therefore fabricated solvency input. The final `$18.4M` protocol estimate and reported full recovery are distinct from the earlier `$7.6M` extraction account ([20](https://blocksec.com/blog/weekly-web3-security-incident-roundup-apr-13-apr-19-2026)).

**Audit invariant:** authenticate the signer/verifier and collateral canonical identity, then validate actual route execution output. Do not infer actual received value from declared `minAmountOut` or sum intermediate hops.

## F. Comparators that prevent misclassification

- **Euler:** donation and missing post-action solvency/self-liquidation logic, not external price-feed manipulation ([21](https://smartcontractshacking.com/hacks/euler-finance-hack-2023)).
- **Radiant:** empty-market index/rounding, not external feed manipulation.
- **dForce:** read-only reentrancy changed the Curve virtual-price observation ([22](https://rekt.news/dforce-network-rekt)).
- **Drift:** governance/durable-nonce takeover enabled fake collateral and withdrawal removal; not a standalone permissionless oracle bug ([23](https://blocksec.com/blog/drift-protocol-incident-multisig-governance-compromise-via-durable-nonce-exploitation)).
- **Compound DAI:** approximately `$89M` liquidation volume is not equivalent to attacker cash profit ([24](https://blog.mounir.io/posts/the-compound-incident/)).

These comparators remain useful for tests but should not inflate an “oracle exploit” count.
