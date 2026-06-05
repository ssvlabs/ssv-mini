constants = import_module("../utils/constants.star")

# deploy builds the official ssvlabs/ssv-network@v2.0.0 contract set on the devnet using the repo's
# own hardhat deploy (scripts/deploy-fresh.ts) — the version the aetheria executor's ABI targets
# (hoodi/mainnet). Replaces the stale Zacholme7/ssv-network foundry fork. See ssvlabs/ssv-mini#29.
def deploy(plan, el, genesis_constants, deployer_image_spec):
    plan.add_service(
        name=constants.DEPLOYER_SERVICE_NAME,
        config=ServiceConfig(
            image=deployer_image_spec,
            entrypoint=["tail", "-f", "/dev/null"],
            env_vars={
                # The image patches the `local` hardhat network to read the EL RPC + deployer key.
                "LOCAL_RPC_URL": el,
                "LOCAL_DEPLOYER_KEY": genesis_constants.PRE_FUNDED_ACCOUNTS[1].private_key,
            },
            files={
                # ethers registration scripts (register_operators runs in this service).
                "/app/registration": plan.upload_files("./registration"),
            },
        ),
        description="Starting SSV contract deployer (ssv-network v2.0.0)",
    )

    plan.exec(
        service_name=constants.DEPLOYER_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "npx tsx scripts/deploy-fresh.ts --env local --network local"],
        ),
        description="Deploying SSV contracts (ssv-network v2.0.0, hardhat deploy-fresh)",
    )

    # Surface the deployed addresses (token / network proxy / views proxy + modules) AND fail fast on
    # determinism drift. The deploy is assumed to produce the same addresses every run: registration
    # (interactions.star) targets the hardcoded constants.SSV_NETWORK_PROXY_CONTRACT, and the aetheria
    # orchestrator seed pins these too. If a future ssv-network/hardhat change shifts an address, this
    # turns a silent mis-registration (operators registered against a wrong/empty address) into a loud
    # failure here. deploy-result.json emits EIP-55 checksummed addresses and constants.star holds the
    # same checksummed form (EIP-55 is deterministic), so a direct == matches — no case folding needed.
    # (kurtosis extract takes a simple field path only, no jq functions like ascii_downcase.) Views is
    # consumed by aetheria, not here, so it is guarded on the aetheria side; proxy + token are the ones
    # this stack registers against.
    deployed = plan.exec(
        service_name=constants.DEPLOYER_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "cat deployments/local/deploy-result.json"],
            extract={
                "proxy": ".ssvNetworkProxy",
                "token": ".ssvToken",
            },
        ),
        description="SSV contract addresses (deploy-result.json)",
    )
    plan.verify(
        value=deployed["extract.proxy"],
        assertion="==",
        target_value=constants.SSV_NETWORK_PROXY_CONTRACT,
    )
    plan.verify(
        value=deployed["extract.token"],
        assertion="==",
        target_value=constants.SSV_TOKEN_CONTRACT,
    )
