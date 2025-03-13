constants = import_module("../utils/constants.star")

# Start an anchor node
def start(plan, index, cl_url, el_rpc, el_ws, key_pem, config):
    enr_addr = "172.16.0.{}".format(index + 23);

    command_arr = [
        "./anchor", "node", "--testnet-dir testnet", "--beacon-nodes", cl_url, 
        "--execution-nodes", el_rpc, "--execution-nodes", el_ws, "--datadir data",
        "--enr-address", enr_addr, "--enr-tcp-port 9100", "--enr-udp-port 9100", 
        "--enr-quic-port 9101", "--port 9100", "--discovery-port 9100", "--quic-port 9101"
    ]

    if index != 0:
        command_arr.append("--boot-nodes")
        command_arr.append(constants.ENR)

    name = "anchor-node-{}".format(index)
    files = get_anchor_files(plan, index, key_pem, config)
    plan.add_service(
        name = name,
        config=ServiceConfig(
            image = constants.ANCHOR_IMAGE,
            cmd=["/bin/sh", "-c", " ".join(command_arr)],
            files = files
        )
    )

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


