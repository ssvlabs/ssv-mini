# spamoor: steady EOA transfers at a FIXED priority fee, so every local (self-built) payload
# has a known, non-zero value. Without it the testnet's blocks are empty, the local payload is
# worth 0, and any builder bid wins trivially, which hides bugs in bid-versus-local valuation.
#
# Expected local value per block ~= throughput * 21000 gas * tipfee (all txs fit in one block).
# Defaults: 10 * 21000 * 2 gwei = 420,000 gwei (0.00042 ETH). A p2p bid must clear this.

SPAMOOR_SERVICE_NAME = "spamoor"

# 2026-10-20: ethpandaops/spamoor:latest, built 2026-09-12.
DEFAULT_IMAGE = "ethpandaops/spamoor@sha256:c8c6ab0816c42335b0b3b843652c3a330c71ffdf7a5cde6d5cf8536958306e1f"

# PRE_FUNDED_ACCOUNTS index. Not 1 (ssv-mini's deployer) and not buildoor's wallet (13).
DEFAULT_WALLET_ACCOUNT = 14

def get_args(args):
    cfg = args.get("spamoor", None)
    if cfg == None:
        return None
    if type(cfg) != "dict":
        fail("spamoor must be a dict, got {}".format(type(cfg)))
    allowed = ["enabled", "image", "pair", "wallet_account", "throughput", "tipfee_gwei", "basefee_gwei"]
    for k in cfg.keys():
        if k not in allowed:
            fail("spamoor.{}: unknown key. Allowed: {}".format(k, ", ".join(allowed)))
    if not cfg.get("enabled", False):
        return None
    for k in ["throughput", "tipfee_gwei", "basefee_gwei"]:
        v = cfg.get(k, 1)
        if type(v) != "int" or v <= 0:
            fail("spamoor.{} must be a positive integer, got {}".format(k, v))
    return struct(
        image = cfg.get("image", DEFAULT_IMAGE),
        pair = cfg.get("pair", 0),
        wallet_account = cfg.get("wallet_account", DEFAULT_WALLET_ACCOUNT),
        throughput = cfg.get("throughput", 10),
        tipfee_gwei = cfg.get("tipfee_gwei", 2),
        basefee_gwei = cfg.get("basefee_gwei", 20),
    )

def start(plan, scfg, all_participants, genesis_constants):
    p = all_participants[scfg.pair]
    el_rpc = "http://{}:{}".format(p.el_context.service_name, p.el_context.rpc_port_num)
    key = genesis_constants.PRE_FUNDED_ACCOUNTS[scfg.wallet_account].private_key
    plan.print("spamoor -> {}: {} tx/slot at tip {} gwei (~{} gwei local value per block)".format(
        el_rpc, scfg.throughput, scfg.tipfee_gwei, scfg.throughput * 21000 * scfg.tipfee_gwei))
    return plan.add_service(
        name = SPAMOOR_SERVICE_NAME,
        description = "Starting spamoor (fixed-tip EOA transfers)",
        config = ServiceConfig(
            image = scfg.image,
            cmd = [
                "eoatx",
                "--privkey=" + key,
                "--rpchost=" + el_rpc,
                "--throughput={}".format(scfg.throughput),
                "--tipfee={}".format(scfg.tipfee_gwei),
                "--basefee={}".format(scfg.basefee_gwei),
                "--max-pending={}".format(scfg.throughput * 2),
            ],
        ),
    )
