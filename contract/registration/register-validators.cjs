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
  const publicKeys = shares.map((s) => s.payload.publicKey);
  const sharesData = shares.map((s) => s.payload.sharesData);
  const operatorIds = shares[0].payload.operatorIds;
  // Fresh cluster (never registered for this owner+operators).
  const cluster = { validatorCount: 0, networkFeeIndex: 0, index: 0, active: true, balance: 0 };

  // v2.0.0 registration is payable: clusters are collateralized with ETH via msg.value (not SSV
  // tokens). 2.5 ETH/validator matches the aetheria executor's AMOUNT_PER_VALIDATOR (proven live
  // to clear the liquidation threshold), keeping the two registration paths comparable when
  // debugging cluster-balance issues.
  const collateral = ethers.parseEther("2.5") * BigInt(publicKeys.length);
  // ethers auto-estimates gas, but geth's eth_estimateGas under-estimates this nested call: real
  // execution forwards only 63/64 of the remaining gas (EIP-150) into the SSVStaking delegatecall, so
  // sending with exactly the estimate starves it into a bare revert (hit on some counts, e.g. 6, not
  // others). Send with a 2x buffer over the estimate so the subcall always has enough forwarded gas.
  const gasEstimate = await ssv.bulkRegisterValidator.estimateGas(publicKeys, operatorIds, sharesData, cluster, { value: collateral });
  await (await ssv.bulkRegisterValidator(publicKeys, operatorIds, sharesData, cluster, { value: collateral, gasLimit: gasEstimate * 2n })).wait();
  console.log("Registered " + publicKeys.length + " validator(s) with " + ethers.formatEther(collateral) + " ETH collateral");
}

main().catch((e) => { console.error(e); process.exit(1); });
