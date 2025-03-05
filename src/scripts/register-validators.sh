#!/bin/bash

# Extract data from JSON file
JSON_FILE="script/keyshares/out.json"
PUBLIC_KEY=$(jq -r '.shares[0].payload.publicKey' "$JSON_FILE")
SHARES_DATA=$(jq -r '.shares[0].payload.sharesData' "$JSON_FILE")
OPERATOR_IDS=$(jq -r '.shares[0].payload.operatorIds | join(",")' "$JSON_FILE")

cast send $SSV_TOKEN_ADDRESS "approve(address,uint256)" $SSV_NETWORK_ADDRESS 1000000000000000000 --private-key $PRIVATE_KEY --rpc-url $ETH_RPC_URL --legacy --silent

# Run the forge command
cd /app/script/register-validator && \
forge script RegisterValidators.s.sol:RegisterValidator \
  --sig "run(address,bytes,bytes,uint64[])" \
  "$SSV_NETWORK_ADDRESS" "$PUBLIC_KEY" "$SHARES_DATA" "[$OPERATOR_IDS]" --broadcast --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY --legacy --silent
