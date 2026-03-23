constants = import_module("../../utils/constants.star")
utils = import_module("../../utils/utils.star")

# Start anchor nodes: first node starts alone (to get ENR), remaining start in parallel
def start(plan, num_nodes, cl_url, el_rpc, el_ws, key_pems, config, image):
    IP_PLACEHOLDER = "KURTOSIS_IP_ADDR_PLACEHOLDER"

    # Start the first node (bootnode)
    files = get_anchor_files(plan, 0, key_pems[0], config)
    command_arr = [
        "node", "--testnet-dir", "/opt/testnet", "--beacon-nodes", cl_url,
        "--execution-rpc", el_rpc, "--execution-ws", el_ws, "--datadir", "/opt/data",
        "--enr-address", IP_PLACEHOLDER, "--enr-tcp-port", "9100", "--enr-udp-port", "9100",
        "--enr-quic-port", "9101", "--port", "9100", "--discovery-port", "9100", "--quic-port", "9101",
        "--logfile-max-number", "0", "--debug-level", "debug",
        # mitigation of https://github.com/sigp/anchor/issues/765
        "--subscribe-all-subnets",
    ]

    plan.add_service(
        name="anchor-node-0",
        description="Starting Anchor bootnode (node 0)",
        config=ServiceConfig(
            image=image,
            entrypoint=["anchor"],
            cmd=command_arr,
            files=files,
            private_ip_address_placeholder=IP_PLACEHOLDER,
            ready_conditions=ReadyCondition(
                recipe=ExecRecipe(
                    command=["/bin/sh", "-c", "test -f /opt/data/network/enr.dat"],
                ),
                field="code",
                assertion="==",
                target_value=0,
                interval="2s",
            ),
        ),
    )

    # Read the ENR from the bootnode
    enr = utils.read_enr_from_file(plan, "anchor-node-0")
    command_arr_with_boot = list(command_arr)
    command_arr_with_boot.extend(["--boot-nodes", enr])

    # Start remaining anchor nodes in parallel
    if num_nodes > 1:
        remaining_configs = {}
        for index in range(1, num_nodes):
            name = "anchor-node-{}".format(index)
            files = get_anchor_files(plan, index, key_pems[index], config)
            remaining_configs[name] = ServiceConfig(
                image=image,
                entrypoint=["anchor"],
                cmd=command_arr_with_boot,
                files=files,
                private_ip_address_placeholder=IP_PLACEHOLDER,
            )
        plan.add_services(remaining_configs, description="Starting {} remaining Anchor nodes in parallel".format(num_nodes - 1))

    return enr

def get_anchor_files(plan, index, key_pem, config):
    if index == 0:
        return {
            "/opt/data": key_pem,
            "/opt/network": plan.upload_files("./config/key"),
            "/opt/testnet": config,
        }
    else:
        return {
            "/opt/data": key_pem,
            "/opt/testnet": config,
        }
