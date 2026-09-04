SSV_TOKEN_CONTRACT = "0x6db20C530b3F96CD5ef64Da2b1b931Cb8f264009"
SSV_OPERATORS_CONTRACT = "0x6f00cAa972723C5e1D1012cdAc385753c2AA3a93"
SSV_CLUSTERS_CONTRACT = "0xDeC3326BE4BaDb9A1fA7Be473Ef8370dA775889a"
SSV_NETWORK_CONTRACT = "0x015B8C864D1B6e9BACd0DD666D77590cFd4188Cb"
SSV_NETWORK_PROXY_CONTRACT = "0xBFfF570853d97636b78ebf262af953308924D3D8"

OWNER_ADDRESS ="0xe25583099ba105d9ec0a67f5ae86d90e50036425"

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
