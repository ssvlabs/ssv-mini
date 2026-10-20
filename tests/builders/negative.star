builders = import_module("../../utils/builders.star")
buildoor = import_module("../../nodes/buildoor/buildoor.star")

ENTRY = {"URL": "http://buildoor:8080"}

def _res(cfg):
    return builders.resolve({"ssv_builders": cfg}, 4)

def _net(extra = ["--emitPayloadAttributes"], operator_pairs = None, blindspots = None, cl_type = "lodestar"):
    args = {
        "network": {"participants": [
            {"cl_type": "lodestar", "count": 1},
            {"cl_type": cl_type, "count": 1, "cl_extra_params": extra},
        ]},
        "nodes": {"anchor": {"count": 0}, "ssv": {"count": 4}},
        "buildoor": {"enabled": True, "pair": 1},
    }
    if operator_pairs != None:
        args["operator_pairs"] = operator_pairs
    if blindspots != None:
        args["blindspot_pairs"] = blindspots
    return args

def _val(args):
    buildoor.validate(buildoor.get_args(args), args)

CASES = {
    "not_dict":          lambda: _res("nope"),
    "unknown_top":       lambda: _res({"shared": {}, "override": {}}),
    "unknown_block_key": lambda: _res({"shared": {"Entries": [ENTRY], "MinBids": 1}}),
    "unknown_entry_key": lambda: _res({"shared": {"Entries": [{"URL": "http://b:1", "AuthDta": "0x01"}]}}),
    "missing_url":       lambda: _res({"shared": {"Entries": [{"AuthData": "0x01"}]}}),
    "negative_minbid":   lambda: _res({"shared": {"MinBid": -1}}),
    "too_many_entries":  lambda: _res({"shared": {"Entries": [ENTRY] * 9}}),
    "override_index":    lambda: _res({"overrides": {"4": {}}}),
    "override_not_int":  lambda: _res({"overrides": {"op1": {}}}),
    "bd_pair_range":     lambda: _val(dict(_net(), buildoor = {"enabled": True, "pair": 2})),
    "bd_primary":        lambda: _val(_net(operator_pairs = [[0], [1], [0], [0]])),
    "bd_fallback":       lambda: _val(_net(operator_pairs = [[0], [0, 1], [0], [0]])),
    "bd_blindspot":      lambda: _val(_net(operator_pairs = [[0], [2], [0], [0]],
                                           blindspots = [{"upstream": 1}])),
    "bd_no_emit":        lambda: _val(_net(extra = [])),
    "bd_not_lodestar":   lambda: _val(_net(cl_type = "lighthouse")),
    "bd_unknown_key":    lambda: buildoor.get_args({"buildoor": {"enabled": True, "pairs": 1}}),
}

def run(plan, args):
    case = args.get("case", "")
    if case not in CASES:
        fail("unknown case {}".format(case))
    CASES[case]()
    plan.print("CASE DID NOT ABORT")
