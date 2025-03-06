SSV_TOKEN_CONTRACT = "0x6db20C530b3F96CD5ef64Da2b1b931Cb8f264009"
SSV_OPERATORS_CONTRACT = "0x6f00cAa972723C5e1D1012cdAc385753c2AA3a93"
SSV_CLUSTERS_CONTRACT = "0xDeC3326BE4BaDb9A1fA7Be473Ef8370dA775889a"
SSV_NETWORK_CONTRACT = "0x015B8C864D1B6e9BACd0DD666D77590cFd4188Cb"
SSV_NETWORK_PROXY_CONTRACT = "0xBFfF570853d97636b78ebf262af953308924D3D8"

# SSV_NODE_COUNT + ANCHOR_NODE_COUNT must be valid committee size
SSV_NODE_COUNT = 2
ANCHOR_NODE_COUNT = 2

VALIDATORS = 16

OWNER_ADDRESS ="0xe25583099ba105d9ec0a67f5ae86d90e50036425"

VALIDATOR_KEYSTORE_SERVICE = "validator-key-generation-cl-validator-keystore"

ANCHOR_KEYSPLIT_SERVICE = "anchor-keysplit"
ANCHOR_CLI_SERVICE_NAME = "anchor"
ANCHOR_IMAGE = ImageBuildSpec(
    image_name="localssv/anchor-unstable",
    build_context_dir="../images",
    build_file="Anchor.docker"
)

FOUNDRY_SERVICE_NAME = "foundry"
FOUNDRY_IMAGE = ImageBuildSpec(
    image_name="localssv/ssv-network",
    build_context_dir="./",
    build_file="Dockerfile.contract",
)





