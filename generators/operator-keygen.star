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
        description="Starting Anchor CLI for key generation",
    )

def generate_keys(plan, num_keys):
    """Generate num_keys RSA keypairs in a single batched keygen exec, then read and store each."""
    keygen_cmds = []
    for i in range(num_keys):
        keygen_cmds.append(
            "anchor keygen --force --datadir /root/.anchor && " +
            "mkdir -p /root/keys/{0} && ".format(i) +
            "cp /root/.anchor/public_key.txt /root/keys/{0}/ && ".format(i) +
            "cp /root/.anchor/unencrypted_private_key.txt /root/keys/{0}/".format(i)
        )

    plan.exec(
        service_name=constants.ANCHOR_CLI_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", " && ".join(keygen_cmds)],
        ),
        description="Generating {} operator RSA keypairs".format(num_keys),
    )

    operator_public_keys = []
    operator_private_keys = []
    pem_artifacts = []

    for index in range(num_keys):
        key_dir = "/root/keys/{}/".format(index)

        public_key_result = plan.exec(
            service_name=constants.ANCHOR_CLI_SERVICE_NAME,
            recipe=ExecRecipe(
                command=["cat", key_dir + "public_key.txt"],
                extract={"public": "."},
            ),
            description="Reading operator {} public key".format(index),
        )
        private_key_result = plan.exec(
            service_name=constants.ANCHOR_CLI_SERVICE_NAME,
            recipe=ExecRecipe(
                command=["cat", key_dir + "unencrypted_private_key.txt"],
                extract={"private": "."},
            ),
            description="Reading operator {} private key".format(index),
        )

        pem_artifact = plan.store_service_files(
            service_name=constants.ANCHOR_CLI_SERVICE_NAME,
            src=key_dir + "unencrypted_private_key.txt",
            name="key-{}".format(index),
            description="Storing operator {} key artifact".format(index),
        )

        operator_public_keys.append(public_key_result["extract.public"])
        operator_private_keys.append(private_key_result["extract.private"])
        pem_artifacts.append(pem_artifact)

    return operator_public_keys, operator_private_keys, pem_artifacts
