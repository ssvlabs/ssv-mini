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
    # Execute the anchor keygen command
    result = plan.exec(
        service_name=constants.ANCHOR_CLI_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "./anchor keygen --force > /dev/null && cat keys.json"],
            extract = {
                "public": "fromjson | .public",
                "private": "fromjson | .private",
            }
        ),
    )

    pem_artifact = plan.store_service_files(
        service_name=constants.ANCHOR_CLI_SERVICE_NAME,
        src="/usr/local/bin/key.pem",
        name="key-{}".format(index),
    )

    return struct(
        public_key=result["extract.public"],
        private_key=result["extract.private"],
        artifact=pem_artifact
    )
