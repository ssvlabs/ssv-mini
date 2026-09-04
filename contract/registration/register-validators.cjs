// Registers SSV validators on the (v2.0.0) SSVNetwork via ethers, replacing the foundry
// RegisterValidators.s.sol. Reads keyshares (shares[].payload.{publicKey,sharesData,operatorIds})
// and bulk-registers them into a fresh cluster, collateralized with ETH via msg.value.
// Note: v2.0.0's bulkRegisterValidator is payable and dropped the SSV-token `amount` param.
const fs = require("fs");
const { ethers } = require("ethers");

const RPC = process.env.LOCAL_RPC_URL;
const KEY = process.env.LOCAL_DEPLOYER_KEY;
const NETWORK_ADDR = process.env.SSV_NETWORK_ADDRESS;
const KEYSHARES_FILE = process.env.KEYSHARES_FILE || "/app/keyshares/out.json";

async function main() {
  const abi = JSON.parse(fs.readFileSync("/app/abis/SSVNetwork.json", "utf8"));
  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(KEY, provider);
  const ssv = new ethers.Contract(NETWORK_ADDR, abi, wallet);

  // Register a CONTIGUOUS PREFIX of the share set: shares[0, count). Each entry's sharesData signs
  // (owner, nonce) as a strict 0-based sequence, so a prefix keeps every registered share's nonce
  // matching its position (0..count-1). SKIPPING a middle entry, by contrast, shifts every later
  // share's expected nonce and the nodes reject the ValidatorAdded events with "malformed event:
  // failed to verify signature" (validators land on-chain but are never adopted; ssvlabs/ssv-mini#36).
  // PRE_REGISTER_COUNT unset ⇒ the full set (the original all-or-nothing behaviour). A smaller count
  // leaves the remaining keystores for the aetheria executor to register as its own cohort — it
  // regenerates fresh sharesData from the live on-chain nonce, which continues from count — the
  // index-partitioned P⊎D split that lets pre-registration and a registering suite share one enclave.
  const all = JSON.parse(fs.readFileSync(KEYSHARES_FILE, "utf8")).shares;
  const count = process.env.PRE_REGISTER_COUNT ? parseInt(process.env.PRE_REGISTER_COUNT, 10) : all.length;
  if (!Number.isInteger(count) || count < 1 || count > all.length) {
    throw new Error("PRE_REGISTER_COUNT must be an integer in [1, " + all.length + "], got: " + process.env.PRE_REGISTER_COUNT);
  }
  const shares = all.slice(0, count);
  const operatorIds = shares[0].payload.operatorIds;

  // A single bulkRegisterValidator tx must stay under Ethereum's 128 KiB tx-size limit — each validator
  // adds ~1.5 KiB of sharesData calldata, so ~85 is the ceiling (90 validators is ~136 KiB and the node
  // rejects it as "oversized data"). Register in batches under that, threading the on-chain cluster
  // snapshot (read back from each batch's ValidatorAdded event) into the next batch. Registration is
  // v2.0.0-payable: 2.5 ETH/validator collateral (matches the executor's AMOUNT_PER_VALIDATOR, which
  // clears the liquidation threshold) via msg.value.
  const BATCH_SIZE = 50;
  const perValidator = ethers.parseEther("2.5");
  let cluster = { validatorCount: 0, networkFeeIndex: 0, index: 0, active: true, balance: 0 };

  for (let i = 0; i < shares.length; i += BATCH_SIZE) {
    const batch = shares.slice(i, i + BATCH_SIZE);
    const publicKeys = batch.map((s) => s.payload.publicKey);
    const sharesData = batch.map((s) => s.payload.sharesData);
    const value = perValidator * BigInt(batch.length);
    // geth's eth_estimateGas runs the lenient eth_call path and under-counts this nested call — real
    // execution forwards only 63/64 of the remaining gas (EIP-150) into the SSVStaking delegatecall, so
    // sending with exactly the estimate starves the subcall into a bare revert. Send with a 2x buffer.
    const gasEstimate = await ssv.bulkRegisterValidator.estimateGas(publicKeys, operatorIds, sharesData, cluster, { value });
    const receipt = await (await ssv.bulkRegisterValidator(publicKeys, operatorIds, sharesData, cluster, { value, gasLimit: gasEstimate * 2n })).wait();
    cluster = clusterFromReceipt(ssv, receipt);
    console.log("  Registered " + (i + batch.length) + "/" + shares.length + " validator(s)");
  }
  console.log("Registered " + shares.length + " validator(s) in batches of up to " + BATCH_SIZE);
}

// clusterFromReceipt reads the updated Cluster struct from the last ValidatorAdded event in a receipt, so
// the next batch registers against the current on-chain cluster state (validatorCount, balance, ...).
function clusterFromReceipt(ssv, receipt) {
  for (let k = receipt.logs.length - 1; k >= 0; k--) {
    let parsed;
    try { parsed = ssv.interface.parseLog(receipt.logs[k]); } catch (_) { continue; }
    if (parsed && parsed.name === "ValidatorAdded") {
      // Read the Cluster struct by name, falling back to positional (?? is 0/false-safe) so this works
      // whether or not the ABI names the tuple's components. Field order is the canonical v2 layout.
      const c = parsed.args.cluster;
      return {
        validatorCount: c.validatorCount ?? c[0],
        networkFeeIndex: c.networkFeeIndex ?? c[1],
        index: c.index ?? c[2],
        active: c.active ?? c[3],
        balance: c.balance ?? c[4],
      };
    }
  }
  throw new Error("no ValidatorAdded event in the registration receipt — cannot read the cluster for the next batch");
}

main().catch((e) => { console.error(e); process.exit(1); });
