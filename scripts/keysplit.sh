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

NONCE="0"
TEMP_DIR=$(mktemp -d)
FINAL_SHARES=()

# Get operator IDs
OPERATOR_IDS=$(cat ../operator_data/operator_data.json | jq -r '.operators[].id' | tr '\n' ',' | sed 's/,$//')

# Get operator public keys
PUBLIC_KEYS=""
for ID in $(echo $OPERATOR_IDS | tr ',' ' '); do
  KEY=$(cat ../operator_data/operator_data.json | jq -r ".operators[] | select(.id == $ID) | .publicKey")

  if [ -z "$PUBLIC_KEYS" ]; then
    PUBLIC_KEYS="$KEY"
  else
    PUBLIC_KEYS="$PUBLIC_KEYS,$KEY"
  fi
done

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
