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
# The recording isn't committed: `make run` (with use_recorded_txs), hive/run.sh and bench-kurtosis.sh call this
# with --if-stale, which records only when an input changed (the deployer Dockerfile, the registration scripts,
# the static keys/keyshares, the pinned addresses, this script). Needs docker and jq; anvil runs in a container.
#
# Each run records into its own temp dir and only moves txs.json + pre-registered.json into static/recorded/
# once the recording passed its checks, writing the fingerprint last. So concurrent runs (parallel
# bench-kurtosis.sh, make run next to hive/run.sh) can't interleave their output, and a failed run never leaves
# a recording that --if-stale would call up to date. Recording twice is harmless: the txs are deterministic.
#
# Limit: the validators stage must be a single tx, i.e. a pool of at most 50 validators (BATCH_SIZE in
# register-validators.cjs). From the second batch on, the script passes the cluster snapshot it read back after
# the previous batch, and that snapshot depends on block numbers (operator fee index), which the replay changes.
# A multi-batch recording would revert on replay with IncorrectClusterState, so it is refused here.
#
# Usage: scripts/record-txs.sh [--if-stale]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/constants.env"
OUT="$ROOT/static/recorded"
CHAIN_ID=3151908
DEPLOYER_KEY=0x39725efee3fb28614de3bacaffe4cc4bd8c436257e2c8bb887c4b5c4be45e76d
DEPLOYER_ADDR=0xE25583099BA105D9ec0A67f5Ae86D90e50036425
RPC=http://127.0.0.1:8545 # anvil, as seen from inside its own container (every cast call runs there)

# fingerprint hashes everything that determines the recorded txs.
fingerprint() {
  (
    cd "$ROOT"
    printf '%s\n' "$DEPLOYER_IMAGE" "$FOUNDRY_IMAGE" "$SSV_NETWORK_PROXY_CONTRACT" "$SSV_TOKEN_CONTRACT" "$CHAIN_ID"
    find contract/Dockerfile.contract contract/registration scripts/record-txs.sh \
      static/keys static/keyshares/out.json -type f | LC_ALL=C sort | xargs shasum -a 256
  ) | shasum -a 256 | cut -d' ' -f1
}

WANT=$(fingerprint)
if [ "${1:-}" = "--if-stale" ] && [ -f "$OUT/txs.json" ] && [ -f "$OUT/pre-registered.json" ] \
  && [ "$(cat "$OUT/fingerprint" 2>/dev/null)" = "$WANT" ]; then
  echo "Recorded txs up to date ($OUT/txs.json)"
  exit 0
fi
command -v jq >/dev/null || { echo "jq not found"; exit 1; }
echo "Recording the SSV deployment + registrations against anvil (~1-2 min)..."
mkdir -p "$OUT"
# Private to this run, inside static/recorded/ so the final mv is a same-filesystem rename and Docker can mount it.
WORK=$(mktemp -d "$OUT/.record.XXXXXX")
trap 'rm -rf "$WORK"' EXIT # replaced by cleanup() below, which removes it too

# The same image the Kurtosis deployer service builds (contract/Dockerfile.contract). --load, like every build
# in the Makefile: with a docker-container buildx builder selected, a plain build stays in the build cache and
# the deployer below would run whatever stale localssv/ssv-network is in the image store. The legacy builder
# rejects --load but always loads, so it is passed only where `docker build` accepts it (the Makefile's
# check-buildx probe).
# (A plain string, not an array: "${arr[@]}" on an empty array trips set -u on macOS' bash 3.2.)
LOAD=
if docker build --help 2>/dev/null | grep -q -- '--load'; then LOAD=--load; fi
docker build -q $LOAD -t "$DEPLOYER_IMAGE" -f "$ROOT/contract/Dockerfile.contract" "$ROOT/contract" >/dev/null

NET="ssv-mini-record-$$"
ANVIL="ssv-mini-record-anvil-$$"
PIN_PID=
cleanup() {
  [ -n "$PIN_PID" ] && kill "$PIN_PID" 2>/dev/null || true
  docker rm -f "$ANVIL" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
docker network create "$NET" >/dev/null

# The scripts price their txs off anvil's fee market, and a replay target starts at a ~1 gwei base fee
# (ethereum-package genesis). With 1s empty blocks anvil's base fee would decay towards zero while the scripts
# run, so it is pinned at 50 gwei, and a recording below MIN_FEE_CAP is rejected. Overpaying is free: the
# deployer has 1e9 ETH. (Mining on demand instead races ethers' 250ms nonce cache: "nonce has already been used".)
MIN_FEE_CAP=2000000000
docker run -d --name "$ANVIL" --network "$NET" --entrypoint anvil "$FOUNDRY_IMAGE" \
  --chain-id "$CHAIN_ID" --host 0.0.0.0 --port 8545 --block-time 1 --gas-limit 60000000 \
  --block-base-fee-per-gas 50000000000 --hardfork prague --silent >/dev/null
cast() { docker exec "$ANVIL" cast "$@"; }
for _ in $(seq 50); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
while true; do cast rpc --rpc-url "$RPC" anvil_setNextBlockBaseFeePerGas 0xba43b7400 >/dev/null 2>&1 || true; sleep 0.3; done &
PIN_PID=$!

cast rpc --rpc-url "$RPC" anvil_setBalance "$DEPLOYER_ADDR" 0x33b2e3c9fd0803ce8000000 >/dev/null

keys_json=$(for i in 0 1 2 3; do jq -Rs . < "$ROOT/static/keys/operator-$i/public_key.txt" | jq 'rtrimstr("\n")'; done | jq -s '{publicKeys: .}')

# deployer runs one stage's script in the deployer image against anvil.
deployer() {
  docker run --rm --network "$NET" \
    -e LOCAL_RPC_URL="http://$ANVIL:8545" \
    -e LOCAL_DEPLOYER_KEY="$DEPLOYER_KEY" \
    -e SSV_NETWORK_ADDRESS="$SSV_NETWORK_PROXY_CONTRACT" \
    -e KEYSHARES_FILE=/app/keyshares/out.json \
    -e PRE_REGISTER_MANIFEST_FILE=/out/pre-registered.json \
    -e OPERATOR_DATA_FILE=/out/operator_data.json \
    -e OPERATOR_KEYS_JSON="$keys_json" \
    -v "$ROOT/contract/registration:/app/registration:ro" \
    -v "$ROOT/static/keyshares:/app/keyshares:ro" \
    -v "$WORK:/out" \
    --entrypoint /bin/sh "$DEPLOYER_IMAGE" -c "set -e; $1"
}

# The deployer's nonce after each stage splits the recorded txs into stages. The pause guards the next script's
# nonce read (it intermittently got a stale one otherwise).
deployer 'npx tsx scripts/deploy-fresh.ts --env local --network local && cp deployments/local/deploy-result.json /out/deploy-result.json'
sleep 2; NONCE_DEPLOYED=$(cast nonce --rpc-url "$RPC" "$DEPLOYER_ADDR")
deployer 'echo "$OPERATOR_KEYS_JSON" > /app/operator_keys.json && node /app/registration/register-operators.cjs'
sleep 2; NONCE_OPERATORS=$(cast nonce --rpc-url "$RPC" "$DEPLOYER_ADDR")
deployer 'node /app/registration/register-validators.cjs'

sleep 2; NONCE_FINAL=$(cast nonce --rpc-url "$RPC" "$DEPLOYER_ADDR")

# Same check as deployer.star: the replay and the SSV nodes use the pinned addresses.
proxy=$(jq -r .ssvNetworkProxy "$WORK/deploy-result.json")
token=$(jq -r .ssvToken "$WORK/deploy-result.json")
[ "$proxy" = "$SSV_NETWORK_PROXY_CONTRACT" ] || { echo "proxy drift: $proxy != $SSV_NETWORK_PROXY_CONTRACT"; exit 1; }
[ "$token" = "$SSV_TOKEN_CONTRACT" ] || { echo "token drift: $token != $SSV_TOKEN_CONTRACT"; exit 1; }
[ -s "$WORK/pre-registered.json" ] || { echo "register-validators.cjs wrote no pre-registered.json"; exit 1; }

# Osaka caps a tx at 2^24 gas (EIP-7825). anvil runs prague, so it would accept a bigger one the devnet rejects.
MAX_TX_GAS=16777216
# Every command substitution below is assigned on its own line: `set -e` doesn't see a failure inside a
# `for x in $(...)` list, which would silently drop that block's txs (the completeness check backs this up).
END_BLOCK=$(cast block-number --rpc-url "$RPC")
: >| "$WORK/txs.jsonl"
for b in $(seq 0 "$END_BLOCK"); do
  hashes=$(cast block "$b" --rpc-url "$RPC" --json | jq -r '.transactions[]')
  for h in $hashes; do
    raw=$(cast rpc --rpc-url "$RPC" eth_getRawTransactionByHash "$h" | jq -r .)
    tx=$(cast tx "$h" --rpc-url "$RPC" --json)
    nonce=$(cast to-dec "$(jq -r .nonce <<<"$tx")")
    if [ "$nonce" -lt "$NONCE_DEPLOYED" ]; then stage=deploy
    elif [ "$nonce" -lt "$NONCE_OPERATORS" ]; then stage=operators
    else stage=validators; fi
    decoded=$(cast decode-tx "$raw")
    fee_cap=$(cast to-dec "$(jq -r .maxFeePerGas <<<"$decoded")")
    gas=$(cast to-dec "$(jq -r '.gas // .gasLimit' <<<"$decoded")")
    [ "$fee_cap" -ge "$MIN_FEE_CAP" ] || { echo "tx nonce $nonce: maxFeePerGas $fee_cap < $MIN_FEE_CAP, would stall on the devnet"; exit 1; }
    [ "$gas" -le "$MAX_TX_GAS" ] || { echo "tx nonce $nonce ($stage): gas $gas > $MAX_TX_GAS, the Osaka devnet would reject it"; exit 1; }
    jq -nc --arg raw "$raw" --arg hash "$h" --arg stage "$stage" --argjson nonce "$nonce" \
      '{stage: $stage, nonce: $nonce, hash: $hash, raw: $raw}' >> "$WORK/txs.jsonl"
  done
done
jq -s --argjson chainId "$CHAIN_ID" --arg deployer "$DEPLOYER_ADDR" --arg image "$DEPLOYER_IMAGE" \
  --arg proxy "$SSV_NETWORK_PROXY_CONTRACT" --arg token "$SSV_TOKEN_CONTRACT" \
  '{chainId: $chainId, deployer: $deployer, deployerImage: $image, ssvNetworkProxy: $proxy, ssvToken: $token,
    txs: (sort_by(.nonce))}' "$WORK/txs.jsonl" >| "$WORK/txs.json"

# Complete: the deployer's nonces 0..n-1 each recorded exactly once, n being its nonce on anvil.
n=$(jq '.txs | length' "$WORK/txs.json")
[ "$n" -eq "$NONCE_FINAL" ] || { echo "recorded $n txs, but the deployer sent $NONCE_FINAL"; exit 1; }
jq -e '[.txs[].nonce] == [range(0; .txs | length)]' "$WORK/txs.json" >/dev/null \
  || { echo "recorded nonces aren't 0..$((n - 1)) exactly once each"; exit 1; }
for s in deploy operators validators; do
  jq -e --arg s "$s" 'any(.txs[]; .stage == $s)' "$WORK/txs.json" >/dev/null || { echo "no $s txs recorded"; exit 1; }
done
nval=$(jq '[.txs[] | select(.stage == "validators")] | length' "$WORK/txs.json")
[ "$nval" -eq 1 ] || {
  echo "the validators stage is $nval txs (register-validators.cjs batches of 50): a replay of batch 2+ reverts with"
  echo "IncorrectClusterState, because the cluster snapshot it passes depends on block numbers. Recorded txs support"
  echo "a pool of at most 50 validators; use the live flow (use_recorded_txs: false) for a larger one."
  exit 1
}

# Publish: the data first (same-filesystem renames), the fingerprint last.
rm -f "$OUT/fingerprint"
mv -f "$WORK/txs.json" "$OUT/txs.json"
mv -f "$WORK/pre-registered.json" "$OUT/pre-registered.json"
echo "$WANT" >| "$WORK/fingerprint"
mv -f "$WORK/fingerprint" "$OUT/fingerprint"
echo "Recorded $(jq -r '[.txs[].stage] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "$OUT/txs.json") txs -> $OUT/txs.json"
