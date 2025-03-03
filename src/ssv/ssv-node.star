shared_utils = import_module("../utils/utils.star")
SSV_CONFIG_DIR_PATH_ON_SERVICE = "/ssv-config"

def generate_config(
        plan,
        index,
        ssv_config_template,
        consensus_client,
        execution_client,
        operator_private_key,
):
    db_path = "./data/db/{}/".format(index)
    file_name = "ssv-config-{}.yaml".format(index)
    log_level = "debug"

    custom_network_name = "local-network"
    genesis_domain_type = "0x00000501"
    alan_domain_type = "0x00000502"
    registry_sync_offset = "181612"
    registry_contract_addr = "0x38A4794cCEd47d3baf7370CcC43B560D3a1beEFA"
    local_events_path = "./config/events.yaml"

    # Prepare data for the template
    data = struct(
        LogLevel=log_level,
        DBPath=db_path,
        BeaconNodeAddr=consensus_client,
        ETH1Addr=execution_client,
        CustomNetworkName=custom_network_name,
        GenesisDomainType=genesis_domain_type,
        AlanDomainType=alan_domain_type,
        RegistrySyncOffset=registry_sync_offset,
        RegistryContractAddr=registry_contract_addr,
        OperatorPrivateKey=operator_private_key,
        LocalEventsPath=local_events_path,
    )

    # Render the template into a file artifact
    rendered_artifact = plan.render_templates(
        {
            file_name: shared_utils.new_template_and_data(ssv_config_template, data),
        },
        name=file_name,
    )

    return rendered_artifact

def start(plan, index, config_artifact):
    """
    Adds and starts an SSV node service in Kurtosis.

    Args:
        plan: Kurtosis execution plan.
        index: The index of the node to start.
        config_artifact: The artifact containing the configuration to use for the node.

    Returns:
        The created service object.
    """

    service_name = "ssv-node-{}".format(index)
    image = "ssv-node:custom-config"  # Matches the new Docker image name
    config_path = "{}/ssv-config-{}.yaml".format(SSV_CONFIG_DIR_PATH_ON_SERVICE, index)

    # Minimal service configuration
    service_config = ServiceConfig(
        image=image,
        entrypoint=[
            "make",
            "BUILD_PATH=/go/bin/ssvnode",
            "start-node",
        ],
        cmd=[],
        env_vars={
            "CONFIG_PATH": config_path,  # Pass the path as an environment variable
        },
        files={
            SSV_CONFIG_DIR_PATH_ON_SERVICE: config_artifact,  # Map the configuration artifact to the desired path
        },
    )

    # Add the service
    plan.add_service(service_name, service_config)

    # Return the service object
    return plan.get_service(service_name)