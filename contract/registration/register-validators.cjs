// Registers SSV validators on the (v2.0.0) SSVNetwork via ethers, replacing the foundry
// RegisterValidators.s.sol. Reads keyshares (shares[].payload.{publicKey,sharesData,operatorIds})
// and bulk-registers them into a fresh cluster, collateralized with ETH via msg.value.
// Note: v2.0.0's bulkRegisterValidator is payable and dropped the SSV-token `amount` param.
const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

const RPC = process.env.LOCAL_RPC_URL;
const KEY = process.env.LOCAL_DEPLOYER_KEY;
const NETWORK_ADDR = process.env.SSV_NETWORK_ADDRESS;
const KEYSHARES_FILE = process.env.KEYSHARES_FILE || "/app/keyshares/out.json";
// Path of the split-point manifest written at the end of main(). interactions.star passes this explicitly;
// the fallback keeps it beside the keyshares for a standalone run.
const MANIFEST_FILE = process.env.PRE_REGISTER_MANIFEST_FILE || path.join(path.dirname(KEYSHARES_FILE), "pre-registered.json");

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
  // bulkRegisterValidator takes one operatorIds per batch, so every share must belong to the same cluster.
  // Validate the WHOLE pool, not just the prefix: a mixed prefix registers everyone under shares[0]'s
  // operators, and cohortD (the tail, published below and registered by the executor under this cluster)
  // lands as malformed ValidatorAdded events — no revert, a green run either way (ssvlabs/ssv-mini#36).
  const operatorIdsKey = JSON.stringify(operatorIds);
  if (all.some((s) => JSON.stringify(s.payload.operatorIds) !== operatorIdsKey)) {
    throw new Error("keyshares span multiple operator sets; ssv-mini registers a single cluster (expected operatorIds " + operatorIdsKey + " for all " + all.length + " shares)");
  }

  // A single bulkRegisterValidator tx must stay under Ethereum's 128 KiB tx-size limit — each validator
  // adds ~1.5 KiB of sharesData calldata, so ~85 is the ceiling (90 validators is ~136 KiB and the node
  // rejects it as "oversized data"). Register in batches under that, threading the on-chain cluster
  // snapshot (read back from each batch's ValidatorAdded event) into the next batch. Registration is
  // v2.0.0-payable: 2.5 ETH/validator collateral (matches the executor's AMOUNT_PER_VALIDATOR, which
  // clears the liquidation threshold) via msg.value.
  const BATCH_SIZE = 50;
  const perValidator = ethers.parseEther("2.5");
  let cluster = { validatorCount: 0, networkFeeIndex: 0, index: 0, active: true, balance: 0 };

  // Cap the buffered gasLimit below the block gas limit: the 2x buffer on a full batch's estimate can
  // exceed the block ceiling, which bounces the tx with "exceeds block gas limit". 90% leaves headroom.
  const gasCap = ((await provider.getBlock("latest")).gasLimit * 9n) / 10n;

  for (let i = 0; i < shares.length; i += BATCH_SIZE) {
    const batch = shares.slice(i, i + BATCH_SIZE);
    const publicKeys = batch.map((s) => s.payload.publicKey);
    const sharesData = batch.map((s) => s.payload.sharesData);
    const value = perValidator * BigInt(batch.length);
    // geth's eth_estimateGas runs the lenient eth_call path and under-counts this nested call — real
    // execution forwards only 63/64 of the remaining gas (EIP-150) into the SSVStaking delegatecall, so
    // sending with exactly the estimate starves the subcall into a bare revert. Send with a 2x buffer,
    // capped at gasCap so the doubled estimate stays under the block gas limit.
    const gasEstimate = await ssv.bulkRegisterValidator.estimateGas(publicKeys, operatorIds, sharesData, cluster, { value });
    // If the bare estimate already meets the cap, clamping to gasCap would send LESS than the estimate and
    // die as an out-of-gas revert — the same bare revert the 2x buffer exists to prevent, only now with no
    // diagnostic. Fail fast pointing at the batch instead; the clamp below still handles the overshoot case.
    if (gasEstimate >= gasCap) {
      throw new Error("batch " + (i / BATCH_SIZE) + " (shares " + i + ".." + (i + batch.length - 1) + "): gas estimate " + gasEstimate + " >= cap " + gasCap + " (90% of block gas limit) — lower BATCH_SIZE");
    }
    const buffered = gasEstimate * 2n;
    const gasLimit = buffered < gasCap ? buffered : gasCap;
    const receipt = await (await ssv.bulkRegisterValidator(publicKeys, operatorIds, sharesData, cluster, { value, gasLimit })).wait();
    cluster = clusterFromReceipt(ssv, receipt);
    console.log("  Registered " + (i + batch.length) + "/" + shares.length + " validator(s)");
  }
  console.log("Registered " + shares.length + " validator(s) in batches of up to " + BATCH_SIZE);

  // Publish the split point N (and the exact P⊎D pubkey partition) as a manifest so the aetheria executor
  // reads the ACTUAL N from the enclave instead of re-declaring it in a second repo (ssvlabs/ssv-mini#53).
  // Otherwise the only trace of N is this service's log, and the service is torn down at the end of Step 4 —
  // an executor offset > N would then silently register nobody at position N and quietly shrink cohort D.
  // cohortP is exactly what we registered above (shares[0, count)); cohortD is the remainder [count, pool)
  // the executor registers. count == pool ⇒ cohortD is empty (full set, no split). interactions.star stores
  // MANIFEST_FILE as the `pre-registered.json` enclave artifact before the service is removed.
  //
  // Also publish the registration context cohortD depends on — ownerAddress, operatorIds and
  // ssvNetworkAddress — so the executor reads them here instead of re-declaring them (the re-declaration this
  // manifest exists to remove). If the deployer key or operator set drifts, N and the cohorts still look
  // valid, but cohortD would sign sharesData for the wrong (owner, nonce) → malformed ValidatorAdded events
  // (ssvlabs/ssv-mini#36). schemaVersion lets consumers tell manifest shapes apart as it grows.
  const manifest = {
    schemaVersion: 1,
    preRegisteredCount: count,
    poolSize: all.length,
    ownerAddress: wallet.address,
    operatorIds: operatorIds,
    ssvNetworkAddress: NETWORK_ADDR,
    cohortP: shares.map((s) => s.payload.publicKey),
    cohortD: all.slice(count).map((s) => s.payload.publicKey),
  };
  fs.writeFileSync(MANIFEST_FILE, JSON.stringify(manifest, null, 2));
  console.log("Wrote pre-registration manifest " + MANIFEST_FILE + " (N=" + count + ", pool=" + all.length + ", |D|=" + manifest.cohortD.length + ")");
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
