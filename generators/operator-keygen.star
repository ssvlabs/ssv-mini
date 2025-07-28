constants = import_module("../utils/constants.star")

def start_cli(plan, keystores):
    plan.add_service(
        name=constants.ANCHOR_CLI_SERVICE_NAME,
        config=ServiceConfig(
            image=constants.ANCHOR_IMAGE,
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
    # Custom dir path passed to anchor keygen command with arg '--data-dir' based on latest anchor commits
    key_dir = "/usr/local/bin/"
    
    # Execute the anchor keygen command (new output based on latest anchor commits: public_key.txt, unencrypted_private_key.txt)
    plan.exec(
        service_name=constants.ANCHOR_CLI_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "./anchor keygen --data-dir " + key_dir + " --force"],
        ),
    )

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
            command=["cat", key_dir + "private_key.txt"],
            extract={"private": "."},
        ),
    )

    # Store the private key file as the artifact
    pem_artifact = plan.store_service_files(
        service_name=constants.ANCHOR_CLI_SERVICE_NAME,
        src=key_dir + "private_key.txt",
        name="key-{}".format(index),
    )

    return struct(
        public_key=public_key_result["extract.public"],
        private_key=private_key_result["extract.private"],
        artifact=pem_artifact
    )