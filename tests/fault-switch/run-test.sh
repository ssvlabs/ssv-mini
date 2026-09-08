#!/bin/bash
set -e

# Fault Switch Test
#
# Tests that `make fault` archives the operator's logs, applies the new FAULT, and verifies the
# node's boot banner names the value that was requested.
#
# What it does:
#   1. Rejects a bogus FAULT value BEFORE touching the enclave: exits non-zero, archives nothing,
#      and leaves OP's container untouched
#   2. Rejects an OP with no matching container BEFORE touching the enclave: exits non-zero,
#      archives nothing, and leaves OP's container untouched (drives the real early-exit path,
#      no docker stubbing)
#   3. Switches operator OP to a known fault; asserts a non-empty archive was written
#   4. Asserts the node's banner names that fault
#   5. Switches to a second fault and asserts the banner changed
#   6. Asserts `make fault-off` reports no fault active
#
# Prerequisites:
#   - A running Gloas enclave whose SSV image is the instrumented build
#     (branch qa/gloas-m3-fault-menu in ../ssv, built as node/ssv-fault)
#   - ../ssv checked out on that branch, so `make fault-list` can enumerate the menu
#
# Usage:
#   make test-fault-switch OP=3

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

OP="${OP:-3}"
ENCLAVE="${ENCLAVE_NAME:-localnet}"
LOG_DIR="${FAULT_LOG_DIR:-.fault-logs}"

banner_fault() {  # prints the qa_fault value the node reported at its latest boot, or nothing
  docker logs "$(docker ps --format '{{.Names}}' | grep -m1 "^ssv-node-$OP--")" 2>&1 \
    | grep "QA FAULT INSTRUMENTATION ACTIVE" | tail -1 \
    | grep -oE '"qa_fault":[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/'
}

container_id() {  # prints the docker container ID for operator index $1 (same anchored primitive as make fault)
  docker ps --format '{{.Names}} {{.ID}}' | grep -m1 "^ssv-node-$1--" | awk '{print $2}'
}

archive_count() {
  ls -1 "$LOG_DIR" 2>/dev/null | wc -l | tr -d ' '
}

echo "──── A bogus FAULT value must fail before the enclave is touched ────"
before_count=$(archive_count)
before_cid=$(container_id "$OP")
if make fault FAULT=vote-index2 OP="$OP" >/dev/null 2>&1; then
  echo "FAIL: a bogus fault value was accepted"; exit 1
fi
after_count=$(archive_count)
if [ "$after_count" -ne "$before_count" ]; then
  echo "FAIL: a bogus fault value archived logs before being rejected ($before_count -> $after_count files)"; exit 1
fi
after_cid=$(container_id "$OP")
if [ "$after_cid" != "$before_cid" ]; then
  echo "FAIL: a bogus fault value touched ssv-node-$OP's container ($before_cid -> $after_cid)"; exit 1
fi

echo "──── An OP with no matching container must fail before the enclave is touched ────"
before_count=$(archive_count)
before_cid=$(container_id "$OP")
if make fault FAULT=vote-index-2 OP=99 >/dev/null 2>&1; then
  echo "FAIL: make fault accepted OP=99, which has no matching container"; exit 1
fi
after_count=$(archive_count)
if [ "$after_count" -ne "$before_count" ]; then
  echo "FAIL: an unresolvable OP archived logs before being rejected ($before_count -> $after_count files)"; exit 1
fi
after_cid=$(container_id "$OP")
if [ "$after_cid" != "$before_cid" ]; then
  echo "FAIL: an unresolvable OP call touched ssv-node-$OP's container ($before_cid -> $after_cid)"; exit 1
fi

echo "──── Switching to vote-index-2 ────"
before=$(archive_count)
make fault FAULT=vote-index-2 OP="$OP"

after=$(archive_count)
if [ "$after" -le "$before" ]; then
  echo "FAIL: no archive file was written to $LOG_DIR"; exit 1
fi
newest="$LOG_DIR/$(ls -t "$LOG_DIR" | head -1)"
if [ ! -s "$newest" ]; then
  echo "FAIL: archive $newest is empty"; exit 1
fi
got=$(banner_fault)
if [ "$got" != "vote-index-2" ]; then
  echo "FAIL: banner reports '$got', expected vote-index-2"; exit 1
fi

echo "──── Switching to two-entries ────"
make fault FAULT=two-entries OP="$OP"
got=$(banner_fault)
if [ "$got" != "two-entries" ]; then
  echo "FAIL: banner reports '$got', expected two-entries"; exit 1
fi

echo "──── Turning the fault off ────"
make fault-off OP="$OP"
if ! docker logs "$(docker ps --format '{{.Names}}' | grep -m1 "^ssv-node-$OP--")" 2>&1 | grep -q "no fault active"; then
  echo "FAIL: fault-off did not produce a 'no fault active' banner"; exit 1
fi

echo "PASS: fault switching archives, applies and verifies"
