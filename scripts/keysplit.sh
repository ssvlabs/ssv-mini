#!/bin/bash
set -euo pipefail

# Check if jq is installed
if ! command -v jq &> /dev/null
then
    echo "jq is not installed. Installing..."
    apt-get update -y
    apt-get install -y jq
else
    echo "jq is already installed."
fi

NONCE="0"
TEMP_DIR=$(mktemp -d)
FINAL_SHARES=()

# Get operator IDs
OPERATOR_IDS="$(jq -r '[.operators[].id | tostring] | join(\",\")' ../operator_data/operator_data.json)"

# Get operator public keys (comma-separated; Anchor accepts `--public-keys` as a list)
PUBLIC_KEYS="$(jq -r '[.operators[].publicKey] | join(\",\")' ../operator_data/operator_data.json)"

# Process each validator key
for VALIDATOR_DIR in ../keystores/keys/*; do
  if [ -d "$VALIDATOR_DIR" ]; then
    VALIDATOR_KEY=$(basename "$VALIDATOR_DIR")
    echo "Processing validator key: $VALIDATOR_KEY with nonce: $NONCE"

    KEYSTORE_PATH="$VALIDATOR_DIR/voting-keystore.json"
    PASSWORD_FILE="../keystores/secrets/$VALIDATOR_KEY"
    TEMP_OUTPUT="$TEMP_DIR/$VALIDATOR_KEY-out.json"

    anchor keysplit manual \
      --keystore-paths "$KEYSTORE_PATH" \
      --password-file "$PASSWORD_FILE" \
      --owner "$OWNER_ADDRESS" \
      --output-path "$TEMP_OUTPUT" \
      --operators "$OPERATOR_IDS" \
      --nonce "$NONCE" \
      --public-keys "$PUBLIC_KEYS" > /dev/null

    if [ $? -eq 0 ] && [ -f "$TEMP_OUTPUT" ]; then
      # Extract the share from the temp file and add to our array
      SHARE=$(jq -c '.shares[0]' "$TEMP_OUTPUT")
      FINAL_SHARES+=("$SHARE")

      # Increment the nonce for the next run
      NONCE=$((NONCE + 1))
    else
      echo "Error processing $VALIDATOR_KEY"
    fi
  fi
done

# Combine all shares into a single output file
echo "{\"shares\": [" > out.json
for i in "${!FINAL_SHARES[@]}"; do
  echo "${FINAL_SHARES[$i]}" >> out.json
  if [ $i -lt $((${#FINAL_SHARES[@]} - 1)) ]; then
    echo "," >> out.json
  fi
done
echo "]}" >> out.json

# Clean up temp directory
rm -rf "$TEMP_DIR"

echo "Successfully processed ${#FINAL_SHARES[@]} validator keys into out.json"
