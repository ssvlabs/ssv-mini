# Operator -> CL/EL pair mapping.
#
# Every SSV and Anchor node used to share one beacon node and one execution node, because
# main.star collapsed the network into a single tuple from all_participants[0]. That made
# per-operator BN faults, the mixed-CL cluster and the fork blind spot untestable, and it
# silently corrupted timing evidence: a single shared BN stalling looks like all four
# operators moving together (see the QA errata for the measured cases).
#
# This module owns the map and, more importantly, its validation. A misconfigured topology
# that boots is worse than one that aborts, because it produces evidence that looks fine
# and is wrong. So every rule below fails the run before any service starts.

def resolve(operator_pairs_arg, operator_count, pair_labels):
    """Validate the operator -> pair map and return it resolved.

    operator_pairs_arg: None, or a list (one entry per operator) of non-empty lists of
        0-based pair indices. Entry 0 of each inner list is the primary; the rest are
        failover targets, in order.
    operator_count: nodes.anchor.count + nodes.ssv.count. Operators share ONE global
        0-based index space (main.star starts Anchor at 0, then SSV continues), which is
        why this map is top-level and not nested under nodes.ssv.
    pair_labels: one human-readable label per pair, used in error messages. Its length is
        the pair count.

    Returns struct(pairs = [[int]], warnings = [string]). Fails on invalid input.
    """
    pair_count = len(pair_labels)

    # Rule 1: absent means today's behaviour — everyone on pair 0. This is what keeps
    # params.yaml, params-boole.yaml and params-gloas.yaml working with no edits, so it
    # must return before any other rule and must NOT emit a shared-primary warning.
    if operator_pairs_arg == None:
        return struct(
            pairs = [[0] for _ in range(operator_count)],
            warnings = [],
        )

    if type(operator_pairs_arg) != "list":
        fail("operator_pairs must be a list of lists, got {}. Example:\n{}".format(
            type(operator_pairs_arg), _example(operator_count)))

    # Rule 2: length must match the operator count exactly. The archive exporter is NOT an
    # operator (main.star renders it without incrementing node_index), so it must not be
    # counted here — otherwise this check would break whenever nodes.exporter.enabled is true.
    if len(operator_pairs_arg) != operator_count:
        fail(
            "operator_pairs has {} entries but this enclave has {} operators " .format(
                len(operator_pairs_arg), operator_count) +
            "(nodes.anchor.count + nodes.ssv.count). One entry per operator is required; " +
            "the archive exporter does not count. Example:\n{}".format(_example(operator_count)))

    resolved = []
    warnings = []
    primary_owner = {}

    for op in range(operator_count):
        entry = operator_pairs_arg[op]

        # Rule 3: each entry is a non-empty list of ints.
        if type(entry) != "list":
            fail("operator_pairs[{}] must be a list of pair indices, got {}. " .format(op, type(entry)) +
                 "Write [0] for a single beacon node, or [0, 1] for a primary plus one fallback.")
        if len(entry) == 0:
            fail("operator_pairs[{}] is empty. Every operator needs at least one pair; " .format(op) +
                 "write [0] to put it on pair 0.")

        seen = {}
        for pos in range(len(entry)):
            idx = entry[pos]
            if type(idx) != "int":
                fail("operator_pairs[{}][{}] must be an integer pair index, got {}.".format(
                    op, pos, type(idx)))

            # Rule 4: in range. The message prints the whole table because pair indices are
            # 0-based while kurtosis service names are 1-based, and that off-by-one is the
            # single most likely mistake here.
            if idx < 0 or idx >= pair_count:
                fail(
                    "operator_pairs[{}] = {}: pair index {} out of range (valid 0-{}).\n".format(
                        op, entry, idx, pair_count - 1) +
                    _table(pair_labels) +
                    "Note: pair indices are 0-based; kurtosis service names are 1-based.")

            # Rule 5: no duplicates within one operator's list. A repeated URL in the joined
            # endpoint string is meaningless to both clients and hides a typo.
            if str(idx) in seen:
                fail("operator_pairs[{}] = {}: pair {} is listed twice. A duplicate endpoint " .format(
                    op, entry, idx) + "is a no-op for both clients and usually means a typo.")
            seen[str(idx)] = True

        # Rule 6: a shared primary is legal (it is today's default) but it silently disables
        # per-operator fault isolation, so say so rather than failing.
        primary = str(entry[0])
        if primary in primary_owner:
            warnings.append(
                "op{} shares its primary beacon node (pair {}) with op{} - " .format(
                    op, entry[0], primary_owner[primary]) +
                "per-operator fault isolation is disabled for these operators")
        else:
            primary_owner[primary] = op

        resolved.append(entry)

    return struct(pairs = resolved, warnings = warnings)

def _table(pair_labels):
    out = ""
    for i in range(len(pair_labels)):
        out += "  pair {} = {}\n".format(i, pair_labels[i])
    return out

def _example(operator_count):
    lines = ["operator_pairs:"]
    for i in range(operator_count):
        lines.append("  - [{}]".format(i))
    return "\n".join(lines)
