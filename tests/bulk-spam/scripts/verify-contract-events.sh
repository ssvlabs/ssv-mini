#!/bin/bash

# Verify SSV Contract Events Script
# This script checks the Ethereum execution node API for SSV validator registration events

set -e

echo "=== SSV CONTRACT EVENTS VERIFICATION ==="

# Parameters
SSV_NETWORK_ADDRESS="$1"
START_BLOCK="$2"
END_BLOCK="$3"
ETH_RPC_URL="$4"
EXPECTED_EVENTS="$5"
OUTPUT_FILE="$6"

if [ -z "$SSV_NETWORK_ADDRESS" ] || [ -z "$START_BLOCK" ] || [ -z "$END_BLOCK" ] || [ -z "$ETH_RPC_URL" ] || [ -z "$EXPECTED_EVENTS" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "Usage: verify-contract-events.sh <ssv_address> <start_block> <end_block> <rpc_url> <expected_events> <output_file>"
    exit 1
fi

echo "Verifying SSV contract events:"
echo "  Contract Address: $SSV_NETWORK_ADDRESS"
echo "  Block Range: $START_BLOCK - $END_BLOCK"
echo "  RPC URL: $ETH_RPC_URL"
echo "  Expected Events: $EXPECTED_EVENTS"

# SSV ValidatorAdded event signature: ValidatorAdded(address,uint64[],bytes,bytes,Cluster)
# This is the event emitted when validators are registered
VALIDATOR_ADDED_TOPIC="0x48a3ea0796746043948f6341d17ff8200937b99262a0b48c2663b951ed7114e5"

# Create output directory
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Initialize verification results
echo "{" > "$OUTPUT_FILE"
echo "  \"verification_start\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," >> "$OUTPUT_FILE"
echo "  \"contract_address\": \"$SSV_NETWORK_ADDRESS\"," >> "$OUTPUT_FILE"
echo "  \"block_range\": {" >> "$OUTPUT_FILE"
echo "    \"start\": $START_BLOCK," >> "$OUTPUT_FILE"
echo "    \"end\": $END_BLOCK" >> "$OUTPUT_FILE"
echo "  }," >> "$OUTPUT_FILE"
echo "  \"expected_events\": $EXPECTED_EVENTS," >> "$OUTPUT_FILE"

# Convert block numbers to hex for RPC calls
START_BLOCK_HEX=$(printf "0x%x" "$START_BLOCK")
END_BLOCK_HEX=$(printf "0x%x" "$END_BLOCK")

echo "Getting logs from blocks $START_BLOCK_HEX to $END_BLOCK_HEX..."

# Get logs for ValidatorAdded events
LOGS_RESPONSE=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    --data "{
        \"jsonrpc\": \"2.0\",
        \"method\": \"eth_getLogs\",
        \"params\": [{
            \"fromBlock\": \"$START_BLOCK_HEX\",
            \"toBlock\": \"$END_BLOCK_HEX\",
            \"address\": \"$SSV_NETWORK_ADDRESS\",
            \"topics\": [\"$VALIDATOR_ADDED_TOPIC\"]
        }],
        \"id\": 1
    }" \
    "$ETH_RPC_URL")

echo "Raw RPC response received"

# Check if the response contains an error
if echo "$LOGS_RESPONSE" | jq -e '.error' > /dev/null; then
    echo "❌ RPC Error occurred:"
    echo "$LOGS_RESPONSE" | jq '.error'
    
    echo "  \"rpc_error\": $(echo "$LOGS_RESPONSE" | jq '.error')," >> "$OUTPUT_FILE"
    echo "  \"success\": false," >> "$OUTPUT_FILE"
    echo "  \"verification_end\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" >> "$OUTPUT_FILE"
    echo "}" >> "$OUTPUT_FILE"
    
    exit 1
fi

# Extract logs array
LOGS=$(echo "$LOGS_RESPONSE" | jq '.result')

if [ "$LOGS" = "null" ] || [ "$LOGS" = "[]" ]; then
    ACTUAL_EVENTS=0
    echo "⚠️  No ValidatorAdded events found in the specified block range"
else
    ACTUAL_EVENTS=$(echo "$LOGS" | jq 'length')
    echo "✅ Found $ACTUAL_EVENTS ValidatorAdded events"
fi

# Analyze events by block
echo "  \"events_analysis\": {" >> "$OUTPUT_FILE"
echo "    \"actual_events\": $ACTUAL_EVENTS," >> "$OUTPUT_FILE"
echo "    \"events_by_block\": [" >> "$OUTPUT_FILE"

if [ "$ACTUAL_EVENTS" -gt 0 ]; then
    # Group events by block number
    BLOCKS_WITH_EVENTS=$(echo "$LOGS" | jq -r '.[].blockNumber' | sort | uniq)
    
    FIRST_BLOCK=true
    for BLOCK_HEX in $BLOCKS_WITH_EVENTS; do
        BLOCK_NUM=$(printf "%d" "$BLOCK_HEX")
        EVENTS_IN_BLOCK=$(echo "$LOGS" | jq --arg block "$BLOCK_HEX" '[.[] | select(.blockNumber == $block)] | length')
        
        if [ "$FIRST_BLOCK" = false ]; then
            echo "      ," >> "$OUTPUT_FILE"
        fi
        FIRST_BLOCK=false
        
        echo "      {" >> "$OUTPUT_FILE"
        echo "        \"block_number\": $BLOCK_NUM," >> "$OUTPUT_FILE"
        echo "        \"block_hex\": \"$BLOCK_HEX\"," >> "$OUTPUT_FILE"
        echo "        \"events_count\": $EVENTS_IN_BLOCK" >> "$OUTPUT_FILE"
        echo "      }" >> "$OUTPUT_FILE"
        
        echo "  Block $BLOCK_NUM: $EVENTS_IN_BLOCK events"
    done
fi

echo "    ]" >> "$OUTPUT_FILE"
echo "  }," >> "$OUTPUT_FILE"

# Calculate success metrics
BLOCKS_CHECKED=$((END_BLOCK - START_BLOCK + 1))
SUCCESS_RATE=0

if [ "$EXPECTED_EVENTS" -gt 0 ]; then
    SUCCESS_RATE=$(echo "$ACTUAL_EVENTS * 100 / $EXPECTED_EVENTS" | bc -l)
fi

# Determine overall success
VERIFICATION_SUCCESS="false"
if [ "$ACTUAL_EVENTS" -eq "$EXPECTED_EVENTS" ]; then
    VERIFICATION_SUCCESS="true"
    echo "✅ Event verification PASSED: $ACTUAL_EVENTS/$EXPECTED_EVENTS events found"
elif [ "$ACTUAL_EVENTS" -gt 0 ]; then
    echo "⚠️  Event verification PARTIAL: $ACTUAL_EVENTS/$EXPECTED_EVENTS events found"
else
    echo "❌ Event verification FAILED: No events found"
fi

# Add summary to output
echo "  \"summary\": {" >> "$OUTPUT_FILE"
echo "    \"blocks_checked\": $BLOCKS_CHECKED," >> "$OUTPUT_FILE"
echo "    \"success_rate_percent\": $SUCCESS_RATE," >> "$OUTPUT_FILE"
echo "    \"verification_passed\": $VERIFICATION_SUCCESS," >> "$OUTPUT_FILE"
echo "    \"discrepancy\": $((EXPECTED_EVENTS - ACTUAL_EVENTS))" >> "$OUTPUT_FILE"
echo "  }," >> "$OUTPUT_FILE"
echo "  \"success\": $VERIFICATION_SUCCESS," >> "$OUTPUT_FILE"
echo "  \"verification_end\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" >> "$OUTPUT_FILE"
echo "}" >> "$OUTPUT_FILE"

echo ""
echo "📊 Contract Events Verification Summary:"
echo "  Blocks Checked: $BLOCKS_CHECKED"
echo "  Expected Events: $EXPECTED_EVENTS"
echo "  Actual Events: $ACTUAL_EVENTS"
echo "  Success Rate: ${SUCCESS_RATE}%"
echo "  Verification: $([ "$VERIFICATION_SUCCESS" = "true" ] && echo "PASSED" || echo "FAILED")"
echo ""
echo "📁 Detailed results saved to: $OUTPUT_FILE"

if [ "$VERIFICATION_SUCCESS" = "false" ]; then
    exit 1
fi 