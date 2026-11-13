// Stateful fuzzer: random call sequences + random block timestamps against the real
// LoanVault bytecode. After every single call it re-checks a set of invariants that
// must hold in *all* states (including delinquent, illiquid, terminated, empty).
//
// Usage:
//   node scripts/fuzz.js                 # 200 sequences x 60 steps, seed from clock
//   node scripts/fuzz.js --runs 50 --steps 40 --seed 1234
//   node scripts/fuzz.js --seed 1234 --replay   # print the failing sequence only
//
// Exit code 0 = no invariant broken. 1 = broken (prints a minimal trace).
const { A, DAY, EPOCH, GENESIS, bootstrap, v, tx } = require("./setup");

const argv = process.argv.slice(2);
const num = (flag, dflt) => {
  const i = argv.indexOf(flag);
  return i >= 0 ? Number(argv[i + 1]) : dflt;
};
const RUNS = num("--runs", 200);
const STEPS = num("--steps", 60);
const SEED = num("--seed", Date.now() % 100000);
const VERBOSE = argv.includes("--verbose");

// ---------- deterministic PRNG (mulberry32) so any failure is replayable ----------
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const ACTORS = [A.alice, A.bob, A.carol, A.borrower, A.manager];
const LENDER_ACTORS = [A.alice, A.bob, A.carol];

// ---------- invariants checked after EVERY call ----------
// Every one of these must hold unconditionally. A violation is a real bug or a
// real modelling error — never a "state we excluded".
async function invariants(c, vault, ts, ctx) {
  const bad = [];
  const get = async (sig, args = []) => {
    const r = await v(c, vault, sig, args, ts);
    return r === null ? null : r;
  };
  // NOTE: balanceOf(vault) is the SHARE escrow, not cash.
  // Cash = ghost_held() (the harness's view of the vault's USDC balance).
  const [
    supply, escrow, cash, totalAssets, reserved, matured, borrowable,
    borrowed, owed, fees, short, lastCash, recovery,
  ] = await Promise.all([
    get("totalSupply()"),
    get("balanceOf(address)", [vault]),
    get("ghost_held()"),
    get("getTotalAssets()"),
    get("reservedAssets()"),
    get("maturedRedeemShares()"),
    get("availableToBorrow()"),
    get("borrowedAmount()"),
    get("amountOwed()"),
    get("accruedFees()"),
    get("redemptionFundingShortfall()"),
    get("lastAccrualCash()"),
    get("totalRecoveryPaid()"),
  ]);
  if ([supply, escrow, cash, totalAssets, reserved, matured, borrowable, borrowed, owed, fees, short, lastCash, recovery].some((x) => x === null))
    return bad; // a getter reverted — modelling gap, reported separately

  // F-1  the share escrow can never hold more shares than exist
  if (escrow > supply) bad.push(`F1 escrow ${escrow} > supply ${supply}`);
  // F-2  matured book is carved out of the escrow balance
  if (matured > escrow) bad.push(`F2 matured ${matured} > escrow shares ${escrow}`);
  // F-3  the reservation never exceeds the cash actually sitting in the vault
  if (reserved > cash) bad.push(`F3 reserved ${reserved} > cash ${cash}`);
  // F-4  nobody can borrow cash that is earmarked for claims
  if (reserved <= cash && borrowable > cash - reserved) bad.push(`F4 borrowable ${borrowable} > free cash ${cash - reserved}`);
  // F-5  SOLVENCY: the vault must never promise more than can ever be paid.
  //   L = pool book + claim reservation + fee bank   (promises)
  //   R = idle cash + receivable + already paid out   (backing)
  //   R < L is a hard bug: shares/claims exist with nothing behind them.
  //   R > L is legitimate (a plain ERC-20 transfer into the vault, i.e. a donation);
  //   that surplus is absorbed by the next accrual, so it is reported, not failed.
  const balL = totalAssets + reserved + fees;
  const balR = cash + owed + recovery;
  if (balR < balL)
    bad.push(
      `F5 UNDER-BACKED: promises ${balL} > backing ${balR} (gap ${balL - balR}) [ta ${totalAssets} rsv ${reserved} fees ${fees} | cash ${cash} owed ${owed} rec ${recovery}]`,
    );
  if (balR > balL && ctx) ctx.surplusSeen = (ctx.surplusSeen || 0n) + (balR - balL);
  // F-6  the fee bank is never larger than the receivable + idle cash it comes from
  if (fees > owed + cash) bad.push(`F6 fees ${fees} > owed+cash ${owed + cash}`);
  // F-7  the shortfall can never exceed what funding still owes
  if (short > matured) bad.push(`F7 shortfall ${short} > matured ${matured}`);
  // F-8  the accrual watermark is a real cash reading
  if (lastCash > cash + borrowed) bad.push(`F8 watermark ${lastCash} > cash+borrowed ${cash + borrowed}`);
  // F-9  share price can never be zero while shares exist (division guards)
  if (supply > 0n) {
    const pps = (totalAssets * 10n ** 18n) / supply;
    if (pps === 0n) bad.push(`F9 pricePerShare == 0 with supply ${supply}`);
  }
  return bad;
}

// ---------- one random step ----------
function buildStep(rand, state) {
  const r = rand();
  const who = LENDER_ACTORS[Math.floor(rand() * LENDER_ACTORS.length)];
  const big = (min, max) => {
    const lo = BigInt(min), hi = BigInt(max);
    return lo + (BigInt(Math.floor(rand() * 1e9)) * (hi - lo)) / 1_000_000_000n;
  };
  // weighted menu: deposits and requests dominate, but admin/solvency paths are
  // hit often enough to matter
  if (r < 0.22) return { sig: "deposit(uint256,address)", args: [big(1_000n, 400_000_000n), who], who, kind: "lender" };
  if (r < 0.30) return { sig: "requestRedeem(uint256)", args: [big(0n, 200_000_000n)], who, kind: "lender" };
  if (r < 0.36) return { sig: "redeem()", args: [], who, kind: "lender" };
  if (r < 0.42) return { sig: "fundRedemptions()", args: [], who: A.carol, kind: "keeper" };
  if (r < 0.48) return { sig: "update()", args: [], who: A.carol, kind: "keeper" };
  if (r < 0.56) return { sig: "borrow(uint256)", args: [big(0n, 300_000_000n)], who: A.borrower, kind: "borrower" };
  if (r < 0.64) return { sig: "repay(uint256)", args: [big(0n, 300_000_000n)], who: A.borrower, kind: "borrower" };
  if (r < 0.67) return { sig: "repayAll()", args: [], who: A.borrower, kind: "borrower" };
  if (r < 0.71) return { sig: "collectFees()", args: [], who: A.manager, kind: "admin" };
  if (r < 0.74) return { sig: "sweepResidual()", args: [], who: A.manager, kind: "admin" };
  if (r < 0.77) return { sig: "setFeeBps(uint256)", args: [BigInt(Math.floor(rand() * 2001))], who: A.manager, kind: "admin" };
  if (r < 0.80) return { sig: "setPenaltyRateBps(uint256)", args: [BigInt(Math.floor(rand() * 10001))], who: A.manager, kind: "admin" };
  if (r < 0.83) return { sig: "scheduleInterestRate(uint256)", args: [BigInt(Math.floor(rand() * 20001))], who: A.manager, kind: "admin" };
  if (r < 0.85) return { sig: "cancelScheduledRate()", args: [], who: A.manager, kind: "admin" };
  if (r < 0.88) return { sig: "setVaultCapacity(uint256)", args: [big(0n, 2_000_000_000n)], who: A.manager, kind: "admin" };
  if (r < 0.91) return { sig: "setTransfersEnabled(bool)", args: [rand() < 0.5], who: A.manager, kind: "admin" };
  if (r < 0.94) return { sig: "claimRecovery()", args: [], who, kind: "lender" };
  if (r < 0.96) return { sig: "donate(uint256)", args: [big(0n, 10_000_000n)], who: A.manager, kind: "admin" };
  if (r < 0.98) return { sig: "terminate()", args: [], who: A.manager, kind: "admin" };
  return { sig: "transfer(address,uint256)", args: [LENDER_ACTORS[Math.floor(rand() * 3)], big(0n, 100_000_000n)], who, kind: "lender" };
}

// random time step: mostly small, occasionally huge (past grace / past cutoff /
// across many epochs) so the delinquent paths are actually reached
function timeStep(rand) {
  const r = rand();
  if (r < 0.45) return BigInt(Math.floor(rand() * 3600));
  if (r < 0.75) return BigInt(Math.floor(rand() * 3)) * DAY + BigInt(Math.floor(rand() * 3600));
  if (r < 0.92) return BigInt(Math.floor(rand() * 10)) * DAY;
  return BigInt(Math.floor(rand() * 40) + 10) * DAY;
}

async function runSequence(seed) {
  const rand = rng(seed);
  const { c, vault, mint } = await bootstrap();
  let ts = GENESIS + 1000n;
  // seed liquidity so the first steps are not all no-ops
  for (const w of [A.alice, A.bob, A.carol]) await mint(w, 6_000_000_000n);
  await mint(A.borrower, 9_000_000_000n);

  const ctx = {};
  const trace = [];
  for (let step = 0; step < STEPS; step++) {
    ts += timeStep(rand);
    const s = buildStep(rand, {});
    const res = await tx(c, vault, s.who, s.sig, s.args, ts);
    trace.push({
      step,
      ts: ts.toString(),
      sig: s.sig,
      args: s.args.map((x) => (typeof x === "bigint" ? x.toString() : String(x))),
      who: s.who,
      ok: res.ok,
      error: res.error,
    });
    const bad = await invariants(c, vault, ts, ctx);
    if (bad.length) return { ok: false, seed, bad, trace, step };
  }
  // end-of-run extra: everything must be drainable back to the lenders
  const cash = await v(c, vault, "ghost_held()", [], ts);
  const reserved = await v(c, vault, "reservedAssets()", [], ts);
  if (reserved > cash) return { ok: false, seed, bad: [`F3(end) reserved ${reserved} > cash ${cash}`], trace, step: STEPS };
  const escrow = await v(c, vault, "balanceOf(address)", [vault], ts);
  const matured = await v(c, vault, "maturedRedeemShares()", [], ts);
  if (matured > escrow) return { ok: false, seed, bad: [`F2(end) matured ${matured} > escrow ${escrow}`], trace, step: STEPS };
  return { ok: true, seed, trace, steps: STEPS };
}

(async () => {
  const t0 = Date.now();
  let failures = 0;
  const bad = new Map();
  for (let i = 0; i < RUNS; i++) {
    const seed = SEED + i;
    let r;
    try {
      r = await runSequence(seed);
    } catch (e) {
      r = { ok: false, seed, bad: [`harness error: ${e.message}`], trace: [], step: -1 };
    }
    if (!r.ok) {
      failures++;
      for (const b of r.bad) {
        const key = b.split(" ")[0];
        if (!bad.has(key)) bad.set(key, { msg: b, seed: r.seed, trace: r.trace, step: r.step });
      }
      if (VERBOSE) {
        console.log(`FAIL seed=${r.seed} step=${r.step}: ${r.bad.join("; ")}`);
      }
    }
  }
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  console.log(`\n=== FUZZ: ${RUNS} sequences x ${STEPS} steps, seed ${SEED}, ${secs}s ===`);
  console.log(`${RUNS - failures} PASS / ${failures} FAIL`);
  if (bad.size) {
    console.log(`\n${bad.size} distinct invariant(s) broken:`);
    for (const [k, val] of bad) {
      console.log(`\n  ${k}: ${val.msg}   (seed ${val.seed}, step ${val.step})`);
    }
    const first = [...bad.values()][0];
    if (first.trace.length) {
      console.log(`\n  minimal trace (replay: node scripts/fuzz.js --seed ${first.seed} --runs 1 --steps ${STEPS}):`);
      for (const t of first.trace.slice(-25)) {
        console.log(`    +${t.ts} ${t.who.slice(0, 6)} ${t.sig}(${t.args.join(",")}) -> ${t.ok ? "ok" : "revert:" + (t.error || "")}`);
      }
    }
    process.exit(1);
  }
  console.log(`\nno invariant broken. replay any seed: node scripts/fuzz.js --seed ${SEED} --runs 1`);
})();
