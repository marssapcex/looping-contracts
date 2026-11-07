# Preserved primary and technical-source notes

Accessed 2026-11-07. These are factual research extracts, not byte-for-byte mirrors of the linked pages. Each item preserves the source URL, source type, and conclusions used by the corpus. No screenshot or search snippet is represented as block-pinned evidence.

## Moonwell MAMO — protocol postmortem

URL: https://forum.moonwell.fi/t/post-mortem-mamo-market-incident-on-base/2208  
Type: primary protocol postmortem.  
Preserved facts: 15,089,595 MAMO supplied; 53,393,290 donated; approximately 3.68× exchange-rate movement; oracle approximately `$0.0106` to `$0.4313`; `$11,028,762` gross principal and `$8,729,454` CCTP outflow. The latter quantities are not combined or relabeled as attacker net profit.

Related technical analysis: https://www.certora.com/blog/moonwell-exploit-supply-cap-bypass-attack  
Preserved control: direct raw-balance donations bypassed a cap enforced only on the mint path.

## Venus THE — risk-manager postmortem

URL: https://community.venus.io/t/the-market-incident-post-mortem/5712  
Type: primary Allez Labs/Venus governance postmortem; attack transaction `0x4f477e941c12bbf32a58dc12db7bb0cb4d31d41ff25b2457e6af3c15d7f5663f`.  
Preserved facts: about 36M THE initially donated directly to vTHE, followed by borrow/donate loops; exchange rate `10,086,934,836` to `38,420,106,438` (3.81×); effective supplied THE peaked at 53,230,145/367% of the 14.5M cap; approximately `$14.9M` assets borrowed and just over `$2M` bad debt. The original supplier's vToken count did not need to increase for its represented collateral to increase. Binance/RedStone divergence caused BoundValidator reverts for about 37 minutes before convergence.

## Curve LlamaLend sDOLA-long2 — risk postmortem

URL: https://gov.curve.finance/t/llamalend-sdola-long2-post-mortem/11020  
Type: primary LlamaRisk/Curve governance postmortem; block 24,566,937; transaction `0xb93506af8f1a39f6a31e2d34f5f6a262c2799fef6e338640f42ab8737ed3d8a4`.  
Preserved facts: four necessary factors were permissionless LLAMMA exchange, 87.9% supply concentration in LLAMMA, permissionless `DolaSavings.stake()` donation, and unsmoothed instantaneous `convertToAssets()`. Twenty-seven borrowers with 10.9M crvUSD debt were hard-liquidated. Borrower loss was approximately 822,475 crvUSD; attacker profit about `$245K`; later liquidator profit separately about `$208K`. The report does not support adding those numbers into one “loss.”

## Lazy Summer USDC vaults — protocol postmortem

URL: https://blog.summer.fi/lazy-summer-usdc-vault-exploit-post-mortem-what-happened-and-what-comes-next/  
Type: primary protocol postmortem.  
Preserved facts: approximately `$6.04M` extracted across two Ethereum USDC vaults in one atomic transaction after months of position accumulation. Stale-valued receipt tokens were donated into zero-cap but still-active Arks included in NAV. The extraction was funded by other liquid Arks. The report explicitly says zero withdrawable balance in the manipulated Ark was not itself the bug and that a zero deposit cap does not remove an Ark from `getActiveArks()` or NAV.

Supporting risk-curator retrospective: https://forum.summer.fi/t/lazy-summer-protocol-exploit-july-6-2026-ba-labs-risk-curator-retrospective/856

## Aave wstETH CAPO — risk postmortem and reimbursement

URL: https://governance.aave.com/t/post-mortem-exchange-rate-misallignment-on-wsteth-core-and-prime-instances/24269  
Type: primary Chaos Labs/Aave governance postmortem.  
Preserved facts: `snapshotRatio` could not update at the same rate as `snapshotTimestamp`; the ratio remained too low for a seven-day timestamp reference. CAPO computed about 1.1939, below the live rate, producing about a 2.855% downward effective move and approximately 10,938 wstETH liquidated across Core and Prime. The protocol incurred no bad debt.

Reimbursement source: https://governance.aave.com/t/direct-to-aip-wsteth-capo-oracle-incident-user-reimbursement/24275  
Preserved distinction: liquidation losses, recovered searcher/builder value, and DAO reimbursement are separate from protocol bad debt.

## Bonzo/Supra — protocol incident report

URL: https://bonzo.finance/blog/bonzo-lend-incident-report-oracle-provider-exploit  
Type: primary protocol report.  
Preserved facts: the Supra verifier accepted an unsigned/invalid proof and stored manipulated SAUCE/HBAR data, which Bonzo lending then consumed. Wallet A principal was approximately `$9.05M`. This is classified as verifier authenticity, not source-market manipulation.

## Ionic counterfeit LBTC — protocol postmortem PDF

URL: https://postmortem.s3.us-east-1.amazonaws.com/postmortem.pdf  
Type: primary protocol report dated 2025-02-08 for the 2025-02-04 incident.  
Preserved facts: social-engineered approval of attacker-deployed counterfeit LBTC, supported by an attacker-associated Balancer pool and API3 feed; 250 LBTC minted and supplied; `$12.3M` supplied assets stolen; `$8.8M` frozen and `$3.5M` bridged off Mode. The report says the code functioned as written; the admission/provenance boundary failed.

## Sonne — protocol postmortem

URL: https://medium.com/@SonneFinance/post-mortem-sonne-finance-exploit-12f3daa82b06  
Type: primary protocol report.  
Preserved facts: permissionless, non-atomic market setup enabled the known empty-market donation exploit, approximately `$20M`. It belongs with initialization/index/rounding controls rather than external feed compromise.

## Inverse Frontier — official incident history

URL: https://docs.inverse.finance/inverse-finance/inverse-finance/legacy-products/frontier-anchor  
Type: official protocol history.  
Preserved facts: April 2022 INV/Keep3r manipulation approximately `$15.6M`; June 2022 yvcrv3crypto valuation incident approximately `$5.83M` protocol loss. Separate mechanisms and dates are preserved.

## Blizz/Venus LUNA — protocol postmortem

URL: https://medium.com/@blizzfinance/blizz-finance-post-mortem-2425a33fe28b  
Type: primary protocol report.  
Preserved facts: the LUNA feed's minimum-price circuit breaker remained at `$0.10` while the market collapsed; the consumer failed to pause. This is not used as evidence for a generic Chainlink failure and is not conflated with Venus's separate accounting.

## Rhea Burrowland — transaction-level security analysis

URL: https://blocksec.com/blog/weekly-web3-security-incident-roundup-apr-13-apr-19-2026  
Type: named security-firm technical reconstruction.  
Preserved facts: `RefV1TokenReceiverMessage.get_token_out()`/`verify_token_out()` summed `min_amount_out` for every hop producing the terminal token, including outputs immediately consumed by the next hop. Circular `A→B→A→B` paths through attacker pools fabricated the value used by open-position solvency checks; the callback booked actual dust without a recheck. Approximately `$18.4M` was drained.  
Recovery source: https://blocksec.com/blog/newsletter-april-2026 — all stolen funds reported recovered by 2026-04-23.

## Silo soUSDC/wstUSR — transaction-level security analysis

URL: https://blocksec.com/blog/weekly-web3-security-incident-roundup-mar-30-apr-5-2026  
Type: named security-firm technical reconstruction; transaction prefix `0xf77a…f3e1`.  
Preserved facts: immutable wstUSR/stUSR exchange-rate oracle continued near 1.133 after secondary-market value collapsed near 0.12; the soUSDC cap blocked its own deposits but not externally credited bUSDC positions; `totalAssets()` counted those positions without minting soUSDC shares. After borrowing the manipulated market's USDC, redemption shortfall was funded from healthy markets. Approximately `$359K` face-valued shortfall. No primary Silo postmortem was located in this research.

## YieldBlox/Blend — transaction-level security analysis

URL: https://blocksec.com/blog/yieldblox-dao-incident-on-stellar-oracle-misconfiguration-enabled-a-10m-drain  
Type: named security-firm technical reconstruction.  
Preserved facts: USTRY valuation used manipulable Stellar DEX/Reflector input. Blend V2 core was not implicated; the incident must be assigned to the valuation/integration layer.

## Tectonic/Cronos — final-accounting report of official postmortem

URL: https://www.theblock.co/news/ecosystems/2026-09-08-cronos-post-mortem-413724  
Type: secondary report quoting Cronos's official postmortem.  
Preserved facts: `$120.4M` affected borrowing across nine markets; rollback from block 90,907,150 to 90,896,188 reversed approximately `$111.2M`; `$9.19M` had left Cronos and remained unrecovered. These final figures supersede the earlier approximately `$75M` estimate used during the incident.

## KelpDAO/LayerZero — infrastructure analysis

URL: https://www.chainalysis.com/blog/kelpdao-bridge-exploit-april-2026/  
Type: named infrastructure/security analysis of LayerZero/Kelp reports.  
Preserved facts: two internal RPC nodes were compromised and external nodes disrupted, causing the sole 1-of-1 DVN to attest a nonexistent source-chain burn; 116,500 rsETH (about `$292M`) was released. This is a verifier/infrastructure comparator, not a market-price exploit.
