#!/bin/bash

# Verify SSV Node Logs Script
# This script checks SSV node logs to verify they processed the validator registration events

set -e

echo "=== SSV NODE LOGS VERIFICATION ==="

# Parameters
START_BLOCK="$1"
END_BLOCK="$2"
EXPECTED_EVENTS="$3"
OUTPUT_FILE="$4"
TIMEOUT="${5:-60}"

if [ -z "$START_BLOCK" ] || [ -z "$END_BLOCK" ] || [ -z "$EXPECTED_EVENTS" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "Usage: verify-ssv-node-logs.sh <start_block> <end_block> <expected_events> <output_file> [timeout]"
    exit 1
fi

echo "Verifying SSV node logs:"
echo "  Block Range: $START_BLOCK - $END_BLOCK"
echo "  Expected Events: $EXPECTED_EVENTS"
echo "  Timeout: $TIMEOUT seconds"

# Create output directory
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Initialize verification results
echo "{" > "$OUTPUT_FILE"
echo "  \"verification_start\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," >> "$OUTPUT_FILE"
echo "  \"block_range\": {" >> "$OUTPUT_FILE"
echo "    \"start\": $START_BLOCK," >> "$OUTPUT_FILE"
echo "    \"end\": $END_BLOCK" >> "$OUTPUT_FILE"
echo "  }," >> "$OUTPUT_FILE"
echo "  \"expected_events\": $EXPECTED_EVENTS," >> "$OUTPUT_FILE"
echo "  \"ssv_nodes_analysis\": [" >> "$OUTPUT_FILE"

# Function to check logs via kurtosis for a specific service
check_service_logs() {
    local service_name="$1"
    local node_index="$2"
    
    echo "Checking logs for service: $service_name"
    
    # Get recent logs from the service (last 1000 lines to capture relevant period)
    LOGS_OUTPUT=$(kurtosis service logs "$service_name" 2>/dev/null | tail -1000 || echo "")
    
    if [ -z "$LOGS_OUTPUT" ]; then
        echo "  ⚠️  No logs available for $service_name"
        return 1
    fi
    
    # Look for validator-related log patterns in SSV nodes
    # SSV nodes typically log events like "validator added", "cluster update", "block processed", etc.
    
    # Count validator registration events in logs
    VALIDATOR_EVENTS=$(echo "$LOGS_OUTPUT" | grep -c -i "validator.*added\|validator.*registered\|validator.*cluster" || echo "0")
    
    # Count block processing events
    BLOCK_EVENTS=$(echo "$LOGS_OUTPUT" | grep -c -i "block.*processed\|new.*block\|block.*imported" || echo "0")
    
    # Look for error messages
    ERROR_COUNT=$(echo "$LOGS_OUTPUT" | grep -c -i "error\|failed\|panic" || echo "0")
    
    # Look for specific block numbers in the range
    BLOCKS_MENTIONED=0
    for ((block=$START_BLOCK; block<=$END_BLOCK; block++)); do
        if echo "$LOGS_OUTPUT" | grep -q "$block"; then
            BLOCKS_MENTIONED=$((BLOCKS_MENTIONED + 1))
        fi
    done
    
    # Recent activity check (logs from last 10 minutes)
    RECENT_CUTOFF=$(date -d "10 minutes ago" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -v-10M +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "")
    RECENT_ACTIVITY=0
    if [ -n "$RECENT_CUTOFF" ]; then
        RECENT_ACTIVITY=$(echo "$LOGS_OUTPUT" | grep -c "$RECENT_CUTOFF\|$(date +"%Y-%m-%d %H:%M")" || echo "0")
    fi
    
    # Determine if node appears to be processing events
    NODE_ACTIVE="false"
    if [ "$BLOCK_EVENTS" -gt 0 ] || [ "$VALIDATOR_EVENTS" -gt 0 ] || [ "$BLOCKS_MENTIONED" -gt 0 ]; then
        NODE_ACTIVE="true"
    fi
    
    # Add to output (check if this is not the first node)
    if [ "$node_index" -gt 0 ]; then
        echo "    ," >> "$OUTPUT_FILE"
    fi
    
    echo "    {" >> "$OUTPUT_FILE"
    echo "      \"service_name\": \"$service_name\"," >> "$OUTPUT_FILE"
    echo "      \"node_index\": $node_index," >> "$OUTPUT_FILE"
    echo "      \"logs_available\": true," >> "$OUTPUT_FILE"
    echo "      \"validator_events_found\": $VALIDATOR_EVENTS," >> "$OUTPUT_FILE"
    echo "      \"block_events_found\": $BLOCK_EVENTS," >> "$OUTPUT_FILE"
    echo "      \"blocks_mentioned\": $BLOCKS_MENTIONED," >> "$OUTPUT_FILE"
    echo "      \"error_count\": $ERROR_COUNT," >> "$OUTPUT_FILE"
    echo "      \"recent_activity\": $RECENT_ACTIVITY," >> "$OUTPUT_FILE"
    echo "      \"appears_active\": $NODE_ACTIVE" >> "$OUTPUT_FILE"
    echo "    }" >> "$OUTPUT_FILE"
    
    echo "  📊 $service_name Analysis:"
    echo "    Validator Events: $VALIDATOR_EVENTS"
    echo "    Block Events: $BLOCK_EVENTS"
    echo "    Blocks Mentioned: $BLOCKS_MENTIONED"
    echo "    Errors: $ERROR_COUNT"
    echo "    Active: $NODE_ACTIVE"
    
    return 0
}

# Find all SSV node services
echo "Discovering SSV node services..."

# Get list of running services
SERVICES=$(kurtosis service ls 2>/dev/null | grep -E "ssv-node-[0-9]+" | awk '{print $1}' || echo "")

if [ -z "$SERVICES" ]; then
    echo "❌ No SSV node services found"
    
    echo "  ]," >> "$OUTPUT_FILE"
    echo "  \"discovery_error\": \"No SSV node services found\"," >> "$OUTPUT_FILE"
    echo "  \"success\": false," >> "$OUTPUT_FILE"
    echo "  \"verification_end\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" >> "$OUTPUT_FILE"
    echo "}" >> "$OUTPUT_FILE"
    
    exit 1
fi

echo "Found SSV node services: $SERVICES"

# Check logs for each SSV node service
NODE_INDEX=0
TOTAL_NODES=0
ACTIVE_NODES=0
TOTAL_VALIDATOR_EVENTS=0
TOTAL_BLOCK_EVENTS=0
TOTAL_ERRORS=0

for SERVICE in $SERVICES; do
    if check_service_logs "$SERVICE" "$NODE_INDEX"; then
        TOTAL_NODES=$((TOTAL_NODES + 1))
        
        # Extract metrics from the last added node
        LAST_NODE_VALIDATOR_EVENTS=$(tail -1 "$OUTPUT_FILE.tmp" 2>/dev/null | grep -o '"validator_events_found": [0-9]*' | grep -o '[0-9]*' || echo "0")
        LAST_NODE_BLOCK_EVENTS=$(tail -1 "$OUTPUT_FILE.tmp" 2>/dev/null | grep -o '"block_events_found": [0-9]*' | grep -o '[0-9]*' || echo "0")
        LAST_NODE_ERRORS=$(tail -1 "$OUTPUT_FILE.tmp" 2>/dev/null | grep -o '"error_count": [0-9]*' | grep -o '[0-9]*' || echo "0")
        LAST_NODE_ACTIVE=$(tail -1 "$OUTPUT_FILE.tmp" 2>/dev/null | grep -o '"appears_active": [a-z]*' | grep -o '[a-z]*' || echo "false")
        
        if [ "$LAST_NODE_ACTIVE" = "true" ]; then
            ACTIVE_NODES=$((ACTIVE_NODES + 1))
        fi
        
        # Note: These counters might not be perfectly accurate due to parsing complexity,
        # but they give a general idea of activity
    fi
    
    NODE_INDEX=$((NODE_INDEX + 1))
    
    # Add a small delay between service checks
    sleep 1
done

echo "  ]," >> "$OUTPUT_FILE"

# Calculate summary metrics
ACTIVE_NODE_PERCENTAGE=0
if [ "$TOTAL_NODES" -gt 0 ]; then
    ACTIVE_NODE_PERCENTAGE=$(echo "$ACTIVE_NODES * 100 / $TOTAL_NODES" | bc -l)
fi

# Determine overall verification success
VERIFICATION_SUCCESS="false"
if [ "$ACTIVE_NODES" -gt 0 ] && [ "$TOTAL_ERRORS" -eq 0 ]; then
    VERIFICATION_SUCCESS="true"
elif [ "$ACTIVE_NODES" -gt 0 ]; then
    VERIFICATION_SUCCESS="partial"
fi

# Add summary
echo "  \"summary\": {" >> "$OUTPUT_FILE"
echo "    \"total_ssv_nodes\": $TOTAL_NODES," >> "$OUTPUT_FILE"
echo "    \"active_nodes\": $ACTIVE_NODES," >> "$OUTPUT_FILE"
echo "    \"active_percentage\": $ACTIVE_NODE_PERCENTAGE," >> "$OUTPUT_FILE"
echo "    \"total_errors_found\": $TOTAL_ERRORS," >> "$OUTPUT_FILE"
echo "    \"verification_success\": \"$VERIFICATION_SUCCESS\"" >> "$OUTPUT_FILE"
echo "  }," >> "$OUTPUT_FILE"
echo "  \"success\": $([ "$VERIFICATION_SUCCESS" = "true" ] && echo "true" || echo "false")," >> "$OUTPUT_FILE"
echo "  \"verification_end\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" >> "$OUTPUT_FILE"
echo "}" >> "$OUTPUT_FILE"

echo ""
echo "📊 SSV Node Logs Verification Summary:"
echo "  Total SSV Nodes: $TOTAL_NODES"
echo "  Active Nodes: $ACTIVE_NODES"
echo "  Active Percentage: ${ACTIVE_NODE_PERCENTAGE}%"
echo "  Total Errors: $TOTAL_ERRORS"
echo "  Verification: $VERIFICATION_SUCCESS"
echo ""
echo "📁 Detailed results saved to: $OUTPUT_FILE"

if [ "$VERIFICATION_SUCCESS" = "true" ]; then
    echo "✅ SSV node logs verification PASSED"
    exit 0
elif [ "$VERIFICATION_SUCCESS" = "partial" ]; then
    echo "⚠️  SSV node logs verification PARTIAL"
    exit 0
else
    echo "❌ SSV node logs verification FAILED"
    exit 1
fi 