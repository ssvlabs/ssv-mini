utils = import_module("../utils/utils.star")
shared_utils = import_module("github.com/ethpandaops/ethereum-package/src/shared_utils/shared_utils.star")
constants = import_module("../utils/constants.star")

SSV_CONFIG_DIR_PATH_ON_SERVICE = "/ssv-config"

STATIC_FILES_DIRPATH = "/static_files"

SSV_CONFIG_DIRPATH = "/ssv-config"

SSV_CONFIG_TEMPLATE_FILEPATH = (
        STATIC_FILES_DIRPATH
        + SSV_CONFIG_DIRPATH
        + "/templates/ssv-config.yml.tmpl"
)

SSV_API_PORT = 9232
SSV_API_PORT_ID = "http"


USED_PORTS = {
    SSV_API_PORT_ID: shared_utils.new_port_spec(
        SSV_API_PORT,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    )
}

def generate_config(
        plan,
        index,
        consensus_client,
        execution_client,
        operator_private_key,
        enr
):

    ssv_config_template = read_file(
        SSV_CONFIG_TEMPLATE_FILEPATH
    )

    db_path = "./data/db/{}/".format(index)
    file_name = "ssv-config-{}.yaml".format(index)
    log_level = "debug"

    custom_network_name = "local-network"
    genesis_domain_type = "0x00000501"
    alan_domain_type = "0x00000502"
    registry_sync_offset = "1"
    registry_contract_addr = constants.SSV_NETWORK_PROXY_CONTRACT 

    discovery = ""
    if enr == "":
        discovery = "mdns"
    else:
        discovery = "discv5"

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
        Discovery=discovery,
        ENR=enr
    )

    # Render the template into a file artifact
    rendered_artifact = plan.render_templates(
        {
            file_name: utils.new_template_and_data(ssv_config_template, data),
        },
        name=file_name,
    )

    return rendered_artifact

def start(plan, index, config_artifact):
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
