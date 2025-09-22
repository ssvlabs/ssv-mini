#!/bin/bash

cast send $SSV_TOKEN_ADDRESS "approve(address,uint256)" $SSV_NETWORK_ADDRESS 1000000000000000000 --private-key $PRIVATE_KEY --rpc-url $ETH_RPC_URL --legacy --silent

# Extract data from JSON file
JSON_FILE="script/keyshares/out.json"

# Get the number of shares in the array
SHARES_COUNT=$(jq '.shares | length' "$JSON_FILE")
echo "Found $SHARES_COUNT validators to register"

PUBLIC_KEYS=$(jq -r "[.shares[].payload.publicKey] | join(\",\")" "$JSON_FILE")
SHARES_DATA=$(jq -r "[.shares[].payload.sharesData] |  join(\",\")" "$JSON_FILE")
OPERATOR_IDS=$(jq -r ".shares[0].payload.operatorIds | join(\",\")" "$JSON_FILE")

# Run the forge command for this validator
# cd /app/script/register-validator && \
forge script /app/script/register-validator/RegisterValidators.s.sol:RegisterValidator \
    --sig "run(address,bytes[],bytes[],uint64[])" \
    "$SSV_NETWORK_ADDRESS" "[$PUBLIC_KEYS]" "[$SHARES_DATA]" "[$OPERATOR_IDS]" --broadcast --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY --legacy --silent


echo "All validators have been registered"

##!/bin/bash
#set -euo pipefail
#
#JSON_FILE="script/keyshares/out.json"
#
## 0) Approve once
#cast send "$SSV_TOKEN_ADDRESS" "approve(address,uint256)" "$SSV_NETWORK_ADDRESS" 1000000000000000000 \
#  --private-key "$PRIVATE_KEY" --rpc-url "$ETH_RPC_URL" --legacy --silent
#
#SHARES_COUNT=$(jq '.shares | length' "$JSON_FILE")
#echo "Found $SHARES_COUNT validators to register"
#
## 1) Flatten to three compact arrays UNDER THE REPO (NOT /tmp)
#PREP_DIR="script/keyshares/prepared"
#mkdir -p "$PREP_DIR"
#PUBKEYS_JSON="$PREP_DIR/pubkeys.json"
#SHARES_JSON="$PREP_DIR/shares.json"
#OPIDS_JSON="$PREP_DIR/opids.json"
#
#jq -c '[.shares[].payload.publicKey]'  "$JSON_FILE" > "$PUBKEYS_JSON"
#jq -c '[.shares[].payload.sharesData]' "$JSON_FILE" > "$SHARES_JSON"
#jq -c '.shares[0].payload.operatorIds' "$JSON_FILE" > "$OPIDS_JSON"
#
## 2) Export paths for the Forge script
#export SSV_NETWORK_ADDRESS
#export PUBKEYS_JSON
#export SHARES_JSON
#export OPIDS_JSON
#
## 3) Run the Forge script (it will vm.readFile these paths)
#forge script /app/script/register-validator/RegisterValidators.s.sol:RegisterValidator \
#  --sig "run()" \
#  --broadcast --rpc-url "$ETH_RPC_URL" --private-key "$PRIVATE_KEY" --legacy --silent
#
## 4) Optional cleanup (keep if your CI needs artifacts)
## rm -f "$PUBKEYS_JSON" "$SHARES_JSON" "$OPIDS_JSON"
