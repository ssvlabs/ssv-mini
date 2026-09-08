topology = import_module("../../utils/topology.star")

LABELS_4 = [
    "cl-1-lodestar-geth / el-1-geth-lodestar",
    "cl-2-lodestar-geth / el-2-geth-lodestar",
    "cl-3-lodestar-geth / el-3-geth-lodestar",
    "cl-4-lodestar-geth / el-4-geth-lodestar",
]

# Each case must abort the run. run-tests.sh asserts a non-zero exit and the substring.
CASES = {
    "not_a_list":    lambda: topology.resolve("nope", 4, LABELS_4),
    "wrong_length":  lambda: topology.resolve([[0], [1]], 4, LABELS_4),
    "entry_not_list": lambda: topology.resolve([0, [1], [2], [3]], 4, LABELS_4),
    "empty_entry":   lambda: topology.resolve([[], [1], [2], [3]], 4, LABELS_4),
    "index_not_int": lambda: topology.resolve([["0"], [1], [2], [3]], 4, LABELS_4),
    "out_of_range":  lambda: topology.resolve([[0], [1], [2], [4]], 4, LABELS_4),
    "negative_index": lambda: topology.resolve([[-1], [1], [2], [3]], 4, LABELS_4),
    "duplicate":     lambda: topology.resolve([[0, 0], [1], [2], [3]], 4, LABELS_4),
}

def run(plan, args):
    case = args.get("case", "")
    if case not in CASES:
        fail("unknown case {}; known: {}".format(case, sorted(CASES.keys())))
    plan.print("running negative case: {}".format(case))
    CASES[case]()
    fail("CASE DID NOT ABORT: {} was expected to fail validation but returned".format(case))
