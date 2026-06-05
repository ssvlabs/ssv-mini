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

    # Assert the deployed network proxy + token equal constants.star, failing the run on drift.
    # Registration (interactions.star) targets the hardcoded constants.SSV_NETWORK_PROXY_CONTRACT and
    # the aetheria seed pins these too, yet nothing enforced it — a future ssv-network/hardhat change
    # that shifts an address would silently register operators against the wrong/empty contract.
    # kurtosis ExecRecipe `extract` treats a command's stdout as an opaque string (it can't field-access
    # JSON — only HTTP-recipe bodies get parsed), so parse deploy-result.json in-container with node
    # (the deployer image is node-based) and exit non-zero on mismatch; verifying the exit code makes
    # the failure explicit regardless of exec's default code handling. Views is consumed by aetheria,
    # not here, so its determinism is guarded on the aetheria side.
    addr_check = (
        'const r=require("/app/deployments/local/deploy-result.json");' +
        'const wantProxy="' + constants.SSV_NETWORK_PROXY_CONTRACT + '";' +
        'const wantToken="' + constants.SSV_TOKEN_CONTRACT + '";' +
        'if(r.ssvNetworkProxy!==wantProxy||r.ssvToken!==wantToken){' +
        'console.error("DEPLOY ADDRESS DRIFT: proxy="+r.ssvNetworkProxy+" token="+r.ssvToken);' +
        'process.exit(1)}' +
        'console.log("deployed proxy + token match constants.star: "+r.ssvNetworkProxy+" / "+r.ssvToken)'
    )
    deployed = plan.exec(
        service_name=constants.DEPLOYER_SERVICE_NAME,
        recipe=ExecRecipe(command=["node", "-e", addr_check]),
        description="Assert deployed proxy + token == constants.star (fail-fast on drift)",
    )
    plan.verify(value=deployed["code"], assertion="==", target_value=0)
