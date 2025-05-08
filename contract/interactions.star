constants = import_module("../utils/constants.star")

def register_operators(plan, public_keys, network_address):
    # Write the keys into the container as json.
    quoted_keys = []
    for key in public_keys:
        quoted_keys.append('"{}"'.format(key))

    json_content = '{{"publicKeys": [{}]}}'.format(", ".join(quoted_keys))
    plan.exec(
        service_name=constants.FOUNDRY_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "echo '{}' > /app/operator_keys.json".format(json_content)]
        )
    )

    # Now, register all of the operators
    command_arr=[
        "forge", "script", "script/register-operator/RegisterOperators.s.sol:RegisterOperators",
        "--sig", "\'run(address)\'", network_address,
        "--rpc-url", "${ETH_RPC_URL}",
        "--private-key", "${PRIVATE_KEY}",
        "--broadcast", "--legacy", "--silent"
    ]

    plan.exec(
        service_name=constants.FOUNDRY_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", " ".join(command_arr)],
        )
    )

    # get a file artifact to the operator data
    operator_data_artifact = plan.store_service_files(
        service_name=constants.FOUNDRY_SERVICE_NAME,
        src="/app/operator_data.json",
        name="operator_data.json"
    )

    return operator_data_artifact


def register_validators(plan, keyshare_artifact, network_address, token_address, rpc, genesis_constants):
    # have to add a new service since we have new files to mount and mounting files to existing services is not supported
    foundry_service = plan.add_service(
        name = "register-validator",
        config = ServiceConfig(
            image=constants.FOUNDRY_IMAGE,
            entrypoint=["tail", "-f", "/dev/null"],
            env_vars = {
                "ETH_RPC_URL": rpc,
                "PRIVATE_KEY": genesis_constants.PRE_FUNDED_ACCOUNTS[1].private_key,
                "SSV_NETWORK_ADDRESS": network_address,
                "SSV_TOKEN_ADDRESS": token_address
            },
            files = {
                "/app/script/register-validator": plan.upload_files("./registration/RegisterValidators.s.sol"),
                "/app/script/keyshares": keyshare_artifact,
                "/app/script/register": plan.upload_files("../scripts/register-validators.sh")
            }
        )
    )

    plan.exec(
        service_name="register-validator",
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "chmod u+x script/register/register-validators.sh && ./script/register/register-validators.sh "]
        )
    )
