// Empirical pre-check for every property shipped in certora/specs.
// Drives the real LoanVault bytecode (via LoanVaultHarness) and asserts, one by one, the exact
// property that the CVL states. Failures here are either (a) a property I must not state, or
// (b) a genuine protocol finding — both are reported with the reproducing sequence.
const { A, DAY, EPOCH, NOTICE, GENESIS, bootstrap, v, tx } = require("./setup");

const out = [];
const results = { pass: [], fail: [], note: [] };
function check(id, ok, detail = "") {
  (ok ? results.pass : results.fail).push(`${id}  ${detail}`);
  out.push(`${ok ? "PASS" : "FAIL"}  ${id.padEnd(44)} ${detail}`);
}
function note(id, detail) {
  results.note.push(`${id}  ${detail}`);
  out.push(`NOTE  ${id.padEnd(44)} ${detail}`);
}
const S = (x) => (x === undefined || x === null ? "?" : x.toString());

const KEY = {
  DEP: 0x262d722d2ab181bb3640b3ead694c3b840ad7f6766b89e81139e3c773ae3dc00n,
  WIT: 0x0f22b21bc2cca331f000138790d008f6fde42ad89895b8069425c37e5784e600n,
};
// LoanVaultDepositsStorage field offsets (slot = BASE + n)
// NOTE: `loanAsset` (address, 20 bytes) and `assetDecimals` (uint8) share slot 0, so every
// subsequent field is one slot earlier than a naive field-by-field count.
const DEP = {
  genesis: 1n,
  rate: 2n,
  borrower: 3n,
  capacity: 4n,
  minimum: 5n,
  totalAssets: 6n,
  lastAccrualTimestamp: 7n,
  scheduledShares: 8n, // mapping
  lenderRegistry: 9n,
  penaltyRate: 10n,
  grace: 11n,
  matured: 12n,
  delinquencyDue: 13n,
  terminatedAt: 14n,
  pendingRate: 15n,
  rateEpoch: 16n,
  transfersEnabled: 17n,
  accruedFees: 18n,
  reserved: 19n,
  resolutionShares: 20n,
  frozenAssets: 21n,
  totalRecoveryPaid: 22n,
  lastAccrualCash: 23n,
  penaltyFrom: 24n,
  epochDuration: 25n,
  withdrawalNotice: 26n,
  interestBase: 27n,
  basePeriodStart: 28n,
};

async function main() {
  // ==================================================================================
  // S1 — accrual, capacity, fee, conversions, owed identity
  // ==================================================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await mint(A.bob, 1_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [400_000_000n, A.alice], t0);
    await tx(c, vault, A.bob, "deposit(uint256,address)", [100_000_000n, A.bob], t0);
    await tx(c, vault, A.borrower, "borrow(uint256)", [300_000_000n], t0 + 1n);

    // multi-boundary jump: 4 epochs skipped in one accrual
    const t1 = t0 + 4n * EPOCH + DAY;
    const snap = async () => ({
      assets: await v(c, vault, "getTotalAssets()", [], t1),
      fees: await v(c, vault, "accruedFees()", [], t1),
      matured: await v(c, vault, "maturedRedeemShares()", [], t1),
      anchor: await v(c, vault, "penaltyActiveSince()", [], t1),
    });
    const before = await snap();
    await tx(c, vault, A.carol, "update()", [], t1);
    const after = await snap();
    check("ADV-10 view projection == execution (assets)", before.assets === after.assets, `${S(before.assets)}`);
    check("ADV-10 view projection == execution (fees)", before.fees === after.fees, `${S(before.fees)}`);
    check("ADV-10 view projection == execution (matured)", before.matured === after.matured);
    check("ADV-10 view projection == execution (anchor)", before.anchor === after.anchor);

    // storage read: unsettled projection equals settled storage
    const storedAssets = await c.raw(vault, KEY.DEP + DEP.totalAssets);
    check("ADV-10 storage totalAssets == getTotalAssets()", storedAssets === after.assets, `${S(storedAssets)}`);

    const held = await v(c, vault, "ghost_held()", [], t1);
    const reserved = await v(c, vault, "reservedAssets()", [], t1);
    const fees = after.fees;
    const rec = await v(c, vault, "totalRecoveryPaid()", [], t1);
    check("ADV-01 watermark == held - reserved", (await v(c, vault, "lastAccrualCash()", [], t1)) === held - reserved);
    const wantOwed = after.assets + reserved + fees > held + rec ? after.assets + reserved + fees - held - rec : 0n;
    check("ADV-16 amountOwed() identity", (await v(c, vault, "amountOwed()", [], t1)) === wantOwed, `${S(wantOwed)}`);
    check("ADV-16 storage reserved == reservedAssets()", (await c.raw(vault, KEY.DEP + DEP.reserved)) === reserved);
    check("ADV-16 storage fees == accruedFees()", (await c.raw(vault, KEY.DEP + DEP.accruedFees)) === fees);

    check("INV feeBps < interestRateBps", (await v(c, vault, "feeBps()", [], t1)) < (await v(c, vault, "interestRateBps()", [], t1)));
    check("INV held >= reservedAssets", held >= reserved, `${S(held)} >= ${S(reserved)}`);
    check("INV maxDeposit <= capacity", (await v(c, vault, "maxDeposit(address)", [A.bob], t1)) <= (await v(c, vault, "vaultCapacity()", [], t1)));
    check("INV exposedAmount <= capacity", (await v(c, vault, "exposedAmount()", [], t1)) <= (await v(c, vault, "vaultCapacity()", [], t1)));
    check("INV convertToShares(0)==0", (await v(c, vault, "convertToShares(uint256)", [0n], t1)) === 0n);
    check("INV convertToAssets(0)==0", (await v(c, vault, "convertToAssets(uint256)", [0n], t1)) === 0n);
    const c1 = await v(c, vault, "convertToShares(uint256)", [1_000_000n], t1);
    const c2 = await v(c, vault, "convertToShares(uint256)", [2_000_000n], t1);
    check("INV convertToShares monotone", c1 <= c2);
    const a1 = await v(c, vault, "convertToAssets(uint256)", [c1], t1);
    const a2 = await v(c, vault, "convertToAssets(uint256)", [c2], t1);
    check("INV convertToAssets monotone", a1 <= a2);
    check("INV share price not dilutable by deposit()", a1 <= 1_000_000n, `${S(a1)} <= 1e6`);
  }

  // ==================================================================================
  // S2 — redemption lifecycle: request -> mature -> fund -> claim
  // ==================================================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [500_000_000n, A.alice], t0);
    const t1 = t0 + 100n;

    const supply0 = await v(c, vault, "totalSupply()", [], t1);
    const bal0 = await v(c, vault, "balanceOf(address)", [A.alice], t1);
    const esc0 = await v(c, vault, "balanceOf(address)", [vault], t1);
    const rr = await tx(c, vault, A.alice, "requestRedeem(uint256)", [100_000_000n], t1);
    check("R-REQ requestRedeem ok", rr.ok, rr.revert);
    check("R-REQ totalSupply unchanged", supply0 === (await v(c, vault, "totalSupply()", [], t1)));
    check("R-REQ user balance -shares", (await v(c, vault, "balanceOf(address)", [A.alice], t1)) === bal0 - 100_000_000n);
    check("R-REQ escrow balance +shares", (await v(c, vault, "balanceOf(address)", [vault], t1)) === esc0 + 100_000_000n);
    check("INV escrow <= totalSupply", (await v(c, vault, "balanceOf(address)", [vault], t1)) <= supply0);

    const req = await v(c, vault, "getUserWithdrawalRequest(address,uint128)", [A.alice, 0n], t1);
    check("R-REQ claimableEpoch == current+1 (before deadline)", req[1] === 1n, `epoch=${S(req[1])}`);
    const sched = await c.raw(vault, c.mapKey("0x" + (1n).toString(16).padStart(64, "0"), KEY.DEP + DEP.scheduledShares));
    note("R-REQ scheduledWithdrawalShares[1] (storage)", S(sched));

    const t2 = t0 + EPOCH + DAY;
    const matured = await v(c, vault, "maturedRedeemShares()", [], t2);
    const due = await v(c, vault, "dueUnprocessedAssets()", [], t2);
    const ta2 = await v(c, vault, "getTotalAssets()", [], t2);
    check("R-MAT matured > 0 after its boundary", matured > 0n, S(matured));
    check("ADV-03 matured shares == epoch shares", matured === 100_000_000n);
    check("ADV-19 maturedLiability <= pool", due <= ta2, `${S(due)} <= ${S(ta2)}`);
    check("R-MAT storage maturedRedeemShares agrees", (await c.raw(vault, KEY.DEP + DEP.matured)) <= matured);

    const epr = await v(c, vault, "getEpochWithdrawalRequest(uint256)", [1n], t2);
    check("ADV-02 epoch.shares == scheduled shares", epr[0] === 100_000_000n && epr[1] === 0n && epr[2] === false);

    const supplyB = await v(c, vault, "totalSupply()", [], t2);
    const reservedB = await v(c, vault, "reservedAssets()", [], t2);
    const maturedB = await v(c, vault, "maturedRedeemShares()", [], t2);
    const liabilityB = await v(c, vault, "dueUnprocessedAssets()", [], t2);
    const assetsB = await v(c, vault, "getTotalAssets()", [], t2);
    const heldB = await v(c, vault, "ghost_held()", [], t2);
    const fr = await tx(c, vault, A.carol, "fundRedemptions()", [], t2);
    check("R-FUND fundRedemptions ok", fr.ok, fr.revert);
    check("R-FUND burns exactly matured shares", (await v(c, vault, "totalSupply()", [], t2)) === supplyB - maturedB);
    check("R-FUND matured -> 0", (await v(c, vault, "maturedRedeemShares()", [], t2)) === 0n);
    check("R-FUND reserved += liability", (await v(c, vault, "reservedAssets()", [], t2)) === reservedB + liabilityB);
    check("R-FUND pool -= liability", (await v(c, vault, "getTotalAssets()", [], t2)) === assetsB - liabilityB);
    check("R-FUND is cash-neutral", (await v(c, vault, "ghost_held()", [], t2)) === heldB);
    check("ADV-01 watermark after funding", (await v(c, vault, "lastAccrualCash()", [], t2)) === heldB - (reservedB + liabilityB));
    note("R-FUND rounding dust retained by pool (assets - liability)", `${S(assetsB)} - ${S(liabilityB)}`);

    const claimable = await v(c, vault, "maxRedeem(address)", [A.alice], t2);
    const maxW = await v(c, vault, "maxWithdraw(address)", [A.alice], t2);
    check("R-FUND maxRedeem == burned shares", claimable === 100_000_000n, S(claimable));
    // claimableRedeemRequest() returns SHARES (see source: `(, shares) = _previewClaim`), maxWithdraw returns
    // ASSETS. At par they differ by accrued interest, so compare against maxRedeem instead.
    check("ADV-22 claimableRedeemRequest returns shares, maxRedeem returns the same",
      (await v(c, vault, "claimableRedeemRequest(uint256,address)", [0n, A.alice], t2)) === claimable);
    check("ADV-22 claimable(shares) <= maxWithdraw(assets)", claimable <= maxW, `${S(claimable)} <= ${S(maxW)}`);

    const supplyC = await v(c, vault, "totalSupply()", [], t2);
    const reservedC = await v(c, vault, "reservedAssets()", [], t2);
    const heldC = await v(c, vault, "ghost_held()", [], t2);
    const jr = await tx(c, vault, A.alice, "redeem()", [], t2);
    check("R-REDEEM redeem ok", jr.ok, jr.revert);
    check("R-REDEEM does not burn supply again", (await v(c, vault, "totalSupply()", [], t2)) === supplyC);
    check("R-REDEEM reserved drops by payout", (await v(c, vault, "reservedAssets()", [], t2)) === reservedC - maxW, S(maxW));
    check("R-REDEEM held drops by payout", (await v(c, vault, "ghost_held()", [], t2)) === heldC - maxW);
    check("ADV-04 reserved == sum of unclaimed epoch funding", (await v(c, vault, "reservedAssets()", [], t2)) === 0n);
    check("R-REDEEM double claim reverts", !(await tx(c, vault, A.alice, "redeem()", [], t2)).ok);
    check("R-REDEEM claimable now 0", (await v(c, vault, "claimableRedeemRequest(uint256,address)", [0n, A.alice], t2)) === 0n);
  }

  // ==================================================================================
  // S3 — delinquency: grace, penalty, blocked entry legs, cure by repay
  // ==================================================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await mint(A.borrower, 2_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [500_000_000n, A.alice], t0);
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [450_000_000n], t0 + 10n);
    const avail = await v(c, vault, "availableToBorrow()", [], t0 + 20n);
    await tx(c, vault, A.borrower, "borrow(uint256)", [avail], t0 + 20n);

    const dueAt = GENESIS + EPOCH; // boundary at which the request matures
    const tGraceMid = dueAt + 1n * DAY;
    const anchor = await v(c, vault, "penaltyActiveSince()", [], tGraceMid);
    check("S3 anchor == dueAt + grace", anchor === dueAt + 3n * DAY, `${S(anchor)} vs ${S(dueAt + 3n * DAY)}`);
    check("S3 shortfall detected at boundary", (await v(c, vault, "redemptionFundingShortfall()", [], tGraceMid)) > 0n);
    check("S3 not delinquent during grace", (await v(c, vault, "isDelinquent()", [], tGraceMid)) === false);
    check("S3 deposits still allowed during grace", (await v(c, vault, "maxDeposit(address)", [A.bob], tGraceMid)) > 0n);

    const tPast = dueAt + 4n * DAY;
    check("S3 delinquent past grace", (await v(c, vault, "isDelinquent()", [], tPast)) === true);
    check("ADV-09 availableToBorrow == 0", (await v(c, vault, "availableToBorrow()", [], tPast)) === 0n);
    check("ADV-09 maxDeposit == 0", (await v(c, vault, "maxDeposit(address)", [A.bob], tPast)) === 0n);
    await mint(A.bob, 100_000n);
    check("ADV-09 deposit reverts", !(await tx(c, vault, A.bob, "deposit(uint256,address)", [1000n, A.bob], tPast)).ok);
    check("ADV-09 borrow reverts", !(await tx(c, vault, A.borrower, "borrow(uint256)", [1n], tPast)).ok);

    // penalty is actually billed: pool grows faster than the base rate alone
    const taA = await v(c, vault, "getTotalAssets()", [], tPast);
    const taB = await v(c, vault, "getTotalAssets()", [], tPast + 7n * DAY);
    const baseOnly = taA + (taA * 1000n * (7n * DAY)) / (365n * DAY * 10000n);
    check("S3 penalty billed on top of base rate", taB > baseOnly, `${S(taB)} > ${S(baseOnly)}`);

    // cure: one repay()
    const owed = await v(c, vault, "amountOwed()", [], tPast);
    const rp = await tx(c, vault, A.borrower, "repay(uint256)", [owed], tPast);
    check("S3 repay ok", rp.ok, rp.revert);
    check("S3 repay funds matured liabilities", (await v(c, vault, "maturedRedeemShares()", [], tPast)) === 0n);
    check("S3 cure clears isDelinquent", (await v(c, vault, "isDelinquent()", [], tPast)) === false);
    check("S3 cure clears penalty", (await v(c, vault, "penaltyActiveSince()", [], tPast)) === 0n);
    check("ADV-11 grace is not renewed by a cure", (await v(c, vault, "penaltyActiveSince()", [], tPast)) === 0n);
  }

  // ==================================================================================
  // S3b — grace renewal. NOTE: a *full* repay funds the cohort, which legitimately clears
  // the one-shot grace grant (`_refreshDelinquency` deletes penaltyFromTimestamp when
  // maturedRedeemShares hits 0). The correct re-onset experiment needs a cure that leaves
  // the cohort unfunded (a donation), and lives in scripts/audit2.js S11.
  // ==================================================================================

  // ==================================================================================
  // S4 — wind-down: snapshot, entitlement, double claim, residual and fee sweep
  // ==================================================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await mint(A.bob, 1_000_000_000n);
    await mint(A.borrower, 2_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [500_000_000n, A.alice], t0);
    await tx(c, vault, A.bob, "deposit(uint256,address)", [300_000_000n, A.bob], t0);
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [100_000_000n], t0 + 10n); // left unfunded
    const av = await v(c, vault, "availableToBorrow()", [], t0 + 20n);
    await tx(c, vault, A.borrower, "borrow(uint256)", [av], t0 + 20n);
    await tx(c, vault, A.borrower, "repay(uint256)", [av / 2n], t0 + 30n);

    const termAt = t0 + EPOCH / 2n;
    check("S4 terminate ok", (await tx(c, vault, A.manager, "terminate()", [], termAt)).ok);
    check("INV terminated() <=> terminatedAt() != 0",
      (await v(c, vault, "terminated()", [], termAt)) === ((await v(c, vault, "terminatedAt()", [], termAt)) !== 0n));
    check("ADV-TERM canTransfer(alice,bob) == false", (await v(c, vault, "canTransfer(address,address)", [A.alice, A.bob], termAt)) === false);
    check("ADV-TERM canTransfer(vault,alice) == true (escrow return)", (await v(c, vault, "canTransfer(address,address)", [vault, A.alice], termAt)) === true);
    check("ADV-TERM wallet transfer reverts", !(await tx(c, vault, A.alice, "transfer(address,uint256)", [A.bob, 1n], termAt)).ok);
    check("ADV-TERM maxDeposit == 0", (await v(c, vault, "maxDeposit(address)", [A.alice], termAt)) === 0n);
    check("ADV-TERM availableToBorrow == 0", (await v(c, vault, "availableToBorrow()", [], termAt)) === 0n);
    check("ADV-TERM deposit reverts", !(await tx(c, vault, A.bob, "deposit(uint256,address)", [1000n, A.bob], termAt)).ok);
    check("ADV-TERM borrow reverts", !(await tx(c, vault, A.borrower, "borrow(uint256)", [1n], termAt)).ok);
    check("ADV-TERM requestRedeem reverts", !(await tx(c, vault, A.bob, "requestRedeem(uint256)", [1_000n], termAt)).ok);
    check("ADV-TERM fundRedemptions reverts", !(await tx(c, vault, A.bob, "fundRedemptions()", [], termAt)).ok);

    const termEpoch = (termAt - GENESIS) / EPOCH;
    const cutoffGuess = GENESIS + (termEpoch + 1n) * EPOCH; // end of the termination epoch
    check("S4 claim blocked before cutoff", !(await tx(c, vault, A.alice, "claimRecovery()", [], termAt)).ok);
    check("S4 claim blocked 1s before cutoff", !(await tx(c, vault, A.alice, "claimRecovery()", [], cutoffGuess - 1n)).ok);
    check("S4 snapshot still empty before first claim",
      (await v(c, vault, "resolutionSnapshot()", [], cutoffGuess))[0] === 0n);
    check("ADV-TERM exposedAmount == 0 past cutoff", (await v(c, vault, "exposedAmount()", [], cutoffGuess)) === 0n);

    const supplyBefore = await v(c, vault, "totalSupply()", [], cutoffGuess);
    const escrowBefore = await v(c, vault, "balanceOf(address)", [vault], cutoffGuess);
    const c1 = await tx(c, vault, A.alice, "claimRecovery()", [], cutoffGuess);
    check("S4 first claim ok", c1.ok, c1.revert);
    const snap1 = await v(c, vault, "resolutionSnapshot()", [], cutoffGuess);
    check("ADV-08 snapshot frozen at first claim", snap1[0] > 0n && snap1[1] > 0n, `${S(snap1[0])} / ${S(snap1[1])}`);
    check("ADV-08 resolutionShares == supply at claim", snap1[0] === supplyBefore, `${S(snap1[0])} vs ${S(supplyBefore)}`);
    check("ADV-08 snapshot storage agrees", (await c.raw(vault, KEY.DEP + DEP.resolutionShares)) === snap1[0] &&
      (await c.raw(vault, KEY.DEP + DEP.frozenAssets)) === snap1[1]);
    check("ADV-14 escrow shares returned on claim",
      (await v(c, vault, "balanceOf(address)", [vault], cutoffGuess)) < escrowBefore);
    note("ADV-14 matured before/after claim",
      `${S((await c.raw(vault, KEY.DEP + DEP.matured)))} (storage at claim)`);

    const claimed1 = await v(c, vault, "claimedRecovery(address)", [A.alice], cutoffGuess);
    check("ADV-06 immediate second claim reverts", !(await tx(c, vault, A.alice, "claimRecovery()", [], cutoffGuess)).ok);
    const snap2 = await v(c, vault, "resolutionSnapshot()", [], cutoffGuess);
    check("ADV-08 snapshot immutable", snap2[0] === snap1[0] && snap2[1] === snap1[1]);

    // second lender claims; total must stay under the frozen book
    const c2 = await tx(c, vault, A.bob, "claimRecovery()", [], cutoffGuess);
    check("S4 second lender claim ok", c2.ok, c2.revert);
    const rec2 = await v(c, vault, "totalRecoveryPaid()", [], cutoffGuess);
    check("ADV-07 totalRecoveryPaid <= frozenAssets", rec2 <= snap1[1], `${S(rec2)} <= ${S(snap1[1])}`);
    const units = await v(c, vault, "balanceOf(address)", [A.alice], cutoffGuess);
    const held = await v(c, vault, "ghost_held()", [], cutoffGuess);
    const reserved = await v(c, vault, "reservedAssets()", [], cutoffGuess);
    const poolRaw = held - reserved + rec2;
    const pool = poolRaw < snap1[1] ? poolRaw : snap1[1];
    const entitled = (units * pool) / snap1[0];
    check("ADV-06 claimedRecovery <= entitlement", (await v(c, vault, "claimedRecovery(address)", [A.alice], cutoffGuess)) <= entitled,
      `${S(await v(c, vault, "claimedRecovery(address)", [A.alice], cutoffGuess))} <= ${S(entitled)}`);
    check("ADV-18 max payout < entitlement + 1 unit of dust", entitled - claimed1 <= 1n, `${S(entitled - claimed1)}`);

    // more recoveries arrive -> incremental claim must be bounded
    await tx(c, vault, A.borrower, "repay(uint256)", [20_000_000n], cutoffGuess);
    await tx(c, vault, A.alice, "claimRecovery()", [], cutoffGuess);
    const claimed3 = await v(c, vault, "claimedRecovery(address)", [A.alice], cutoffGuess);
    const rec3 = await v(c, vault, "totalRecoveryPaid()", [], cutoffGuess);
    const held3 = await v(c, vault, "ghost_held()", [], cutoffGuess);
    const pool3raw = held3 - reserved + rec3;
    const pool3 = pool3raw < snap1[1] ? pool3raw : snap1[1];
    const ent3 = (units * pool3) / snap1[0];
    check("ADV-06 entitlement tracks growing pool", claimed3 <= ent3, `${S(claimed3)} <= ${S(ent3)}`);
    check("ADV-06 cumulative claims monotone", claimed3 >= claimed1);

    // residual sweep: only cash above the outstanding lender book
    const owedNow = await v(c, vault, "amountOwed()", [], cutoffGuess);
    if (owedNow > 0n) await tx(c, vault, A.borrower, "repay(uint256)", [owedNow], cutoffGuess);
    const recB = await v(c, vault, "totalRecoveryPaid()", [], cutoffGuess);
    const book = snap1[1];
    const outstanding = book > recB ? book - recB : 0n;
    const reservedNow = await v(c, vault, "reservedAssets()", [], cutoffGuess);
    const sw = await tx(c, vault, A.manager, "sweepResidual()", [], cutoffGuess);
    const heldAfter = await v(c, vault, "ghost_held()", [], cutoffGuess);
    check("ADV-15 sweepResidual leaves lender book intact", !sw.ok || heldAfter >= reservedNow + outstanding,
      `swept? ${sw.ok} held=${S(heldAfter)} need=${S(reservedNow + outstanding)}`);

    const cf = await tx(c, vault, A.manager, "collectFees()", [], cutoffGuess);
    const recC = await v(c, vault, "totalRecoveryPaid()", [], cutoffGuess);
    const outstanding2 = book > recC ? book - recC : 0n;
    const heldAfterFee = await v(c, vault, "ghost_held()", [], cutoffGuess);
    check("ADV-15 collectFees leaves lender book intact", !cf.ok ||
      heldAfterFee >= (await v(c, vault, "reservedAssets()", [], cutoffGuess)) + outstanding2,
      `fees=${S(await v(c, vault, "accruedFees()", [], cutoffGuess))}`);
    check("ADV-15 sweepResidual is not paid to an arbitrary address",
      (await v(c, vault, "terminated()", [], cutoffGuess)) === true);
  }

  // ==================================================================================
  // S5 — queue accounting: multi-lender, multi-epoch, merge, claim order
  // ==================================================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    for (const w of [A.alice, A.bob, A.carol]) await mint(w, 1_000_000_000n);
    for (const w of [A.alice, A.bob, A.carol]) {
      await tx(c, vault, w, "deposit(uint256,address)", [300_000_000n, w], t0);
    }
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [10_000_000n], t0 + 10n);
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [15_000_000n], t0 + 20n);
    await tx(c, vault, A.bob, "requestRedeem(uint256)", [20_000_000n], t0 + 30n);
    const tMid = t0 + EPOCH + EPOCH / 2n;
    await tx(c, vault, A.carol, "requestRedeem(uint256)", [30_000_000n], tMid);

    const ar = await v(c, vault, "getUserWithdrawalRequest(address,uint128)", [A.alice, 0n], tMid);
    check("ADV-02 same-epoch requests merge into one entry", ar[0] === 25_000_000n, S(ar[0]));
    const epA = ar[1];
    const epC = (await v(c, vault, "getUserWithdrawalRequest(address,uint128)", [A.carol, 0n], tMid))[1];
    check("ADV-02 queue epochs non-decreasing per user", epC > epA, `${S(epA)} -> ${S(epC)}`);
    check("ADV-02 epoch shares == sum of that epoch's requests",
      (await v(c, vault, "getEpochWithdrawalRequest(uint256)", [epA], tMid))[0] === 45_000_000n);

    const tFund = tMid + EPOCH;
    const fr = await tx(c, vault, A.carol, "fundRedemptions()", [], tFund);
    check("S5 funding ok", fr.ok, fr.revert);
    const ep = await v(c, vault, "getEpochWithdrawalRequest(uint256)", [epA], tFund);
    const epCq = await v(c, vault, "getEpochWithdrawalRequest(uint256)", [epC], tFund);
    const reserved = await v(c, vault, "reservedAssets()", [], tFund);
    check("ADV-04 sum of epoch fundedAssets == reservedAssets", ep[1] + epCq[1] === reserved, `${S(ep[1])}+${S(epCq[1])} vs ${S(reserved)}`);
    check("ADV-04 funded flag == epoch <= fundedThroughEpoch",
      ep[2] === (epA <= (await v(c, vault, "fundedThroughEpoch()", [], tFund))));
    check("ADV-03 matured shares == shares of matured epochs", (await c.raw(vault, KEY.DEP + DEP.matured)) === 0n);

    const aPay = await v(c, vault, "claimableRedeemRequest(uint256,address)", [0n, A.alice], tFund);
    const bPay = await v(c, vault, "claimableRedeemRequest(uint256,address)", [0n, A.bob], tFund);
    check("ADV-05 payouts <= epoch funded", aPay + bPay <= ep[1], `${S(aPay + bPay)} <= ${S(ep[1])}`);
    await tx(c, vault, A.bob, "redeem()", [], tFund);
    const aPayAfter = await v(c, vault, "claimableRedeemRequest(uint256,address)", [0n, A.alice], tFund);
    check("ADV-13 claim order does not change payout", aPay === aPayAfter, `${S(aPay)} vs ${S(aPayAfter)}`);
    // `bPay` above was the SHARE count from `claimableRedeemRequest`; compare against the asset
    // payout that `redeem()` actually released.
    const reservedAfterBob = await v(c, vault, "reservedAssets()", [], tFund);
    const bobAssets = ep[1] + epCq[1] - reservedAfterBob;
    check("ADV-04 reservation releases exactly the asset payout",
      reservedAfterBob + bobAssets === ep[1] + epCq[1] && bobAssets >= bPay,
      `released ${S(bobAssets)} assets for ${S(bPay)} shares`);
    await tx(c, vault, A.alice, "redeem()", [], tFund);
    // Carol's single `redeem()` drains her whole funded prefix (epochs epA and epC).
    await tx(c, vault, A.carol, "redeem()", [], tFund);
    // NOTE: 1 wei of rounding dust can survive — see FINDING F-5. It is cumulative, not per claim.
    const dustAfter = await v(c, vault, "reservedAssets()", [], tFund);
    check("ADV-04 reservation drained to rounding dust only", dustAfter <= 1n, `left=${S(dustAfter)} wei`);
    check("ADV-05 sum of payouts <= epoch fundedAssets", aPay + bPay <= ep[1]);
    note("ADV-05 rounding retention per epoch", `${S(ep[1] - (aPay + bPay))} wei kept in the pool`);
  }

  // ==================================================================================
  // S6 — donation: must not cure a historical shortfall
  // ==================================================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [500_000_000n, A.alice], t0);
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [500_000_000n], t0 + 10n);
    const av = await v(c, vault, "availableToBorrow()", [], t0 + 20n);
    await tx(c, vault, A.borrower, "borrow(uint256)", [av], t0 + 20n);

    const tShort = GENESIS + EPOCH; // boundary: matured, no cash -> shortfall anchored
    await tx(c, vault, A.bob, "update()", [], tShort); // settle so storage reflects the boundary test
    const anchorStored = await c.raw(vault, KEY.DEP + DEP.delinquencyDue);
    check("S6 accrual anchors shortfall at the boundary", anchorStored !== 0n, S(anchorStored));
    check("S6 anchor == boundary timestamp", anchorStored === tShort, `${S(anchorStored)} vs ${S(tShort)}`);

    const wm0 = await v(c, vault, "lastAccrualCash()", [], tShort);
    // untracked donation (plain ERC-20 transfer into the vault)
    await c.call(vault, A.bob, "donate(uint256)", [999_000_000n], tShort);
    const wm1 = await v(c, vault, "lastAccrualCash()", [], tShort);
    check("ADV-01 watermark ignores an untracked donation", wm0 === wm1, `${S(wm0)} == ${S(wm1)}`);
    const held1 = await v(c, vault, "ghost_held()", [], tShort);
    const matured1 = await v(c, vault, "maturedRedeemShares()", [], tShort);
    const due1 = await v(c, vault, "dueUnprocessedAssets()", [], tShort);
    check("S6 donation makes live cash cover the claim", held1 >= due1, `${S(held1)} >= ${S(due1)}`);
    check("S6 legal window: matured escrow got the cash first", matured1 > 0n);
  }

  // ==================================================================================
  // S7 — scheduled rate change + fee ceiling
  // ==================================================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [500_000_000n, A.alice], t0);
    check("S7 schedule ok", (await tx(c, vault, A.manager, "scheduleInterestRate(uint256)", [2000n], t0 + 10n)).ok);
    const sched = await v(c, vault, "scheduledInterestRate()", [], t0 + 10n);
    check("ADV-12 activation == currentEpoch + 2", sched[1] === (await v(c, vault, "currentEpoch()", [], t0 + 10n)) + 2n, S(sched[1]));
    // fee ceiling is the *lower* of current and pending: pending(2000) > current(1000) => ceiling 1000
    check("ADV-12 fee must stay below the lower of {current, scheduled}",
      !(await tx(c, vault, A.manager, "setFeeBps(uint256)", [1500n], t0 + 20n)).ok);
    check("ADV-12 fee below both is accepted",
      (await tx(c, vault, A.manager, "setFeeBps(uint256)", [900n], t0 + 20n)).ok);
    const tAct = t0 + 3n * EPOCH;
    await tx(c, vault, A.carol, "update()", [], tAct);
    check("ADV-12 scheduled rate activated at its epoch", (await v(c, vault, "interestRateBps()", [], tAct)) === 2000n);
    check("ADV-12 schedule cleared after activation", (await v(c, vault, "scheduledInterestRate()", [], tAct))[1] === 0n);
    check("ADV-12 activation is idempotent (second poke)", (await (async () => {
      await tx(c, vault, A.carol, "update()", [], tAct + 100n);
      return (await v(c, vault, "interestRateBps()", [], tAct + 100n)) === 2000n;
    })()));
    // cancel path
    await tx(c, vault, A.manager, "scheduleInterestRate(uint256)", [1200n], tAct + 200n);
    check("ADV-12 cancel before activation", (await tx(c, vault, A.manager, "cancelScheduledRate()", [], tAct + 300n)).ok);
    check("ADV-12 cancel clears schedule", (await v(c, vault, "scheduledInterestRate()", [], tAct + 300n))[1] === 0n);
    const tLate = tAct + 10n * EPOCH;
    await tx(c, vault, A.manager, "scheduleInterestRate(uint256)", [1100n], tLate);
    check("ADV-12 cancel after activation reverts", !(await tx(c, vault, A.manager, "cancelScheduledRate()", [], tLate + 3n * EPOCH)).ok);
  }

  // ==================================================================================
  // S8 — pause + registry gating (harness mirror)
  // ==================================================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [500_000_000n, A.alice], t0);
    await tx(c, vault, A.manager, "pauseDeposits()", [], t0);
    check("INV depositsPaused => maxDeposit == 0", (await v(c, vault, "maxDeposit(address)", [A.alice], t0)) === 0n);
    check("S8 deposit reverts while paused", !(await tx(c, vault, A.alice, "deposit(uint256,address)", [1000n, A.alice], t0)).ok);
    await tx(c, vault, A.manager, "unpauseDeposits()", [], t0);
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [100_000_000n], t0 + 10n);
    await tx(c, vault, A.manager, "pauseWithdrawals()", [], t0 + 20n);
    check("INV withdrawalsPaused => maxWithdraw == 0", (await v(c, vault, "maxWithdraw(address)", [A.alice], t0 + 20n)) === 0n);
    check("INV withdrawalsPaused => availableToBorrow == 0", (await v(c, vault, "availableToBorrow()", [], t0 + 20n)) === 0n);
    check("S8 requestRedeem reverts while paused", !(await tx(c, vault, A.alice, "requestRedeem(uint256)", [1n], t0 + 20n)).ok);
    await tx(c, vault, A.manager, "unpauseWithdrawals()", [], t0 + 30n);

    // registry revocation must gate every exit leg
    await c.call(vault, A.manager, "setApproved(address,bool)", [A.alice, false], t0 + 40n);
    check("ADV-20 revoked lender: claimable == 0",
      (await v(c, vault, "claimableRedeemRequest(uint256,address)", [0n, A.alice], t0 + 40n)) === 0n);
    check("ADV-20 revoked lender: maxWithdraw == 0", (await v(c, vault, "maxWithdraw(address)", [A.alice], t0 + 40n)) === 0n);
    check("ADV-20 revoked lender: requestRedeem reverts",
      !(await tx(c, vault, A.alice, "requestRedeem(uint256)", [1n], t0 + 40n)).ok);
    check("ADV-20 revoked lender: deposit reverts",
      !(await tx(c, vault, A.alice, "deposit(uint256,address)", [1000n, A.alice], t0 + 40n)).ok);
    check("ADV-20 revocation does not block canTransfer (transfers are registry-free)",
      (await v(c, vault, "canTransfer(address,address)", [A.alice, A.bob], t0 + 40n)) ===
      (await v(c, vault, "transfersEnabled()", [], t0 + 40n)));
    await c.call(vault, A.manager, "setApproved(address,bool)", [A.alice, true], t0 + 50n);
    check("ADV-20 re-approval restores exit legs",
      (await v(c, vault, "claimableRedeemRequest(uint256,address)", [0n, A.alice], t0 + 50n)) >= 0n);
  }

  // ==================================================================================
  // S9 — transfers: escrow-only entry, dust, and no schedule corruption
  // ==================================================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [500_000_000n, A.alice], t0);
    check("ADV-21 canTransfer(alice,bob) false when disabled",
      (await v(c, vault, "canTransfer(address,address)", [A.alice, A.bob], t0)) === false);
    check("ADV-21 canTransfer(alice,vault) false outside requestRedeem",
      (await v(c, vault, "canTransfer(address,address)", [A.alice, vault], t0)) === false);
    check("ADV-21 raw transfer into the vault reverts",
      !(await tx(c, vault, A.alice, "transfer(address,uint256)", [vault, 1_000n], t0)).ok);
    check("ADV-21 mint/burn path allowed", (await v(c, vault, "canTransfer(address,address)", [A.zero, A.alice], t0)) === true);
    await tx(c, vault, A.manager, "setTransfersEnabled(bool)", [true], t0 + 10n);
    check("ADV-21 wallet transfer allowed when enabled",
      (await tx(c, vault, A.alice, "transfer(address,uint256)", [A.bob, 1_000_000n], t0 + 20n)).ok);
    check("ADV-21 transfers still cannot target the vault",
      (await v(c, vault, "canTransfer(address,address)", [A.bob, vault], t0 + 20n)) === false);

    // zero-share escrow: request of 0 must revert (no empty queue entry)
    check("ADV-21 requestRedeem(0) reverts", !(await tx(c, vault, A.alice, "requestRedeem(uint256)", [0n], t0 + 30n)).ok);
    // deposit below minimum reverts
    check("ADV-21 deposit below minimum reverts",
      !(await tx(c, vault, A.alice, "deposit(uint256,address)", [999n, A.alice], t0 + 30n)).ok);
    // capacity
    check("ADV-21 deposit above capacity reverts",
      !(await tx(c, vault, A.alice, "deposit(uint256,address)", [2_000_000_000n, A.alice], t0 + 30n)).ok);
  }

  // ==================================================================================
  // S10 — maturation idempotency: no double-count across repeated pokes
  // ==================================================================================
  {
    const { c, vault, mint } = await bootstrap();
    const t0 = GENESIS + 1000n;
    await mint(A.alice, 1_000_000_000n);
    await tx(c, vault, A.alice, "deposit(uint256,address)", [500_000_000n, A.alice], t0);
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [100_000_000n], t0 + 10n);
    const t1 = t0 + 2n * EPOCH;
    const m1 = await v(c, vault, "maturedRedeemShares()", [], t1);
    await tx(c, vault, A.bob, "update()", [], t1);
    const m2 = await v(c, vault, "maturedRedeemShares()", [], t1);
    await tx(c, vault, A.bob, "update()", [], t1 + 1n);
    const m3 = await v(c, vault, "maturedRedeemShares()", [], t1 + 1n);
    check("ADV-03 maturation is idempotent across pokes", m1 === m2 && m2 === m3, `${S(m1)}/${S(m2)}/${S(m3)}`);
    check("ADV-03 matured == single epoch's scheduled shares", m1 === 100_000_000n);
    const t3 = t0 + 4n * EPOCH;
    check("ADV-03 no re-maturation on later boundaries", (await v(c, vault, "maturedRedeemShares()", [], t3)) === 100_000_000n);
  }

  // ==================================================================================
  // S11 — ghost closures (the ghosts the CVL conservation laws rely on)
  // ==================================================================================
  {
    const { c, vault, mint } = await bootstrap();
    let ts = GENESIS + 1000n;
    await mint(A.alice, 5_000_000_000n);
    await mint(A.bob, 5_000_000_000n);
    await mint(A.borrower, 9_000_000_000n);

    const checkGhosts = async (label) => {
      const supply = await v(c, vault, "totalSupply()", [], ts);
      const minted = await v(c, vault, "ghost_minted()", [], ts);
      const burned = await v(c, vault, "ghost_burned()", [], ts);
      const escrow = await v(c, vault, "balanceOf(address)", [vault], ts);
      const gIn = await v(c, vault, "ghost_escrowIn()", [], ts);
      const gOut = await v(c, vault, "ghost_escrowOut()", [], ts);
      const bfv = await v(c, vault, "ghost_burnedFromVault()", [], ts);
      check(`GHOST I1 totalSupply == minted - burned (${label})`, supply === minted - burned,
        `${S(supply)} vs ${S(minted - burned)}`);
      check(`GHOST I2 escrow == in - out (${label})`, escrow === gIn - gOut, `${S(escrow)} vs ${S(gIn - gOut)}`);
      check(`GHOST I3 vault burns are a subset of global burns (${label})`, bfv <= burned, `${S(bfv)} <= ${S(burned)}`);
      check(`GHOST I4 funded burn == escrow released by funding (${label})`, bfv <= gOut, `${S(bfv)} <= ${S(gOut)}`);
    };

    // 1) deposits + requests (escrow grows, supply unchanged)
    await tx(c, vault, A.alice, "deposit(uint256,address)", [500_000_000n, A.alice], ts);
    await checkGhosts("deposit");
    ts += 3_600n;
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [150_000_000n], ts);
    ts += 3_600n;
    await tx(c, vault, A.bob, "deposit(uint256,address)", [300_000_000n, A.bob], ts);
    await tx(c, vault, A.bob, "requestRedeem(uint256)", [100_000_000n], ts);
    await checkGhosts("requests");
    const supplyBeforeFund = await v(c, vault, "totalSupply()", [], ts);
    const escrowBeforeFund = await v(c, vault, "balanceOf(address)", [vault], ts);

    // 2) accrue past the boundaries, then fund: supply must drop by exactly the burn
    ts += 8n * 86400n;
    await tx(c, vault, A.carol, "update()", [], ts);
    const maturedNow = await v(c, vault, "maturedRedeemShares()", [], ts);
    check("GHOST matured == escrow before funding", maturedNow === escrowBeforeFund, `${S(maturedNow)} vs ${S(escrowBeforeFund)}`);
    const fr = await tx(c, vault, A.carol, "fundRedemptions()", [], ts);
    check("GHOST funding succeeds", fr.ok, fr.revert);
    const supplyAfterFund = await v(c, vault, "totalSupply()", [], ts);
    check("GHOST funding burn == matured escrow", supplyBeforeFund - supplyAfterFund === maturedNow,
      `${S(supplyBeforeFund - supplyAfterFund)} vs ${S(maturedNow)}`);
    check("GHOST funding empties the escrow", (await v(c, vault, "balanceOf(address)", [vault], ts)) === 0n);
    await checkGhosts("funding");

    // 3) claims
    await tx(c, vault, A.alice, "redeem()", [], ts);
    await tx(c, vault, A.bob, "redeem()", [], ts);
    await checkGhosts("claims");
    check("GHOST claims never burn supply again",
      (await v(c, vault, "totalSupply()", [], ts)) === supplyAfterFund);

    // 4) wind-down with a fresh unfunded cohort
    ts += 3_600n;
    await tx(c, vault, A.alice, "requestRedeem(uint256)", [40_000_000n], ts);
    await checkGhosts("wind-down request");
    ts += 8n * 86400n;
    await tx(c, vault, A.manager, "terminate()", [], ts);
    ts += 14n * 86400n;
    const rec = await tx(c, vault, A.alice, "claimRecovery()", [], ts);
    check("GHOST wind-down claim ok", rec.ok, rec.revert);
    await checkGhosts("wind-down claim");
    check("GHOST escrow fully returned after every lender claimed",
      (await v(c, vault, "balanceOf(address)", [vault], ts)) === 0n,
      S(await v(c, vault, "balanceOf(address)", [vault], ts)));
  }

  for (const line of out) console.log(line);
  console.log(`\n=== ${results.pass.length} PASS / ${results.fail.length} FAIL / ${results.note.length} NOTE ===`);
  if (results.fail.length) console.log("FAILURES:\n" + results.fail.join("\n"));
}
main().catch((e) => console.error("ERR", e.stack));
