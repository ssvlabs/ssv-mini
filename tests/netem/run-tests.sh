#!/bin/bash
# Unit tests for scripts/netem's pure helpers.
#
# scripts/netem guards its main() behind a sourced-vs-executed check, so this file can source it and
# call the helpers directly. Everything tested here is pure string/list logic — no docker, no
# kurtosis, no enclave — so the suite runs in well under a second and is safe to run anywhere.
# The parts that genuinely need a live enclave (tc application, container resolution) are verified
# by hand per docs in scripts/netem's header; they are not faked here, because a mocked `tc` would
# assert our own mock rather than the kernel's behaviour.
#
# Usage: make test-netem   (or ./tests/netem/run-tests.sh)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$PROJECT_DIR/scripts/netem"

failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; echo "        $2"; failures=$((failures + 1)); }

# eq <name> <got> <want>
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2', want '$3'"; fi; }

# rejects <name> <function> <arg>  — the validator must exit non-zero
rejects() {
  local name=$1 fn=$2 arg=${3-}
  if "$fn" "$arg" >/dev/null 2>&1; then fail "$name" "accepted '$arg', expected rejection"; else pass "$name"; fi
}
accepts() {
  local name=$1 fn=$2 arg=${3-}
  if "$fn" "$arg" >/dev/null 2>&1; then pass "$name"; else fail "$name" "rejected '$arg', expected acceptance"; fi
}

echo "── netem_primary_host: extract the PRIMARY beacon host from a rendered BeaconNodeAddr ──"
# The rendered config carries the resolved endpoint list, ';'-joined for go-SSV. The primary is
# entry 0 — that is the BN whose link FLT-01/PTC-06 shape. Fallbacks must be ignored, or shaping
# would target a CL the operator is not actually using.
eq "single endpoint"        "$(netem_primary_host 'http://cl-1-lodestar-geth:4000')"                                  "cl-1-lodestar-geth"
eq "list takes entry 0"     "$(netem_primary_host 'http://cl-2-lodestar-geth:4000;http://cl-1-lodestar-geth:4000')"   "cl-2-lodestar-geth"
eq "quoted yaml value"      "$(netem_primary_host '"http://cl-3-lodestar-geth:4000"')"                                "cl-3-lodestar-geth"
eq "https scheme"           "$(netem_primary_host 'https://cl-1-lodestar-geth:4000')"                                 "cl-1-lodestar-geth"
eq "no port"                "$(netem_primary_host 'http://cl-1-lodestar-geth')"                                       "cl-1-lodestar-geth"
eq "surrounding whitespace" "$(netem_primary_host '  http://cl-4-teku-geth:4000  ')"                                   "cl-4-teku-geth"
rejects "empty is rejected" netem_primary_host ""

echo
echo "── validators: a bad argument must abort BEFORE any tc runs ──"
accepts "delay 200 ok"        netem_validate_ms 200
accepts "delay 1 ok"          netem_validate_ms 1
rejects "delay 0 rejected"    netem_validate_ms 0
rejects "delay -5 rejected"   netem_validate_ms -5
rejects "delay 20ms rejected" netem_validate_ms "20ms"
rejects "delay empty"         netem_validate_ms ""
accepts "loss 10 ok"          netem_validate_pct 10
accepts "loss 100 ok"         netem_validate_pct 100
accepts "loss 0 ok"           netem_validate_pct 0
rejects "loss 101 rejected"   netem_validate_pct 101
rejects "loss 10.5 rejected"  netem_validate_pct "10.5"
accepts "target bn"           netem_validate_target bn
accepts "target p2p"          netem_validate_target p2p
accepts "target all"          netem_validate_target all
rejects "target BN uppercase" netem_validate_target BN
rejects "target bogus"        netem_validate_target peers
accepts "op 0 ok"             netem_validate_op 0
accepts "op 12 ok"            netem_validate_op 12
rejects "op -1 rejected"      netem_validate_op -1
rejects "op x rejected"       netem_validate_op x
rejects "op empty"            netem_validate_op ""

echo
echo "── netem_shared_ops: who ELSE is on this beacon node ──"
# The shared-CL guard exists because 'stop operator 3's CL' silently taking op0 down with it is how
# an FLT-04 run gets misread. Input is 'op<TAB>host' lines, as produced by netem_topology.
MAP=$'0\tcl-1-lodestar-geth\n1\tcl-2-lodestar-geth\n2\tcl-3-lodestar-geth\n3\tcl-4-lodestar-geth'
eq "strict split: nobody shares" "$(netem_shared_ops 3 cl-4-lodestar-geth "$MAP")" ""
SHARED=$'0\tcl-1-lodestar-geth\n1\tcl-1-lodestar-geth\n2\tcl-3-lodestar-geth\n3\tcl-1-lodestar-geth'
eq "shared: lists the others"    "$(netem_shared_ops 0 cl-1-lodestar-geth "$SHARED")" "1 3"
eq "shared: excludes self"       "$(netem_shared_ops 1 cl-1-lodestar-geth "$SHARED")" "0 3"
eq "unshared inside a shared map" "$(netem_shared_ops 2 cl-3-lodestar-geth "$SHARED")" ""
# The default profiles (params.yaml, params-boole.yaml, params-gloas.yaml) put EVERY operator on
# pair 0, so the guard must fire loudly there rather than silently shaping one of four.
ALL_ONE=$'0\tcl-1-lighthouse-geth\n1\tcl-1-lighthouse-geth\n2\tcl-1-lighthouse-geth\n3\tcl-1-lighthouse-geth'
eq "shared-CL default profile"   "$(netem_shared_ops 0 cl-1-lighthouse-geth "$ALL_ONE")" "1 2 3"

echo
echo "── netem_peer_ops: the p2p target set is every OTHER operator ──"
eq "excludes self"    "$(netem_peer_ops 1 "$MAP")" "0 2 3"
eq "excludes self, 0" "$(netem_peer_ops 0 "$MAP")" "1 2 3"

echo
if [ $failures -eq 0 ]; then echo "netem: all cases passed"; exit 0; fi
echo "netem: $failures case(s) failed"; exit 1
