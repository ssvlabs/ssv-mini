utils = import_module("../../utils/utils.star")
shared_utils = import_module("github.com/ethpandaops/ethereum-package/src/shared_utils/shared_utils.star")
constants = import_module("../../utils/constants.star")

SSV_API_PORT = 9232
SSV_API_PORT_NAME = "api"

def generate_config(
        plan,
        index,
        consensus_client,
        execution_client,
        operator_private_key,
        enr,
        is_exporter,
):
    discovery = ""
    if enr == "":
        discovery = "mdns"
    else:
        discovery = "discv5"

    # Prepare data for the template
    data = struct(
        LogLevel="debug",
        DBPath="./data/db/{}/".format(index),
        BeaconNodeAddr=consensus_client,
        ETH1Addr=execution_client,
        Network="testnet", #if not set - default to "mainnet"
        DomainType="0x00000000",
        RegistrySyncOffset="1",
        RegistryContractAddr=constants.SSV_NETWORK_PROXY_CONTRACT,
        OperatorPrivateKey=operator_private_key,
        DiscoveryProtocolID = "0x737376647635", # ssvdv5
        Discovery=discovery,
        ENR=enr,
        Exporter=is_exporter,
        SSVAPIPort=SSV_API_PORT
    )

    plan.print(
        "generating SSV node config artifact with data: " + json.indent(json.encode(data)))

    ssv_config_template = read_file("config.yml.tmpl")
    file_name = "ssv-config-{}.yaml".format(index)

    # Render the template into a file artifact
    rendered_artifact = plan.render_templates(
        {
            file_name: utils.new_template_and_data(ssv_config_template, data),
        },
        name=file_name,
    )

    return rendered_artifact

def start(plan, index, config_artifact, is_exporter):
    SSV_CONFIG_DIR_PATH_ON_SERVICE = "/ssv-config"
    service_name = "ssv-node-{}".format(index) if not is_exporter else "ssv-exporter"
    image = "node/ssv"  # Matches the new Docker image name
    config_path = "{}/ssv-config-{}.yaml".format(SSV_CONFIG_DIR_PATH_ON_SERVICE, index)

    # Minimal service configuration
    service_config = ServiceConfig(
        image=image,
        entrypoint=[
            "make",
            "BUILD_PATH=/go/bin/ssvnode",
            "start-node",
        ],
        ports={
            SSV_API_PORT_NAME: PortSpec(
                number=SSV_API_PORT,
                transport_protocol="TCP",
                application_protocol="http",
            )
        },
        cmd=[],
        env_vars={
            "CONFIG_PATH": config_path,  # Pass the path as an environment variable
        },
        files={
            SSV_CONFIG_DIR_PATH_ON_SERVICE: config_artifact,  # Map the configuration artifact to the desired path
        },
    )

    # Add the service
    return plan.add_service(service_name, service_config)