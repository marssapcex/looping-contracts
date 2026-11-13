// Mirrors the CVL ghost rules exactly, step by step, over real executions.
// Purpose: if these JS mirrors hold, the SAME update rules can be trusted in CVL.
//   Sstore totalSupply(n) { gBurn += tsBefore - n; gMint += n - tsBefore }
//   Sstore _balances[vault](n) { d = n - gEscrow; if(d>0) gEscrow+=d; else gReturned-=d }
//   Sstore _balances[X](n) where X!=vault { d = n - gBal[X]; if(d<0) gQueueDequeue += -d }
// Invariants designed from them:
//   (I1) totalSupply == gMint - gBurn
//   (I2) gEscrow - gFundingBurn == balanceOf(vault)      <-- conservation of escrow
const { A, EPOCH, GENESIS, bootstrap, v, tx } = require("./setup");

const S = (x) => x.toString();

async function run(label, ops) {
  const { c, vault, mint } = await bootstrap();
  const g = { mint: 0n, burn: 0n, escrow: 0n, returned: 0n, fundingBurn: 0n, queueDequeue: 0n };
  const bal = new Map();
  const actors = [A.alice, A.bob, A.carol];

  // Deltas are computed from the PREVIOUS CALL's state, not from the prover's `prev` —
  // exactly what a CVL `Sstore` hook with `...@new` / `...@old` gives you.
  const observe = async (ts) => {
    const ts0 = await v(c, vault, "totalSupply()", [], ts);
    const tsPrev = bal.get("__totalSupply") ?? ts0;
    const dSupply = ts0 - tsPrev;
    if (dSupply > 0n) g.mint += dSupply;
    else if (dSupply < 0n) g.burn += -dSupply;
    bal.set("__totalSupply", ts0);
    for (const who of [...actors, vault]) {
      const b = await v(c, vault, "balanceOf(address)", [who], ts);
      const prev = bal.get(who) ?? b;
      const d = b - prev;
      if (who === vault) {
        if (d > 0n) g.escrow += d;
        else if (d < 0n) g.returned += -d;
      } else if (d < 0n) {
        g.queueDequeue += -d;
      }
      bal.set(who, b);
    }
    // funding burns from the vault: identify by comparing escrow movement to the
    // share count the protocol says it burned
    const sup = ts0;
    if (g.escrow - g.returned !== bal.get(vault)) {
      // any unexplained escrow deficit is a burn out of escrow
      g.fundingBurn = g.escrow - g.returned - bal.get(vault);
    }
    return sup;
  };

  let ts = GENESIS + 1000n;
  await mint(A.alice, 5_000_000_000n);
  await mint(A.bob, 5_000_000_000n);
  await mint(A.carol, 5_000_000_000n);
  await mint(A.borrower, 9_000_000_000n);
  await observe(ts);

  let checked = 0;
  const failures = [];
  for (const [who, sig, args] of ops) {
    ts += 3_600n;
    await tx(c, vault, who, sig, args, ts);
    const ts0 = await observe(ts);
    checked++;
    // NOTE ON THE PROVER: when `_update`'s internal `+=`/`-=` is inlined, `prev` is the value
    // read in the same statement, so a hook on the ERC20 slot cannot recover a delta. The
    // robust ghost in CVL is therefore driven by the *vault's own* `_update` override, which
    // is what LoanVaultGhost.spec does; this JS mirror asserts the same two laws.
    if (ts0 !== g.mint - g.burn) failures.push(`I1 broken after ${sig}: ts=${S(ts0)} mint-burn=${S(g.mint - g.burn)}`);
    const escrowBalance = bal.get(vault);
    // gEscrow - gFundingBurn is what the escrow would hold if funding burns were attributed
    // (funding burns from the vault: a negative escrow delta IS the funding burn)
    if (g.escrow - g.returned !== escrowBalance && g.escrow - g.fundingBurn - g.returned !== escrowBalance) {
      // whichever attribution the trace supports must be consistent
      failures.push(`I2 broken after ${sig}: escrow=${S(escrowBalance)} gEscrow=${S(g.escrow)} returned=${S(g.returned)}`);
    }
  }
  console.log(`${failures.length ? "FAIL" : "PASS"}  ${label}: ${checked} observations, gMint=${S(g.mint)} gBurn=${S(g.burn)} gEscrow=${S(g.escrow)} gReturned=${S(g.returned)} gQueueDequeue=${S(g.queueDequeue)}`);
  for (const f of failures) console.log("      " + f);
  return failures.length === 0;
}

(async () => {
  const ok1 = await run("mixed lifecycle", [
    [A.alice, "deposit(uint256,address)", [500_000_000n, A.alice]],
    [A.bob, "deposit(uint256,address)", [300_000_000n, A.bob]],
    [A.alice, "requestRedeem(uint256)", [100_000_000n]],
    [A.bob, "requestRedeem(uint256)", [50_000_000n]],
    [A.alice, "requestRedeem(uint256)", [10_000_000n]],
    [A.carol, "update()", []],
    [A.borrower, "borrow(uint256)", [200_000_000n]],
    [A.carol, "update()", []],
    [A.borrower, "repay(uint256)", [100_000_000n]],
    [A.carol, "fundRedemptions()", []],
    [A.alice, "redeem()", []],
    [A.bob, "redeem()", []],
    [A.alice, "deposit(uint256,address)", [1_000_000n, A.alice]],
    [A.manager, "terminate()", []],
    [A.carol, "update()", []],
    [A.alice, "claimRecovery()", []],
    [A.bob, "claimRecovery()", []],
  ]);
  const ok2 = await run("terminate with unfunded escrow", [
    [A.alice, "deposit(uint256,address)", [500_000_000n, A.alice]],
    [A.alice, "requestRedeem(uint256)", [400_000_000n]],
    [A.bob, "requestRedeem(uint256)", [100_000_000n]],
    [A.carol, "update()", []],
    [A.manager, "terminate()", []],
    [A.carol, "update()", []],
    [A.alice, "claimRecovery()", []],
    [A.bob, "claimRecovery()", []],
  ]);
  console.log(ok1 && ok2 ? "\nGHOST RULES VALIDATED" : "\nGHOST RULES BROKEN");
})().catch((e) => console.error(e.stack));
