# using local image with custom config tag, taken from https://github.com/ssvlabs/ssv/pull/1308
# TODO: 1) decide where to pull ssv from; 2) change tag after merging custom config feature
SSV_NODE_IMAGE = "ssv-node:custom-config"
SSV_CLI_SERVICE_NAME = "ssv-cli"

def start_cli(plan):
    files = {}
    plan.add_service(
        name=SSV_CLI_SERVICE_NAME,
        config=ServiceConfig(
            image=SSV_NODE_IMAGE,
            entrypoint=["tail", "-f", "/dev/null"],
            files=files,
        ),
    )

def generate_operator_keys(plan):
    plan.print("generating operator keys")

    plan.exec(
        service_name=SSV_CLI_SERVICE_NAME,
        recipe=ExecRecipe(
            command=[
                "/bin/sh", "-c",
                "/go/bin/ssvnode generate-operator-keys > /tmp/ssv_keys"
            ]
        ),
    )

    public_key = plan.exec(
        service_name=SSV_CLI_SERVICE_NAME,
        recipe=ExecRecipe(command=[
            "/bin/sh", "-c",
            "cat /tmp/ssv_keys | grep 'generated public key' | awk -F'\"' '{print $(NF-1)}' | tr -d ' \n\r'"
        ])
    )["output"]

    private_key = plan.exec(
        service_name=SSV_CLI_SERVICE_NAME,
        recipe=ExecRecipe(command=[
            "/bin/sh", "-c",
            "cat /tmp/ssv_keys | grep 'generated private key' | awk -F'\"' '{print $(NF-1)}' | tr -d ' \n\r'"
        ])
    )["output"]

    plan.print("generated operator keys")
    plan.print(public_key)
    plan.print(private_key)

    return struct(
        public_key=public_key,
        private_key=private_key,
    )


def generate_config(plan, consensus_client, execution_client, contract, operator_private_key):
    plan.print("generating config")

    plan.exec(
        service_name=SSV_CLI_SERVICE_NAME,
        recipe=ExecRecipe(
            command=[
                "/bin/sh", "-c",
                "/go/bin/ssvnode generate-config --output-path=/tmp/ssv_config --consensus-client={} --execution-client={} --ssv-registry-contract-addr={} --ssv-registry-sync-offset=1 --operator-private-key={}".format(consensus_client, execution_client, contract, operator_private_key)
            ]
        ),
    )

    config = plan.exec(service_name=SSV_CLI_SERVICE_NAME, recipe=ExecRecipe(command=["/bin/sh", "-c", "cat /tmp/ssv_config"]))["output"]

    plan.print("generated config")
    plan.print(config)

    return struct(
        config=config,
    )
