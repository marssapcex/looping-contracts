// Scenario harness: real LoanVault bytecode, real accounting, scripted adversarial sequences.
// This is what I use to decide *which* properties are actually true before writing CVL for them.
const { Chain_, addr } = require("./evm");
const { solidityPackedKeccak256, AbiCoder } = require("ethers");

const A = {
  alice: "0x00000000000000000000000000000000000000a1",
  bob: "0x00000000000000000000000000000000000000b0",
  carol: "0x00000000000000000000000000000000000000c0",
  borrower: "0x00000000000000000000000000000000000000b4",
  manager: "0x00000000000000000000000000000000000000f0",
  feeRecipient: "0x00000000000000000000000000000000000000fe",
  zero: "0x0000000000000000000000000000000000000000",
};

const DAY = 86400n;
const EPOCH = 7n * DAY;
const NOTICE = 3n * DAY;
const GENESIS = 1_700_000_000n;

const params = (over = {}) => [
  over.asset, over.borrower ?? A.borrower, over.feeRecipient ?? A.feeRecipient,
  over.registry, "Loan Vault Share", "lvUSDC",
  over.rate ?? 1000n, over.fee ?? 100n, over.capacity ?? 1_000_000_000n,
  over.minimum ?? 1000n, over.penalty ?? 500n, over.grace ?? 3n * DAY,
  over.epochDuration ?? EPOCH, over.notice ?? NOTICE,
];

async function bootstrap({ penalty = 500n, rate = 1000n, fee = 100n, transfers = false } = {}) {
  const c = new Chain_();
  await c.init();
  const ts = GENESIS;
  const usdc = await c.deploy("certora/harness/Mocks.sol:MockERC20", [], A.manager, ts);
  const roles = await c.deploy("certora/harness/Mocks.sol:MockRoleManager", [A.manager], A.manager, ts);
  const reg = await c.deploy("certora/harness/Mocks.sol:MockLenderRegistry", [roles, A.manager], A.manager, ts);
  const vault = await c.deploy("certora/harness/LoanVaultHarness.sol:LoanVaultHarness", [A.manager], A.manager, ts);
  const init = await c.call(
    vault,
    A.manager,
    "initialize((address,address,address,address,string,string,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))",
    [params({ asset: usdc, registry: reg, penalty, rate, fee })],
    ts,
  );
  if (!init.ok) throw new Error("initialize failed: " + init.error + " " + init.revert);

  const approve = async (who) => c.call(reg, A.manager, "forceApprove(address,address)", [vault, who], ts);
  const mint = async (who, amt) => c.call(usdc, A.manager, "mint(address,uint256)", [who, amt], ts);
  const approveToken = async (who) =>
    c.call(usdc, who, "approve(address,uint256)", [vault, (1n << 255n)], ts);

  for (const w of [A.alice, A.bob, A.carol, A.borrower]) {
    await approve(w);
    await approveToken(w);
  }
  await c.call(vault, A.manager, "setTransfersEnabled(bool)", [transfers], ts);
  return { c, usdc, roles, reg, vault, approve, mint, approveToken };
}

const v = (c, vault, sig, args, ts) => c.view(vault, sig, args, ts);
const tx = (c, vault, from, sig, args, ts) => c.call(vault, from, sig, args, ts);

async function snap(c, vault, ts) {
  const [totalAssets, totalSupply, reserved, matured, borrowable, borrowed, owed, fees, short, lastCash] =
    await Promise.all([
      v(c, vault, "getTotalAssets()", [], ts),
      v(c, vault, "totalSupply()", [], ts),
      v(c, vault, "reservedAssets()", [], ts),
      v(c, vault, "maturedRedeemShares()", [], ts),
      v(c, vault, "availableToBorrow()", [], ts),
      v(c, vault, "borrowedAmount()", [], ts),
      v(c, vault, "amountOwed()", [], ts),
      v(c, vault, "accruedFees()", [], ts),
      v(c, vault, "redemptionFundingShortfall()", [], ts),
      v(c, vault, "lastAccrualCash()", [], ts),
    ]);
  const held = await v(c, "certora/harness/Mocks.sol:MockERC20".length ? "" : "", "", []).catch(() => null);
  return { totalAssets, totalSupply, reserved, matured, borrowable, borrowed, owed, fees, short, lastCash };
}

module.exports = { A, DAY, EPOCH, NOTICE, GENESIS, bootstrap, v, tx, snap, params };
