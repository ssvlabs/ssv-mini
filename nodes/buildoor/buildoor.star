# buildoor: an ePBS (Gloas, EIP-7732) builder run as an ssv-mini-owned service.
#
# Why not ethereum-package's own `mev_type: buildoor`: ssv-mini is pinned to ethereum-package
# 6.1.0, which carries only the FIRST buildoor integration, from before the launcher fixes on
# its main branch (#1422/#1470/#1480/#1483). Bumping the package moves every client default
# at once, so the builder is launched here instead, mirroring the launcher on main
# (src/mev/buildoor/buildoor_launcher.star) and buildoor's own .github/e2e/kurtosis.yaml.
#
# THE ONE TOPOLOGY RULE: buildoor must NEVER share a beacon node with the SSV operators.
# Since Lodestar v1.47 (ChainSafe/lodestar#9998) a beacon node does not add bids published
# through its own API to its own bid pool, and gossipsub never loops a self-published message
# back. So a proposer on the builder's beacon node is blind to the builder's p2p bids. buildoor
# therefore attaches to a SECOND participant (default pair 1 = cl-2/el-2), and the SSV nodes'
# beacon node (pair 0 = cl-1) receives the bids over gossip. validate() fails the run when any
# operator lists the builder's pair, as primary OR fallback.
#
# The builder is not registered at genesis (builder_count needs Gloas at genesis, and these
# profiles fork into Gloas at epoch 2). With --lifecycle, buildoor deposits its own builder
# from the wallet below after the fork, and the builder becomes active a few epochs later.

BUILDOOR_SERVICE_NAME = "buildoor"
BUILDOOR_API_PORT = 8080
BUILDOOR_API_PORT_NAME = "api"

# buildoor is work in progress and its `main` tag moves daily, so pin by digest.
# 2026-10-20: ethpandaops/buildoor:main built 2026-10-19T09:31Z from buildoor a5a6bfa.
DEFAULT_IMAGE = "ethpandaops/buildoor@sha256:ecdb2499e1d897a7fb1b0566c9515bf3041ede1b9c523f5636f596ef650313e5"

# ethereum-package 6.1.0's DEFAULT_MEV_SECRET_KEY (src/package_io/constants.star), without 0x.
# Its public key is DEFAULT_MEV_PUBKEY 0xa55c1285...0571cb5. Use it to pin BuilderPubKeys.
DEFAULT_BUILDER_PRIVKEY = "607a11b45a7219cc61a3d9c5fd08c7eebd602a6a19a977f8d3771d5711a550f2"
DEFAULT_BUILDER_PUBKEY = "0xa55c1285d84ba83a5ad26420cd5ad3091e49c55a813eee651cd467db38a8c8e63192f47955e9376f6b42f6d190571cb5"

# Index into ethereum-package's PRE_FUNDED_ACCOUNTS for the lifecycle wallet (deposits and
# top-ups). ssv-mini's contract deployer and validator registration use account 1; a shared
# account would race their nonces. Spamoor uses another index (see spamoor.star).
DEFAULT_WALLET_ACCOUNT = 13

# ethereum-package 6.1.0 uploads the EL JWT secret as the artifact "jwt_file" (main.star) and
# mounts it at /jwt/jwtsecret on every client. Re-use the same artifact and path.
JWT_ARTIFACT_NAME = "jwt_file"
JWT_MOUNTPOINT = "/jwt"
JWT_PATH = JWT_MOUNTPOINT + "/jwtsecret"

# Gwei added to every p2p bid so it clears the proposer's local payload. 1 ETH, far above the
# local value even with spamoor running at a fixed tip.
DEFAULT_EPBS_BID_SUBSIDY = 1000000000

def builder_api_url():
    """The URL buildoor advertises and serves its builder API on. Its hostname ("buildoor") is
    the default AuthData every SSV operator signs into BuilderRequestAuth, and buildoor checks
    it against --builder-api-url, so a Builders entry must name exactly this host."""
    return "http://{}:{}".format(BUILDOOR_SERVICE_NAME, BUILDOOR_API_PORT)

def get_args(args):
    """Return the validated `buildoor` params block, or None when disabled. Pure."""
    cfg = args.get("buildoor", None)
    if cfg == None:
        return None
    if type(cfg) != "dict":
        fail("buildoor must be a dict, got {}".format(type(cfg)))
    allowed = ["enabled", "image", "pair", "wallet_account", "epbs_bid_subsidy", "log_level", "extra_args"]
    for k in cfg.keys():
        if k not in allowed:
            fail("buildoor.{}: unknown key. Allowed: {}".format(k, ", ".join(allowed)))
    if not cfg.get("enabled", False):
        return None
    pair = cfg.get("pair", 1)
    if type(pair) != "int" or pair < 0:
        fail("buildoor.pair must be a non-negative integer pair index, got {}".format(pair))
    extra = cfg.get("extra_args", [])
    if type(extra) != "list":
        fail("buildoor.extra_args must be a list of strings, got {}".format(type(extra)))
    for a in extra:
        if type(a) != "string":
            fail("buildoor.extra_args entries must be strings, got {}".format(type(a)))
    return struct(
        image = cfg.get("image", DEFAULT_IMAGE),
        pair = pair,
        wallet_account = cfg.get("wallet_account", DEFAULT_WALLET_ACCOUNT),
        epbs_bid_subsidy = cfg.get("epbs_bid_subsidy", DEFAULT_EPBS_BID_SUBSIDY),
        log_level = cfg.get("log_level", "debug"),
        extra_args = extra,
    )

def _expanded_participants(network_args):
    """ethereum-package expands `count: N` into N participants in order. Mirror that, so a
    pair index maps to the params entry it came from."""
    out = []
    for p in network_args["participants"]:
        for _ in range(p.get("count", 1)):
            out.append(p)
    return out

def validate(bcfg, args):
    """Fail before any service starts if the builder would share a beacon node with an SSV
    operator, or if its beacon node does not emit payload attributes. Pure: reads only args, so
    it runs before ethereum-package starts and a bad topology never leaves a half-built enclave."""
    participants = _expanded_participants(args["network"])
    if bcfg.pair >= len(participants):
        fail("buildoor.pair = {} but the network has only {} participants (pairs 0-{}). ".format(
            bcfg.pair, len(participants), len(participants) - 1) +
             "Add a second participant for the builder (see params-gloas-builder.yaml).")

    # Pair indices an operator's beacon node may resolve to, primary or fallback. A blind-spot
    # proxy (topology.star) is pair len(participants)+i and forwards to its `upstream`, so an
    # operator on a proxy in front of the builder's pair shares that beacon node too.
    blindspots = args.get("blindspot_pairs", []) or []
    operator_count = args["nodes"]["anchor"]["count"] + args["nodes"]["ssv"]["count"]
    operator_pairs = args.get("operator_pairs", None)
    if operator_pairs == None:
        operator_pairs = [[0] for _ in range(operator_count)]
    for op in range(len(operator_pairs)):
        entry = operator_pairs[op]
        if type(entry) != "list":
            continue  # topology.resolve reports the shape error
        for idx in entry:
            real = idx
            if type(idx) == "int" and idx >= len(participants) and idx - len(participants) < len(blindspots):
                real = blindspots[idx - len(participants)].get("upstream", -1)
            if real == bcfg.pair:
                fail(("buildoor.pair = {} but operator {} uses that beacon node (operator_pairs[{}] = {}). " +
                      "Since Lodestar v1.47 a beacon node does not add bids published through its own " +
                      "API to its own bid pool, so that operator would never see buildoor's p2p bids. " +
                      "Give the builder a pair no operator uses, as primary or fallback.").format(
                    bcfg.pair, op, op, entry))

    p = participants[bcfg.pair]
    if p.get("cl_type", "") == "lodestar":
        if "--emitPayloadAttributes" not in p.get("cl_extra_params", []):
            fail(("buildoor.pair = {} is a Lodestar participant without --emitPayloadAttributes " +
                  "in cl_extra_params. buildoor builds on the payload_attributes SSE event, and " +
                  "Lodestar does not emit it by default.").format(bcfg.pair))
    else:
        fail(("buildoor.pair = {} runs cl_type {}. Only Lodestar is wired and tested here " +
              "(its payload-attributes flag is checked above); add the equivalent check for " +
              "another client before using it.").format(bcfg.pair, p.get("cl_type", "?")))

def start(plan, bcfg, all_participants, genesis_constants):
    """Start buildoor on participant `bcfg.pair`. Returns struct(url, service)."""
    p = all_participants[bcfg.pair]
    cl_url = "http://{}:{}".format(p.cl_context.beacon_service_name, p.cl_context.http_port)
    el_rpc = "http://{}:{}".format(p.el_context.service_name, p.el_context.rpc_port_num)
    el_engine = "http://{}:{}".format(p.el_context.service_name, p.el_context.engine_rpc_port_num)

    wallet_key = genesis_constants.PRE_FUNDED_ACCOUNTS[bcfg.wallet_account].private_key
    if wallet_key.startswith("0x"):
        wallet_key = wallet_key[2:]

    cmd = [
        "run",
        "--cl-client=" + cl_url,
        "--el-rpc=" + el_rpc,
        "--el-engine-api=" + el_engine,
        "--el-jwt-secret=" + JWT_PATH,
        "--wallet-privkey=" + wallet_key,
        "--builder-privkey=" + DEFAULT_BUILDER_PRIVKEY,
        "--api-port={}".format(BUILDOOR_API_PORT),
        "--builder-api-url=" + builder_api_url(),
        "--extra-data=" + BUILDOOR_SERVICE_NAME,
        "--epbs-enabled",
        "--builder-api-enabled",
        # Deposit the builder after the Gloas fork and keep it topped up.
        "--lifecycle",
        # No cap on the builder deposit queue fee: a delayed deposit only delays activation.
        "--deposit-max-fee=0",
        "--epbs-bid-subsidy={}".format(bcfg.epbs_bid_subsidy),
        "--log-level=" + bcfg.log_level,
    ] + bcfg.extra_args

    plan.print("buildoor -> pair {} ({} / {}), builder API {}".format(
        bcfg.pair, p.cl_context.beacon_service_name, p.el_context.service_name, builder_api_url()))

    svc = plan.add_service(
        name = BUILDOOR_SERVICE_NAME,
        description = "Starting buildoor (ePBS builder) on {}".format(p.cl_context.beacon_service_name),
        config = ServiceConfig(
            image = bcfg.image,
            cmd = cmd,
            ports = {
                BUILDOOR_API_PORT_NAME: PortSpec(
                    number = BUILDOOR_API_PORT,
                    transport_protocol = "TCP",
                    application_protocol = "http",
                ),
            },
            files = {
                JWT_MOUNTPOINT: JWT_ARTIFACT_NAME,
            },
        ),
    )
    return struct(url = builder_api_url(), service = svc)
