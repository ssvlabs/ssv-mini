constants = import_module("../utils/constants.star")
utils = import_module("../utils/utils.star")

def start_cli(plan, keystores, args):
    plan.add_service(
        name=constants.ANCHOR_CLI_SERVICE_NAME,
        config=ServiceConfig(
            image=utils.get_anchor_image(args),
            entrypoint=["tail", "-f", "/dev/null"],
            files={
                "/keystores": keystores.files_artifact_uuid,
            },
        ),
    )

# Generate num_keys rsa keypairs
def generate_keys(plan, num_keys):
    operator_public_keys = []
    operator_private_keys = []
    pem_artifacts = []

    for index in range(0, num_keys):
        keys = generate_operator_keys(plan, index)
        operator_public_keys.append(keys.public_key)
        operator_private_keys.append(keys.private_key)
        pem_artifacts.append(keys.artifact)
    
    return operator_public_keys, operator_private_keys, pem_artifacts


# Generate a new keypair 
def generate_operator_keys(plan, index):
    # Execute the anchor keygen command (new output based on latest anchor commits: public_key.txt, unencrypted_private_key.txt)
    plan.exec(
        service_name=constants.ANCHOR_CLI_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "anchor keygen --force"],
        ),
    )

    # Read the public and private key files from the correct output directory
    key_dir = "/root/.anchor/hoodi/"

    public_key_result = plan.exec(
        service_name=constants.ANCHOR_CLI_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["cat", key_dir + "public_key.txt"],
            extract={"public": "."},
        ),
    )
    private_key_result = plan.exec(
        service_name=constants.ANCHOR_CLI_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["cat", key_dir + "unencrypted_private_key.txt"],
            extract={"private": "."},
        ),
    )

    # Store the private key file as the artifact (for compatibility with previous usage)
    pem_artifact = plan.store_service_files(
        service_name=constants.ANCHOR_CLI_SERVICE_NAME,
        src=key_dir + "unencrypted_private_key.txt",
        name="key-{}".format(index),
    )

    return struct(
        public_key=public_key_result["extract.public"],
        private_key=private_key_result["extract.private"],
        artifact=pem_artifact
    )
