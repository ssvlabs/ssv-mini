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

BLINDSPOT_PORT = 4000

def _start_blindspot_proxies(plan, args, all_participants):
    """Start one spec-rewriting proxy per blindspot_pairs entry.

    Each returns a synthetic "pair" whose CL is the proxy and whose EL is the upstream
    pair's EL untouched - the proxy sits on the CL path only.
    """
    entries = args.get("blindspot_pairs", [])
    if type(entries) != "list":
        fail("blindspot_pairs must be a list of {upstream: <pair index>, strip: [<spec key>]}")

    extra = []
    for i in range(len(entries)):
        e = entries[i]
        upstream_idx = e.get("upstream", None)
        if type(upstream_idx) != "int":
            fail("blindspot_pairs[{}].upstream must be an integer pair index".format(i))
        if upstream_idx < 0 or upstream_idx >= len(all_participants):
            fail("blindspot_pairs[{}].upstream = {} is not a real pair (valid 0-{}). ".format(
                i, upstream_idx, len(all_participants) - 1) +
                 "A blind-spot pair must proxy an actual participant, not another proxy.")
        strip = e.get("strip", ["GLOAS_FORK_EPOCH"])
        if type(strip) != "list" or len(strip) == 0:
            fail("blindspot_pairs[{}].strip must be a non-empty list of spec keys".format(i))

        up = all_participants[upstream_idx]
        name = "blindspot-proxy-{}".format(i)
        svc = plan.add_service(
            name = name,
            description = "Starting {} in front of {}".format(
                name, up.cl_context.beacon_service_name),
            config = ServiceConfig(
                image = "blindspot-proxy",
                env_vars = {
                    "UPSTREAM": "http://{}:{}".format(
                        up.cl_context.ip_addr, up.cl_context.http_port),
                    "STRIP": ",".join(strip),
                    "LISTEN_PORT": str(BLINDSPOT_PORT),
                },
                ports = {
                    "http": PortSpec(
                        number = BLINDSPOT_PORT,
                        transport_protocol = "TCP",
                        application_protocol = "http",
                    ),
                },
            ),
        )
        extra.append(struct(
            label = "{} -> {} (strip {})".format(
                name, up.cl_context.beacon_service_name, ",".join(strip)),
            cl_url = "http://{}:{}".format(svc.ip_address, BLINDSPOT_PORT),
            el_rpc = "http://{}:{}".format(up.el_context.ip_addr, up.el_context.rpc_port_num),
            el_ws = "ws://{}:{}".format(up.el_context.ip_addr, up.el_context.ws_port_num),
        ))
    return extra

def _endpoints_for(all_participants, blindspots, idx):
    """Resolve a pair index across real participants and appended blind-spot pairs."""
    if idx < len(all_participants):
        p = all_participants[idx]
        return struct(
            cl_url = "http://{}:{}".format(p.cl_context.ip_addr, p.cl_context.http_port),
            el_rpc = "http://{}:{}".format(p.el_context.ip_addr, p.el_context.rpc_port_num),
            el_ws = "ws://{}:{}".format(p.el_context.ip_addr, p.el_context.ws_port_num),
        )
    b = blindspots[idx - len(all_participants)]
    return struct(cl_url = b.cl_url, el_rpc = b.el_rpc, el_ws = b.el_ws)

def build(plan, args, all_participants):
    """Resolve the operator -> pair map against the live ethereum-package participants."""
    pair_labels = []
    for p in all_participants:
        pair_labels.append("{} / {}".format(
            p.cl_context.beacon_service_name, p.el_context.service_name))

    operator_count = args["nodes"]["anchor"]["count"] + args["nodes"]["ssv"]["count"]
    if operator_count == 0:
        fail("no operators configured: nodes.anchor.count and nodes.ssv.count are both 0")

    blindspots = _start_blindspot_proxies(plan, args, all_participants)
    for b in blindspots:
        pair_labels.append(b.label)

    r = resolve(args.get("operator_pairs", None), operator_count, pair_labels)

    operators = []
    for op in range(operator_count):
        cl_urls = []
        el_rpc_urls = []
        el_ws_urls = []
        for idx in r.pairs[op]:
            ep = _endpoints_for(all_participants, blindspots, idx)
            cl_urls.append(ep.cl_url)
            el_rpc_urls.append(ep.el_rpc)
            el_ws_urls.append(ep.el_ws)
        operators.append(struct(
            index = op,
            pairs = r.pairs[op],
            cl_urls = cl_urls,
            el_rpc_urls = el_rpc_urls,
            el_ws_urls = el_ws_urls,
        ))

    # infra is pair 0 and is deliberately a separate field, not operators[0]. The contract
    # deploy, the two block-height gates, the keysplit, the validator registration and the
    # monitor are enclave-level singletons, not any operator's view of the chain. They are
    # the same thing today and will not be after this change, so the names must differ.
    first = all_participants[0]
    infra = struct(
        cl_url = "http://{}:{}".format(first.cl_context.ip_addr, first.cl_context.http_port),
        el_rpc = "http://{}:{}".format(first.el_context.ip_addr, first.el_context.rpc_port_num),
        el_ws = "ws://{}:{}".format(first.el_context.ip_addr, first.el_context.ws_port_num),
        cl_service = first.cl_context.beacon_service_name,
        el_service = first.el_context.service_name,
    )

    _print_topology(plan, operators, pair_labels, r.warnings)

    return struct(pair_count = len(pair_labels), operators = operators, infra = infra)

def _print_topology(plan, operators, pair_labels, warnings):
    # Printed at bring-up on purpose. "Which beacon node was operator N actually on?" has
    # had to be reconstructed after the fact more than once; this line answers it in the run
    # log, and it makes the 0-based-pair vs 1-based-service-name off-by-one visible now
    # rather than during analysis.
    lines = ["operator topology ({} operators, {} pairs):".format(
        len(operators), len(pair_labels))]
    for op in operators:
        extra = ""
        if len(op.pairs) > 1:
            extra = " (+{} fallback)".format(len(op.pairs) - 1)
        lines.append("  op{} -> pairs {}  {}{}".format(
            op.index, op.pairs, pair_labels[op.pairs[0]], extra))
    plan.print("\n".join(lines))
    for w in warnings:
        plan.print("WARNING: {}".format(w))
