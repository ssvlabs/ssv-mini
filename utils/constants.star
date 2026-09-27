# The image pins and chain constants shared with the Makefile and the shell scripts live in ../constants.env,
# the single source of truth; this module parses it and re-exports the values for the Starlark side.
def _read_env(path):
    values = {}
    for raw in read_file(path).splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep or not key:
            fail("{}: malformed line, want KEY=value: {}".format(path, raw))
        if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        values[key] = value
    return values

_ENV = _read_env("../constants.env")

def _require(key):
    if key not in _ENV:
        fail("constants.env has no {} entry".format(key))
    return _ENV[key]

SSV_TOKEN_CONTRACT = _require("SSV_TOKEN_CONTRACT")
SSV_OPERATORS_CONTRACT = _require("SSV_OPERATORS_CONTRACT")
SSV_CLUSTERS_CONTRACT = _require("SSV_CLUSTERS_CONTRACT")
SSV_NETWORK_CONTRACT = _require("SSV_NETWORK_CONTRACT")
SSV_NETWORK_PROXY_CONTRACT = _require("SSV_NETWORK_PROXY_CONTRACT")

OWNER_ADDRESS = _require("OWNER_ADDRESS")
MNEMONIC = _require("MNEMONIC")

# Defaults for a params file's images: block (utils.get_image).
IMAGES = {
    "ssv": _require("SSV_IMAGE"),
    "anchor": _require("ANCHOR_IMAGE"),
    "monitor": _require("MONITOR_IMAGE"),
    "redis": _require("REDIS_IMAGE"),
    "postgres": _require("POSTGRES_IMAGE"),
    "deployer": _require("DEPLOYER_IMAGE"),
}

# Participant images by client type, filled in when a params file leaves el_image / cl_image unset
# (utils.apply_network_defaults).
DEFAULT_EL_IMAGES = {"geth": _require("GETH_IMAGE")}
DEFAULT_CL_IMAGES = {"lighthouse": _require("LIGHTHOUSE_IMAGE")}

ETH2_VAL_TOOLS_IMAGE = _require("ETH2_VAL_TOOLS_IMAGE")

# The aetheria local_testnet seed: indices [SSV_SEED_START_INDEX, SSV_SEED_START_INDEX +
# SSV_MANAGED_VALIDATOR_COUNT) are deposited-but-VC-idle validators the SSV operators adopt. These MIRROR
# static/keyshares/out.json and the external aetheria seed (ssvlabs/aetheria .../insert_test_data.sql).
# SSV_MANAGED_VALIDATOR_COUNT is set by scripts/generate-static-keys.sh (Step 4) from SSV_VALIDATOR_COUNT
# when the keyshares are (re)generated — to scale the pool, run that script with SSV_VALIDATOR_COUNT=N and
# regenerate the aetheria seed to the same N. main.star's validator-layout guard reads these.
SSV_SEED_START_INDEX = 64         # first deposited-but-VC-idle validator index; VCs must stay in [0, this)
SSV_MANAGED_VALIDATOR_COUNT = 10  # SSV-adopted validators, indices [64, 64 + this); set by generate-static-keys.sh

# Default boole_epoch when a params file leaves it unset — a far-future epoch that keeps the SSV Boole
# fork dormant for any real run, shared by the SSV (node.star) and Anchor (utils.star) config renderers
# so the two can't drift. Deliberately not a large "disabled" sentinel like MaxUint64 or the old 1<<63:
# a Boole-aware node's Network.Validate() FATALs on a scheduled boole epoch above the epoch->slot
# overflow cap (~5.76e17 = MaxUint64 / SlotsPerEpoch), only the exact MaxUint64 counts as unscheduled,
# and the config pipeline float-rounds large ints anyway. 1e9 clears the cap and is float-exact.
# See ssvlabs/ssv-mini#49.
BOOLE_DORMANT_EPOCH = 1000000000

ANCHOR_KEYSPLIT_SERVICE = "anchor-keysplit"
ANCHOR_CLI_SERVICE_NAME = "anchor"

DEPLOYER_SERVICE_NAME = "deployer"  # kurtosis service running the contract deployer
REGISTER_VALIDATOR_SERVICE_NAME = "register-validator"  # kurtosis service running validator pre-registration
