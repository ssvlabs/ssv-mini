constants = import_module("../utils/constants.star")

FOUNDRY_IMAGE = "ghcr.io/foundry-rs/foundry:latest"

# Optionally supply a deposits JSON artifact containing an array of objects with
# keys: pubkey, withdrawal_credentials, signature, deposit_data_root (0x-prefixed)
def start_deposit_bot(plan, el_rpc_url, deposit_contract_address, private_key, count=1, interval_seconds=1, deposits_json_artifact=None):
    """
    Starts a lightweight service that submits deposits from a JSON file using cast.
    The JSON file is expected to contain an array of objects with fields:
    pubkey (0x...), withdrawal_credentials (0x...), signature (0x...), deposit_data_root (0x...)
    """
    service_name = "deposit-bot"
    script = """
#!/bin/sh
set -eu
COUNT=${COUNT:-4}
DEPOSITS_JSON=${DEPOSITS_JSON:-/deposits/deposits.json}

if [ ! -f "$DEPOSITS_JSON" ]; then
  print "deposits file does not exist, exiting"
  exit 1
fi
  
echo "submitting deposits from JSON: $DEPOSITS_JSON (limit=$COUNT)"
normalize() {
case "$1" in
  0x*|0X*) echo "$1" ;;
  *) echo "0x$1" ;;
esac
}

JSON=$(tr -d ' \n\t' < "$DEPOSITS_JSON")
idx=1
while [ $idx -le $COUNT ]; do
  PUBKEY=$(printf "%s" "$JSON" | grep -o '"pubkey":"[^"]*"' | sed 's/"pubkey":"//' | sed 's/"$//' | sed -n "${idx}p")
  WITHDRAW=$(printf "%s" "$JSON" | grep -o '"withdrawal_credentials":"[^"]*"' | sed 's/"withdrawal_credentials":"//' | sed 's/"$//' | sed -n "${idx}p")
  SIG=$(printf "%s" "$JSON" | grep -o '"signature":"[^"]*"' | sed 's/"signature":"//' | sed 's/"$//' | sed -n "${idx}p")
  ROOT=$(printf "%s" "$JSON" | grep -o '"deposit_data_root":"[^"]*"' | sed 's/"deposit_data_root":"//' | sed 's/"$//' | sed -n "${idx}p")
  [ -z "$PUBKEY" ] && break
  PUBKEY=$(normalize "$PUBKEY"); WITHDRAW=$(normalize "$WITHDRAW"); SIG=$(normalize "$SIG"); ROOT=$(normalize "$ROOT")
  echo "deposit: $PUBKEY"
  cast send \
    --rpc-url "$ETH_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --value 32000000000000000000 \
    "$DEPOSIT_CONTRACT" "deposit(bytes,bytes,bytes,bytes32)" "$PUBKEY" "$WITHDRAW" "$SIG" "$ROOT" || true
  sleep "$INTERVAL"
  idx=$((idx+1))
done

echo "done"; tail -f /dev/null
"""

    # Create a files artifact containing run.sh using render_templates
    run_artifact = plan.render_templates({
        "run.sh": struct(template=script, data={}),
    }, name="deposit-bot-run-sh")
    files = { "/scripts": run_artifact }
    # Optionally mount deposits JSON under /deposits
    if deposits_json_artifact != None:
        files["/deposits"] = deposits_json_artifact

    env = {
        "ETH_RPC_URL": el_rpc_url,
        "PRIVATE_KEY": private_key,
        "DEPOSIT_CONTRACT": deposit_contract_address,
        "INTERVAL": str(interval_seconds),
        "COUNT": str(count),
    }

    plan.add_service(
        name=service_name,
        config=ServiceConfig(
            image=FOUNDRY_IMAGE,
            entrypoint=["/bin/sh","/scripts/run.sh"],
            env_vars=env,
            files=files,
        )
    )

def generate_deposits_with_eth2_val_tools(plan, mnemonic, start_index, count, fork_version, withdrawal_address):
    """
    Uses protolambda/eth2-val-tools to generate deposit-data JSON for `count` validators
    from the given mnemonic. Returns a files artifact containing deposits.json.
    """
    SERVICE_NAME = "deposit-gen"
    # Use a public image that exists on Docker Hub
    IMAGE = "protolambda/eth2-val-tools:latest"
    TOOL = "/app/eth2-val-tools"
    plan.add_service(
        name=SERVICE_NAME,
        config=ServiceConfig(
            image=IMAGE,
            entrypoint=["sleep","99999"],
        )
    )

    out_dir = "/out"
    out_file = out_dir + "/deposits.json"
    stop_index = start_index + count
    # eth2-val-tools: write JSON array to STDOUT; redirect to file
    cmd = (
        "mkdir -p {out} && {tool} deposit-data "
        + "--validators-mnemonic \"{mnemo}\" --source-min {start} --source-max {stop} "
        + "--fork-version {fork} --amount 32000000000 --withdrawal-credentials-type 0x01 "
        + "--withdrawal-address {waddr} --as-json-list > {ofile}"
    )
    cmd = cmd.format(
        out=out_dir,
        tool=TOOL,
        mnemo=mnemonic,
        start=start_index,
        stop=stop_index,
        fork=fork_version,
        waddr=withdrawal_address,
        ofile=out_file,
    )

    plan.exec(service_name=SERVICE_NAME, recipe=ExecRecipe(command=["sh","-c", cmd]))

    artifact = plan.store_service_files(service_name=SERVICE_NAME, src=out_dir, name="deposits")
    return artifact
