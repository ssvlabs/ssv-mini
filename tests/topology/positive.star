topology = import_module("../../utils/topology.star")

LABELS_4 = [
    "cl-1-lodestar-geth / el-1-geth-lodestar",
    "cl-2-lodestar-geth / el-2-geth-lodestar",
    "cl-3-lodestar-geth / el-3-geth-lodestar",
    "cl-4-lodestar-geth / el-4-geth-lodestar",
]

def assert_eq(plan, name, got, want):
    if got != want:
        fail("{}: got {}, want {}".format(name, got, want))
    plan.print("  ok  {}".format(name))

def run(plan, args):
    plan.print("topology.resolve positive cases")

    # Rule 1: absent key -> every operator on pair 0.
    r = topology.resolve(None, 4, LABELS_4)
    assert_eq(plan, "rule1/absent-defaults-to-pair-0", r.pairs, [[0], [0], [0], [0]])

    # Rule 1: an absent key must not warn about a shared primary. Every operator
    # sharing pair 0 IS today's behaviour, so warning on it would fire on every
    # existing params file and train people to ignore the warning.
    assert_eq(plan, "rule1/absent-does-not-warn", r.warnings, [])

    # A strict one-BN-each split is the M4 default.
    r = topology.resolve([[0], [1], [2], [3]], 4, LABELS_4)
    assert_eq(plan, "strict-split", r.pairs, [[0], [1], [2], [3]])
    assert_eq(plan, "strict-split/no-warnings", r.warnings, [])

    # Fallback lists are preserved in order — order is the failover order.
    r = topology.resolve([[2, 0, 1, 3], [1], [2], [3]], 4, LABELS_4)
    assert_eq(plan, "fallback/order-preserved", r.pairs[0], [2, 0, 1, 3])

    # Rule 6: an explicit shared primary warns but does not fail.
    r = topology.resolve([[1], [1], [2], [3]], 4, LABELS_4)
    assert_eq(plan, "rule6/shared-primary-resolves", r.pairs, [[1], [1], [2], [3]])
    if len(r.warnings) != 1:
        fail("rule6: expected exactly 1 warning, got {}: {}".format(len(r.warnings), r.warnings))
    if "op0" not in r.warnings[0] or "op1" not in r.warnings[0]:
        fail("rule6: warning must name both operators, got: {}".format(r.warnings[0]))
    plan.print("  ok  rule6/shared-primary-warns")

    # A single pair enclave still resolves (params.yaml has one participant group of count 2,
    # but a count-1 group is legal).
    r = topology.resolve([[0], [0]], 2, ["cl-1-lodestar-geth / el-1-geth-lodestar"])
    assert_eq(plan, "single-pair", r.pairs, [[0], [0]])

    # Blind-spot pairs are appended AFTER the real participants, so they are addressable by
    # index like any other pair and pair 0 is always real (which is what lets infra never
    # resolve to a proxy).
    labels_5 = LABELS_4 + ["blindspot-proxy-0 -> cl-4-lodestar-geth (strip GLOAS_FORK_EPOCH)"]
    r = topology.resolve([[0], [1], [2], [4]], 4, labels_5)
    assert_eq(plan, "blindspot/addressable-as-a-pair", r.pairs, [[0], [1], [2], [4]])
    assert_eq(plan, "blindspot/no-warnings", r.warnings, [])

    # validate_blindspot_pairs() is pure - the label+range-check half split out of
    # _start_blindspot_proxies so resolve() can see blind-spot pairs before any service
    # starts. An absent key behaves like [] (no blind-spot pairs).
    v = topology.validate_blindspot_pairs([], ["cl-4-lodestar-geth"])
    assert_eq(plan, "bs/empty-is-noop", v.entries, [])
    assert_eq(plan, "bs/empty-labels", v.labels, [])

    v = topology.validate_blindspot_pairs(
        [{"upstream": 0, "strip": ["GLOAS_FORK_EPOCH"]}], ["cl-4-lodestar-geth"])
    assert_eq(plan, "bs/upstream-resolved", v.entries[0].upstream, 0)
    assert_eq(plan, "bs/strip-preserved", v.entries[0].strip, ["GLOAS_FORK_EPOCH"])
    assert_eq(
        plan, "bs/label-format", v.labels[0],
        "blindspot-proxy-0 -> cl-4-lodestar-geth (strip GLOAS_FORK_EPOCH)")

    # strip defaults to [GLOAS_FORK_EPOCH] when omitted.
    v = topology.validate_blindspot_pairs([{"upstream": 0}], ["cl-4-lodestar-geth"])
    assert_eq(plan, "bs/strip-default", v.entries[0].strip, ["GLOAS_FORK_EPOCH"])

    plan.print("ALL POSITIVE CASES PASSED")
