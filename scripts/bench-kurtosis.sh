#!/usr/bin/env bash
# Times one Kurtosis bring-up end to end, with the same pass criterion as the hive simulator: every SSV-managed
# validator (indices 64-73) seen live by the beacon node at least once. Needs pre_register_validators: true in
# the params file, or the SSV nodes have no validators. Removes its own enclave afterwards.
#
# Usage: scripts/bench-kurtosis.sh <params-file> [timeout-seconds]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARAMS="$1"
TIMEOUT="${2:-1500}"
ENCLAVE="bench-$(date +%s)"
LOG="$(mktemp -t "$ENCLAVE").log"

trap 'kurtosis enclave rm -f "$ENCLAVE" >/dev/null 2>&1 || true' EXIT

t0=$(date +%s)
echo "[$ENCLAVE] kurtosis run --args-file $PARAMS (log: $LOG)"
kurtosis run --enclave "$ENCLAVE" --args-file "$PARAMS" "$ROOT" > "$LOG" 2>&1 || { tail -30 "$LOG"; exit 1; }
t_plan=$(date +%s)
echo "[+$((t_plan - t0))s] plan finished (SSV nodes started)"

CL=$(kurtosis port print "$ENCLAVE" cl-1-lighthouse-geth http)
python3 -I - "$CL" "$t0" "$TIMEOUT" <<'EOF'
import json, sys, time, urllib.request

cl, t0, timeout = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
validators = [str(i) for i in range(64, 74)]

def get(path, body=None):
    req = urllib.request.Request(cl + path, json.dumps(body).encode() if body is not None else None,
                                 {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=10))["data"]

def rel():
    return "+%ds" % (time.time() - t0)

genesis = int(get("/eth/v1/beacon/genesis")["genesis_time"])
slot = int(get("/eth/v1/config/spec")["SECONDS_PER_SLOT"])
print("[%s] genesis was at +%ds, %ds slots" % (rel(), genesis - t0, slot))

seen, first = set(), None
while time.time() - t0 < timeout:
    epoch = max(0, int(time.time() - genesis) // slot // 32)
    for e in {max(epoch - 1, 0), epoch}:
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
