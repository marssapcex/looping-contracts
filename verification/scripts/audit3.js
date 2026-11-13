// Probe the invariants I am unsure about before shipping them in CVL.
const { A, DAY, EPOCH, GENESIS, bootstrap, v, tx } = require("./setup");
const S = (x) => (x === undefined ? "?" : x.toString());
(async () => {
  // (a) can accrued interest push exposedAmount above vaultCapacity?
  {
    const { c, vault, mint } = await bootstrap({ rate: 1000n, fee: 100n });
    const t0 = GENESIS + 1000n;
    const cap = await v(c, vault, "vaultCapacity()", [], t0);
    await mint(A.alice, cap);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [cap - 1000n, A.alice], t0);
    const t1 = t0 + 5n * 365n * DAY;
    const exposed = await v(c, vault, "exposedAmount()", [], t1);
    console.log("capacity", S(cap), "exposed after 5y", S(exposed), "==> exposed<=cap?", exposed <= cap);
    console.log("maxDeposit when over cap:", S(await v(c, vault, "maxDeposit(address)", [A.alice], t1)));
    console.log("totalAssets when over cap:", S(await v(c, vault, "totalAssets()", [], t1)));
  }
  // (b) supply 0 with totalAssets > 0 (donation left behind)?
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [1_000_000n, A.alice], t0);
    await c.call(vault, A.alice, "donate(uint256)", [100_000_000n], t0 + 1n);
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [1_000_000n], t0 + 2n);
    const tF = GENESIS + EPOCH + DAY;
    await tx(c, vault, A.bob, "fundRedemptions()", [], tF);
    await tx(c, vault, A.alice, "redeem()", [], tF);
    console.log("supply", S(await v(c, vault, "totalSupply()", [], tF)),
                "totalAssets", S(await v(c, vault, "totalAssets()", [], tF)),
                "held", S(await v(c, vault, "ghost_held()", [], tF)));
  }
  // (c) past the termination cutoff: exposedAmount==0 but matured liability>0?
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [500_000_000n, A.alice], t0);
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [400_000_000n], t0 + 10n);
    const av = await v(c, vault, "availableToBorrow()", [], t0 + 20n);
    await tx(c, vault, A.borrower, "borrow(uint256)", [av], t0 + 20n);
    const termAt = t0 + EPOCH / 2n;
    await tx(c, vault, A.manager, "terminate()", [], termAt);
    const tPast = GENESIS + 2n * EPOCH;
    console.log("past cutoff: exposed", S(await v(c, vault, "exposedAmount()", [], tPast)),
      "dueUnprocessed", S(await v(c, vault, "dueUnprocessedAssets()", [], tPast)),
      "totalAssets", S(await v(c, vault, "totalAssets()", [], tPast)),
      "matured", S(await v(c, vault, "maturedRedeemShares()", [], tPast)),
      "shortfall", S(await v(c, vault, "redemptionFundingShortfall()", [], tPast)));
    console.log("maxDeposit past cutoff", S(await v(c, vault, "maxDeposit(address)", [A.alice], tPast)));
  }
  // (d) matured==0 but penaltyActiveSince!=0 (post wind-down escrow return)?
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [500_000_000n, A.alice], t0);
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [100_000_000n], t0 + 10n);
    const av = await v(c, vault, "availableToBorrow()", [], t0 + 20n);
    await tx(c, vault, A.borrower, "borrow(uint256)", [av], t0 + 20n);
    const tPast = GENESIS + 3n * EPOCH; // long delinquency, then terminate
    await tx(c, vault, A.manager, "terminate()", [], tPast);
    const tC = GENESIS + 5n * EPOCH;
    await tx(c, vault, A.alice, "claimRecovery()", [], tC);
    console.log("post-claim: matured", S(await v(c, vault, "maturedRedeemShares()", [], tC)),
      "penaltyActiveSince", S(await v(c, vault, "penaltyActiveSince()", [], tC)),
      "isDelinquent", S(await v(c, vault, "isDelinquent()", [], tC)));
  }
})().catch(e => console.error(e.stack));
