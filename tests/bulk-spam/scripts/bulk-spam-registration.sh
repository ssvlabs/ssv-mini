#!/bin/bash

# Bulk Spam Validator Registration Script
# This script executes multiple batches of fake validator registrations for load testing

set -e

echo "=== BULK SPAM VALIDATOR REGISTRATION STARTED ==="
echo "Configuration:"
echo "  Batch Count: $BATCH_COUNT"
echo "  Validators per Batch: $VALIDATORS_PER_BATCH"
echo "  Delay between Batches: $DELAY_BETWEEN_BATCHES seconds"
echo "  Target Events per Block: $TARGET_EVENTS_PER_BLOCK"
echo "  Detailed Logging: $DETAILED_LOGGING"
echo "  SSV Network Address: $SSV_NETWORK_ADDRESS"
echo "  RPC URL: $ETH_RPC_URL"

# Create logs directory
mkdir -p /spam-logs

# Extract operator IDs from operator data
OPERATOR_IDS=$(jq -r '.operators | map(.id) | join(",")' /app/operator_data.json)
echo "Using Operator IDs: $OPERATOR_IDS"

# Initialize statistics
TOTAL_VALIDATORS_REGISTERED=0
TOTAL_BATCHES_COMPLETED=0
TOTAL_FAILED_BATCHES=0
START_TIME=$(date +%s)
START_BLOCK=$(cast block-number --rpc-url $ETH_RPC_URL)

echo "Starting spam registration at block: $START_BLOCK"

# Log initial state
echo "{" > /spam-logs/spam_session.json
echo "  \"session_start\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," >> /spam-logs/spam_session.json
echo "  \"start_block\": $START_BLOCK," >> /spam-logs/spam_session.json
echo "  \"configuration\": {" >> /spam-logs/spam_session.json
echo "    \"batch_count\": $BATCH_COUNT," >> /spam-logs/spam_session.json
echo "    \"validators_per_batch\": $VALIDATORS_PER_BATCH," >> /spam-logs/spam_session.json
echo "    \"delay_between_batches\": $DELAY_BETWEEN_BATCHES," >> /spam-logs/spam_session.json
echo "    \"target_events_per_block\": $TARGET_EVENTS_PER_BLOCK" >> /spam-logs/spam_session.json
echo "  }," >> /spam-logs/spam_session.json
echo "  \"batches\": [" >> /spam-logs/spam_session.json

# Process each batch
for ((batch=0; batch<$BATCH_COUNT; batch++)); do
    echo ""
    echo "=== PROCESSING BATCH $((batch + 1))/$BATCH_COUNT ==="
    
    BATCH_START_TIME=$(date +%s)
    BATCH_START_BLOCK=$(cast block-number --rpc-url $ETH_RPC_URL)
    
    # Load fake keys for this batch
    BATCH_FILE="/app/fake-keys/batch_${batch}.json"
    
    if [ ! -f "$BATCH_FILE" ]; then
        echo "ERROR: Batch file not found: $BATCH_FILE"
        TOTAL_FAILED_BATCHES=$((TOTAL_FAILED_BATCHES + 1))
        continue
    fi
    
    # Extract public keys from batch file
    PUBLIC_KEYS=$(jq -r '.public_keys | map(.) | join(",")' "$BATCH_FILE")
    VALIDATORS_IN_BATCH=$(jq -r '.actual_count' "$BATCH_FILE")
    
    echo "Batch $((batch + 1)): Registering $VALIDATORS_IN_BATCH fake validators"
    
    if [ "$DETAILED_LOGGING" = "true" ]; then
        echo "Public keys preview (first 3): $(echo "$PUBLIC_KEYS" | cut -d',' -f1-3)..."
    fi
    
    # Add batch info to log (not the last batch)
    if [ $batch -gt 0 ]; then
        echo "    ," >> /spam-logs/spam_session.json
    fi
    echo "    {" >> /spam-logs/spam_session.json
    echo "      \"batch_number\": $((batch + 1))," >> /spam-logs/spam_session.json
    echo "      \"start_time\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," >> /spam-logs/spam_session.json
    echo "      \"start_block\": $BATCH_START_BLOCK," >> /spam-logs/spam_session.json
    echo "      \"validators_count\": $VALIDATORS_IN_BATCH," >> /spam-logs/spam_session.json
    
    # Execute the forge script for this batch
    FORGE_OUTPUT_FILE="/spam-logs/batch_${batch}_output.log"
    BATCH_SUCCESS=false
    
    if forge script /app/script/register-spam/BulkSpamRegistration.s.sol:BulkSpamRegistration \
        --sig "run(address,bytes[],uint64[],uint256,uint256)" \
        "$SSV_NETWORK_ADDRESS" "[$PUBLIC_KEYS]" "[$OPERATOR_IDS]" "$((batch + 1))" "$TARGET_EVENTS_PER_BLOCK" \
        --broadcast --rpc-url "$ETH_RPC_URL" --private-key "$PRIVATE_KEY" --legacy \
        > "$FORGE_OUTPUT_FILE" 2>&1; then
        
        echo "✅ Batch $((batch + 1)) completed successfully"
        BATCH_SUCCESS=true
        TOTAL_VALIDATORS_REGISTERED=$((TOTAL_VALIDATORS_REGISTERED + VALIDATORS_IN_BATCH))
        TOTAL_BATCHES_COMPLETED=$((TOTAL_BATCHES_COMPLETED + 1))
    else
        echo "❌ Batch $((batch + 1)) failed"
        TOTAL_FAILED_BATCHES=$((TOTAL_FAILED_BATCHES + 1))
        
        if [ "$DETAILED_LOGGING" = "true" ]; then
            echo "Error details:"
            tail -10 "$FORGE_OUTPUT_FILE"
        fi
    fi
    
    BATCH_END_TIME=$(date +%s)
    BATCH_END_BLOCK=$(cast block-number --rpc-url $ETH_RPC_URL)
    BATCH_DURATION=$((BATCH_END_TIME - BATCH_START_TIME))
    BATCH_BLOCKS_USED=$((BATCH_END_BLOCK - BATCH_START_BLOCK))
    
    # Complete batch info in log
    echo "      \"end_time\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," >> /spam-logs/spam_session.json
    echo "      \"end_block\": $BATCH_END_BLOCK," >> /spam-logs/spam_session.json
    echo "      \"duration_seconds\": $BATCH_DURATION," >> /spam-logs/spam_session.json
    echo "      \"blocks_used\": $BATCH_BLOCKS_USED," >> /spam-logs/spam_session.json
    echo "      \"success\": $BATCH_SUCCESS," >> /spam-logs/spam_session.json
    
    if [ $BATCH_BLOCKS_USED -gt 0 ] && [ "$BATCH_SUCCESS" = "true" ]; then
        EVENTS_PER_BLOCK=$((VALIDATORS_IN_BATCH / BATCH_BLOCKS_USED))
        echo "      \"actual_events_per_block\": $EVENTS_PER_BLOCK" >> /spam-logs/spam_session.json
        echo "Batch $((batch + 1)) stats: $BATCH_DURATION seconds, $BATCH_BLOCKS_USED blocks, ~$EVENTS_PER_BLOCK events/block"
    else
        echo "      \"actual_events_per_block\": 0" >> /spam-logs/spam_session.json
    fi
    
    echo "    }" >> /spam-logs/spam_session.json
    
    # Wait before next batch (except for the last batch)
    if [ $((batch + 1)) -lt $BATCH_COUNT ] && [ $DELAY_BETWEEN_BATCHES -gt 0 ]; then
        echo "Waiting $DELAY_BETWEEN_BATCHES seconds before next batch..."
        sleep $DELAY_BETWEEN_BATCHES
    fi
done

# Finalize session log
END_TIME=$(date +%s)
END_BLOCK=$(cast block-number --rpc-url $ETH_RPC_URL)
TOTAL_DURATION=$((END_TIME - START_TIME))
TOTAL_BLOCKS_USED=$((END_BLOCK - START_BLOCK))

echo "  ]," >> /spam-logs/spam_session.json
echo "  \"session_end\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," >> /spam-logs/spam_session.json
echo "  \"end_block\": $END_BLOCK," >> /spam-logs/spam_session.json
echo "  \"total_duration_seconds\": $TOTAL_DURATION," >> /spam-logs/spam_session.json
echo "  \"total_blocks_used\": $TOTAL_BLOCKS_USED," >> /spam-logs/spam_session.json
echo "  \"summary\": {" >> /spam-logs/spam_session.json
echo "    \"total_validators_registered\": $TOTAL_VALIDATORS_REGISTERED," >> /spam-logs/spam_session.json
echo "    \"total_batches_completed\": $TOTAL_BATCHES_COMPLETED," >> /spam-logs/spam_session.json
echo "    \"total_failed_batches\": $TOTAL_FAILED_BATCHES," >> /spam-logs/spam_session.json
if [ $TOTAL_BLOCKS_USED -gt 0 ]; then
    AVERAGE_EVENTS_PER_BLOCK=$((TOTAL_VALIDATORS_REGISTERED / TOTAL_BLOCKS_USED))
    echo "    \"average_events_per_block\": $AVERAGE_EVENTS_PER_BLOCK" >> /spam-logs/spam_session.json
else
    echo "    \"average_events_per_block\": 0" >> /spam-logs/spam_session.json
fi
echo "  }" >> /spam-logs/spam_session.json
echo "}" >> /spam-logs/spam_session.json

echo ""
echo "=== BULK SPAM REGISTRATION COMPLETED ==="
echo "📊 Final Statistics:"
echo "  Total Duration: $TOTAL_DURATION seconds"
echo "  Total Blocks Used: $TOTAL_BLOCKS_USED"
echo "  Total Validators Registered: $TOTAL_VALIDATORS_REGISTERED"
echo "  Successful Batches: $TOTAL_BATCHES_COMPLETED/$BATCH_COUNT"
echo "  Failed Batches: $TOTAL_FAILED_BATCHES"

if [ $TOTAL_BLOCKS_USED -gt 0 ]; then
    AVERAGE_EVENTS_PER_BLOCK=$((TOTAL_VALIDATORS_REGISTERED / TOTAL_BLOCKS_USED))
    echo "  Average Events per Block: $AVERAGE_EVENTS_PER_BLOCK"
fi

echo ""
echo "📁 Log files saved to /spam-logs/"
echo "  - spam_session.json: Complete session statistics"
echo "  - batch_*_output.log: Individual batch forge outputs"

if [ $TOTAL_FAILED_BATCHES -gt 0 ]; then
    echo ""
    echo "⚠️  Warning: $TOTAL_FAILED_BATCHES batches failed. Check individual batch logs for details."
    exit 1
fi

echo ""
echo "✅ All batches completed successfully!" 