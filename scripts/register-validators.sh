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