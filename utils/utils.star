constants = import_module("constants.star")

# Image utility functions
def get_image(args, image_name):
    """Get image name from configuration, with fallback to default"""
    images = args.get("images", {})
    return images.get(image_name, "")

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

def new_template_and_data(template, template_data_json):
    return struct(template=template, data=template_data_json)


def anchor_testnet_artifact(plan, args):
    base_path = "../nodes/anchor/config"
    config = Directory(
        artifact_names = [
            "el_cl_genesis_data",
            plan.upload_files(base_path + "/ssv_boot_enr.yaml"),
            plan.upload_files(base_path + "/ssv_contract_address.txt"),
            plan.upload_files(base_path + "/ssv_contract_block.txt"),
            plan.upload_files(base_path + "/ssv_domain_type.txt"),
            plan.upload_files(base_path + "/ssv_network_name.txt"),
            plan.render_templates(
                {
                    "ssv_fork_schedule.yaml": struct(
                        template=read_file(base_path + "/ssv_fork_schedule.yaml"),
                        data = {
                            "BooleEpoch": args.get("boole_epoch", constants.BOOLE_DORMANT_EPOCH),
                        }
                    )
                }
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
