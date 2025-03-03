ethereum_package = import_module(
    "github.com/y0sher/ethereum-package/main.star"
)
genesis_constants = import_module(
    "github.com/ethpandaops/ethereum-package/src/prelaunch_data_generator/genesis_constants/genesis_constants.star"
)

blocks = import_module("./src/blockchain/blocks.star")
validator_keystores = import_module("./src/validators/validator_keystore_generator.star")

utils = import_module("./src/utils/utils.star")
deployer = import_module("./src/contract//deployer.star")
constants = import_module("./src/contract/constants.star")
# e2m = import_module("./src/e2m/e2m_launcher.star")
ssv = import_module("./src/ssv/ssv.star")

SSV_NODE_COUNT = 4


def run(plan, args):
    ethereum_network = ethereum_package.run(plan, args)
    cl_url, el_rpc_uri, el_ws_url = utils.get_eth_urls(ethereum_network.all_participants)
    cl_name, el_name = utils.get_eth_service_names(ethereum_network.all_participants)

    validator_data = validator_keystores.generate_validator_keystores(plan, args["network_params"]["preregistered_validator_keys_mnemonic"], 128, 8) # todo: calculate from network_params
    
    blocks.wait_until_node_reached_block(plan, el_name, 3)

    # e2m.launch_e2m(plan, cl_url)

    deployer.run(plan, el_rpc_uri, ethereum_network.blockscout_sc_verif_url, False, validator_data)

    ssv.start_cli(plan)

    operator_keys = []
    operator_configs = []
    for index in range(0, SSV_NODE_COUNT):
        keys = ssv.generate_operator_keys(plan)
        plan.print("keys")
        plan.print(keys)

        private_key = keys.private_key
        plan.print("private_key")
        plan.print(private_key)

        public_key = keys.public_key
        plan.print("public_key")
        plan.print(public_key)

        operator_configs.append(ssv.generate_config(plan, el_ws_url, cl_url, constants.SSV_NETWORK_CONTRACT, private_key))
        operator_keys.append(public_key)


    # deployer.verify_many(plan, constants.CONTRACTS)
    # deployer.verify(plan, "0x015B8C864D1B6e9BACd0DD666D77590cFd4188Cb")

    deployer.register_operators(plan, operator_keys, genesis_constants, constants.SSV_NETWORK_CONTRACT,
                                el_rpc_uri)
    
    deployer.register_validators(plan, genesis_constants, constants.SSV_TOKEN_CONTRACT,constants.SSV_NETWORK_CONTRACT,
                               el_rpc_uri)

