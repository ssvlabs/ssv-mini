# HardHat has problems with node 20 so we use an older version of node
HARDHAT_SERVICE_NAME = "hardhat"


image = ImageBuildSpec(
        image_name="localssv/ssv-network",
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
    "VALIDATORS_PER_OPERATOR_LIMIT": "500"
    }  

# creates a container with Node JS and installs the required depenencies of the hardhat project passed
# plan - is the Kurtosis plan
# hardhat_project_url - a Kurtosis locator to a directory containing the hardhat files (with hardhat.config.ts at the root of the dir)
# env_vars - Optional argument to set some environment variables in the container; can use this to set the RPC_URI as an example
# returns - hardhat_service; a Kurtosis Service object containing .name, .ip_address, .hostname & .ports
def init(plan, eth1_url, blockscout_url):

    env_vars = get_env_vars(eth1_url, blockscout_url)

    hardhat_service = plan.add_service(
        name = "hardhat",
        config = ServiceConfig(
            image = image,
            entrypoint = ["sleep", "999999"],
            env_vars = env_vars,
        )
    )

    return hardhat_service


# runs npx hardhat test with the given contract
# plan - is the Kurtosis plan
# smart_contract - the path to smart_contract relative to the hardhat_project passed to `init`; if you pass nothing it runs all suites via npx hardhat test
# network - the network to run npx hardhat run against; defaults to local
def test(plan, smart_contract = None, network = "devnet"):
    command_arr = ["npx", "hardhat", "test", "--network", network]
    if smart_contract:
        command_arr = ["npx", "hardhat", "test", smart_contract, "--network", network]
    return plan.exec(
        service_name = HARDHAT_SERVICE_NAME,
        recipe = ExecRecipe(
            command = ["/bin/sh", "-c", " ".join(command_arr)]
        )
    )


# runs npx hardhat compile with the given smart contract
# plan is the Kurtosis plan
def compile(plan):
    command_arr = ["npm", "run", "build"]
    return plan.exec(
        service_name = HARDHAT_SERVICE_NAME,
        recipe = ExecRecipe(
            command = ["/bin/sh", "-c", " ".join(command_arr)]
        )
    )


# runs npx hardhat run with the given contract
# plan - is the Kurtosis plan
# smart_contract - the path to smart_contract relative to the hardhat_project passed to `init`
# network - the network to run npx hardhat run against; defaults to local
def run(plan, smart_contract, network = "local"):
    command_arr = ["npx", "hardhat", "run", smart_contract, "--network", network]
    return plan.exec(
        service_name = HARDHAT_SERVICE_NAME,
        recipe = ExecRecipe(
            command = ["/bin/sh", "-c", " ".join(command_arr)]
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
        service_name = HARDHAT_SERVICE_NAME,
        recipe = ExecRecipe(
            command = ["/bin/sh", "-c", " ".join(command_arr)]
        )
    )


# runs npx hardhat run with the given contract
# plan - is the Kurtosis plan
# task_name - the taskname to run
# network - the network to run npx hardhat run against; defaults to local
def deploy(plan):
    command_arr = ["npx", "hardhat", "deploy:all", "--network", "devnet", "--machine true"]
    out = plan.exec(
        service_name = HARDHAT_SERVICE_NAME,
        recipe = ExecRecipe(
            command = ["/bin/sh", "-c", " ".join(command_arr)],
            extract = {
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

def verify(plan, contract_address, network = "local"):
    command_arr = ["npx", "hardhat", "verify", "--network", network, contract_address]
    return plan.exec(
        service_name = HARDHAT_SERVICE_NAME,
        recipe = ExecRecipe(
            command = ["/bin/sh", "-c", " ".join(command_arr)]
        )
    )

def verify_many(plan, contracts):
    command_arr = []
    for contract in contracts:
        cmdarr = "npx hardhat verify --network devnet " + contract
        command_arr.append(cmdarr)


    return plan.exec(
        service_name = HARDHAT_SERVICE_NAME,
        recipe = ExecRecipe(
            command = ["/bin/sh", "-c", " && ".join(command_arr)]
        )
    )

# destroys the hardhat container; running this is optional
def cleanup(plan):
    plan.remove_service(HARDHAT_SERVICE_NAME)