#!/usr/bin/env bash
# Times one Kurtosis bring-up end to end, with the same pass criterion as the hive simulator: every SSV-managed
# validator (indices [SSV_SEED_START_INDEX, +SSV_MANAGED_VALIDATOR_COUNT) from utils/constants.star) seen live by the beacon node at least once. Needs pre_register_validators: true in
# the params file, or the SSV nodes have no validators. Removes its own enclave afterwards.
#
# Usage: [MIN_EPOCH=N] scripts/bench-kurtosis.sh <params-file> [timeout-seconds]
#   MIN_EPOCH counts liveness only from that epoch on (e.g. the fork epoch, to check duties after a fork).
#   KEEP_ENCLAVE=1 leaves the enclave running afterwards, for inspection.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARAMS="$1"
TIMEOUT="${2:-1500}"
ENCLAVE="bench-$(date +%s)-$$"
# GNU mktemp needs the X's; macOS also accepts a bare -t prefix, Linux doesn't.
LOG="$(mktemp "${TMPDIR:-/tmp}/$ENCLAVE.XXXXXX")"
# The SSV pool, from the same constants main.star's layout guard uses (generate-static-keys.sh keeps them synced).
star_const() { sed -nE "s/^$1 = ([0-9]+).*/\1/p" "$ROOT/utils/constants.star"; }
SSV_FIRST=$(star_const SSV_SEED_START_INDEX)
SSV_COUNT=$(star_const SSV_MANAGED_VALIDATOR_COUNT)
[ -n "$SSV_FIRST" ] && [ -n "$SSV_COUNT" ] || { echo "can't read the SSV pool from utils/constants.star"; exit 1; }

if grep -qE '^use_recorded_txs:[[:space:]]*true' "$PARAMS"; then "$ROOT/scripts/record-txs.sh" --if-stale; fi

[ -n "${KEEP_ENCLAVE:-}" ] || trap 'kurtosis enclave rm -f "$ENCLAVE" >/dev/null 2>&1 || true' EXIT

t0=$(date +%s)
echo "[$ENCLAVE] kurtosis run --args-file $PARAMS (log: $LOG)"
kurtosis run --enclave "$ENCLAVE" --args-file "$PARAMS" "$ROOT" > "$LOG" 2>&1 || { tail -30 "$LOG"; exit 1; }
t_plan=$(date +%s)
echo "[+$((t_plan - t0))s] plan finished (SSV nodes started)"

CL_SERVICE=$(kurtosis enclave inspect "$ENCLAVE" 2>/dev/null | grep -oE 'cl-1-[a-z]+-[a-z]+' | head -1)
CL=$(kurtosis port print "$ENCLAVE" "$CL_SERVICE" http)
python3 -I - "$CL" "$t0" "$TIMEOUT" "${MIN_EPOCH:-0}" "$SSV_FIRST" "$SSV_COUNT" <<'EOF'
import json, sys, time, urllib.request

cl, t0, timeout, min_epoch = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
first_ssv, n_ssv = int(sys.argv[5]), int(sys.argv[6])
validators = [str(i) for i in range(first_ssv, first_ssv + n_ssv)]

def get(path, body=None):
    req = urllib.request.Request(cl + path, json.dumps(body).encode() if body is not None else None,
                                 {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=10))["data"]

def rel():
    return "+%ds" % (time.time() - t0)

genesis = int(get("/eth/v1/beacon/genesis")["genesis_time"])
slot = int(get("/eth/v1/config/spec")["SECONDS_PER_SLOT"])
print("[%s] genesis was at +%ds, %ds slots, counting epochs >= %d" % (rel(), genesis - t0, slot, min_epoch))

seen, first = set(), None
while time.time() - t0 < timeout:
    epoch = max(0, int(time.time() - genesis) // slot // 32)
    for e in {max(epoch - 1, min_epoch), max(epoch, min_epoch)}:
        if e > epoch:
            continue
        try:
            live = {d["index"] for d in get("/eth/v1/validator/liveness/%d" % e, validators) if d["is_live"]}
        except Exception:
            continue
        if live and first is None:
            first = time.time()
            print("[%s] first SSV validator live (epoch %d)" % (rel(), e))
        seen |= live
    if len(seen) == len(validators):
        print("[%s] every SSV validator live at least once (slot %d)" % (rel(), (time.time() - genesis) // slot))
        sys.exit(0)
    time.sleep(2)
print("[%s] TIMEOUT: %d/%d SSV validators seen live" % (rel(), len(seen), len(validators)))
sys.exit(1)
EOF
