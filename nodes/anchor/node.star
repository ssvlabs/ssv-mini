constants = import_module("../../utils/constants.star")
utils = import_module("../../utils/utils.star")

ANCHOR_METRICS_PORT_NAME = "metrics"
ANCHOR_METRICS_PORT = 5164

def _command_for(endpoints, boot_enr, metrics_port, ip_placeholder):
    """Anchor's CLI takes COMMA-separated endpoint lists (value_delimiter = ',' at
    anchor/cli/src/cli.rs:52,64). --execution-ws is a single SensitiveUrl, so it gets the
    primary only."""
    cmd = [
        "node", "--testnet-dir", "/opt/testnet",
        "--beacon-nodes", ",".join(endpoints.cl_urls),
        "--execution-rpc", ",".join(endpoints.el_rpc_urls),
        "--execution-ws", endpoints.el_ws_urls[0],
        "--datadir", "/opt/data",
        "--enr-address", ip_placeholder, "--enr-tcp-port", "9100", "--enr-udp-port", "9100",
        "--enr-quic-port", "9101", "--port", "9100", "--discovery-port", "9100", "--quic-port", "9101",
        "--logfile-max-number", "0", "--debug-level", "debug",
        # mitigation of https://github.com/sigp/anchor/issues/765
        "--subscribe-all-subnets",
        # Prometheus metrics; anchor defaults the listen address to 127.0.0.1, which is
        # unreachable from outside the container, so bind 0.0.0.0 for the published port.
        "--metrics", "--metrics-address", "0.0.0.0", "--metrics-port", str(metrics_port),
    ]
    if boot_enr != "":
        cmd.extend(["--boot-nodes", boot_enr])
    return cmd

# Start anchor nodes: first node starts alone (to get ENR), remaining start in parallel
def start(plan, num_nodes, operators, key_pems, config, image):
    IP_PLACEHOLDER = "KURTOSIS_IP_ADDR_PLACEHOLDER"

    # Start the first node (bootnode)
    files = get_anchor_files(plan, 0, key_pems[0], config)
    command_arr = _command_for(operators[0], "", ANCHOR_METRICS_PORT, IP_PLACEHOLDER)

    metrics_ports = {
        ANCHOR_METRICS_PORT_NAME: PortSpec(
            number=ANCHOR_METRICS_PORT,
            transport_protocol="TCP",
            application_protocol="http",
        ),
    }

    plan.add_service(
        name="anchor-node-0",
        description="Starting Anchor bootnode (node 0)",
        config=ServiceConfig(
            image=image,
            entrypoint=["anchor"],
            cmd=command_arr,
            files=files,
            ports=metrics_ports,
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

    # Start remaining anchor nodes in parallel
    if num_nodes > 1:
        remaining_configs = {}
        for index in range(1, num_nodes):
            name = "anchor-node-{}".format(index)
            files = get_anchor_files(plan, index, key_pems[index], config)
            remaining_configs[name] = ServiceConfig(
                image=image,
                entrypoint=["anchor"],
                cmd=_command_for(operators[index], enr, ANCHOR_METRICS_PORT, IP_PLACEHOLDER),
                files=files,
                ports=metrics_ports,
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
