constants = import_module("../utils/constants.star")

# SSV nodes read the registry events FOLLOW_DISTANCE blocks behind head (ssv executionclient.DefaultFollowDistance),
# and exit if their event syncer has nothing to process yet. Hence the wait before starting them.
FOLLOW_DISTANCE = 8

SLOTS_PER_EPOCH = 32
# Seconds from ethereum-package fixing the genesis timestamp to the CL producing its first block (EL/CL/VC
# launch, images cached). On a laptop, genesis timestamp to SSV start measured 45s at 4s slots, i.e. ~1s plus
# the blocks below; this leaves headroom for a slower host.
GENESIS_TO_CHAIN_START_SECONDS = 15
# Blocks from the chain starting to the SSV nodes starting: the recorded txs land in block 2, then
# FOLLOW_DISTANCE + 1 more.
BLOCKS_BEFORE_SSV = FOLLOW_DISTANCE + 3
# Aim the SSV start this many slots before epoch 1, so a slow start still catches all of it.
MARGIN_SLOTS = 2

REPLAY_SCRIPT = """
import json, sys, time, urllib.request

rpc, stages, wait_blocks = sys.argv[1], sys.argv[2].split(","), int(sys.argv[3])

def call(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(rpc, body, {"Content-Type": "application/json"})
    resp = json.load(urllib.request.urlopen(req, timeout=10))
    if "error" in resp:
        raise RuntimeError("%s: %s" % (method, resp["error"]))
    return resp["result"]

txs = [t for t in json.load(open("/recorded/txs.json"))["txs"] if t["stage"] in stages]
for t in txs:
    try:
        call("eth_sendRawTransaction", [t["raw"]])
    except Exception as e:
        # Kurtosis only shows the tail of a failed task's output, so keep the cause on one short line.
        sys.exit("recorded tx %d (%s) rejected: %s" % (t["nonce"], t["stage"], e))

last = 0
for t in txs:
    while True:
        try:
            receipt = call("eth_getTransactionReceipt", [t["hash"]])
        except RuntimeError as e:
            if "indexing is in progress" not in str(e):
                raise
            receipt = None
        if receipt:
            break
        time.sleep(1)
    if receipt["status"] != "0x1":
        sys.exit("recorded tx %d (%s) reverted" % (t["nonce"], t["stage"]))
    last = max(last, int(receipt["blockNumber"], 16))

target = last + wait_blocks
while int(call("eth_blockNumber", []), 16) < target:
    time.sleep(1)
print("replayed %d recorded txs (%s), mined by block %d; EL now at block %d" % (len(txs), ",".join(stages), last, target))
"""

# replay sends the pre-signed SSV deployment / registration txs (static/recorded/txs.json, made by
# scripts/record-txs.sh) instead of running hardhat and the ethers scripts live: same txs, but they all land
# within a block or two instead of one receipt per 12s block. It then waits until the events are past the SSV
# follow distance, so the nodes can start right after (replacing the fixed "wait for block 16").
#
# The recording is only valid for what it was made from: the static keys and keyshares, the deployer key, the
# chain id and the ssv-network version of the deployer image. Re-record after changing any of them.
def replay(plan, el_rpc, with_validators):
    stages = ["deploy", "operators"]
    if with_validators:
        stages.append("validators")
    plan.run_python(
        run=REPLAY_SCRIPT,
        args=[el_rpc, ",".join(stages), str(FOLLOW_DISTANCE + 1)],
        files={"/recorded": plan.upload_files("../static/recorded/txs.json", name="recorded-txs")},
        wait="5m",
        description="Replaying recorded SSV txs ({}) and waiting out the follow distance".format(", ".join(stages)),
    )


# align_genesis_to_epoch puts genesis in the past (a negative ethereum-package genesis_delay) so that the SSV
# nodes come up just before epoch 1.
#
# An SSV node can't attest in epoch 0: its attestation data has source == target == genesis, which the runner
# rejects ("attestation data source >= target"). On a chain that starts at genesis that is ~6.4 min (12s slots)
# of nothing, after the SSV nodes are long up. With genesis in the past the chain opens late in epoch 0, the
# recorded replay and the follow distance are mined there, and the nodes start with all of epoch 1 ahead.
# ethereum-package computes genesis as `date + genesis_delay` and doesn't check the sign; the CL just starts
# at the current slot. If the budget above is off the run still works: too early idles through part of epoch 0,
# too late misses epoch-1 duties already past (so "every validator live" slips to epoch 2).
def align_genesis_to_epoch(network_args):
    params = dict(network_args["network_params"])
    slot = params.get("seconds_per_slot", 12)
    params["genesis_delay"] = GENESIS_TO_CHAIN_START_SECONDS + (BLOCKS_BEFORE_SSV + MARGIN_SLOTS - SLOTS_PER_EPOCH) * slot
    aligned = dict(network_args)
    aligned["network_params"] = params
    return aligned
