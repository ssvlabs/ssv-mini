constants = import_module("../utils/constants.star")
utils = import_module("../utils/utils.star")

# register_operators registers the SSV operators on-chain via the ethers script
# (register-operators.cjs) in the node-based deployer image, and returns the operator_data.json
# artifact (id + publicKey per operator) the rest of ssv-mini consumes.
def register_operators(plan, public_keys, network_address):
    quoted_keys = []
    for key in public_keys:
        quoted_keys.append('"{}"'.format(key))

    json_content = '{{"publicKeys": [{}]}}'.format(", ".join(quoted_keys))
    plan.exec(
        service_name=constants.DEPLOYER_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "echo '{}' > /app/operator_keys.json".format(json_content)],
        ),
        description="Writing {} operator public keys".format(len(public_keys)),
    )

    plan.exec(
        service_name=constants.DEPLOYER_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "SSV_NETWORK_ADDRESS={} node /app/registration/register-operators.cjs".format(network_address)],
        ),
        description="Registering {} operators on-chain (ethers)".format(len(public_keys)),
    )

    operator_data_artifact = plan.store_service_files(
        service_name=constants.DEPLOYER_SERVICE_NAME,
        src="/app/operator_data.json",
        name="operator_data.json",
        description="Storing operator registration data",
    )

    return operator_data_artifact


# register_validators bulk-registers the keyshare validators on-chain via the ethers script
# (register-validators.cjs) in a node-based service with the keyshares mounted, then publishes the
# split-point manifest and RETURNS its enclave files artifact (name: pre-registered.json).
#
# Gated behind pre_register_validators (default off, main.star Step 4): when set, bulk-registers
# the static keyshares on-chain at bring-up so a standalone `kurtosis run` (no aetheria executor)
# yields operators that actually run validators. Off by default because the executor registers and
# funds its own validators. Devnet pre-registration tracked under #29.
#
# The manifest (preRegisteredCount N, poolSize, cohortP/cohortD pubkeys) gives the split point N an
# enclave-visible source of truth so the aetheria executor reads the real N instead of re-declaring it
# across repos (ssvlabs/ssv-mini#53).
def register_validators(plan, keyshare_artifact, network_address, rpc, genesis_constants, args):
    # Pre-register only the first pre_register_count keyshares (P) when set (>0); the rest are left for
    # the aetheria executor to register as its own cohort (D). Default 0 → PRE_REGISTER_COUNT unset →
    # register-validators.cjs registers the full set (the original behaviour). See that script / #176.
    # Write the manifest to /app (the image's writable layer, like operator_data.json) rather than into the
    # /app/keyshares artifact mount, whose writability isn't guaranteed. The consumer downloads it by artifact
    # name, so the internal path doesn't matter.
    manifest_file = "/app/pre-registered.json"
    env_vars = {
        "LOCAL_RPC_URL": rpc,
        "LOCAL_DEPLOYER_KEY": genesis_constants.PRE_FUNDED_ACCOUNTS[1].private_key,
        "SSV_NETWORK_ADDRESS": network_address,
        "KEYSHARES_FILE": "/app/keyshares/out.json",
        "PRE_REGISTER_MANIFEST_FILE": manifest_file,
    }
    pre_register_count = args.get("pre_register_count", 0)
    if pre_register_count > 0:
        env_vars["PRE_REGISTER_COUNT"] = str(pre_register_count)

    plan.add_service(
        name=constants.REGISTER_VALIDATOR_SERVICE_NAME,
        config=ServiceConfig(
            image=utils.get_deployer_image_spec(args),
            entrypoint=["tail", "-f", "/dev/null"],
            env_vars=env_vars,
            files={
                "/app/registration": plan.upload_files("./registration"),
                "/app/keyshares": keyshare_artifact,
            },
        ),
        description="Starting validator registration service",
    )

    plan.exec(
        service_name=constants.REGISTER_VALIDATOR_SERVICE_NAME,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "node /app/registration/register-validators.cjs"],
        ),
        description="Registering {} validator(s) on-chain (ethers)".format(str(pre_register_count) if pre_register_count > 0 else "all"),
    )

    # Store the manifest register-validators.cjs just wrote as a named enclave artifact, BEFORE main.star
    # removes this service (N would otherwise vanish with the teardown). The aetheria executor fetches it
    # with `kurtosis files download <enclave> pre-registered.json` (ssvlabs/ssv-mini#53).
    return plan.store_service_files(
        service_name=constants.REGISTER_VALIDATOR_SERVICE_NAME,
        src=manifest_file,
        name="pre-registered.json",
        description="Storing the pre-registration manifest (split point N + cohort P/D pubkeys)",
    )
