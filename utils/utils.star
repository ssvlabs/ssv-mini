constants = import_module("constants.star")

def get_network_attributes(all_participants):
    el_context = all_participants[0].el_context
    el_service_name = el_context.service_name
    el_ip_addr = el_context.ip_addr
    el_ws_port = el_context.ws_port_num
    el_rpc_port = el_context.rpc_port_num

    el_rpc_uri = "http://{0}:{1}".format(el_ip_addr, el_rpc_port)
    el_ws_uri = "ws://{0}:{1}".format(el_ip_addr, el_ws_port)

    cl_context = all_participants[0].cl_context
    cl_service_name = cl_context.beacon_service_name
    cl_ip_addr = cl_context.ip_addr
    cl_http_port_num = cl_context.http_port
    cl_uri = "http://{0}:{1}".format(cl_ip_addr, cl_http_port_num)

    return (cl_service_name, cl_uri, el_service_name, el_rpc_uri, el_ws_uri)

def new_template_and_data(template, template_data_json):
    return struct(template=template, data=template_data_json)


def anchor_testnet_artifact(plan):
    base_path = "../nodes/anchor/config"
    config = Directory(
        artifact_names = [
            plan.upload_files(base_path + "/config.yaml"),
            plan.upload_files(base_path + "/deposit_contract_block.txt"),
            plan.upload_files(base_path + "/ssv_boot_enr.yaml"),
            plan.upload_files(base_path + "/ssv_contract_address.txt"),
            plan.upload_files(base_path + "/ssv_contract_block.txt"),
            plan.upload_files(base_path + "/ssv_domain_type.txt"),
        ]
    )
    return config

def read_enr_from_file(plan, service_name):
    # Execute a command to read the ENR file on the container
    result = plan.exec(
        service_name = service_name,
        recipe = ExecRecipe(
            command = ["/bin/sh", "-c", "cat /usr/local/bin/data/network/enr.dat"]
        )
    )
    
    # Return the ENR content
    return result["output"]
