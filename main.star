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

    cl1_service_name, cl1_url, el1_service_name, el1_rpc, el1_ws = utils.get_network_attributes(ethereum_network.all_participants[0])
    cl2_service_name, cl2_url, el2_service_name, el2_rpc, el2_ws = utils.get_network_attributes(ethereum_network.all_participants[1])
    cl3_service_name, cl3_url, el3_service_name, el3_rpc, el3_ws = utils.get_network_attributes(ethereum_network.all_participants[2])
    cl8_service_name, cl8_url, el8_service_name, el8_rpc, el8_ws = utils.get_network_attributes(ethereum_network.all_participants[7])

    blocks.wait_until_node_reached_block(plan, el1_service_name, 1)

    plan.print("deploying SSV smart contracts")
    deployer.deploy(plan, el1_rpc, genesis_constants)

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
        el1_rpc
    )

    plan.print("registering network validators")
    # Register validators on the network
    interactions.register_validators(
        plan,
        keyshare_artifact,
        constants.SSV_NETWORK_PROXY_CONTRACT, 
        constants.SSV_TOKEN_CONTRACT,
        el1_rpc,
        genesis_constants
    )

    node_index = 0
    enr = ""

    if anchor_node_count > 0:
        plan.print("deploying Anchor nodes. Node count: " + str(anchor_node_count))

        # start up all of the anchor nodes
        config = utils.anchor_testnet_artifact(plan)
        enr = anchor_node.start(plan, anchor_node_count, cl1_url, el1_rpc, el1_ws, pem_artifacts, config)

    node_index += anchor_node_count

    plan.print("deploying SSV nodes. Node count: " + str(ssv_node_count))
   
    # NOTE: When more than one cluster is deployed, Monitor requires this URL to point to an SSV Node running in Exporter mode.
    ssv_node_api_url = None

    if ssv_node_count > 0:
        # SSV Node requires a 'mature' Execution Layer (EL) client for the Event Syncer component to function properly. 
        # Otherwise, it may crash and require a restart, hence some reasonable delay needs to be introduced.
        blocks.wait_until_node_reached_block(plan, el1_service_name, 16)

    cl_urls = [cl1_url, cl2_url, cl3_url, cl8_url]
    el_urls = [el1_ws, el2_ws, el3_ws, el8_ws]

    # Start up the ssv nodes
    for i in range(0, ssv_node_count):
        is_exporter = False
        config = ssv_node.generate_config(plan, node_index, cl_urls[i], el_urls[i], private_keys[node_index], enr, is_exporter)
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

        plan.print("launching monitor. SSV node API URL: {}. CL URL: {}".format(ssv_node_api_url, cl1_url))
        monitor.start(plan, ssv_node_api_url, cl1_url)

    # Optional: deposit submitter to help trigger EIP-6110 behavior
    if "deposits" in args and args["deposits"].get("enabled", False):
        wait_for_block = int(args["deposits"].get("wait_for_block", 40))
        plan.print("waiting for block 40 to start deposit generator")
        blocks.wait_until_node_reached_block(plan, el1_service_name, wait_for_block)

        plan.print("starting deposit generator and submitter")
        start_index = int(args["deposits"].get("start_index", 0))
        count = int(args["deposits"].get("count", 1))
        interval = int(args["deposits"].get("interval_seconds", 3))
        # Use EL RPC of participant 0 by default for casting
        net_params = args["network"]["network_params"]
        deposit_address = net_params.get("deposit_contract_address", "0x00000000219ab540356cBB839Cbe05303d7705Fa")
        deposits_json_artifact = None
        if "json_path" in args["deposits"]:
            deposits_json_artifact = plan.upload_files(str(args["deposits"]["json_path"]))
        else:
            plan.print("no deposits.json provided; generating deposit-data with eth2-val-tools")
            fork_version = "0x10000038"  # aligns with config.yaml in our generated testnet
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
            el1_rpc,
            deposit_address,
            genesis_constants.PRE_FUNDED_ACCOUNTS[1].private_key,
            count=count,
            interval_seconds=interval,
            deposits_json_artifact=deposits_json_artifact,
        )
