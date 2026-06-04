// Registers SSV validators on the (v2.0.0) SSVNetwork via ethers — replaces the foundry
// RegisterValidators.s.sol. Reads keyshares (shares[].payload.{publicKey,sharesData,operatorIds}),
// approves the SSV token, and bulk-registers them into a fresh cluster.
// Note: v2.0.0's bulkRegisterValidator dropped the `amount` param (4 args, not 5).
const fs = require("fs");
const { ethers } = require("ethers");

const RPC = process.env.LOCAL_RPC_URL;
const KEY = process.env.LOCAL_DEPLOYER_KEY;
const NETWORK_ADDR = process.env.SSV_NETWORK_ADDRESS;
const TOKEN_ADDR = process.env.SSV_TOKEN_ADDRESS;
const KEYSHARES_FILE = process.env.KEYSHARES_FILE || "/app/keyshares/out.json";

async function main() {
  const abi = JSON.parse(fs.readFileSync("/app/abis/SSVNetwork.json", "utf8"));
  const provider = new ethers.JsonRpcProvider(RPC);
  const wallet = new ethers.Wallet(KEY, provider);
  const ssv = new ethers.Contract(NETWORK_ADDR, abi, wallet);
  const token = new ethers.Contract(TOKEN_ADDR, ["function approve(address,uint256) returns (bool)"], wallet);

  const shares = JSON.parse(fs.readFileSync(KEYSHARES_FILE, "utf8")).shares;
  const publicKeys = shares.map((s) => s.payload.publicKey);
  const sharesData = shares.map((s) => s.payload.sharesData);
  const operatorIds = shares[0].payload.operatorIds;
  // Fresh cluster (never registered for this owner+operators).
  const cluster = { validatorCount: 0, networkFeeIndex: 0, index: 0, active: true, balance: 0 };

  await (await token.approve(NETWORK_ADDR, ethers.parseEther("1"))).wait();
  await (await ssv.bulkRegisterValidator(publicKeys, operatorIds, sharesData, cluster)).wait();
  console.log("Registered " + publicKeys.length + " validator(s)");
}

main().catch((e) => { console.error(e); process.exit(1); });
