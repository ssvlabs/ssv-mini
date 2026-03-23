#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATIC_DIR="$PROJECT_DIR/static"
WORK_DIR=$(mktemp -d)

# Configuration — must match params.yaml and ethereum-package defaults
MNEMONIC="giant issue aisle success illegal bike spike question tent bar rely arctic volcano long crawl hungry vocal artwork sniff fantasy very lucky have athlete"
CL_VALIDATOR_START=64    # First 64 validators belong to CL nodes (32 * 2 nodes)
SSV_VALIDATOR_COUNT=10   # 74 total - 64 CL = 10 SSV validators
NUM_OPERATORS=4
OWNER_ADDRESS="0xe25583099ba105d9ec0a67f5ae86d90e50036425"

ANCHOR_IMAGE="sigp/anchor:v1.2.0"
ETH2_VAL_TOOLS_IMAGE="protolambda/eth2-val-tools@sha256:098a46aa48e47da6450e40ac6ca32f41bc961adaf3cb8968e61de701fa7c72f5"

trap "rm -rf $WORK_DIR" EXIT

echo "=== Generating static keys and keyshares ==="

# Clean and create output
rm -rf "$STATIC_DIR"
mkdir -p "$STATIC_DIR/keys" "$STATIC_DIR/keyshares"

# Step 1: Generate validator keystores
echo ""
echo "Step 1/3: Generating validator keystores..."
docker run --rm \
    -v "$WORK_DIR:/work" \
    "$ETH2_VAL_TOOLS_IMAGE" \
    keystores \
    --insecure \
    --prysm-pass password \
    --out-loc /work/keystores \
    --source-mnemonic "$MNEMONIC" \
    --source-min $CL_VALIDATOR_START \
    --source-max $((CL_VALIDATOR_START + SSV_VALIDATOR_COUNT))
echo "  Generated $SSV_VALIDATOR_COUNT validator keystores"

# Step 2: Generate operator RSA keys
echo ""
echo "Step 2/3: Generating $NUM_OPERATORS operator RSA keypairs..."
for i in $(seq 0 $((NUM_OPERATORS - 1))); do
    mkdir -p "$WORK_DIR/keys/operator-$i"
done

docker run --rm --entrypoint="" \
    -v "$WORK_DIR/keys:/keys" \
    "$ANCHOR_IMAGE" \
    sh -c "
        for i in \$(seq 0 $((NUM_OPERATORS - 1))); do
            anchor keygen --force --datadir /tmp/anchor
            cp /tmp/anchor/public_key.txt /keys/operator-\$i/
            cp /tmp/anchor/unencrypted_private_key.txt /keys/operator-\$i/
        done
    "

# Copy keys to static dir and build operator_data.json
for i in $(seq 0 $((NUM_OPERATORS - 1))); do
    mkdir -p "$STATIC_DIR/keys/operator-$i"
    cp "$WORK_DIR/keys/operator-$i/public_key.txt" "$STATIC_DIR/keys/operator-$i/"
    cp "$WORK_DIR/keys/operator-$i/unencrypted_private_key.txt" "$STATIC_DIR/keys/operator-$i/"
    echo "  Operator $i: keys generated"
done

# Build operator_data.json using python3 (available on macOS and Linux)
python3 -c "
import json, os
operators = []
for i in range($NUM_OPERATORS):
    with open('$STATIC_DIR/keys/operator-{}/public_key.txt'.format(i)) as f:
        pk = f.read().strip()
    operators.append({'id': i + 1, 'publicKey': pk})
with open('$WORK_DIR/operator_data.json', 'w') as f:
    json.dump({'operators': operators}, f, indent=2)
"
echo "  Built operator_data.json"

# Step 3: Generate keyshares
echo ""
echo "Step 3/3: Generating keyshares..."

docker run --rm --entrypoint="" \
    -v "$WORK_DIR/keystores:/keystores:ro" \
    -v "$WORK_DIR/operator_data.json:/operator_data.json:ro" \
    -v "$STATIC_DIR/keyshares:/output" \
    -e OWNER_ADDRESS="$OWNER_ADDRESS" \
    "$ANCHOR_IMAGE" \
    sh -c '
        apt-get update -qq && apt-get install -y -qq --no-install-recommends jq >/dev/null 2>&1

        OPERATOR_IDS=$(jq -r ".operators[].id" /operator_data.json | tr "\n" "," | sed "s/,$//" )
        PUBLIC_KEYS=""
        for ID in $(echo $OPERATOR_IDS | tr "," " "); do
            KEY=$(jq -r ".operators[] | select(.id == $ID) | .publicKey" /operator_data.json)
            if [ -z "$PUBLIC_KEYS" ]; then PUBLIC_KEYS="$KEY"; else PUBLIC_KEYS="$PUBLIC_KEYS,$KEY"; fi
        done

        NONCE=0
        TEMP=$(mktemp -d)
        SHARES=""

        for VALIDATOR_DIR in /keystores/keys/*; do
            [ -d "$VALIDATOR_DIR" ] || continue
            VALIDATOR_KEY=$(basename "$VALIDATOR_DIR")
            echo "  Splitting key: $VALIDATOR_KEY (nonce=$NONCE)"

            anchor keysplit manual \
                --keystore-paths "$VALIDATOR_DIR/voting-keystore.json" \
                --password-file "/keystores/secrets/$VALIDATOR_KEY" \
                --owner "$OWNER_ADDRESS" \
                --output-path "$TEMP/$VALIDATOR_KEY.json" \
                --operators "$OPERATOR_IDS" \
                --nonce "$NONCE" \
                --public-keys "$PUBLIC_KEYS" > /dev/null 2>&1

            SHARE=$(jq -c ".shares[0]" "$TEMP/$VALIDATOR_KEY.json")
            if [ -z "$SHARES" ]; then SHARES="$SHARE"; else SHARES="$SHARES,$SHARE"; fi
            NONCE=$((NONCE + 1))
        done

        echo "{\"shares\": [$SHARES]}" | jq "." > /output/out.json
        echo ""
        echo "  Generated keyshares with $NONCE shares"
    '

echo ""
echo "=== Static files generated ==="
find "$STATIC_DIR" -type f | sort | while read f; do
    echo "  $f"
done
