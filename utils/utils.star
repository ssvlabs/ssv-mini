constants = import_module("constants.star")

# Image utility functions
def get_image(args, image_name):
    """Get an image from the params file's images: block, falling back to its constants.env pin"""
    # `or`, not a .get default: a bare `images:` (YAML null) or an empty entry falls back to the pin too.
    images = args.get("images") or {}
    return images.get(image_name) or constants.IMAGES[image_name]

def get_ssv_image(args):
    """Get SSV node image"""
    return get_image(args, "ssv")

def get_anchor_image(args):
    """Get Anchor node image"""
    return get_image(args, "anchor")

def get_monitor_image(args):
    """Get Monitor image"""
    return get_image(args, "monitor")

def get_redis_image(args):
    """Get Redis image"""
    return get_image(args, "redis")

def get_postgres_image(args):
    """Get PostgreSQL image"""
    return get_image(args, "postgres")

def get_deployer_image_spec(args):
    """Get Deployer image build spec"""
    deployer_image_name = get_image(args, "deployer")
    return ImageBuildSpec(
        image_name=deployer_image_name,
        build_context_dir="./",
        build_file="Dockerfile.contract",
    )

def apply_network_defaults(network_args, use_static_keys):
    """Return a copy of the ethereum-package args with the constants.env defaults filled in: each participant's
    el_image / cl_image (by client type, when unset) and the genesis validator mnemonic, which a static-keys run
    must not override (the static keys derive from it)."""
    network_args = dict(network_args)
    participants = []
    for participant in network_args["participants"]:
        participant = dict(participant)
        # ethereum-package's own client-type defaults, so an omitted type still gets the pinned image.
        el_type = participant.get("el_type", "geth")
        cl_type = participant.get("cl_type", "lighthouse")
        if not participant.get("el_image") and el_type in constants.DEFAULT_EL_IMAGES:
            participant["el_image"] = constants.DEFAULT_EL_IMAGES[el_type]
        if not participant.get("cl_image") and cl_type in constants.DEFAULT_CL_IMAGES:
            participant["cl_image"] = constants.DEFAULT_CL_IMAGES[cl_type]
        participants.append(participant)
    network_args["participants"] = participants

    network_params = dict(network_args["network_params"])
    mnemonic = network_params.get("preregistered_validator_keys_mnemonic") or constants.MNEMONIC
    if use_static_keys and mnemonic != constants.MNEMONIC:
        fail("network_params.preregistered_validator_keys_mnemonic differs from constants.env's MNEMONIC, which the static keys are derived from. Drop the override, set use_static_keys: false, or change MNEMONIC and regenerate the keys (make generate-keys).")
    network_params["preregistered_validator_keys_mnemonic"] = mnemonic
    network_args["network_params"] = network_params
    return network_args

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


def anchor_testnet_artifact(plan, args):
    base_path = "../nodes/anchor/config"
    config = Directory(
        artifact_names = [
            "el_cl_genesis_data",
            plan.upload_files(base_path + "/ssv_boot_enr.yaml", description="Uploading Anchor SSV boot ENR"),
            plan.upload_files(base_path + "/ssv_contract_block.txt", description="Uploading Anchor SSV contract block"),
            plan.upload_files(base_path + "/ssv_domain_type.txt", description="Uploading Anchor SSV domain type"),
            plan.upload_files(base_path + "/ssv_network_name.txt", description="Uploading Anchor SSV network name"),
            plan.render_templates(
                {
                    "ssv_contract_address.txt": struct(
                        template="{{ .Address }}",
                        data={"Address": constants.SSV_NETWORK_PROXY_CONTRACT},
                    ),
                    "ssv_fork_schedule.yaml": struct(
                        template=read_file(base_path + "/ssv_fork_schedule.yaml"),
                        data = {
                            "BooleEpoch": args.get("boole_epoch", constants.BOOLE_DORMANT_EPOCH),
                        }
                    )
                },
                description="Rendering Anchor SSV contract address and fork schedule",
            )
        ]
    )
    return config

def read_enr_from_file(plan, service_name):
    # Execute a command to read the ENR file on the container
    result = plan.exec(
        service_name = service_name,
        recipe = ExecRecipe(
            command = ["/bin/sh", "-c", "cat /opt/data/network/enr.dat"]
        )
    )
    
    # Return the ENR content
    return result["output"]
