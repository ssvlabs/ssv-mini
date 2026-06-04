// Registers SSV operators on the (v2.0.0) SSVNetwork via ethers — the deployer image is
// node-based, so this replaces the foundry RegisterOperators.s.sol. Reads operator public keys
// from OPERATOR_KEYS_FILE, registers each, and writes {operators:[{id,publicKey}]} to
// OPERATOR_DATA_FILE (same shape the rest of ssv-mini consumes).
const fs = require("fs");
const { ethers } = require("ethers");

const RPC = process.env.LOCAL_RPC_URL;
const KEY = process.env.LOCAL_DEPLOYER_KEY;
const NETWORK_ADDR = process.env.SSV_NETWORK_ADDRESS;
const KEYS_FILE = process.env.OPERATOR_KEYS_FILE || "/app/operator_keys.json";
const OUT_FILE = process.env.OPERATOR_DATA_FILE || "/app/operator_data.json";

const OPERATOR_FEE = 1000000000n; // 1 SSV (smallest unit)
const MAX_OPERATOR_FEE = 76528650000000n;

async function main() {
  const abi = JSON.parse(fs.readFileSync("/app/abis/SSVNetwork.json", "utf8"));
  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(KEY, provider);
  const ssv = new ethers.Contract(NETWORK_ADDR, abi, wallet);

  const publicKeys = JSON.parse(fs.readFileSync(KEYS_FILE, "utf8")).publicKeys;
  const coder = ethers.AbiCoder.defaultAbiCoder();

  await (await ssv.updateMaximumOperatorFee(MAX_OPERATOR_FEE)).wait();

  const operators = [];
  for (const pk of publicKeys) {
    // The operator public key (RSA PEM string) is ABI-encoded as `bytes`, matching SSV tooling.
    const encoded = coder.encode(["string"], [pk]);
    const receipt = await (await ssv.registerOperator(encoded, OPERATOR_FEE, false)).wait();
    let id;
    for (const log of receipt.logs) {
      try {
        const parsed = ssv.interface.parseLog(log);
        if (parsed && parsed.name === "OperatorAdded") { id = Number(parsed.args.operatorId); break; }
      } catch (_) { /* not an SSVNetwork event */ }
    }
    if (id === undefined) throw new Error("OperatorAdded event not found for operator " + pk);
    operators.push({ id, publicKey: pk });
    console.log("Registered operator id=" + id);
  }

  fs.writeFileSync(OUT_FILE, JSON.stringify({ operators }, null, 2));
  console.log("Wrote " + OUT_FILE + " (" + operators.length + " operators)");
}

main().catch((e) => { console.error(e); process.exit(1); });
