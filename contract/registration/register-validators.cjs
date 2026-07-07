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

  const shares = JSON.parse(fs.readFileSync(KEYSHARES_FILE, "utf8")).shares;
  const publicKeys = shares.map((s) => s.payload.publicKey);
  const sharesData = shares.map((s) => s.payload.sharesData);
  const operatorIds = shares[0].payload.operatorIds;
  // Fresh cluster (never registered for this owner+operators).
  const cluster = { validatorCount: 0, networkFeeIndex: 0, index: 0, active: true, balance: 0 };

  // v2.0.0 registration is payable: clusters are collateralized with ETH via msg.value (not SSV
  // tokens). Scale the deposit with the validator count (~1 ETH/validator proven sufficient; 2x
  // for headroom, 10 ETH floor) to stay above the liquidation threshold.
  const collateral = ethers.parseEther(String(Math.max(10, publicKeys.length * 2)));
  await (await ssv.bulkRegisterValidator(publicKeys, operatorIds, sharesData, cluster, { value: collateral })).wait();
  console.log("Registered " + publicKeys.length + " validator(s) with " + ethers.formatEther(collateral) + " ETH collateral");
}

main().catch((e) => { console.error(e); process.exit(1); });
