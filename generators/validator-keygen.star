NODE_KEYSTORES_OUTPUT_DIRPATH_FORMAT_STR = "/node-keystores"
NODE_UNREGISTERED_KEYSTORES_OUTPUT_DIRPATH_FORMAT_STR = "/node-keystores-unregistered"

PRYSM_PASSWORD = "password"
PRYSM_PASSWORD_FILEPATH_ON_GENERATOR = "/tmp/prysm-password.txt"

KEYSTORES_GENERATION_TOOL_NAME = "/app/eth2-val-tools"

ETH_VAL_TOOLS_IMAGE = "protolambda/eth2-val-tools:latest"
LIGHTHOUSE_IMAGE = "sigp/lighthouse:v7.1.0"

SUCCESSFUL_EXEC_CMD_EXIT_CODE = 0

RAW_KEYS_DIRNAME = "keys"
RAW_SECRETS_DIRNAME = "secrets"

NIMBUS_KEYS_DIRNAME = "nimbus-keys"
PRYSM_DIRNAME = "prysm"

TEKU_KEYS_DIRNAME = "teku-keys"
TEKU_SECRETS_DIRNAME = "teku-secrets"

KEYSTORE_GENERATION_FINISHED_FILEPATH_FORMAT = "/tmp/keystores_generated-{0}-{1}"

SERVICE_NAME_REGSITER = "validator-key-generation-ssv-validator-keystore"    
SERVICE_NAME_UNREGSITER = "validator-key-generation-ssv-validator-keystore-unregistered"    

ENTRYPOINT_ARGS = [
    "sleep",
    "99999",
]

SERVICE_CONFIG = ServiceConfig(
    image=ETH_VAL_TOOLS_IMAGE,
    entrypoint=ENTRYPOINT_ARGS,
    files={},
)

ARTIFACT_PREFIX = 'ssv-validators'


def generate_validator_keystores(plan, mnemonic, start_index, validator_count, register=True):
    if register:
        service_name = SERVICE_NAME_REGSITER
        output_dirpath = NODE_KEYSTORES_OUTPUT_DIRPATH_FORMAT_STR
    else:
        service_name = SERVICE_NAME_UNREGSITER
        output_dirpath = NODE_UNREGISTERED_KEYSTORES_OUTPUT_DIRPATH_FORMAT_STR
    
    plan.add_service(service_name, SERVICE_CONFIG)

    stop_index = start_index + validator_count

    generate_keystores_cmd = '{0} keystores --insecure --prysm-pass {1} --out-loc {2} --source-mnemonic "{3}" --source-min {4} --source-max {5}'.format(
        KEYSTORES_GENERATION_TOOL_NAME,
        PRYSM_PASSWORD,
        output_dirpath ,
        mnemonic,
        start_index,
        stop_index,
    )
    teku_permissions_cmd = (
            "chmod 0777 -R " + output_dirpath  + "/" + TEKU_KEYS_DIRNAME
    )
    raw_secret_permissions_cmd = (
            "chmod 0600 -R " + output_dirpath  + "/" + RAW_SECRETS_DIRNAME
    )

    all_sub_command_strs = [generate_keystores_cmd, teku_permissions_cmd, raw_secret_permissions_cmd]

    command_str = " && ".join(all_sub_command_strs)

    command_result = plan.exec(
        recipe=ExecRecipe(command=["sh", "-c", command_str]), service_name=service_name
    )
    plan.verify(command_result["code"], "==", SUCCESSFUL_EXEC_CMD_EXIT_CODE)

    artifact_name = "{0}-{1}-{2}".format(
        ARTIFACT_PREFIX,
        start_index,
        stop_index - 1,
    )
    artifact_name = plan.store_service_files(
        service_name, output_dirpath , name=artifact_name
    )

    base_dirname_in_artifact = path_base(output_dirpath )
    keystore_files = struct(
        files_artifact_uuid=artifact_name,
        raw_root_dirpath=path_join(base_dirname_in_artifact),
        raw_keys_relative_dirpath=path_join(base_dirname_in_artifact, RAW_KEYS_DIRNAME),
        raw_secrets_relative_dirpath=path_join(base_dirname_in_artifact, RAW_SECRETS_DIRNAME),
        nimbus_keys_relative_dirpath=path_join(base_dirname_in_artifact, NIMBUS_KEYS_DIRNAME),
        prysm_relative_dirpath=path_join(base_dirname_in_artifact, PRYSM_DIRNAME),
        teku_keys_relative_dirpath=path_join(base_dirname_in_artifact, TEKU_KEYS_DIRNAME),
        teku_secrets_relative_dirpath=path_join(base_dirname_in_artifact, TEKU_SECRETS_DIRNAME),
    )

    return keystore_files


def generate_unregistered_validator_keystores_uniform(plan, mnemonic, start_index, validator_count, password):
    service_name = SERVICE_NAME_UNREGSITER
    output_dirpath = NODE_UNREGISTERED_KEYSTORES_OUTPUT_DIRPATH_FORMAT_STR

    # Start a dormant Lighthouse container to generate EIP-2335 keystores with a uniform password
    plan.add_service(service_name, ServiceConfig(
        image=LIGHTHOUSE_IMAGE,
        entrypoint=["tail", "-f", "/dev/null"],
        env_vars={
            "MNEMONIC": mnemonic,
            "UNIFORM_PASSWORD": password,
        },
    ))

    stop_index = start_index + validator_count

    # Generate validators into Lighthouse's default structure under output_dirpath
    # Then align directories to match expected structure (keys + secrets)
    gen_cmd = (
        "mkdir -p {out} {out}/vm && "
        + "printf '%s\n' \"$MNEMONIC\" > /tmp/mnemonic.txt && "
        + "printf '%s\n' \"$UNIFORM_PASSWORD\" > /tmp/pw && "
        + "cat /tmp/pw | lighthouse validator_manager create "
        + "--output-path {out}/vm "
        + "--first-index {start} --count {count} "
        + "--mnemonic-path /tmp/mnemonic.txt "
        + "--stdin-inputs --specify-voting-keystore-password "
        + "--disable-deposits --force-bls-withdrawal-credentials && "
        + "(command -v jq >/dev/null 2>&1 || (apk add --no-cache jq) || (apt-get update -y && apt-get install -y jq) || (apt update -y && apt install -y jq)) && "
        + "mkdir -p {out}/keys {out}/secrets && "
        + "jq -c '.[]' {out}/vm/validators.json | while read -r item; do "
        + "pub=$(echo \"$item\" | jq -r '.voting_keystore | fromjson | .pubkey'); "
        + "pass=$(echo \"$item\" | jq -r '.voting_keystore_password'); "
        + "pk=0x${{pub#0x}}; mkdir -p {out}/keys/$pk; "
        + "echo \"$pass\" > {out}/secrets/$pk; "
        + "echo \"$item\" | jq -r '.voting_keystore' > {out}/keys/$pk/voting-keystore.json; "
        + "done"
    ).format(out=output_dirpath, start=str(start_index), count=str(validator_count))

    command_result = plan.exec(
        recipe=ExecRecipe(command=["sh", "-c", gen_cmd]), service_name=service_name
    )
    plan.verify(command_result["code"], "==", SUCCESSFUL_EXEC_CMD_EXIT_CODE)

    artifact_name = "{0}-{1}-{2}".format(
        ARTIFACT_PREFIX,
        start_index,
        stop_index - 1,
    )
    artifact_name = plan.store_service_files(
        service_name, output_dirpath, name=artifact_name
    )

    base_dirname_in_artifact = path_base(output_dirpath)
    keystore_files = struct(
        files_artifact_uuid=artifact_name,
        raw_root_dirpath=path_join(base_dirname_in_artifact),
        raw_keys_relative_dirpath=path_join(base_dirname_in_artifact, RAW_KEYS_DIRNAME),
        raw_secrets_relative_dirpath=path_join(base_dirname_in_artifact, RAW_SECRETS_DIRNAME),
        nimbus_keys_relative_dirpath=path_join(base_dirname_in_artifact, NIMBUS_KEYS_DIRNAME),
        prysm_relative_dirpath=path_join(base_dirname_in_artifact, PRYSM_DIRNAME),
        teku_keys_relative_dirpath=path_join(base_dirname_in_artifact, TEKU_KEYS_DIRNAME),
        teku_secrets_relative_dirpath=path_join(base_dirname_in_artifact, TEKU_SECRETS_DIRNAME),
    )

    return keystore_files


def path_join(*args):
    joined_path = "/".join(args)
    return joined_path.replace("//", "/")


def path_base(path):
    split_path = path.split("/")
    return split_path[-1]
