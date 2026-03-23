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
    ssv_node_count = args["nodes"]["ssv"]["count"]
    anchor_node_count = args["nodes"]["anchor"]["count"]

    ssv_image = utils.get_ssv_image(args)
    anchor_image = utils.get_anchor_image(args)
    monitor_image = utils.get_monitor_image(args)
    postgres_image = utils.get_postgres_image(args)
    redis_image = utils.get_redis_image(args)
    foundry_image_spec = utils.get_foundry_image_spec(args)

    if not cluster.is_valid_cluster_size(ssv_node_count + anchor_node_count):
        fail("invalid cluster size: ", str(ssv_node_count + anchor_node_count))

    if ssv_node_count == 0 and args["monitor"]["enabled"]:
        fail("SSV Node count is equal to '0'. Monitor must not be enabled")

    # ── Step 1: Launch Ethereum network ──
    plan.print("Step 1/5: Launching Ethereum network (EL + CL + validators)")
    network_args = args["network"]
    ethereum_network = ethereum_package.run(plan, network_args)

    cl_service_name, cl_url, el_service_name, el_rpc, el_ws = utils.get_network_attributes(ethereum_network.all_participants)

    blocks.wait_until_node_reached_block(plan, el_service_name, 1)

    # ── Step 2: Deploy SSV smart contracts ──
    plan.print("Step 2/5: Deploying SSV smart contracts")
    deployer.deploy(plan, el_rpc, genesis_constants, foundry_image_spec)

    # ── Step 3: Prepare operator keys and keyshares ──
    use_static_keys = args.get("use_static_keys", True)
    number_of_keys = ssv_node_count + anchor_node_count

    if use_static_keys:
        plan.print("Step 3/5: Loading pre-computed static keys and keyshares")
        public_keys = []
        private_keys = []
        pem_artifacts = []
        for i in range(number_of_keys):
            public_keys.append(read_file("./static/keys/operator-{}/public_key.txt".format(i)).strip())
            private_keys.append(read_file("./static/keys/operator-{}/unencrypted_private_key.txt".format(i)).strip())
            pem_artifacts.append(plan.upload_files(
                "./static/keys/operator-{}/unencrypted_private_key.txt".format(i),
                name="key-{}".format(i),
                description="Uploading static operator key {}".format(i),
            ))

        interactions.register_operators(plan, public_keys, constants.SSV_NETWORK_PROXY_CONTRACT)
        plan.remove_service(constants.FOUNDRY_SERVICE_NAME, description="Cleaning up contract deployer")

        keyshare_artifact = plan.upload_files(
            "./static/keyshares/out.json",
            name="keyshares.json",
            description="Uploading pre-computed keyshares",
        )
    else:
        plan.print("Step 3/5: Generating operator keys and keyshares (dynamic mode)")
        non_ssv_validators = network_args["participants"][0]["validator_count"] * network_args["participants"][0]["count"]
        total_validators = network_args["network_params"]["preregistered_validator_count"]

        eth_args = input_parser.input_parser(plan, network_args)

        keystore_files = validator_keygen.generate_validator_keystores(
            plan,
            eth_args.network_params.preregistered_validator_keys_mnemonic,
            non_ssv_validators,
            total_validators - non_ssv_validators
        )
        plan.remove_service(validator_keygen.SERVICE_NAME, description="Cleaning up validator keystore generator")

        operator_keygen.start_cli(plan, keystore_files, args)

        public_keys, private_keys, pem_artifacts = operator_keygen.generate_keys(plan, number_of_keys)
        plan.remove_service(constants.ANCHOR_CLI_SERVICE_NAME, description="Cleaning up operator key generator")

        operator_data_artifact = interactions.register_operators(plan, public_keys, constants.SSV_NETWORK_PROXY_CONTRACT)
        plan.remove_service(constants.FOUNDRY_SERVICE_NAME, description="Cleaning up contract deployer")

        keyshare_artifact = keysplit.split_keys(
            plan,
            keystore_files,
            operator_data_artifact,
            constants.SSV_NETWORK_PROXY_CONTRACT,
            constants.OWNER_ADDRESS,
            el_rpc,
            args
        )
        plan.remove_service(constants.ANCHOR_KEYSPLIT_SERVICE, description="Cleaning up keysplit service")

    # ── Step 4: Register validators on-chain ──
    plan.print("Step 4/5: Registering validators on-chain")
    interactions.register_validators(
        plan,
        keyshare_artifact,
        constants.SSV_NETWORK_PROXY_CONTRACT,
        constants.SSV_TOKEN_CONTRACT,
        el_rpc,
        genesis_constants,
        args
    )
    plan.remove_service("register-validator", description="Cleaning up validator registrar")

    # ── Step 5: Start SSV and Anchor nodes ──
    node_index = 0
    enr = ""

    if anchor_node_count > 0:
        plan.print("Step 5/5: Starting {} Anchor + {} SSV nodes".format(anchor_node_count, ssv_node_count))
        config = utils.anchor_testnet_artifact(plan, args)
        enr = anchor_node.start(plan, anchor_node_count, cl_url, el_rpc, el_ws, pem_artifacts, config, anchor_image)
    else:
        plan.print("Step 5/5: Starting {} SSV nodes".format(ssv_node_count))

    node_index += anchor_node_count

    ssv_node_api_url = None

    if ssv_node_count > 0:
        blocks.wait_until_node_reached_block(plan, el_service_name, 16)

        ssv_configs = {}
        for _ in range(0, ssv_node_count):
            is_exporter = False
            config = ssv_node.generate_config(plan, node_index, cl_url, el_ws, private_keys[node_index], enr, is_exporter, args)
            service_name = "ssv-node-{}".format(node_index)
            ssv_configs[service_name] = ssv_node.get_service_config(node_index, config, is_exporter, ssv_image)
            node_index += 1

        ssv_services = plan.add_services(
            ssv_configs,
            description="Starting {} SSV nodes in parallel".format(ssv_node_count),
        )

        first_ssv_name = "ssv-node-{}".format(node_index - ssv_node_count)
        ssv_node_api_url = ssv_services[first_ssv_name].ports[ssv_node.SSV_API_PORT_NAME].url

    monitor_enabled = args["monitor"]["enabled"]
    if monitor_enabled:
        if ssv_node_count == 0:
            return

        plan.print("Launching monitor stack")
        monitor.start(plan, ssv_node_api_url, cl_url, monitor_image, postgres_image, redis_image)
