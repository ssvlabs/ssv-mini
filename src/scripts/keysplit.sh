#!/bin/bash
NONCE="0"

VALIDATOR_KEY=$(ls ../keystores/keys/ | head -1)
PASSWORD=$(cat ../keystores/secrets/$VALIDATOR_KEY)
KEYSTORE_PATH="../keystores/keys/$VALIDATOR_KEY/voting-keystore.json"
OPERATOR_IDS=$(cat ../operator_data/operator_data.json | jq -r '.operators[].id' | tr '\n' ',' | sed 's/,$//')

PUBLIC_KEYS=""
for ID in $(echo $OPERATOR_IDS | tr ',' ' '); do
  KEY=$(cat ../operator_data/operator_data.json | jq -r ".operators[] | select(.id == $ID) | .publicKey")
  
  if [ -z "$PUBLIC_KEYS" ]; then
    PUBLIC_KEYS="$KEY"
  else
    PUBLIC_KEYS="$PUBLIC_KEYS,$KEY"
  fi
done

../anchor keysplit manual \
  --keystore-path "$KEYSTORE_PATH" \
  --password "$PASSWORD" \
  --owner "$OWNER_ADDRESS" \
  --output-path "out.json" \
  --operators "$OPERATOR_IDS" \
  --nonce "$NONCE" \
  --public-keys "$PUBLIC_KEYS" > /dev/null
