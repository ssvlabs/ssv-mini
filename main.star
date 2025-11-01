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
deposit_bot = import_module("./deposit/deposit_bot.star")

def run(plan, args):
    plan.print("validating input")
    ssv_node_count = args["nodes"]["ssv"]["count"]
    anchor_node_count = args["nodes"]["anchor"]["count"]

    # Retrieve all Docker images at the start
    ssv_image = utils.get_ssv_image(args)
    anchor_image = utils.get_anchor_image(args)
    monitor_image = utils.get_monitor_image(args)
    postgres_image = utils.get_postgres_image(args)
    redis_image = utils.get_redis_image(args)
    foundry_image_spec = utils.get_foundry_image_spec(args)

    plan.print("validating configurations...")
    if not cluster.is_valid_cluster_size(ssv_node_count + anchor_node_count):
        fail("invalid cluster size: ", str(ssv_node_count + anchor_node_count))

    if ssv_node_count == 0 and args["observability"]["monitor"]["enabled"]:
        fail("SSV Node count is equal to '0'. Monitor must not be enabled")

    plan.print("launching blockchain network")
    network_args = args["network"]
    ethereum_network = ethereum_package.run(plan, network_args)
    
    plan.print("network launched. Network output: " + json.indent(json.encode(ethereum_network)))

    plan.print("blockchain network is running. Waiting for it to be ready")

    cl_service_name, cl_url, el_service_name, el_rpc, el_ws = utils.get_network_attributes(ethereum_network.all_participants[0])

    blocks.wait_until_node_reached_block(plan, el_service_name, 1)

    plan.print("deploying SSV smart contracts")
    deployer.deploy(plan, el_rpc, genesis_constants, foundry_image_spec)

    non_ssv_validators = 0
    for p in network_args["participants"]:
        non_ssv_validators += p["validator_count"] * p["count"]

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
    operator_keygen.start_cli(plan, keystore_files, args)
    
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
        el_rpc,
        args
    )

    plan.print("registering network validators")
    # Register validators on the network
    interactions.register_validators(
        plan,
        keyshare_artifact,
        constants.SSV_NETWORK_PROXY_CONTRACT, 
        constants.SSV_TOKEN_CONTRACT,
        el_rpc,
        genesis_constants,
        args
    )

    node_index = 0
    enr = ""

    if anchor_node_count > 0:
        plan.print("deploying Anchor nodes. Node count: " + str(anchor_node_count))

        # start up all of the anchor nodes
        config = utils.anchor_testnet_artifact(plan)
        enr = anchor_node.start(plan, anchor_node_count, cl_url, el_rpc, el_ws, pem_artifacts, config, anchor_image)

    node_index += anchor_node_count

    plan.print("deploying SSV nodes. Node count: " + str(ssv_node_count))
   
    # NOTE: When more than one cluster is deployed, Monitor requires this URL to point to an SSV Node running in Exporter mode.
    ssv_node_api_url = None

    if ssv_node_count > 0:
        # SSV Node requires a 'mature' Execution Layer (EL) client for the Event Syncer component to function properly. 
        # Otherwise, it may crash and require a restart, hence some reasonable delay needs to be introduced.
        blocks.wait_until_node_reached_block(plan, el_service_name, 16)

    eth_node_indices = None
    if "eth_node_indices" in args["nodes"]["ssv"]:
        eth_node_indices = args["nodes"]["ssv"]["eth_node_indices"]
    else:
        eth_node_indices = [0] * ssv_node_count

    # Start up the ssv nodes
    for i in range(0, ssv_node_count):
        cl_i_service_name, cl_i_url, el_i_service_name, el_i_rpc, el_i_ws = utils.get_network_attributes(
            ethereum_network.all_participants[eth_node_indices[i]])

        is_exporter = False
        config = ssv_node.generate_config(plan, node_index, cl_i_url, el_i_ws, private_keys[node_index], enr, is_exporter)
        plan.print("generated SSV node config artifact: " + json.indent(json.encode(config)))

        plan.print("starting SSV node with index: " + str(node_index))
        node_service = ssv_node.start(plan, node_index, config, is_exporter, ssv_image)

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
        monitor.start(plan, ssv_node_api_url, cl_url, monitor_image, postgres_image, redis_image)

    # Optional: deposit submitter to help trigger EIP-6110 behavior
    if "deposits" in args and args["deposits"].get("enabled", False):
        wait_for_block = int(args["deposits"].get("wait_for_block", 0))
        plan.print("waiting for block {} to start deposit generator".format(wait_for_block))
        blocks.wait_until_node_reached_block(plan, el_service_name, wait_for_block)

        start_index = int(args["deposits"].get("start_index", 0))
        count = int(args["deposits"].get("count", 1))
        interval = int(args["deposits"].get("interval_seconds", 1))
        plan.print("starting generating and submitting deposits every {} second(s) from index {}, total amount {}"
                   .format(interval, start_index, count))

        # Use EL RPC of participant 0 by default for casting
        net_params = args["network"]["network_params"]
        # 0x00000000219ab540356cBB839Cbe05303d7705Fa is the mainnet/default DEPOSIT_CONTRACT_ADDRESS
        # https://ethereum.github.io/consensus-specs/specs/phase0/deposit-contract/#configuration
        deposit_address = net_params.get("deposit_contract_address", "0x00000000219ab540356cBB839Cbe05303d7705Fa")
        plan.print("generating deposit-data with eth2-val-tools")
        fork_version = "0x10000038"  # must be same with GENESIS_FORK_VERSION in nodes/anchor/config/config.yaml
        deposits_json_artifact = deposit_bot.generate_deposits_with_eth2_val_tools(
            plan,
            eth_args.network_params.preregistered_validator_keys_mnemonic,
            start_index,
            count,
            fork_version,
            constants.OWNER_ADDRESS,
        )
        deposit_bot.start_deposit_bot(
            plan,
            el_rpc,
            deposit_address,
            genesis_constants.PRE_FUNDED_ACCOUNTS[1].private_key,
            count=count,
            interval_seconds=interval,
            deposits_json_artifact=deposits_json_artifact,
        )
