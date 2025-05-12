constants = import_module("../utils/constants.star")

def split_keys(plan, keystores, operator_data_artifact, network_address, owner_address, rpc):
    plan.add_service(
        name=constants.ANCHOR_KEYSPLIT_SERVICE,
        config=ServiceConfig(
            image=constants.ANCHOR_IMAGE,
            entrypoint=["tail", "-f", "/dev/null"],
            files={
                "/usr/local/bin/operator_data": operator_data_artifact,
                "/usr/local/bin/keystores": keystores.files_artifact_uuid,
                "/usr/local/bin/keysplit": plan.upload_files("../scripts/keysplit.sh")
            },
            env_vars = {
                "OWNER_ADDRESS": constants.OWNER_ADDRESS,
                "ETH_RPC_URL": rpc
            }
        )
    )

    plan.exec(
        service_name=constants.ANCHOR_KEYSPLIT_SERVICE,
        recipe=ExecRecipe(
            command=["/bin/sh", "-c", "chmod u+x keysplit/keysplit.sh && cd keysplit && ./keysplit.sh"]
        )
    )

    keyshare_artifact = plan.store_service_files(
        service_name = constants.ANCHOR_KEYSPLIT_SERVICE,
        src="/usr/local/bin/keysplit/out.json",
        name="keyshares.json"
    )


    return keyshare_artifact
