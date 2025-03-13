constants = import_module("constants.star")

def get_eth_urls(all_participants):
    el_ip_addr = all_participants[
        0
    ].el_context.ip_addr
    el_ws_port = all_participants[
        0
    ].el_context.ws_port_num
    el_rpc_port = all_participants[
        0
    ].el_context.rpc_port_num
    el_rpc_uri = "http://{0}:{1}".format(el_ip_addr, el_rpc_port)
    el_ws_uri = "ws://{0}:{1}".format(el_ip_addr, el_ws_port)
    cl_ip_addr = all_participants[
        0
    ].cl_context.ip_addr
    cl_http_port_num = all_participants[
        0
    ].cl_context.http_port
    cl_uri = "http://{0}:{1}".format(cl_ip_addr, cl_http_port_num)

    return (cl_uri, el_rpc_uri, el_ws_uri)

def new_template_and_data(template, template_data_json):
    return struct(template=template, data=template_data_json)


def anchor_testnet_artifact(plan):
    config = Directory(
        artifact_names = [
            plan.upload_files("../testnet-configs/anchor-config/config.yaml"),
            plan.upload_files("../testnet-configs/anchor-config/deposit_contract_block.txt"),
            plan.upload_files("../testnet-configs/anchor-config/ssv_boot_enr.yaml"),
            plan.upload_files("../testnet-configs/anchor-config/ssv_contract_address.txt"),
            plan.upload_files("../testnet-configs/anchor-config/ssv_contract_block.txt"),
            plan.upload_files("../testnet-configs/anchor-config/ssv_domain_type.txt"),
        ]
    )
    return config

def generate_enr(plan, container_ip):
    # start the service with enr-cli
    command_arr = [
        "enr-cli",
        "build",
        "-j", "network/key",
        "-i", container_ip,
        "-s", "1",
        "-p", "9100",
        "-u", "9100"
    ]

    plan.add_service(
        name = "enr-cli",
        config = ServiceConfig(
            image = constants.ENR_CLI_IMAGE,
            entrypoint=["tail", "-f", "/dev/null"],
            files = {
                "/usr/local/bin/network": plan.upload_files("../testnet-configs/anchor-config/key"),
            }
        )
    )

    result = plan.exec(
        service_name = "enr-cli",
        recipe = ExecRecipe(
            command=["/bin/sh", "-c", " ".join(command_arr)],
            extract = {
                "enr": "split(\"\\n\") | map(select(startswith(\"Built ENR: \"))) | .[0] | sub(\"Built ENR: \"; \"\")"
            }
        )
    )

    return result["extract.enr"]






