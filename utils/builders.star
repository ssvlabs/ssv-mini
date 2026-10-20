# The SSV node's `Builders` config block (Gloas / ePBS direct-builder overlay, ssv
# cli/operator/config.go + protocol/v2/types/gloas/builder_entry.go, docs/EXTERNAL_BUILDERS.md).
#
# Params key `ssv_builders` (top level, absent = no Builders block on any node):
#
#   ssv_builders:
#     shared:                      # rendered into every SSV operator's config
#       MinBid: 0
#       BuilderBoostFactor: 100
#       Entries:
#         - URL: "http://buildoor:8080"
#           MaxExecutionPayment: 0
#     overrides:                   # GLOBAL operator index -> full REPLACEMENT block
#       "3": {}                    # {} = no Builders block on operator 3
#
# The keys are the node's own YAML keys, passed through unchanged, so any test the node's config
# supports can be expressed here. An override replaces `shared` whole (no deep merge): a
# divergence test then states the complete block that operator runs, which is easier to audit.
# The archive exporter never gets the block (it does not propose).
#
# Why a native param and not `kurtosis service update`: an update drops the node's file mounts
# and cold-resyncs it. The block must be present at bring-up.
#
# The node requires the SAME list on every operator of a committee (AuthData is threshold-signed);
# an override that diverges is legal here on purpose, because that divergence is a test case.

MAX_ENTRIES = 8  # ssv gloas.MaxBuilderEntries

_CONFIG_KEYS = ["MinBid", "BuilderBoostFactor", "Entries"]
_ENTRY_KEYS = ["URL", "AuthData", "BuilderPubKeys", "MaxExecutionPayment", "MinBid", "BuilderBoostFactor"]

def _check_uint(where, v):
    if type(v) != "int" or v < 0:
        fail("{} must be a non-negative integer, got {} ({})".format(where, v, type(v)))

def _check_block(where, block):
    if type(block) != "dict":
        fail("{} must be a dict with keys {}, got {}".format(where, _CONFIG_KEYS, type(block)))
    for k in block.keys():
        if k not in _CONFIG_KEYS:
            # The node's YAML decoder ignores unknown keys, so a typo would silently drop a knob.
            fail("{}.{}: unknown key. Allowed: {}".format(where, k, ", ".join(_CONFIG_KEYS)))
    if "MinBid" in block:
        _check_uint(where + ".MinBid", block["MinBid"])
    if "BuilderBoostFactor" in block:
        _check_uint(where + ".BuilderBoostFactor", block["BuilderBoostFactor"])
    entries = block.get("Entries", [])
    if type(entries) != "list":
        fail("{}.Entries must be a list, got {}".format(where, type(entries)))
    if len(entries) > MAX_ENTRIES:
        fail("{}.Entries has {} entries; the node allows at most {}".format(where, len(entries), MAX_ENTRIES))
    for i in range(len(entries)):
        e = entries[i]
        ew = "{}.Entries[{}]".format(where, i)
        if type(e) != "dict":
            fail("{} must be a dict, got {}".format(ew, type(e)))
        for k in e.keys():
            if k not in _ENTRY_KEYS:
                fail("{}.{}: unknown key. Allowed: {}".format(ew, k, ", ".join(_ENTRY_KEYS)))
        if type(e.get("URL", None)) != "string" or e["URL"] == "":
            fail("{}.URL is required (a non-empty string)".format(ew))
        for k in ["MaxExecutionPayment", "MinBid", "BuilderBoostFactor"]:
            if k in e:
                _check_uint(ew + "." + k, e[k])
        if "AuthData" in e and type(e["AuthData"]) != "string":
            fail("{}.AuthData must be a 0x-hex string".format(ew))
        if "BuilderPubKeys" in e:
            if type(e["BuilderPubKeys"]) != "list":
                fail("{}.BuilderPubKeys must be a list of 0x-hex strings".format(ew))

def resolve(args, operator_count):
    """Validate `ssv_builders` and return one block per global operator index (None = no block).
    Pure; fails on invalid input. Call at plan time, before any service starts."""
    cfg = args.get("ssv_builders", None)
    if cfg == None:
        return [None for _ in range(operator_count)]
    if type(cfg) != "dict":
        fail("ssv_builders must be a dict with keys shared/overrides, got {}".format(type(cfg)))
    for k in cfg.keys():
        if k not in ["shared", "overrides"]:
            fail("ssv_builders.{}: unknown key. Allowed: shared, overrides".format(k))

    shared = cfg.get("shared", None)
    if shared != None:
        _check_block("ssv_builders.shared", shared)

    overrides = cfg.get("overrides", {})
    if overrides == None:
        overrides = {}
    if type(overrides) != "dict":
        fail("ssv_builders.overrides must be a dict keyed by global operator index, got {}".format(type(overrides)))
    by_index = {}
    for k in overrides.keys():
        # Kurtosis passes args through JSON, so YAML int keys arrive as strings.
        ks = str(k)
        if not ks.isdigit() or int(ks) >= operator_count:
            fail("ssv_builders.overrides key {} is not a global operator index (valid 0-{})".format(
                k, operator_count - 1))
        block = overrides[k]
        if block == None:
            block = {}
        _check_block("ssv_builders.overrides.{}".format(ks), block)
        by_index[int(ks)] = block

    out = []
    for i in range(operator_count):
        block = by_index.get(i, shared)
        # An empty block renders nothing: the node's zero value means "not configured".
        if block == None or len(block) == 0:
            out.append(None)
        else:
            out.append(block)
    return out

def render(block):
    """The YAML value for the top-level `Builders:` key, or "" for none. JSON is a YAML flow
    mapping, so json.encode yields valid YAML with the node's exact key names."""
    if block == None:
        return ""
    return json.encode(block)
