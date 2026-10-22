#!/usr/bin/env bash
# Records the SSV contract deployment + operator/validator registration as pre-signed raw transactions
# (static/recorded/txs.json), for the use_recorded_txs fast path (contract/recorded.star) and the hive simulator.
#
# The live flow runs hardhat deploy-fresh and the ethers registration scripts against the devnet, waiting for a
# receipt per tx on 12s blocks (~7 min). Everything they send is deterministic: the deployer key (ethereum-package
# PRE_FUNDED_ACCOUNTS[1]), its nonces, the chain id and the static keys never change. So this runs the exact same
# scripts once against anvil (same chain id, 1s blocks) and pulls every signed tx back out; replaying them in
# nonce order lands them all in one or two blocks.
#
# Each tx is tagged with its stage (deploy, operators, validators) so a replay can stop after the operators.
#
# Re-run whenever the deployer image (ssv-network version), the static keys or the keyshares change.
#
# Usage: scripts/record-txs.sh [deployer-image]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/constants.env"
DEPLOYER_IMAGE="${1:-$DEPLOYER_IMAGE}"
OUT="$ROOT/static/recorded"
PORT=18545
CHAIN_ID=3151908
DEPLOYER_KEY=0x39725efee3fb28614de3bacaffe4cc4bd8c436257e2c8bb887c4b5c4be45e76d
DEPLOYER_ADDR=0xE25583099BA105D9ec0A67f5Ae86D90e50036425
RPC="http://127.0.0.1:$PORT"

command -v anvil >/dev/null || { echo "anvil not found (foundryup)"; exit 1; }
mkdir -p "$OUT"

# The scripts price their txs off anvil's fee market, and a replay target starts at a ~1 gwei base fee
# (ethereum-package genesis). With 1s empty blocks anvil's base fee would decay towards zero while the scripts
# run, so it is pinned at 50 gwei, and a recording below MIN_FEE_CAP is rejected. Overpaying is free: the
# deployer has 1e9 ETH. (Mining on demand instead races ethers' 250ms nonce cache: "nonce has already been used".)
MIN_FEE_CAP=2000000000
anvil --chain-id "$CHAIN_ID" --port "$PORT" --host 0.0.0.0 --block-time 1 --gas-limit 60000000 \
  --block-base-fee-per-gas 50000000000 --hardfork prague --silent &
ANVIL_PID=$!
for _ in $(seq 50); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
while true; do cast rpc --rpc-url "$RPC" anvil_setNextBlockBaseFeePerGas 0xba43b7400 >/dev/null 2>&1 || true; sleep 0.3; done &
PIN_PID=$!
trap 'kill $ANVIL_PID $PIN_PID 2>/dev/null || true' EXIT

cast rpc --rpc-url "$RPC" anvil_setBalance "$DEPLOYER_ADDR" 0x33b2e3c9fd0803ce8000000 >/dev/null

keys_json=$(for i in 0 1 2 3; do jq -Rs . < "$ROOT/static/keys/operator-$i/public_key.txt" | jq 'rtrimstr("\n")'; done | jq -s '{publicKeys: .}')

# deployer runs one stage's script in the deployer image against anvil.
deployer() {
  docker run --rm \
    -e LOCAL_RPC_URL="http://host.docker.internal:$PORT" \
    -e LOCAL_DEPLOYER_KEY="$DEPLOYER_KEY" \
    -e SSV_NETWORK_ADDRESS="$SSV_NETWORK_PROXY_CONTRACT" \
    -e KEYSHARES_FILE=/app/keyshares/out.json \
    -e PRE_REGISTER_MANIFEST_FILE=/out/pre-registered.json \
    -e OPERATOR_DATA_FILE=/out/operator_data.json \
    -e OPERATOR_KEYS_JSON="$keys_json" \
    -v "$ROOT/contract/registration:/app/registration:ro" \
    -v "$ROOT/static/keyshares:/app/keyshares:ro" \
    -v "$OUT:/out" \
    --entrypoint /bin/sh "$DEPLOYER_IMAGE" -c "set -e; $1"
}

# The deployer's nonce after each stage splits the recorded txs into stages. The pause guards the next script's
# nonce read (it intermittently got a stale one otherwise).
deployer 'npx tsx scripts/deploy-fresh.ts --env local --network local && cp deployments/local/deploy-result.json /out/deploy-result.json'
sleep 2; NONCE_DEPLOYED=$(cast nonce --rpc-url "$RPC" "$DEPLOYER_ADDR")
deployer 'echo "$OPERATOR_KEYS_JSON" > /app/operator_keys.json && node /app/registration/register-operators.cjs'
sleep 2; NONCE_OPERATORS=$(cast nonce --rpc-url "$RPC" "$DEPLOYER_ADDR")
deployer 'node /app/registration/register-validators.cjs'

proxy=$(jq -r .ssvNetworkProxy "$OUT/deploy-result.json")
[ "$proxy" = "$SSV_NETWORK_PROXY_CONTRACT" ] || { echo "proxy drift: $proxy != $SSV_NETWORK_PROXY_CONTRACT"; exit 1; }

END_BLOCK=$(cast block-number --rpc-url "$RPC")
: > "$OUT/txs.jsonl.tmp"
for b in $(seq 0 "$END_BLOCK"); do
  for h in $(cast block "$b" --rpc-url "$RPC" --json | jq -r '.transactions[]'); do
    raw=$(cast rpc --rpc-url "$RPC" eth_getRawTransactionByHash "$h" | jq -r .)
    nonce=$(cast to-dec "$(cast tx "$h" --rpc-url "$RPC" --json | jq -r .nonce)")
    if [ "$nonce" -lt "$NONCE_DEPLOYED" ]; then stage=deploy
    elif [ "$nonce" -lt "$NONCE_OPERATORS" ]; then stage=operators
    else stage=validators; fi
    fee_cap=$(cast to-dec "$(cast decode-tx "$raw" | jq -r .maxFeePerGas)")
    [ "$fee_cap" -ge "$MIN_FEE_CAP" ] || { echo "tx nonce $nonce: maxFeePerGas $fee_cap < $MIN_FEE_CAP, would stall on the devnet"; exit 1; }
    jq -nc --arg raw "$raw" --arg hash "$h" --arg stage "$stage" --argjson nonce "$nonce" \
      '{stage: $stage, nonce: $nonce, hash: $hash, raw: $raw}' >> "$OUT/txs.jsonl.tmp"
  done
done
jq -s --argjson chainId "$CHAIN_ID" --arg deployer "$DEPLOYER_ADDR" --arg image "$DEPLOYER_IMAGE" \
  '{chainId: $chainId, deployer: $deployer, deployerImage: $image, txs: (sort_by(.nonce))}' "$OUT/txs.jsonl.tmp" > "$OUT/txs.json"
rm "$OUT/txs.jsonl.tmp"
echo "Recorded $(jq -r '[.txs[].stage] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "$OUT/txs.json") txs -> $OUT/txs.json"
