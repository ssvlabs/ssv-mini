#!/bin/bash
# cl-proxy test suite. Needs no enclave and no Kurtosis.
#
#   1. `go test` on the proxy itself (tests/cl-proxy/proxy_test.go): every rule against a fake
#      POST-only beacon node, pass-through of everything else, the control API, the access log,
#      SSE flushing and the blind-spot spec strip. Runs with the host Go toolchain when there is
#      one, else inside the golang image the Dockerfile builds with.
#   2. The pure helpers of scripts/cl-proxy (argument validation and the control query), sourced
#      the same way tests/netem sources scripts/netem.
#
# Usage: make test-cl-proxy   (or ./tests/cl-proxy/run-tests.sh)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
failures=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; echo "        $2"; failures=$((failures + 1)); }

echo "── go test (proxy rules, pass-through, control API, access log) ──"
if command -v go >/dev/null 2>&1; then
  out=$(cd "$SCRIPT_DIR" && go vet ./... 2>&1 && go test -count=1 ./... 2>&1)
else
  out=$(docker run --rm -v "$SCRIPT_DIR":/src -w /src golang:1.26 sh -c 'go vet ./... && go test -count=1 ./...' 2>&1)
fi
if [ $? -eq 0 ]; then
  pass "go test"
else
  fail "go test" "$(echo "$out" | grep -v '^20[0-9][0-9]/' | tail -20)"
fi

# shellcheck source=/dev/null
source "$PROJECT_DIR/scripts/cl-proxy"

eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "got '$2', want '$3'"; fi; }
rejects() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then fail "$name" "accepted: $*"; else pass "$name"; fi
}

echo
echo "── scripts/cl-proxy: control query ──"
eq "post-405 on"              "$(clproxy_rule_query post-405 on)"                       "name=post-405&state=on"
eq "post-405 slots"           "$(clproxy_rule_query post-405 on 130,131)"               "name=post-405&state=on&slots=130,131"
eq "post-405 no translation"  "$(clproxy_rule_query post-405 on '' false)"              "name=post-405&state=on&translate_get=false"
eq "no-include-payload off"   "$(clproxy_rule_query no-include-payload off)"            "name=no-include-payload&state=off"
eq "no-include-payload remove" "$(clproxy_rule_query no-include-payload on 72 '' '' remove)" "name=no-include-payload&state=on&slots=72&mode=remove"
eq "version-header value"     "$(clproxy_rule_query version-header on 140 '' electra)"  "name=version-header&state=on&slots=140&value=electra"

echo
echo "── scripts/cl-proxy: bad arguments must abort before anything is sent ──"
rejects "unknown rule"                   clproxy_rule_query post-404 on
rejects "empty rule"                     clproxy_rule_query "" on
rejects "bad state"                      clproxy_rule_query post-405 yes
rejects "slots with a space"             clproxy_rule_query post-405 on "130, 131"
rejects "slots not numbers"              clproxy_rule_query post-405 on "s130"
rejects "translate-get on another rule"  clproxy_rule_query version-header on "" true
rejects "translate-get not a bool"       clproxy_rule_query post-405 on "" yes
rejects "value on another rule"          clproxy_rule_query post-405 on "" "" fulu
rejects "value with a quote"             clproxy_rule_query version-header on "" "" "fulu'"
rejects "mode on another rule"           clproxy_rule_query post-405 on "" "" "" remove
rejects "mode not false/remove"          clproxy_rule_query no-include-payload on "" "" "" drop
rejects "proxy name missing"             clproxy_validate_name ""
rejects "proxy name not a proxy"         clproxy_validate_name ssv-node-0
eq      "blindspot proxy name accepted"  "$(clproxy_validate_name blindspot-proxy-0 && echo ok)" "ok"

echo
if [ $failures -eq 0 ]; then
  echo "cl-proxy: all cases passed"
  exit 0
fi
echo "cl-proxy: $failures case(s) failed"
exit 1
