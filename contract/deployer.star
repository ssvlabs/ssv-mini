constants = import_module("../utils/constants.star")

# deploy all of the contracts
def deploy(plan, el, genesis_constants):
    env_vars = get_env_vars(el, genesis_constants.PRE_FUNDED_ACCOUNTS[1].private_key)

    # start the foundry service
    foundry_service = plan.add_service(
        name = constants.FOUNDRY_SERVICE_NAME,
        config = ServiceConfig(
            image=constants.FOUNDRY_IMAGE,
            entrypoint=["tail", "-f", "/dev/null"],
            env_vars = env_vars,
            files = {
                "/app/script/register-operator": plan.upload_files("./registration/RegisterOperators.s.sol"),
            }
        )
    )

    # Deploy the contracts to the chain
    command_arr = ["forge", "script", "script/DeployAll.s.sol:DeployAll", "--broadcast", "--rpc-url", "${ETH_RPC_URL}", "--private-key", "${PRIVATE_KEY}", "--legacy", "--silent"]
    out = plan.exec(
        service_name = constants.FOUNDRY_SERVICE_NAME,
        recipe = ExecRecipe(
            command = ["/bin/sh", "-c", " ".join(command_arr)]
        )
    )

# set the environment variables for contract deployment
def get_env_vars(eth1_url, private_key):
    return {
        "ETH_RPC_URL": eth1_url,
        "PRIVATE_KEY": private_key,
        "MINIMUM_BLOCKS_BEFORE_LIQUIDATION": "100800",
        "MINIMUM_LIQUIDATION_COLLATERAL": "200000000",
        "OPERATOR_MAX_FEE_INCREASE": "3",
        "DECLARE_OPERATOR_FEE_PERIOD": "259200",  # 3 days
        "EXECUTE_OPERATOR_FEE_PERIOD": "345600",  # 4 days
        "VALIDATORS_PER_OPERATOR_LIMIT": "500",
        "OPERATOR_KEYS_FILE": "/app/operator_keys.json"
    }
