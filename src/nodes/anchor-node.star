constants = import_module("../utils/constants.star")
utils = import_module("../utils/utils.star")

# Start an anchor node
def start(plan, num_nodes, cl_url, el_rpc, el_ws, key_pem, config):
    # Define IP placeholder that Kurtosis will replace with the container's actual IP at runtime
    IP_PLACEHOLDER = "KURTOSIS_IP_ADDR_PLACEHOLDER"
    enr = ""
    
    for index in range(0, num_nodes):
        name = "anchor-node-{}".format(index)
        files = get_anchor_files(plan, index, key_pem, config)
        
        # Create command array using the placeholder for this node's IP
        command_arr = [
            "node", "--testnet-dir", "testnet", "--beacon-nodes", cl_url,
            "--execution-nodes", el_rpc, "--execution-nodes", el_ws, "--datadir", "data",
            "--enr-address", IP_PLACEHOLDER, "--enr-tcp-port", "9100", "--enr-udp-port", "9100",
            "--enr-quic-port", "9101", "--port", "9100", "--discovery-port", "9100", "--quic-port", "9101"
        ]
        
        # Add boot nodes parameter if not the first node
        if index > 0 and enr:
            command_arr.extend(["--boot-nodes", enr])

        plan.print(command_arr)
        
        # Create the service with the placeholder in the command
        service = plan.add_service(
            name = name,
            config=ServiceConfig(
                image = constants.ANCHOR_IMAGE,
                entrypoint=["./anchor"],
                cmd=command_arr,
                files = files,
                private_ip_address_placeholder=IP_PLACEHOLDER
            )
        )
        
        # For the first node, generate the ENR after creation to share with other nodes
        if index == 0:
            # Use the actual IP address for ENR generation
            container_ip = service.ip_address
            enr = utils.generate_enr(plan, container_ip)

def fresh_command_arr(plan, cl_url, el_rpc, el_ws, container_ip):
    return [
        "./anchor", "node", "--testnet-dir testnet", "--beacon-nodes", cl_url, 
        "--execution-nodes", el_rpc, "--execution-nodes", el_ws, "--datadir data",
        "--enr-address", container_ip, "--enr-tcp-port 9100", "--enr-udp-port 9100", 
        "--enr-quic-port 9101", "--port 9100", "--discovery-port 9100", "--quic-port 9101",
    ]


def get_anchor_files(plan, index, key_pem, config):
    if index == 0:
        # this is the "main" bootnode
        return {
            "/usr/local/bin/data": key_pem,
            "/usr/local/bin/data/network": plan.upload_files("../testnet-configs/anchor-config/key"),
            "/usr/local/bin/testnet": config
        }
    else:
        # this is a normal node
        return {
            "/usr/local/bin/data": key_pem,
            "/usr/local/bin/testnet": config
        }


