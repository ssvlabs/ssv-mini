#!/bin/bash
set -uo pipefail

# builders.resolve (ssv_builders) + buildoor.validate test suite. Same mechanics as
# tests/topology/run-tests.sh: no --dry-run (plan.print must emit), one shared empty enclave,
# one process per expected failure (Starlark has no try/except).
#
# Usage: make test-builders   (or ./tests/builders/run-tests.sh)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../.."

POSITIVE="tests/builders/positive.star"
NEGATIVE="tests/builders/negative.star"
ENCLAVE="builders-test"
failures=0

kurtosis enclave rm -f "$ENCLAVE" >/dev/null 2>&1
trap 'kurtosis enclave rm -f "$ENCLAVE" >/dev/null 2>&1' EXIT

echo "── positive cases ──"
if out=$(kurtosis run . --main-file "$POSITIVE" --enclave "$ENCLAVE" 2>&1) && echo "$out" | grep -q "ALL POSITIVE CASES PASSED"; then
  echo "PASS  positive"
else
  echo "FAIL  positive"
  echo "$out" | tail -20
  failures=$((failures + 1))
fi

echo ""
echo "── negative cases (each must abort) ──"
set -- \
  not_dict "ssv_builders must be a dict" \
  unknown_top "ssv_builders.override: unknown key" \
  unknown_block_key "ssv_builders.shared.MinBids: unknown key" \
  unknown_entry_key "Entries[0].AuthDta: unknown key" \
  missing_url "Entries[0].URL is required" \
  negative_minbid "ssv_builders.shared.MinBid must be a non-negative integer" \
  too_many_entries "the node allows at most 8" \
  override_index "is not a global operator index (valid 0-3)" \
  override_not_int "is not a global operator index (valid 0-3)" \
  bd_pair_range "but the network has only 2 participants" \
  bd_primary "but operator 1 uses that beacon node" \
  bd_fallback "but operator 1 uses that beacon node" \
  bd_blindspot "but operator 1 uses that beacon node" \
  bd_no_emit "without --emitPayloadAttributes" \
  bd_not_lodestar "Only Lodestar is wired" \
  bd_unknown_key "buildoor.pairs: unknown key"

while [ $# -gt 0 ]; do
  case="$1"; want="$2"; shift 2
  out=$(kurtosis run . --main-file "$NEGATIVE" --enclave "$ENCLAVE" "{\"case\":\"$case\"}" 2>&1)
  rc=$?
  if [ $rc -eq 0 ] || echo "$out" | grep -q "CASE DID NOT ABORT"; then
    echo "FAIL  $case: validation accepted invalid input"
    failures=$((failures + 1))
  elif echo "$out" | grep -qF "$want"; then
    echo "PASS  $case"
  else
    echo "FAIL  $case: aborted, but the message did not contain: $want"
    echo "$out" | tail -10
    failures=$((failures + 1))
  fi
done

echo ""
if [ $failures -eq 0 ]; then echo "builders: all cases passed"; exit 0; fi
echo "builders: $failures case(s) failed"
exit 1
