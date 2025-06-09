#!/bin/bash

# Master Verification Script
# Coordinates both contract events verification and SSV node logs verification

set -e

echo "=== MASTER SPAM VERIFICATION ==="

# Parameters
SSV_NETWORK_ADDRESS="$1"
START_BLOCK="$2"
END_BLOCK="$3"
ETH_RPC_URL="$4"
EXPECTED_EVENTS="$5"
CHECK_CONTRACT_EVENTS="$6"
CHECK_SSV_NODE_LOGS="$7"
TIMEOUT="$8"
OUTPUT_DIR="$9"

if [ -z "$SSV_NETWORK_ADDRESS" ] || [ -z "$START_BLOCK" ] || [ -z "$END_BLOCK" ] || [ -z "$ETH_RPC_URL" ] || [ -z "$EXPECTED_EVENTS" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Usage: master-verification.sh <ssv_address> <start_block> <end_block> <rpc_url> <expected_events> <check_contract> <check_ssv_logs> <timeout> <output_dir>"
    exit 1
fi

echo "Master verification configuration:"
echo "  SSV Contract Address: $SSV_NETWORK_ADDRESS"
echo "  Block Range: $START_BLOCK - $END_BLOCK"
echo "  RPC URL: $ETH_RPC_URL"
echo "  Expected Events: $EXPECTED_EVENTS"
echo "  Check Contract Events: $CHECK_CONTRACT_EVENTS"
echo "  Check SSV Node Logs: $CHECK_SSV_NODE_LOGS"
echo "  Timeout: $TIMEOUT seconds"
echo "  Output Directory: $OUTPUT_DIR"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Initialize master verification results
MASTER_OUTPUT="$OUTPUT_DIR/master_verification.json"
echo "{" > "$MASTER_OUTPUT"
echo "  \"verification_start\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," >> "$MASTER_OUTPUT"
echo "  \"configuration\": {" >> "$MASTER_OUTPUT"
echo "    \"ssv_contract_address\": \"$SSV_NETWORK_ADDRESS\"," >> "$MASTER_OUTPUT"
echo "    \"block_range\": {" >> "$MASTER_OUTPUT"
echo "      \"start\": $START_BLOCK," >> "$MASTER_OUTPUT"
echo "      \"end\": $END_BLOCK" >> "$MASTER_OUTPUT"
echo "    }," >> "$MASTER_OUTPUT"
echo "    \"expected_events\": $EXPECTED_EVENTS," >> "$MASTER_OUTPUT"
echo "    \"check_contract_events\": $CHECK_CONTRACT_EVENTS," >> "$MASTER_OUTPUT"
echo "    \"check_ssv_node_logs\": $CHECK_SSV_NODE_LOGS," >> "$MASTER_OUTPUT"
echo "    \"timeout\": $TIMEOUT" >> "$MASTER_OUTPUT"
echo "  }," >> "$MASTER_OUTPUT"
echo "  \"verification_results\": {" >> "$MASTER_OUTPUT"

# Track overall success
OVERALL_SUCCESS="true"
CONTRACT_VERIFICATION_SUCCESS="skipped"
SSV_LOGS_VERIFICATION_SUCCESS="skipped"

# 1. Contract Events Verification
if [ "$CHECK_CONTRACT_EVENTS" = "true" ]; then
    echo ""
    echo "🔍 Step 1: Verifying contract events via Ethereum API..."
    
    CONTRACT_OUTPUT="$OUTPUT_DIR/contract_events_verification.json"
    
    if timeout "$TIMEOUT" /app/script/verify-contract-events.sh \
        "$SSV_NETWORK_ADDRESS" \
        "$START_BLOCK" \
        "$END_BLOCK" \
        "$ETH_RPC_URL" \
        "$EXPECTED_EVENTS" \
        "$CONTRACT_OUTPUT"; then
        
        CONTRACT_VERIFICATION_SUCCESS="passed"
        echo "✅ Contract events verification completed successfully"
    else
        CONTRACT_VERIFICATION_SUCCESS="failed"
        OVERALL_SUCCESS="false"
        echo "❌ Contract events verification failed"
    fi
    
    # Add contract verification results to master output
    echo "    \"contract_events\": {" >> "$MASTER_OUTPUT"
    echo "      \"status\": \"$CONTRACT_VERIFICATION_SUCCESS\"," >> "$MASTER_OUTPUT"
    echo "      \"output_file\": \"$CONTRACT_OUTPUT\"," >> "$MASTER_OUTPUT"
    
    if [ -f "$CONTRACT_OUTPUT" ]; then
        # Extract key metrics from contract verification
        ACTUAL_EVENTS=$(jq -r '.events_analysis.actual_events // 0' "$CONTRACT_OUTPUT" 2>/dev/null || echo "0")
        SUCCESS_RATE=$(jq -r '.summary.success_rate_percent // 0' "$CONTRACT_OUTPUT" 2>/dev/null || echo "0")
        
        echo "      \"actual_events\": $ACTUAL_EVENTS," >> "$MASTER_OUTPUT"
        echo "      \"success_rate_percent\": $SUCCESS_RATE" >> "$MASTER_OUTPUT"
    else
        echo "      \"actual_events\": 0," >> "$MASTER_OUTPUT"
        echo "      \"success_rate_percent\": 0" >> "$MASTER_OUTPUT"
    fi
    
    echo "    }," >> "$MASTER_OUTPUT"
else
    echo "⏭️  Skipping contract events verification (disabled)"
    echo "    \"contract_events\": {" >> "$MASTER_OUTPUT"
    echo "      \"status\": \"skipped\"," >> "$MASTER_OUTPUT"
    echo "      \"reason\": \"disabled in configuration\"" >> "$MASTER_OUTPUT"
    echo "    }," >> "$MASTER_OUTPUT"
fi

# 2. SSV Node Logs Verification
if [ "$CHECK_SSV_NODE_LOGS" = "true" ]; then
    echo ""
    echo "🔍 Step 2: Verifying SSV node logs..."
    
    SSV_LOGS_OUTPUT="$OUTPUT_DIR/ssv_node_logs_verification.json"
    
    if timeout "$TIMEOUT" /app/script/verify-ssv-node-logs.sh \
        "$START_BLOCK" \
        "$END_BLOCK" \
        "$EXPECTED_EVENTS" \
        "$SSV_LOGS_OUTPUT" \
        "$TIMEOUT"; then
        
        if [ -f "$SSV_LOGS_OUTPUT" ]; then
            VERIFICATION_RESULT=$(jq -r '.summary.verification_success // "failed"' "$SSV_LOGS_OUTPUT" 2>/dev/null || echo "failed")
            
            if [ "$VERIFICATION_RESULT" = "true" ]; then
                SSV_LOGS_VERIFICATION_SUCCESS="passed"
                echo "✅ SSV node logs verification completed successfully"
            elif [ "$VERIFICATION_RESULT" = "partial" ]; then
                SSV_LOGS_VERIFICATION_SUCCESS="partial"
                echo "⚠️  SSV node logs verification partially successful"
            else
                SSV_LOGS_VERIFICATION_SUCCESS="failed"
                OVERALL_SUCCESS="false"
                echo "❌ SSV node logs verification failed"
            fi
        else
            SSV_LOGS_VERIFICATION_SUCCESS="failed"
            OVERALL_SUCCESS="false"
            echo "❌ SSV node logs verification failed - no output file"
        fi
    else
        SSV_LOGS_VERIFICATION_SUCCESS="failed"
        OVERALL_SUCCESS="false"
        echo "❌ SSV node logs verification timed out or failed"
    fi
    
    # Add SSV logs verification results to master output
    echo "    \"ssv_node_logs\": {" >> "$MASTER_OUTPUT"
    echo "      \"status\": \"$SSV_LOGS_VERIFICATION_SUCCESS\"," >> "$MASTER_OUTPUT"
    echo "      \"output_file\": \"$SSV_LOGS_OUTPUT\"," >> "$MASTER_OUTPUT"
    
    if [ -f "$SSV_LOGS_OUTPUT" ]; then
        # Extract key metrics from SSV logs verification
        TOTAL_NODES=$(jq -r '.summary.total_ssv_nodes // 0' "$SSV_LOGS_OUTPUT" 2>/dev/null || echo "0")
        ACTIVE_NODES=$(jq -r '.summary.active_nodes // 0' "$SSV_LOGS_OUTPUT" 2>/dev/null || echo "0")
        ACTIVE_PERCENTAGE=$(jq -r '.summary.active_percentage // 0' "$SSV_LOGS_OUTPUT" 2>/dev/null || echo "0")
        
        echo "      \"total_ssv_nodes\": $TOTAL_NODES," >> "$MASTER_OUTPUT"
        echo "      \"active_nodes\": $ACTIVE_NODES," >> "$MASTER_OUTPUT"
        echo "      \"active_percentage\": $ACTIVE_PERCENTAGE" >> "$MASTER_OUTPUT"
    else
        echo "      \"total_ssv_nodes\": 0," >> "$MASTER_OUTPUT"
        echo "      \"active_nodes\": 0," >> "$MASTER_OUTPUT"
        echo "      \"active_percentage\": 0" >> "$MASTER_OUTPUT"
    fi
    
    echo "    }" >> "$MASTER_OUTPUT"
else
    echo "⏭️  Skipping SSV node logs verification (disabled)"
    echo "    \"ssv_node_logs\": {" >> "$MASTER_OUTPUT"
    echo "      \"status\": \"skipped\"," >> "$MASTER_OUTPUT"
    echo "      \"reason\": \"disabled in configuration\"" >> "$MASTER_OUTPUT"
    echo "    }" >> "$MASTER_OUTPUT"
fi

# Finalize master verification results
echo "  }," >> "$MASTER_OUTPUT"
echo "  \"overall_success\": $OVERALL_SUCCESS," >> "$MASTER_OUTPUT"
echo "  \"verification_end\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" >> "$MASTER_OUTPUT"
echo "}" >> "$MASTER_OUTPUT"

echo ""
echo "=== MASTER VERIFICATION SUMMARY ==="
echo "📊 Verification Results:"
echo "  Contract Events: $CONTRACT_VERIFICATION_SUCCESS"
echo "  SSV Node Logs: $SSV_LOGS_VERIFICATION_SUCCESS"
echo "  Overall Success: $OVERALL_SUCCESS"
echo ""
echo "📁 Verification artifacts saved to: $OUTPUT_DIR"
echo "  - master_verification.json: Complete verification summary"

if [ "$CHECK_CONTRACT_EVENTS" = "true" ]; then
    echo "  - contract_events_verification.json: Contract events analysis"
fi

if [ "$CHECK_SSV_NODE_LOGS" = "true" ]; then
    echo "  - ssv_node_logs_verification.json: SSV node logs analysis"
fi

echo ""
if [ "$OVERALL_SUCCESS" = "true" ]; then
    echo "✅ MASTER VERIFICATION PASSED"
    echo "All enabled verification checks completed successfully!"
    exit 0
else
    echo "❌ MASTER VERIFICATION FAILED"
    echo "One or more verification checks failed. Check individual logs for details."
    exit 1
fi 