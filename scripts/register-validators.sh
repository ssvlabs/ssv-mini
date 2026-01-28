#!/bin/bash
set -e

# Check if jq is installed
if ! command -v jq &> /dev/null
then
    echo "jq is not installed. Installing..."
    apt update -y
    apt install -y jq
else
    echo "jq is already installed."
fi


# Extract data from JSON file first to calculate required approval
JSON_FILE="script/keyshares/out.json"

# Get the number of shares in the array
SHARES_COUNT=$(jq '.shares | length' "$JSON_FILE")
echo "Found $SHARES_COUNT validators to register"

# Approve tokens: 15 ETH per validator × SHARES_COUNT validators
# Using 1000 ETH total approval to ensure sufficient allowance (15 * 32 = 480 ETH needed)
APPROVAL_AMOUNT="1000000000000000000000"  # 1000 ETH in wei
echo "Approving $APPROVAL_AMOUNT wei for $SHARES_COUNT validators"
cast send $SSV_TOKEN_ADDRESS "approve(address,uint256)" $SSV_NETWORK_ADDRESS $APPROVAL_AMOUNT --private-key $PRIVATE_KEY --rpc-url $ETH_RPC_URL --legacy --silent

PUBLIC_KEYS=$(jq -r "[.shares[].payload.publicKey] | join(\",\")" "$JSON_FILE")
SHARES_DATA=$(jq -r "[.shares[].payload.sharesData] |  join(\",\")" "$JSON_FILE")
OPERATOR_IDS=$(jq -r ".shares[0].payload.operatorIds | join(\",\")" "$JSON_FILE")

# Run the forge command for this validator
# cd /app/script/register-validator && \
forge script /app/script/register-validator/RegisterValidators.s.sol:RegisterValidator \
    --sig "run(address,bytes[],bytes[],uint64[])" \
    "$SSV_NETWORK_ADDRESS" "[$PUBLIC_KEYS]" "[$SHARES_DATA]" "[$OPERATOR_IDS]" --broadcast --rpc-url $ETH_RPC_URL --private-key $PRIVATE_KEY --legacy --silent
  

echo "All validators have been registered"
