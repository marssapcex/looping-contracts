// Tiny EVM driver used to *empirically* validate the CVL properties before writing them.
// Deploys the real LoanVault + mocks, then lets `fuzz.js` drive protocol calls at chosen timestamps.
const { VM } = require("@ethereumjs/vm");
const { Common, Chain, Hardfork } = require("@ethereumjs/common");
const { Address, Account } = require("@ethereumjs/util");
const { Block } = require("@ethereumjs/block");
const { Interface, AbiCoder, keccak256 } = require("ethers");

const artifacts = require("../out/artifacts.json");

function addr(hexOrString) {
  if (hexOrString instanceof Address) return hexOrString;
  const h = hexOrString.startsWith("0x") ? hexOrString.slice(2) : hexOrString;
  return new Address(Buffer.from(h.padStart(40, "0"), "hex"));
}

const hex = (a) => a.toString();

class Chain_ {
  constructor() {
    this.ifaces = {};
    this.nextTs = 1_700_000_000n;
    this.blockNumber = 1n;
  }

  async init() {
    const common = new Common({ chain: Chain.Mainnet, hardfork: Hardfork.Cancun });
    this.vm = await VM.create({ common });
  }

  iface(key) {
    if (!this.ifaces[key]) this.ifaces[key] = new Interface(artifacts[key].abi);
    return this.ifaces[key];
  }

  block(ts) {
    this.blockNumber += 1n;
    return Block.fromBlockData(
      { header: { number: this.blockNumber, timestamp: ts, gasLimit: 200_000_000n, baseFeePerGas: 0n } },
      { common: this.vm.common },
    );
  }

  async fund(who, wei = 10n ** 24n) {
    const a = addr(who);
    let acc = await this.vm.stateManager.getAccount(a);
    if (!acc) acc = new Account(0n, 0n);
    acc.balance = wei;
    await this.vm.stateManager.putAccount(a, acc);
  }

  async deploy(key, args, callerHex, ts) {
    await this.fund(callerHex);
    const iface = this.iface(key);
    const ctorInputs = artifacts[key].abi.find((x) => x.type === "constructor")?.inputs ?? [];
    const encodedArgs = AbiCoder.defaultAbiCoder().encode(
      ctorInputs.map((i) => i.type),
      args,
    );
    const data = Buffer.from(artifacts[key].bytecode + encodedArgs.slice(2), "hex");
    const res = await this.vm.evm.runCall({
      caller: addr(callerHex),
      data,
      gasLimit: 100_000_000n,
      value: 0n,
      block: this.block(ts),
      skipBalance: true,
    });
    if (res.execResult.exceptionError) {
      throw new Error(`deploy ${key} failed: ${res.execResult.exceptionError.error}`);
    }
    const address = hex(res.createdAddress);
    this.ifaces[address] = iface;
    return address;
  }

  async call(address, callerHex, sig, args, ts, value = 0n) {
    const iface = this.ifaces[address];
    const data = Buffer.from(iface.encodeFunctionData(sig, args).slice(2), "hex");
    const res = await this.vm.evm.runCall({
      to: addr(address),
      caller: addr(callerHex),
      data,
      gasLimit: 100_000_000n,
      value,
      block: this.block(ts),
      skipBalance: true,
    });
    const err = res.execResult.exceptionError;
    const revert = res.execResult.exceptionError && Buffer.from(res.execResult.returnValue).length === 0
      ? "(custom error / panic: no revert string)"
      : res.execResult.exceptionError
        ? `0x${Buffer.from(res.execResult.returnValue).toString("hex")}`
        : "";
    return { ok: !err, error: err?.error ?? null, revert, gasUsed: res.execResult.executionGasUsed };
  }

  async view(address, sig, args, ts) {
    const iface = this.ifaces[address];
    const data = Buffer.from(iface.encodeFunctionData(sig, args).slice(2), "hex");
    const res = await this.vm.evm.runCall({
      to: addr(address),
      caller: addr("0x000000000000000000000000000000000000dEaD"),
      data,
      gasLimit: 200_000_000n,
      block: this.block(ts),
      skipBalance: true,
    });
    if (res.execResult.exceptionError) return null;
    const out = Buffer.from(res.execResult.returnValue).toString("hex");
    const decoded = iface.decodeFunctionResult(sig, "0x" + out);
    return decoded.length === 1 ? decoded[0] : decoded;
  }

  // ---------- raw storage ----------
  mapKey(keyHex, slotBigInt) {
    // keccak256(abi.encode(key, slot))
    const enc = AbiCoder.defaultAbiCoder().encode(["bytes32", "uint256"], [
      keyHex.length === 66 ? keyHex : "0x" + keyHex.padStart(64, "0"),
      slotBigInt,
    ]);
    return BigInt(keccak256(enc));
  }

  async raw(address, slotBigInt) {
    const key = Buffer.from(slotBigInt.toString(16).padStart(64, "0"), "hex");
    const v = await this.vm.stateManager.getContractStorage(addr(address), key);
    return v && v.length ? BigInt("0x" + Buffer.from(v).toString("hex")) : 0n;
  }
}

module.exports = { Chain_, addr, artifacts };
