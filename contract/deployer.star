constants = import_module("../utils/constants.star")

# deploy builds the official ssvlabs/ssv-network@v2.0.0 contract set on the devnet using the repo's
# own hardhat deploy (scripts/deploy-fresh.ts) — the version the aetheria executor's ABI targets
# (hoodi/mainnet). Replaces the stale Zacholme7/ssv-network foundry fork. See ssvlabs/ssv-mini#29.
def deploy(plan, el, genesis_constants, deployer_image_spec):
    plan.add_service(
        name=constants.FOUNDRY_SERVICE_NAME,
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
        service_name=constants.FOUNDRY_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "npx tsx scripts/deploy-fresh.ts --env local --network local"],
        ),
        description="Deploying SSV contracts (ssv-network v2.0.0, hardhat deploy-fresh)",
    )

    # Surface the deployed addresses (token / network proxy / views proxy + modules) so they can be
    # pinned in utils/constants.star + the aetheria orchestrator seed.
    plan.exec(
        service_name=constants.FOUNDRY_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "cat deployments/local/deploy-result.json"],
        ),
        description="SSV contract addresses (deploy-result.json)",
    )
