SSV_TOKEN_CONTRACT = "0x6db20C530b3F96CD5ef64Da2b1b931Cb8f264009"
SSV_OPERATORS_CONTRACT = "0x6f00cAa972723C5e1D1012cdAc385753c2AA3a93"
SSV_CLUSTERS_CONTRACT = "0xDeC3326BE4BaDb9A1fA7Be473Ef8370dA775889a"
SSV_NETWORK_CONTRACT = "0x015B8C864D1B6e9BACd0DD666D77590cFd4188Cb"
SSV_NETWORK_PROXY_CONTRACT = "0xBFfF570853d97636b78ebf262af953308924D3D8"

OWNER_ADDRESS ="0xe25583099ba105d9ec0a67f5ae86d90e50036425"

# The aetheria local_testnet seed: indices [SSV_SEED_START_INDEX, SSV_SEED_START_INDEX +
# SSV_MANAGED_VALIDATOR_COUNT) are deposited-but-VC-idle validators the SSV operators adopt. These
# MIRROR values pinned in static/keyshares/out.json and the external aetheria seed
# (ssvlabs/aetheria .../insert_test_data.sql); scripts/generate-static-keys.sh derives the keyshares
# from them. Not free knobs - changing them requires regenerating the static keyshares AND updating the
# aetheria seed to match. main.star's validator-layout guard reads them.
SSV_SEED_START_INDEX = 64         # first deposited-but-VC-idle validator index; VCs must stay in [0, this)
SSV_MANAGED_VALIDATOR_COUNT = 10  # SSV-adopted validators, indices [64, 74)

ANCHOR_KEYSPLIT_SERVICE = "anchor-keysplit"
ANCHOR_CLI_SERVICE_NAME = "anchor"

DEPLOYER_SERVICE_NAME = "deployer"  # kurtosis service running the contract deployer
REGISTER_VALIDATOR_SERVICE_NAME = "register-validator"  # kurtosis service running validator pre-registration
