#!/bin/bash
set -uo pipefail

# topology.resolve test suite.
#
# Starlark has no try/except, so each expected-failure case runs as its own process and we
# assert on the exit code plus a substring of the fail() message.
#
# Two mechanics, both verified against kurtosis 1.18.3 before this plan was written:
#   - Do NOT pass --dry-run. plan.print is a deferred INSTRUCTION, so under --dry-run it
#     renders as the literal text "Printing a message" and never emits its value, which
#     would make the success marker unobservable. Without --dry-run the value is printed.
#     fail() aborts during evaluation either way and exits 1.
#   - Pin --enclave so all runs reuse ONE enclave. Each fresh enclave costs a few seconds
#     of setup, and this suite makes 16 invocations. These files add no services, so the
#     shared enclave stays empty. It is removed at the end.
#
# Usage: make test-topology   (or ./tests/topology/run-tests.sh)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

POSITIVE="tests/topology/positive.star"
NEGATIVE="tests/topology/negative.star"
ENCLAVE="topology-test"
failures=0

# Start from a clean shared enclave, and always remove it on the way out.
kurtosis enclave rm -f "$ENCLAVE" >/dev/null 2>&1
trap 'kurtosis enclave rm -f "$ENCLAVE" >/dev/null 2>&1' EXIT

echo "── positive cases ──"
if out=$(kurtosis run . --main-file "$POSITIVE" --enclave "$ENCLAVE" 2>&1); then
  if echo "$out" | grep -q "ALL POSITIVE CASES PASSED"; then
    echo "PASS  positive"
  else
    echo "FAIL  positive: ran clean but the completion marker is missing"
    echo "$out" | tail -20
    failures=$((failures + 1))
  fi
else
  echo "FAIL  positive: run aborted"
  echo "$out" | tail -20
  failures=$((failures + 1))
fi

echo ""
echo "── negative cases (each must abort) ──"

# case name, substring that must appear in the failure output — as a flat pair list, not an
# associative array. macOS ships /bin/bash 3.2 (no `declare -A`, confirmed via `bash --version`
# before writing this), so the pairs are walked with `set --` instead.
set -- \
  not_a_list "must be a list of lists" \
  wrong_length "but this enclave has 4 operators" \
  entry_not_list "must be a list of pair indices" \
  empty_entry "is empty" \
  index_not_int "must be an integer pair index" \
  out_of_range "out of range (valid 0-3)" \
  negative_index "out of range (valid 0-3)" \
  duplicate "is listed twice" \
  blindspot_not_declared "out of range (valid 0-3)" \
  bs_not_a_list "blindspot_pairs must be a list of" \
  bs_entry_not_dict "must be a dict shaped" \
  bs_upstream_not_int "upstream must be an integer pair index" \
  bs_upstream_out_of_range "is not a real pair (valid 0-3)" \
  bs_strip_empty "must be a non-empty list of spec keys" \
  bs_strip_not_string "must be a string spec key"

while [ $# -gt 0 ]; do
  case="$1"
  want="$2"
  shift 2

  out=$(kurtosis run . --main-file "$NEGATIVE" --enclave "$ENCLAVE" "{\"case\":\"$case\"}" 2>&1)
  rc=$?
  if [ $rc -eq 0 ]; then
    echo "FAIL  $case: expected a non-zero exit, got 0"
    failures=$((failures + 1))
  elif echo "$out" | grep -q "CASE DID NOT ABORT"; then
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
if [ $failures -eq 0 ]; then
  echo "topology: all cases passed"
  exit 0
fi
echo "topology: $failures case(s) failed"
exit 1
