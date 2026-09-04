ethereum_package = import_module("github.com/ethpandaops/ethereum-package/main.star@6.1.0")
input_parser = import_module("github.com/ethpandaops/ethereum-package/src/package_io/input_parser.star@6.1.0")
genesis_constants = import_module("github.com/ethpandaops/ethereum-package/src/prelaunch_data_generator/genesis_constants/genesis_constants.star@6.1.0")
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
    deployer_image_spec = utils.get_deployer_image_spec(args)

    if not cluster.is_valid_cluster_size(ssv_node_count + anchor_node_count):
        fail("invalid cluster size: " + str(ssv_node_count + anchor_node_count) + ". Valid sizes: 4, 7, 10, 13 (3f+1 for BFT). Edit nodes.ssv.count in params.yaml.")

    if ssv_node_count == 0 and args["monitor"]["enabled"]:
        fail("SSV Node count is equal to '0'. Monitor must not be enabled")

    # ── Step 1: Launch Ethereum network ──
    plan.print("Step 1/5: Launching Ethereum network (EL + CL + validators)")
    network_args = args["network"]

    # Guard the aetheria local_testnet seed layout: it adopts deposited-but-VC-idle validators at
    # indices 64-73 (ssvlabs/aetheria orchestrator/script/insert_test_data.sql). VCs run
    # [0, total validator_count*count over all participants); genesis deposits [0, preregistered_validator_count).
    # If VC coverage reaches 64 the SSV operators would run VC-active validators -> double-sign -> slashing.
    # Sum over ALL participant groups (not just [0]): validators are assigned sequentially, so adding a
    # second group (e.g. EL/CL diversity) would extend coverage and could silently reach index 64. Fail on
    # drift by default; unsafe_skip_validator_layout_guard opts out for a standalone liveness probe (below).
    vc_validators = 0
    for p in network_args["participants"]:
        vc_validators += p["validator_count"] * p["count"]
    deposited_validators = network_args["network_params"]["preregistered_validator_count"]
    # Universal invariant (both paths): genesis must deposit at least as many validators as the VCs run,
    # else a validator client would run undeposited keys.
    if deposited_validators < vc_validators:
        fail("preregistered_validator_count ({}) must be >= total VC validators ({}) - otherwise validator clients run undeposited keys.".format(deposited_validators, vc_validators))
    # unsafe_skip_validator_layout_guard opts out of the strict 64/74 guard for a STANDALONE base-chain
    # liveness probe (ssvlabs/ssv-mini#38): a bare `kurtosis run` with pre_register_validators: false and
    # NO aetheria executor leaves the SSV nodes adopting zero beacon validators (Step 4 skipped; keyshares
    # never reach the nodes), so raising validator_count past 64 to test post-Gloas committee/PTC liveness
    # is safe. Combining it with pre_register_validators: true is rejected below (that half of the contract
    # is detectable in-repo). The aetheria-executor half can't be detected here, so the caller MUST NOT set
    # the flag on an enclave an executor's (event)/(ptc)/(proposer)/(p2p) suite registers validators
    # against, else the extra VCs overlap the seed at 64-73 and double-sign -> slashing.
    if args.get("unsafe_skip_validator_layout_guard", False):
        # Enforce the detectable half of the flag's contract: pre_register_validators adopts the seed at
        # 64-73, contradicting skip's "no SSV validators" premise, and a >64 VC set would overlap it ->
        # double-sign. (The external-executor half can't be detected in-repo - still caller's responsibility.)
        if args.get("pre_register_validators", False):
            fail("unsafe_skip_validator_layout_guard is incompatible with pre_register_validators: true - pre-registration makes the SSV operators run the seed at indices 64-73, so a >64 VC set would overlap them -> double-sign -> slashing. The skip flag is for bare liveness probes with no SSV validators; drop one of the two.")
        # The monitor FATAL-crashes after ~2min of head-stall - exactly the condition a liveness probe
        # observes - so warn (not fail: monitor-on does not affect the beacon-API head-slot evidence).
        if args["monitor"]["enabled"]:
            plan.print("WARNING: unsafe_skip_validator_layout_guard=true with monitor.enabled=true - the monitor FATAL-crashes after ~2min of head-stall, i.e. exactly the condition a liveness probe (ssvlabs/ssv-mini#38) is trying to observe. Set monitor.enabled: false for probe runs.")
        plan.print("WARNING: unsafe_skip_validator_layout_guard=true - skipping the 64/74 validator-layout guard (VCs run [0,{}), genesis deposits [0,{})). SAFE ONLY if no SSV-managed validators are adopted on this enclave (no pre_register, no aetheria validator suite); otherwise VC/SSV overlap -> double-sign -> slashing.".format(vc_validators, deposited_validators))
    else:
        if vc_validators > constants.SSV_SEED_START_INDEX or deposited_validators < constants.SSV_SEED_START_INDEX + constants.SSV_MANAGED_VALIDATOR_COUNT:
            fail("local_testnet validator layout drift: VCs run [0,{}), genesis deposits [0,{}). The aetheria seed adopts indices 64-73 (must be deposited AND VC-idle) - keep total validator_count*count <= 64 and preregistered_validator_count >= 74, or update the aetheria seed. For a standalone base-chain liveness probe with no SSV validators (ssvlabs/ssv-mini#38), set unsafe_skip_validator_layout_guard: true.".format(vc_validators, deposited_validators))
    # Validate pre_register_count (the pool-split knob) here at plan time, before the enclave is built —
    # bad input must fail OUT of the dangerous mode, not into it (failing at Step 4 leaves a half-built
    # enclave to tear down). Negative or > the pool would fall back to registering the full set (the
    # ValidatorAlreadyExists collision the split avoids); a positive count with pre_register_validators:
    # false registers nothing while cohort P is expected. register-validators.cjs keeps its own [1, N]
    # check as defence-in-depth.
    pre_register_count = args.get("pre_register_count", 0)
    if pre_register_count < 0 or pre_register_count >= constants.SSV_MANAGED_VALIDATOR_COUNT:
        fail("pre_register_count ({}) must be < {} (the pool size): a positive value splits the pool (P = first N, cohort D = the rest) and must leave D non-empty; the full pool would leave D empty, so use 0 to register everything with no split.".format(pre_register_count, constants.SSV_MANAGED_VALIDATOR_COUNT))
    if pre_register_count > 0 and not args.get("pre_register_validators", False):
        fail("pre_register_count ({}) > 0 requires pre_register_validators: true — otherwise Step 4 is skipped and nothing registers while cohort P is expected. Set pre_register_validators: true (or PRE_REGISTER_VALIDATORS=true), or drop the count.".format(pre_register_count))

    ethereum_network = ethereum_package.run(plan, network_args)

    cl_service_name, cl_url, el_service_name, el_rpc, el_ws = utils.get_network_attributes(ethereum_network.all_participants)

    blocks.wait_until_node_reached_block(plan, el_service_name, 1)

    # ── Step 2: Deploy SSV smart contracts ──
    plan.print("Step 2/5: Deploying SSV smart contracts")
    deployer.deploy(plan, el_rpc, genesis_constants, deployer_image_spec)

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
        plan.remove_service(constants.DEPLOYER_SERVICE_NAME, description="Cleaning up contract deployer")

        keyshare_artifact = plan.upload_files(
            "./static/keyshares/out.json",
            name="keyshares.json",
            description="Uploading pre-computed keyshares",
        )
    else:
        plan.print("Step 3/5: Generating operator keys and keyshares (dynamic mode)")
        non_ssv_validators = vc_validators  # validators consumed by the genesis EL/CL VCs (total across participants; computed in the layout guard above)
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
        plan.remove_service(constants.DEPLOYER_SERVICE_NAME, description="Cleaning up contract deployer")

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
    # Default: skipped on the v2.0.0 contracts. The aetheria executor registers and funds its own
    # validators (registration is payable/msg.value on v2.0.0) onto a clean, empty cluster. Under the
    # pool split (pre_register_count > 0) the executor's cohort D instead registers onto the P-populated
    # cluster — it passes the LIVE on-chain cluster snapshot (validatorCount N, N*2.5 ETH), not the zero
    # struct this repo's P path uses, so nonce continuity AND the cluster snapshot both hold. Validated
    # end-to-end by aetheria#176.
    #
    # Opt-in pre-registration (pre_register_validators: true): register the static keyshares on-chain
    # here so a standalone `kurtosis run` (no aetheria) yields operators that actually run validators.
    # Needed by consumers that gate CI on this testnet without the executor (e.g. sigp/anchor). This
    # is the devnet pre-registration path tracked in ssvlabs/ssv-mini#29.
    #
    # ON-mode contract: the static keyshares occupy the validator pool at indices 64-73. Pre-registering
    # the FULL set (pre_register_count unset/0) collides with the aetheria executor's own
    # validator-registering suites ((event)/(ptc)/(proposer)/(p2p)) — both register the same pubkeys, so
    # a combined enclave reverts with ValidatorAlreadyExists; use standard (flag-off) enclaves there.
    # pre_register_count: N registers only the first N keyshares (P = indices [64, 64+N)), leaving
    # [64+N, 74) for the executor to register as its own cohort (D) — the index-partitioned split that
    # lets pre-registration and a registering suite share one enclave (aetheria#176). register_validators
    # reads pre_register_count from args.
    if args.get("pre_register_validators", False):
        effective_count = pre_register_count if pre_register_count > 0 else constants.SSV_MANAGED_VALIDATOR_COUNT
        plan.print("Step 4/5: Pre-registering {} validator(s) on-chain — cohort P = indices [{}, {}) (pre_register_validators=true, pre_register_count={})".format(
            effective_count, constants.SSV_SEED_START_INDEX, constants.SSV_SEED_START_INDEX + effective_count, pre_register_count))
        interactions.register_validators(
            plan,
            keyshare_artifact,
            constants.SSV_NETWORK_PROXY_CONTRACT,
            el_rpc,
            genesis_constants,
            args,
        )
        plan.remove_service(constants.REGISTER_VALIDATOR_SERVICE_NAME, description="Cleaning up validator registration service")
    else:
        plan.print("Step 4/5: Skipping validator pre-registration (executor registers its own; see #29)")

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
            ssv_configs[service_name] = ssv_node.get_service_config(node_index, config, ssv_image)
            node_index += 1

        # Optional archive-exporter node (enabled in params-boole). Read-only: an empty operator key —
        # it doesn't sign, and its p2p identity auto-generates like every node's. generate_config renders
        # it in archive mode, which serves the committee duty traces the aetheria (boole) Step 12 reads.
        # Singular by design (the aetheria side pins the hostname `ssv-exporter`), hence a bool, not a count.
        exporter_enabled = args["nodes"].get("exporter", {}).get("enabled", False)
        if exporter_enabled:
            exporter_config = ssv_node.generate_config(plan, node_index, cl_url, el_ws, "", enr, True, args)
            ssv_configs["ssv-exporter"] = ssv_node.get_service_config(node_index, exporter_config, ssv_image)

        ssv_services = plan.add_services(
            ssv_configs,
            description="Starting {} SSV services in parallel".format(len(ssv_configs)),
        )

        # The exporter above reused node_index without incrementing it, so node_index is still
        # anchor_node_count + ssv_node_count here — this resolves to the first SSV node.
        first_ssv_name = "ssv-node-{}".format(node_index - ssv_node_count)
        ssv_node_api_url = ssv_services[first_ssv_name].ports[ssv_node.SSV_API_PORT_NAME].url

    monitor_enabled = args["monitor"]["enabled"]
    if monitor_enabled:
        if ssv_node_count == 0:
            return

        plan.print("Launching monitor stack")
        monitor.start(plan, ssv_node_api_url, cl_url, monitor_image, postgres_image, redis_image)
