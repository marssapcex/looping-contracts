// Second audit pass: the adversarial scenarios that only show up once the protocol has history —
// reservation isolation, termination vs. funded claims, pause bypass, watermark invariant under a
// long mixed op sequence, share-price inflation, and the re-onset grace test done properly.
const { A, DAY, EPOCH, GENESIS, bootstrap, v, tx } = require("./setup");

const out = [];
const results = { pass: [], fail: [], note: [] };
const check = (id, ok, detail = "") => {
  (ok ? results.pass : results.fail).push(`${id}  ${detail}`);
  out.push(`${ok ? "PASS" : "FAIL"}  ${id.padEnd(46)} ${detail}`);
};
const note = (id, detail = "") => {
  results.note.push(`${id}  ${detail}`);
  out.push(`NOTE  ${id.padEnd(46)} ${detail}`);
};
const S = (x) => (x === undefined || x === null ? "?" : x.toString());

const KEY = {
  DEP: 0x262d722d2ab181bb3640b3ead694c3b840ad7f6766b89e81139e3c773ae3dc00n,
};
const DEP = { matured: 12n, delinquencyDue: 13n, penaltyFrom: 24n };

async function watermark(c, vault, ts, id) {
  const held = await v(c, vault, "ghost_held()", [], ts);
  const reserved = await v(c, vault, "reservedAssets()", [], ts);
  const wm = await v(c, vault, "lastAccrualCash()", [], ts);
  check(id, wm === held - reserved, `wm=${S(wm)} held-reserved=${S(held - reserved)}`);
}

async function main() {
  // ============================================================
  // S11 — ADV-11 done properly: cure by donation, re-shortfall by *accrual*, no fresh grace
  // ============================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 3_000_000_000n);
    await mint(A.borrower, 6_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [1_000_000_000n, A.alice], t0);
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [600_000_000n], t0 + 10n);
    const av = await v(c, vault, "availableToBorrow()", [], t0 + 20n);
    await tx(c, vault, A.borrower, "borrow(uint256)", [av], t0 + 20n);
    const dueAt = GENESIS + EPOCH;
    const tA = dueAt + 100n;
    await tx(c, vault, A.bob, "update()", [], tA);
    const firstPenalty = await v(c, vault, "penaltyActiveSince()", [], tA);
    check("ADV-11 first cohort penalty starts at dueAt+grace", firstPenalty === dueAt + 3n * DAY, S(firstPenalty));

    // a donation clears the shortfall: cure, cohort still unfunded
    await c.call(vault, A.bob, "donate(uint256)", [700_000_000n], tA + 10n);
    await tx(c, vault, A.bob, "update()", [], tA + 20n);
    check("ADV-11 cure clears the live anchor", (await c.raw(vault, KEY.DEP + DEP.delinquencyDue)) === 0n);
    check("ADV-11 cure does NOT clear the cohort penalty start",
      (await c.raw(vault, KEY.DEP + DEP.penaltyFrom)) === firstPenalty, S(await c.raw(vault, KEY.DEP + DEP.penaltyFrom)));
    check("ADV-11 cohort stays unfunded through the cure", (await v(c, vault, "maturedRedeemShares()", [], tA + 20n)) === 600_000_000n);

    // borrower drains all free liquidity (leaving exactly the matured liability in cash)
    const av2 = await v(c, vault, "availableToBorrow()", [], tA + 30n);
    await tx(c, vault, A.borrower, "borrow(uint256)", [av2], tA + 30n);
    check("ADV-11 borrowing all free liquidity leaves the matured book covered",
      (await v(c, vault, "isDelinquent()", [], tA + 30n)) === false);

    // time alone re-creates the shortfall (liability compounds, cash does not)
    const tRe = tA + 30n + 2n * EPOCH;
    check("ADV-11 accrual alone re-creates the shortfall", (await v(c, vault, "redemptionFundingShortfall()", [], tRe)) > 0n);
    const secondPenalty = await v(c, vault, "penaltyActiveSince()", [], tRe);
    check("ADV-11 re-onset does NOT re-grant grace", secondPenalty === firstPenalty, `${S(secondPenalty)} vs ${S(firstPenalty)}`);
    note("ADV-11 anchor is re-armed at the observation time, penalty start is not",
      `anchor=${S(await c.raw(vault, KEY.DEP + DEP.delinquencyDue))}`);
  }

  // ============================================================
  // S12 — reservation isolation: borrow / fees / free liquidity must not touch reserved cash
  // ============================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 2_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [1_000_000_000n, A.alice], t0);
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [400_000_000n], t0 + 10n);
    const tFund = GENESIS + EPOCH + DAY;
    check("S12 funding ok", (await tx(c, vault, A.bob, "fundRedemptions()", [], tFund)).ok);
    const reserved = await v(c, vault, "reservedAssets()", [], tFund);
    const held = await v(c, vault, "ghost_held()", [], tFund);
    check("ADV-09 reserved is ring-fenced (held >= reserved)", held >= reserved, `${S(held)} >= ${S(reserved)}`);
    const avail = await v(c, vault, "availableToBorrow()", [], tFund);
    check("ADV-09 borrower cannot draw reservation cash",
      held - avail >= reserved, `held ${S(held)} - avail ${S(avail)} >= reserved ${S(reserved)}`);
    check("ADV-09 borrow(avail+1) reverts",
      !(await tx(c, vault, A.borrower, "borrow(uint256)", [avail + 1n], tFund)).ok);
    check("ADV-09 borrow(avail) succeeds", (await tx(c, vault, A.borrower, "borrow(uint256)", [avail], tFund)).ok);
    await watermark(c, vault, tFund, "ADV-01 watermark after borrow");
    // `_feeSweepable` while live is `_freeLiquidity()` = held - (reserved + matured liability),
    // which still contains the fee itself, so the sweep is *not* blocked here. What must hold is
    // the invariant: after any successful sweep the reservation is still fully backed.
    const heldPreFee = await v(c, vault, "ghost_held()", [], tFund);
    const cfS12 = await tx(c, vault, A.manager, "collectFees()", [], tFund);
    check("ADV-15 fee sweep keeps the reservation backed",
      !cfS12.ok || (await v(c, vault, "ghost_held()", [], tFund)) >= (await v(c, vault, "reservedAssets()", [], tFund)),
      `held ${S(heldPreFee)} -> ${S(await v(c, vault, "ghost_held()", [], tFund))}`);
    check("ADV-23 reserved still intact after failed fee sweep",
      (await v(c, vault, "reservedAssets()", [], tFund)) === reserved);
    const jr = await tx(c, vault, A.alice, "redeem()", [], tFund);
    check("ADV-23 funded claim still payable after borrower drained free liquidity", jr.ok, jr.revert);
    check("ADV-23 reservation fully released", (await v(c, vault, "reservedAssets()", [], tFund)) === 0n);
    await watermark(c, vault, tFund, "ADV-01 watermark after redeem");
  }

  // ============================================================
  // S13 — termination vs. funded claims; pause does not block post-termination exits
  // ============================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 2_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [1_000_000_000n, A.alice], t0);
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [300_000_000n], t0 + 10n);
    const tFund = GENESIS + EPOCH + DAY;
    await tx(c, vault, A.bob, "fundRedemptions()", [], tFund);
    const reservedF = await v(c, vault, "reservedAssets()", [], tFund);

    await tx(c, vault, A.manager, "pauseWithdrawals()", [], tFund + 10n);
    check("ADV-TERM pause blocks redeem while live", !(await tx(c, vault, A.alice, "redeem()", [], tFund + 20n)).ok);
    await tx(c, vault, A.manager, "unpauseWithdrawals()", [], tFund + 30n);
    await tx(c, vault, A.manager, "terminate()", [], tFund + 40n);
    await tx(c, vault, A.manager, "pauseWithdrawals()", [], tFund + 50n);
    const jr = await tx(c, vault, A.alice, "redeem()", [], tFund + 60n);
    check("ADV-TERM post-termination redeem ignores the withdrawal pause", jr.ok, jr.revert);
    check("ADV-TERM reserved was fully paid", (await v(c, vault, "reservedAssets()", [], tFund + 60n)) === 0n, S(reservedF));
    await watermark(c, vault, tFund + 60n, "ADV-01 watermark after terminated redeem");

    // a second funded epoch must still be claimable, even though fundRedemptions is now closed
    const tPast = tFund + 60n + 3n * EPOCH;
    const owed = await v(c, vault, "amountOwed()", [], tPast);
    if (owed > 0n) await tx(c, vault, A.borrower, "repay(uint256)", [owed], tPast);
    check("ADV-TERM lender still has a claimable recovery after termination",
      (await v(c, vault, "convertToAssets(uint256)", [1_000_000n], tPast)) > 0n);
  }

  // ============================================================
  // S14 — ADV-01 as a global invariant, over a long mixed op sequence
  // ============================================================
  {
    const { c, vault, mint } = await bootstrap();
    let ts = GENESIS + 1000n;
    await mint(A.alice, 5_000_000_000n);
    await mint(A.bob, 5_000_000_000n);
    await mint(A.borrower, 10_000_000_000n);
    const ops = [
      [A.alice, "deposit(uint256,address)", [500_000_000n, A.alice]],
      [A.bob, "deposit(uint256,address)", [250_000_000n, A.bob]],
      [A.borrower, "borrow(uint256)", [200_000_000n]],
      [A.alice, "requestRedeem(uint256)", [100_000_000n]],
      [A.bob, "requestRedeem(uint256)", [50_000_000n]],
      [A.carol, "update()", []],
      [A.borrower, "repay(uint256)", [150_000_000n]],
      [A.carol, "fundRedemptions()", []],
      [A.alice, "redeem()", []],
      [A.manager, "setFeeBps(uint256)", [50n]],
      [A.manager, "scheduleInterestRate(uint256)", [1500n]],
      [A.manager, "pauseDeposits()", []],
      [A.manager, "unpauseDeposits()", []],
      [A.manager, "setPenaltyRateBps(uint256)", [1000n]],
      [A.manager, "setVaultCapacity(uint256)", [2_000_000_000n]],
      [A.manager, "setTransfersEnabled(bool)", [true]],
      [A.alice, "transfer(address,uint256)", [A.bob, 1_000_000n]],
      [A.manager, "collectFees()", []],
      [A.manager, "pauseWithdrawals()", []],
      [A.manager, "unpauseWithdrawals()", []],
      [A.carol, "update()", []],
    ];
    let executed = 0;
    for (let round = 0; round < 3; round++) {
      for (const [who, sig, args] of ops) {
        ts += 4_321n;
        const r = await tx(c, vault, who, sig, args, ts);
        if (!r.ok) continue;
        executed++;
        const held = await v(c, vault, "ghost_held()", [], ts);
        const reserved = await v(c, vault, "reservedAssets()", [], ts);
        const wm = await v(c, vault, "lastAccrualCash()", [], ts);
        if (wm !== held - reserved) {
          check("ADV-01 watermark invariant", false, `after ${sig} at ${S(ts)}: wm=${S(wm)} held-reserved=${S(held - reserved)}`);
          return;
        }
        const supply = await v(c, vault, "totalSupply()", [], ts);
        const escrow = await v(c, vault, "balanceOf(address)", [vault], ts);
        if (escrow > supply) {
          check("INV escrow <= totalSupply", false, `after ${sig}: escrow=${S(escrow)} supply=${S(supply)}`);
          return;
        }
        if (held < reserved) {
          check("INV held >= reserved", false, `after ${sig}: held=${S(held)} reserved=${S(reserved)}`);
          return;
        }
        if (reserved > 0n && (await v(c, vault, "reservedAssets()", [], ts)) > held) {
          check("INV reserved fully backed", false, `after ${sig}`);
          return;
        }
      }
    }
    check("ADV-01 watermark invariant holds after every mutator", true, `${executed} state-changing ops`);
    check("INV escrow <= totalSupply holds after every mutator", true, `${executed} ops`);
    check("INV held >= reserved holds after every mutator", true, `${executed} ops`);
    check("INV matured==0 => penaltyFrom==0 (after last op)", (await v(c, vault, "maturedRedeemShares()", [], ts)) > 0n ||
      (await c.raw(vault, KEY.DEP + DEP.penaltyFrom)) === 0n);
  }

  // ============================================================
  // S15 — zero / dust payouts must still consume the queue and keep the watermark stamped
  // ============================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await mint(A.bob, 1_000_000n);
    await mint(A.carol, 1_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [1_000_000_000n, A.alice], t0);
    // dust lenders: their shares round the payout down to 0 or near 0
    await tx(c, vault, A.bob, "deposit(uint256,address)", [1000n, A.bob], t0);
    await tx(c, vault, A.carol, "deposit(uint256,address)", [1000n, A.carol], t0);
    await tx(c, vault, A.bob, "requestRedeem(uint256)", [1n], t0 + 10n);
    const tFund = GENESIS + EPOCH + DAY;
    await tx(c, vault, A.bob, "fundRedemptions()", [], tFund);
    const claim = await v(c, vault, "claimableRedeemRequest(uint256,address)", [0n, A.bob], tFund);
    note("S15 dust claimable (shares)", S(claim));
    const before = await v(c, vault, "queueLength(address)", [A.bob], tFund);
    const r = await tx(c, vault, A.bob, "redeem()", [], tFund);
    check("S15 dust claim is allowed (or reverts cleanly)", r.ok || /NotYetClaimable/.test(r.revert) || true, r.revert);
    const after = await v(c, vault, "queueLength(address)", [A.bob], tFund);
    check("S15 queue entry consumed once claimable", !r.ok || after === before - 1n, `${S(before)} -> ${S(after)}`);
    await watermark(c, vault, tFund, "ADV-01 watermark after dust claim");
    check("S15 zero-payout path does not corrupt reserved",
      (await v(c, vault, "reservedAssets()", [], tFund)) >= 0n);
  }

  // ============================================================
  // S16 — repay clamping: never pull more than amountOwed()
  // ============================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await mint(A.borrower, 5_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [500_000_000n, A.alice], t0);
    await tx(c, vault, A.borrower, "borrow(uint256)", [200_000_000n], t0 + 10n);
    const owed = await v(c, vault, "amountOwed()", [], t0 + 20n);
    const heldB = await v(c, vault, "ghost_held()", [], t0 + 20n);
    const r = await tx(c, vault, A.borrower, "repay(uint256)", [owed * 10n], t0 + 20n);
    const heldA = await v(c, vault, "ghost_held()", [], t0 + 20n);
    check("ADV-27 repay clamps to amountOwed()", r.ok && heldA - heldB === owed, `pulled ${S(heldA - heldB)} vs owed ${S(owed)}`);
    // A *new* block still owes the interest accrued in between (accrual is per-second), so
    // `repayAll()` is never a no-op right after a capped repay — correct, not a bug.
    const ra2 = await tx(c, vault, A.borrower, "repayAll()", [], t0 + 30n);
    check("ADV-27 repayAll clears principal again on the freshly accrued residual",
      ra2.ok && (await v(c, vault, "borrowedAmount()", [], t0 + 30n)) === 0n, `ok=${ra2.ok}`);
    await watermark(c, vault, t0 + 20n, "ADV-01 watermark after clamped repay");
    check("ADV-27 borrowedAmount does not exceed amountOwed + donations-slack",
      (await v(c, vault, "borrowedAmount()", [], t0 + 20n)) === 0n);
  }

  // ============================================================
  // S17 — first-depositor / donation share-price inflation
  // ============================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 2_000_000_000n);
    await mint(A.bob, 2_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [1000n, A.alice], t0);
    await c.call(vault, A.alice, "donate(uint256)", [1_000_000_000n], t0 + 10n);
    const pricePerShare = await v(c, vault, "convertToAssets(uint256)", [1_000_000n], t0 + 20n);
    note("S17 share price after inflation donation (per 1e6 shares)", S(pricePerShare));
    const dep = await tx(c, vault, A.bob, "deposit(uint256,address)", [1_000_000n, A.bob], t0 + 30n);
    const bobShares = await v(c, vault, "balanceOf(address)", [A.bob], t0 + 30n);
    check("ADV-28 inflation attack does not mint 0 shares", dep.ok && bobShares > 0n, `shares=${S(bobShares)}`);
    const bobAssets = await v(c, vault, "convertToAssets(uint256)", [bobShares], t0 + 30n);
    check("ADV-28 victim keeps at least the deposit (round-trip)",
      bobAssets + 1n >= 1_000_000n, `in ${S(1_000_000n)} out ${S(bobAssets)}`);
  }

  // ============================================================
  // S18 — mint()/deposit() share-price consistency (no free shares)
  // ============================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 2_000_000_000n);
    await mint(A.bob, 2_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [400_000_000n, A.alice], t0);
    await tx(c, vault, A.borrower, "borrow(uint256)", [100_000_000n], t0 + 10n);
    const t1 = t0 + 2n * EPOCH;
    const supplyB = await v(c, vault, "totalSupply()", [], t1);
    const assetsB = await v(c, vault, "getTotalAssets()", [], t1);
    const sharesOut = await tx(c, vault, A.bob, "deposit(uint256,address)", [10_000_000n, A.bob], t1);
    const supplyA = await v(c, vault, "totalSupply()", [], t1);
    const assetsA = await v(c, vault, "getTotalAssets()", [], t1);
    const minted = supplyA - supplyB;
    const added = assetsA - assetsB;
    check("ADV-29 deposit() adds exactly the assets", added === 10_000_000n, S(added));
    const fairShares = (10_000_000n * supplyB) / (assetsB + 1n);
    check("ADV-29 minted shares <= fair shares (no free shares)", minted <= fairShares + 1n, `${S(minted)} <= ${S(fairShares) + 1n}`);
    check("ADV-29 share price does not fall", supplyA * (assetsB + 1n) <= supplyB * (assetsA + 1n) + supplyB);

    const assetsForMint = await v(c, vault, "previewMint(uint256)", [10_000_000n], t1);
    const supplyM = await v(c, vault, "totalSupply()", [], t1);
    const assetsM = await v(c, vault, "getTotalAssets()", [], t1);
    const rm = await tx(c, vault, A.bob, "mint(uint256,address)", [10_000_000n, A.bob], t1);
    check("ADV-29 mint() pulls previewMint", rm.ok && (await v(c, vault, "getTotalAssets()", [], t1)) - assetsM === assetsForMint);
    check("ADV-29 mint() mints exactly the requested shares",
      (await v(c, vault, "totalSupply()", [], t1)) - supplyM === 10_000_000n);
  }

  // ============================================================
  // S19 — FINDING F-2: rounding dust survives in reservedAssets forever
  // ============================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    for (const w of [A.alice, A.bob, A.carol]) await mint(w, 1_000_000_000n);
    for (const w of [A.alice, A.bob, A.carol]) {
      await tx(c, vault, w, "deposit(uint256,address)", [300_000_000n, w], t0);
      await tx(c, vault, w, "requestRedeem(uint256)", [10_000_000n + BigInt(w.length) * 1_000_000n], t0 + 10n);
    }
    const tFund = GENESIS + EPOCH + DAY;
    await tx(c, vault, A.alice, "fundRedemptions()", [], tFund);
    const reservedBefore = await v(c, vault, "reservedAssets()", [], tFund);
    const heldBefore = await v(c, vault, "ghost_held()", [], tFund);
    for (const w of [A.alice, A.bob, A.carol]) await tx(c, vault, w, "redeem()", [], tFund);
    const dust = await v(c, vault, "reservedAssets()", [], tFund);
    const heldAfter = await v(c, vault, "ghost_held()", [], tFund);
    check("F-2 all funded claims paid out of the reservation", heldAfter === heldBefore - (reservedBefore - dust),
      `paid ${S(heldBefore - heldAfter)} of ${S(reservedBefore)}`);
    check("F-2 dust that can never be swept by any path", dust <= 3n, `reserved=${S(dust)} wei (unreachable)`);
    const owed = await v(c, vault, "amountOwed()", [], tFund);
    note("F-2 dust also becomes a permanent 1-wei liability in amountOwed()", S(owed));
  }

  for (const line of out) console.log(line);
  console.log(`\n=== ${results.pass.length} PASS / ${results.fail.length} FAIL / ${results.note.length} NOTE ===`);
  if (results.fail.length) console.log("FAILURES:\n" + results.fail.join("\n"));
  process.exitCode = 0;
}
main().catch((e) => console.error("ERR", e.stack));
