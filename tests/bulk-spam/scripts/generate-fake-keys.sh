#!/bin/bash

# Generate fake validator public keys for bulk spam registration
# Usage: generate-fake-keys.sh <total_validators> <validators_per_batch> <output_dir>

TOTAL_VALIDATORS=$1
VALIDATORS_PER_BATCH=$2
OUTPUT_DIR=$3

if [ -z "$TOTAL_VALIDATORS" ] || [ -z "$VALIDATORS_PER_BATCH" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: generate-fake-keys.sh <total_validators> <validators_per_batch> <output_dir>"
    exit 1
fi

echo "Generating $TOTAL_VALIDATORS fake validator keys in batches of $VALIDATORS_PER_BATCH"
echo "Output directory: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR"

# Function to generate a fake BLS public key (48 bytes)
generate_fake_pubkey() {
    local index=$1
    # Create a deterministic but fake 96-character hex string (48 bytes)
    # Using sha256 of index to ensure uniqueness
    local hash=$(echo "fake_validator_$index" | sha256sum | cut -d' ' -f1)
    # Extend to 96 characters by repeating and truncating
    local extended="${hash}${hash}${hash}"
    echo "0x${extended:0:96}"
}

# Generate keys in batches
BATCH_NUM=0
VALIDATOR_INDEX=0

while [ $VALIDATOR_INDEX -lt $TOTAL_VALIDATORS ]; do
    BATCH_FILE="$OUTPUT_DIR/batch_${BATCH_NUM}.json"
    
    echo "Generating batch $BATCH_NUM..."
    
    # Start JSON structure
    echo "{" > "$BATCH_FILE"
    echo "  \"batch_number\": $BATCH_NUM," >> "$BATCH_FILE"
    echo "  \"validators_in_batch\": []," >> "$BATCH_FILE"
    echo "  \"public_keys\": [" >> "$BATCH_FILE"
    
    # Generate keys for this batch
    KEYS_IN_BATCH=0
    while [ $KEYS_IN_BATCH -lt $VALIDATORS_PER_BATCH ] && [ $VALIDATOR_INDEX -lt $TOTAL_VALIDATORS ]; do
        FAKE_PUBKEY=$(generate_fake_pubkey $VALIDATOR_INDEX)
        
        if [ $KEYS_IN_BATCH -gt 0 ]; then
            echo "    ," >> "$BATCH_FILE"
        fi
        echo -n "    \"$FAKE_PUBKEY\"" >> "$BATCH_FILE"
        
        KEYS_IN_BATCH=$((KEYS_IN_BATCH + 1))
        VALIDATOR_INDEX=$((VALIDATOR_INDEX + 1))
    done
    
    # Close JSON structure
    echo "" >> "$BATCH_FILE"
    echo "  ]," >> "$BATCH_FILE"
    echo "  \"actual_count\": $KEYS_IN_BATCH," >> "$BATCH_FILE"
    echo "  \"generated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" >> "$BATCH_FILE"
    echo "}" >> "$BATCH_FILE"
    
    echo "Generated batch $BATCH_NUM with $KEYS_IN_BATCH validators"
    BATCH_NUM=$((BATCH_NUM + 1))
done

# Generate summary file
SUMMARY_FILE="$OUTPUT_DIR/summary.json"
echo "{" > "$SUMMARY_FILE"
echo "  \"total_validators\": $TOTAL_VALIDATORS," >> "$SUMMARY_FILE"
echo "  \"validators_per_batch\": $VALIDATORS_PER_BATCH," >> "$SUMMARY_FILE"
echo "  \"total_batches\": $BATCH_NUM," >> "$SUMMARY_FILE"
echo "  \"generated_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," >> "$SUMMARY_FILE"
echo "  \"note\": \"These are fake validator keys generated for bulk spam testing. They are not real BLS keys and should not be used for actual validation.\"" >> "$SUMMARY_FILE"
echo "}" >> "$SUMMARY_FILE"

echo "Successfully generated $TOTAL_VALIDATORS fake validator keys in $BATCH_NUM batches"
echo "Summary written to: $SUMMARY_FILE" 