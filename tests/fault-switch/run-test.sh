#!/bin/bash
set -e

# Fault Switch Test
#
# Tests that `make fault` archives the operator's logs, applies the new FAULT, and verifies the
# node's boot banner names the value that was requested.
#
# What it does:
#   1. Rejects a bogus value BEFORE touching the enclave
#   2. Switches operator OP to a known fault; asserts a non-empty archive was written
#   3. Asserts the node's banner names that fault
#   4. Switches to a second fault and asserts the banner changed
#   5. Asserts `make fault-off` reports no fault active
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

echo "──── A bogus value must fail before the enclave is touched ────"
if make fault FAULT=vote-index2 OP="$OP" >/dev/null 2>&1; then
  echo "FAIL: a bogus fault value was accepted"; exit 1
fi

echo "──── Switching to vote-index-2 ────"
before=$(ls -1 "$LOG_DIR" 2>/dev/null | wc -l | tr -d ' ')
make fault FAULT=vote-index-2 OP="$OP"

after=$(ls -1 "$LOG_DIR" | wc -l | tr -d ' ')
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
