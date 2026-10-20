builders = import_module("../../utils/builders.star")
buildoor = import_module("../../nodes/buildoor/buildoor.star")

ENTRY = {"URL": "http://buildoor:8080"}

def assert_eq(plan, name, got, want):
    if got != want:
        fail("{}: got {}, want {}".format(name, got, want))
    plan.print("  ok  {}".format(name))

def net(cl_extra_params, operator_pairs = None):
    args = {
        "network": {"participants": [
            {"cl_type": "lodestar", "count": 1},
            {"cl_type": "lodestar", "count": 1, "cl_extra_params": cl_extra_params},
        ]},
        "nodes": {"anchor": {"count": 0}, "ssv": {"count": 4}},
        "buildoor": {"enabled": True, "pair": 1},
    }
    if operator_pairs != None:
        args["operator_pairs"] = operator_pairs
    return args

def run(plan, args):
    plan.print("builders.resolve / buildoor.validate positive cases")

    # Absent key: no Builders block anywhere, so every existing params file is unchanged.
    assert_eq(plan, "absent", builders.resolve({}, 4), [None, None, None, None])

    # shared goes to every operator.
    r = builders.resolve({"ssv_builders": {"shared": {"Entries": [ENTRY]}}}, 4)
    assert_eq(plan, "shared", r, [{"Entries": [ENTRY]}] * 4)

    # An override REPLACES shared whole; {} (or null) means no block for that operator.
    div = {"Entries": [{"URL": "http://buildoor:8080", "AuthData": "0x01"}]}
    r = builders.resolve({"ssv_builders": {"shared": {"Entries": [ENTRY]},
                                           "overrides": {"1": div, "3": {}, "2": None}}}, 4)
    assert_eq(plan, "overrides", r, [{"Entries": [ENTRY]}, div, None, None])

    # Overrides with no shared block: only the named operator gets one.
    r = builders.resolve({"ssv_builders": {"overrides": {"0": {"BuilderBoostFactor": 0}}}}, 4)
    assert_eq(plan, "override-only", r, [{"BuilderBoostFactor": 0}, None, None, None])

    # Rendered as JSON (valid YAML flow style) with the node's own key names.
    assert_eq(plan, "render", builders.render({"MinBid": 5, "Entries": [ENTRY]}),
              '{"Entries":[{"URL":"http://buildoor:8080"}],"MinBid":5}')
    assert_eq(plan, "render-none", builders.render(None), "")

    # buildoor on pair 1, every operator on pair 0 (the params-gloas-builder.yaml layout).
    b = buildoor.get_args(net(["--emitPayloadAttributes"]))
    buildoor.validate(b, net(["--emitPayloadAttributes"]))
    plan.print("  ok  buildoor/default-layout")
    # Fallbacks that avoid the builder's pair are fine.
    a = net(["--emitPayloadAttributes"])
    a["network"]["participants"].append({"cl_type": "lodestar", "count": 1})
    a["operator_pairs"] = [[0, 2], [0], [2], [2, 0]]
    buildoor.validate(buildoor.get_args(a), a)
    plan.print("  ok  buildoor/fallbacks-avoid-builder-pair")
    assert_eq(plan, "buildoor/disabled", buildoor.get_args({"buildoor": {"enabled": False}}), None)

    plan.print("ALL POSITIVE CASES PASSED")
