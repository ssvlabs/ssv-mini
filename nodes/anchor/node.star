constants = import_module("../../utils/constants.star")
utils = import_module("../../utils/utils.star")

# Start an anchor node
def start(plan, num_nodes, cl_url, el_rpc, el_ws, key_pems, config, image):
    IP_PLACEHOLDER = "KURTOSIS_IP_ADDR_PLACEHOLDER"
    enr = ""
    
    # Start the first node
    name = "anchor-node-0"
    files = get_anchor_files(plan, 0, key_pems[0], config)
    command_arr = [
        "node", "--testnet-dir", "/opt/testnet", "--beacon-nodes", cl_url,
        "--execution-rpc", el_rpc, "--execution-ws", el_ws, "--datadir", "/opt/data",
        "--enr-address", IP_PLACEHOLDER, "--enr-tcp-port", "9100", "--enr-udp-port", "9100",
        "--enr-quic-port", "9101", "--port", "9100", "--discovery-port", "9100", "--quic-port", "9101",
        "--logfile-max-number", "0", "--debug-level", "debug",
        # mitigation of https://github.com/sigp/anchor/issues/765
        "--subscribe-all-subnets"
    ]

    plan.add_service(
        name = name,
        config=ServiceConfig(
            image = image,
            entrypoint=["anchor"],
            cmd=command_arr,
            files = files,
            private_ip_address_placeholder=IP_PLACEHOLDER,
            # need to wait for the node to get its id and write out its enr
            ready_conditions =  ReadyCondition(
                recipe = ExecRecipe(
                    command = ["/bin/sh", "-c", "test -f /opt/data/network/enr.dat"]
                ),
                field = "code",
                assertion = "==",
                target_value = 0,
                interval = "2s",
            )
        )
    )
    
    # Read the ENR from the file
    enr = utils.read_enr_from_file(plan, name)
    command_arr.extend(["--boot-nodes", enr])

    # Start the rest of the nodes with the ENR from the first node
    for index in range(1, num_nodes):
        name = "anchor-node-{}".format(index)
        files = get_anchor_files(plan, index, key_pems[index], config)

        # Create the service with the placeholder in the command
        plan.add_service(
            name = name,
            config=ServiceConfig(
                image = image,
                entrypoint=["anchor"],
                cmd=command_arr,
                files = files,
                private_ip_address_placeholder=IP_PLACEHOLDER
            )
        )

    return enr

def get_anchor_files(plan, index, key_pem, config):
    if index == 0:
        # this is the "main" bootnode
        return {
            "/opt/data": key_pem,
            "/opt/network": plan.upload_files("./config/key"),
            "/opt/testnet": config
        }
    else:
        # this is a normal node
        return {
            "/opt/data": key_pem,
            "/opt/testnet": config
        }


