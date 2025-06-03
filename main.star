ethereum_package = import_module("github.com/ethpandaops/ethereum-package/main.star")
input_parser = import_module("github.com/ethpandaops/ethereum-package/src/package_io/input_parser.star")
genesis_constants = import_module("github.com/ethpandaops/ethereum-package/src/prelaunch_data_generator/genesis_constants/genesis_constants.star")
ssv_node = import_module("./nodes/ssv/node.star")
anchor_node = import_module("./nodes/anchor/node.star")
blocks = import_module("./blockchain/blocks.star")
utils = import_module("./utils/utils.star")
deployer = import_module("./contract/deployer.star")
interactions = import_module("./contract/interactions.star")
operator_keygen = import_module("./generators/operator-keygen.star")
validator_keygen = import_module("./generators/validator-keygen.star")
keysplit = import_module("./generators/keysplit.star")
constants = import_module("./utils/constants.star")
monitor = import_module("./monitor/monitor.star")
cluster = import_module("./nodes/cluster.star")

def run(plan, args):
    plan.print("validating input")
    ssv_node_count = args["nodes"]["ssv"]["count"]
    anchor_node_count = args["nodes"]["anchor"]["count"]

    if not cluster.is_valid_cluster_size(ssv_node_count + anchor_node_count):
        fail("invalid cluster size: ", str(ssv_node_count + anchor_node_count))

    plan.print("launching blockchain network")
    network_args = args["network"]
    ethereum_network = ethereum_package.run(plan, network_args)

    plan.print("blockchain network is running. Waiting for it to be ready")
    cl_url, el_rpc, el_ws = utils.get_eth_urls(ethereum_network.all_participants)
    blocks.wait_until_node_reached_block(plan, "el-1-geth-lighthouse", 1)

    plan.print("deploying SSV smart contracts")
    deployer.deploy(plan, el_rpc, genesis_constants)

    non_ssv_validators = network_args["participants"][0]["validator_count"] * network_args["participants"][0]["count"]
    total_validators = network_args["network_params"]["preregistered_validator_count"]
    
    eth_args = input_parser.input_parser(plan, network_args)
    
    # Generate new keystore files
    keystore_files = validator_keygen.generate_validator_keystores(
        plan, 
        eth_args.network_params.preregistered_validator_keys_mnemonic, 
        non_ssv_validators, 
        total_validators - non_ssv_validators
    )

    # Generate public/private keypair for every operator we are going to deploy
    operator_keygen.start_cli(plan, keystore_files)
    
    number_of_keys = ssv_node_count + anchor_node_count
    
    plan.print("generating operator keys. Number of keys: " + str(number_of_keys))
    public_keys, private_keys, pem_artifacts = operator_keygen.generate_keys(plan, number_of_keys)

    # Once we have all of the keys, register each operator with the network
    operator_data_artifact = interactions.register_operators(plan, public_keys, constants.SSV_NETWORK_PROXY_CONTRACT)

    # Split the ssv validator keys into into keyshares
    keyshare_artifact = keysplit.split_keys(
        plan, 
        keystore_files, 
        operator_data_artifact,
        constants.SSV_NETWORK_PROXY_CONTRACT, 
        constants.OWNER_ADDRESS,
        el_rpc
    )

    plan.print("registering network validators")
    # Register validators on the network
    interactions.register_validators(
        plan,
        keyshare_artifact,
        constants.SSV_NETWORK_PROXY_CONTRACT, 
        constants.SSV_TOKEN_CONTRACT,
        el_rpc,
        genesis_constants
    )

    node_index = 0
    enr = ""

    if anchor_node_count > 0:
        plan.print("deploying Anchor nodes. Node count: " + str(anchor_node_count))

        # start up all of the anchor nodes
        config = utils.anchor_testnet_artifact(plan)
        enr = anchor_node.start(plan, anchor_node_count, cl_url, el_rpc, el_ws, pem_artifacts, config)

    node_index += anchor_node_count

    plan.print("deploying SSV nodes. Node count: " + str(ssv_node_count))
   
    # NOTE: When more than one cluster is deployed, Monitor requires this URL to point to an SSV Node running in Exporter mode.
    ssv_node_api_url = None

    # Start up the ssv nodes
    for _ in range(0, ssv_node_count):
        is_exporter = False
        config = ssv_node.generate_config(plan, node_index, cl_url, el_ws, private_keys[node_index], enr, is_exporter)
        plan.print("generated SSV node config artifact: " + json.indent(json.encode(config)))

        plan.print("starting SSV node with index: " + str(node_index))
        node_service = ssv_node.start(plan, node_index, config, is_exporter)

        plan.print("ssv node started. Service name: " + node_service.name)

        if ssv_node_api_url == None:
            ssv_node_api_url = node_service.ports[ssv_node.SSV_API_PORT_NAME].url

        node_index += 1

    monitor_enabled = args["monitor"]["enabled"]
    if monitor_enabled:
        if ssv_node_count == 0:
            plan.print("no SSV nodes deployed. Skipping monitor deployment")
            return

        plan.print("launching monitor. SSV node API URL: {}. CL URL: {}".format(ssv_node_api_url, cl_url))
        monitor.start(plan, ssv_node_api_url, cl_url)
