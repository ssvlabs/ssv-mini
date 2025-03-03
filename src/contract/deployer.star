# HardHat has problems with node 20 so we use an older version of node
HARDHAT_SERVICE_NAME = "hardhat"

image = ImageBuildSpec(
    image_name="localssv/contracts",
    build_context_dir="./",
    build_file="Dockerfile.contract",
)


def get_env_vars(eth1_url, blockscout_url):
    return {
        "GAS_PRICE": "2000000",
        "GAS": "50000000000",
        "DEVNET_ETH_NODE_URL": eth1_url,
        "BLOCKSCOUT_URL": blockscout_url,
        "MINIMUM_BLOCKS_BEFORE_LIQUIDATION": "100800",
        "MINIMUM_LIQUIDATION_COLLATERAL": "200000000",
        "OPERATOR_MAX_FEE_INCREASE": "3",
        "DECLARE_OPERATOR_FEE_PERIOD": "259200",  # 3 days
        "EXECUTE_OPERATOR_FEE_PERIOD": "345600",  # 4 days
        "VALIDATORS_PER_OPERATOR_LIMIT": "500",
        "KEYSTORE_PATH": "/usr/src/app/keystores/teku-keys/",
        "PASSWORDS_PATH": "/usr/src/app/keystores/teku-secrets/",
    }


def register_operators(plan,
                       operator_public_keys,
                       genesis_constants,
                       ssv_network_address,
                       el_url,
                       network="kurtosis"):

    # TODO: set keys in a loop, something like this:
    #     for index, public_key in enumerate(operator_public_keys):
    #         env_var = "OPERATOR_" + str(index) + "_PUBLIC_KEY=" + public_key
    #         env_vars_commands.append(env_var)
    env_vars_commands = ["SSV_NODE_COUNT=" + str(len(operator_public_keys)),
                         "OWNER_PRIVATE_KEY=" + genesis_constants.PRE_FUNDED_ACCOUNTS[1].private_key, # contracts are deployed using genesis_constants.PRE_FUNDED_ACCOUNTS[1]
                         "SSV_NETWORK_ADDRESS_STAGE=" + ssv_network_address,
                         "OPERATOR_1_PUBLIC_KEY=" + operator_public_keys[0].rstrip(),  # TODO: don't hardcode indices
                         "OPERATOR_2_PUBLIC_KEY=" + operator_public_keys[1].rstrip(),
                         "OPERATOR_3_PUBLIC_KEY=" + operator_public_keys[2].rstrip(),
                         "OPERATOR_4_PUBLIC_KEY=" + operator_public_keys[3].rstrip(),
                         "RPC_URI=" + el_url
                         ]

    plan.print("env for registering operators")
    plan.print(env_vars_commands)

    for env in env_vars_commands: # useful for debugging
        exec_result = plan.exec(
            service_name=HARDHAT_SERVICE_NAME,
            recipe=ExecRecipe(
                command=["/bin/sh", "-c", "echo " + env + " >> .env"]
            )
        )

    env_vars_str = " ".join(env_vars_commands)
    register_operators_script_path = "scripts/register-operators.ts"
    hardhat_command = env_vars_str + " npx hardhat run " + register_operators_script_path + " --network " + network

    plan.print("Registering operators with the smart contract...", hardhat_command)
    exec_result = plan.exec(
        service_name=HARDHAT_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", hardhat_command]
        )
    )

    register_exec_output = exec_result.get("output", "No output provided.")
    plan.print("Operator registration output:\n" + register_exec_output)
    plan.print("Operator registration process completed.")


def register_validators(plan,
                       genesis_constants,
                       ssv_token_address,
                       ssv_network_address,
                       el_url,
                       network="kurtosis"):

    # TODO: set keys in a loop, something like this:
    #     for index, public_key in enumerate(operator_public_keys):
    #         env_var = "OPERATOR_" + str(index) + "_PUBLIC_KEY=" + public_key
    #         env_vars_commands.append(env_var)
    env_vars_commands = [
                         "OWNER_PRIVATE_KEY=" + genesis_constants.PRE_FUNDED_ACCOUNTS[1].private_key, # contracts are deployed using genesis_constants.PRE_FUNDED_ACCOUNTS[1]
                         "SSV_TOKEN_ADDRESS=" + ssv_token_address,
                         "SSV_NETWORK_ADDRESS_STAGE=" + ssv_network_address,
                         "RPC_URI=" + el_url,
                         "KEYSTORE_PATH=" + "/usr/src/app/keystores/teku-keys/"
                         ]

    plan.print("env for registering validators")
    plan.print(env_vars_commands)

    for env in env_vars_commands: # useful for debugging
        exec_result = plan.exec(
            service_name=HARDHAT_SERVICE_NAME,
            recipe=ExecRecipe(
                command=["/bin/sh", "-c", "echo " + env + " >> .env"]
            )
        )

    env_vars_str = " ".join(env_vars_commands)
    register_operators_script_path = "scripts/register-validators.ts"
    hardhat_command = env_vars_str + " npx hardhat run " + register_operators_script_path + " --network " + network

    plan.print("Registering operators with the smart contract...", hardhat_command)
    exec_result = plan.exec(
        service_name=HARDHAT_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", hardhat_command]
        )
    )

    register_exec_output = exec_result.get("output", "No output provided.")
    plan.print("validator registration output:\n" + register_exec_output)
    plan.print("validator registration process completed.")

# creates a container with Node JS and installs the required depenencies of the hardhat project passed
# plan - is the Kurtosis plan
# hardhat_project_url - a Kurtosis locator to a directory containing the hardhat files (with hardhat.config.ts at the root of the dir)
# env_vars - Optional argument to set some environment variables in the container; can use this to set the RPC_URI as an example
# returns - hardhat_service; a Kurtosis Service object containing .name, .ip_address, .hostname & .ports
def run(plan, eth1_url, blockscout_url, deployAll=False, keystore_files=None):
    scripts_project_dir = "./scripts"
    scripts_files = plan.upload_files(scripts_project_dir)

    scripts_image_dir = "/usr/src/app/scripts"
    keystore_dir = "/usr/src/app/keystores"
    files = {
        scripts_image_dir: scripts_files,
        keystore_dir: keystore_files.files_artifact_uuid
    }

    env_vars = get_env_vars(eth1_url, blockscout_url)

    hardhat_service = plan.add_service(
        name="hardhat",
        config=ServiceConfig(
            image=image,
            entrypoint=["sleep", "999999"],
            files=files,
            env_vars=env_vars,
        )
    )

    compile(plan)
    if deployAll:
        contracts = deploy(plan)
        return contracts
    # skipping verification for now as its too slow and sometimes fails
    #verify_many(plan, [contracts.ssvTokenAddress, contracts.operatorsModAddress, contracts.clustersModAddress,
    #contracts.daoModAddress, contracts.viewsModAddress, contracts.ssvNetworkAddress])xr

    return


# runs npx hardhat test with the given contract
# plan - is the Kurtosis plan
# smart_contract - the path to smart_contract relative to the hardhat_project passed to `init`; if you pass nothing it runs all suites via npx hardhat test
# network - the network to run npx hardhat run against; defaults to local
def test(plan, smart_contract=None, network="kurtosis"):
    command_arr = ["npx", "hardhat", "test", "--network", network]
    if smart_contract:
        command_arr = ["npx", "hardhat", "test", smart_contract, "--network", network]
    return plan.exec(
        service_name=HARDHAT_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", " ".join(command_arr)]
        )
    )


# runs npx hardhat compile with the given smart contract
# plan is the Kurtosis plan
def compile(plan):
    command_arr = ["npm", "run", "build" ]
    return plan.exec(
        service_name=HARDHAT_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", " ".join(command_arr)]
        )
    )


# runs npx hardhat run with the given contract
# plan - is the Kurtosis plan
# smart_contract - the path to smart_contract relative to the hardhat_project passed to `init`
# network - the network to run npx hardhat run against; defaults to local
def npx_run(plan, smart_contract, network="kurtosis"):
    command_arr = ["npx", "hardhat", "run", smart_contract, "--network", network]
    return plan.exec(
        service_name=HARDHAT_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", " ".join(command_arr)]
        )
    )

    # runs npx hardhat run with the given contract


# plan - is the Kurtosis plan
# smart_contract - the path to smart_contract relative to the hardhat_project passed to `init`
# network - the network to run npx hardhat run against; defaults to local
def script(plan, script_path, args=[]):
    command_arr = ["npx ts-node", script_path]
    command_arr += args
    return plan.exec(
        service_name=HARDHAT_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", " ".join(command_arr)]
        )
    )


# runs npx hardhat run with the given contract
# plan - is the Kurtosis plan
# task_name - the taskname to run
# network - the network to run npx hardhat run against; defaults to local
def deploy(plan):
    command_arr = ["npx", "hardhat", "deploy:all", "--network", "kurtosis", "--machine true"]
    out = plan.exec(
        service_name=HARDHAT_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", " ".join(command_arr)],
            extract={
                "ssvTokenAddress": "fromjson | .ssvTokenAddress",
                "operatorsModAddress": "fromjson | .operatorsModAddress",
                "clustersModAddress": "fromjson | .clustersModAddress",
                "daoModAddress": "fromjson | .daoModAddress",
                "viewsModAddress": "fromjson | .viewsModAddress",
                "ssvNetworkAddress": "fromjson | .ssvNetworkAddress"
            }
        )
    )
    return struct(
        ssvTokenAddress=out["extract.ssvTokenAddress"],
        operatorsModAddress=out["extract.operatorsModAddress"],
        clustersModAddress=out["extract.clustersModAddress"],
        daoModAddress=out["extract.daoModAddress"],
        viewsModAddress=out["extract.viewsModAddress"],
        ssvNetworkAddress=out["extract.ssvNetworkAddress"]
    )


def verify(plan, contract_address, network="kurtosis"):
    command_arr = ["npx", "hardhat", "verify", "--network", network, contract_address]
    return plan.exec(
        service_name=HARDHAT_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", " ".join(command_arr)]
        )
    )


def verify_many(plan, contracts, network="kurtosis"):
    for contract in contracts:
        command_arr = ["npx", "hardhat", "verify", "--network", network, contract]
        plan.exec(
        service_name=HARDHAT_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", " ".join(command_arr)]
        )
    )


# destroys the hardhat container; running this is optional
def cleanup(plan):
    plan.remove_service(HARDHAT_SERVICE_NAME)
