constants = import_module("../utils/constants.star")
utils = import_module("../utils/utils.star")

def register_operators(plan, public_keys, network_address):
    quoted_keys = []
    for key in public_keys:
        quoted_keys.append('"{}"'.format(key))

    json_content = '{{"publicKeys": [{}]}}'.format(", ".join(quoted_keys))
    plan.exec(
        service_name=constants.FOUNDRY_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "echo '{}' > /app/operator_keys.json".format(json_content)],
        ),
        description="Writing {} operator public keys".format(len(public_keys)),
    )

    command_arr = [
        "forge", "script", "script/register-operator/RegisterOperators.s.sol:RegisterOperators",
        "--sig", "\'run(address)\'", network_address,
        "--rpc-url", "${ETH_RPC_URL}",
        "--private-key", "${PRIVATE_KEY}",
        "--broadcast", "--legacy", "--silent",
    ]

    plan.exec(
        service_name=constants.FOUNDRY_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", " ".join(command_arr)],
        ),
        description="Registering {} operators on-chain".format(len(public_keys)),
    )

    operator_data_artifact = plan.store_service_files(
        service_name=constants.FOUNDRY_SERVICE_NAME,
        src="/app/operator_data.json",
        name="operator_data.json",
        description="Storing operator registration data",
    )

    return operator_data_artifact


def register_validators(plan, keyshare_artifact, network_address, token_address, rpc, genesis_constants, args):
    plan.add_service(
        name="register-validator",
        config=ServiceConfig(
            image=utils.get_foundry_image_spec(args),
            entrypoint=["tail", "-f", "/dev/null"],
            env_vars={
                "ETH_RPC_URL": rpc,
                "PRIVATE_KEY": genesis_constants.PRE_FUNDED_ACCOUNTS[1].private_key,
                "SSV_NETWORK_ADDRESS": network_address,
                "SSV_TOKEN_ADDRESS": token_address,
            },
            files={
                "/app/script/register-validator": plan.upload_files("./registration/RegisterValidators.s.sol"),
                "/app/script/keyshares": keyshare_artifact,
                "/app/script/register": plan.upload_files("../scripts/register-validators.sh"),
            },
        ),
        description="Starting validator registration service",
    )

    plan.exec(
        service_name="register-validator",
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "chmod u+x script/register/register-validators.sh && ./script/register/register-validators.sh"],
        ),
        description="Registering validators on-chain (forge script)",
    )
