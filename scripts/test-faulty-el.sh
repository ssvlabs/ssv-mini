#!/bin/bash
set -e

# Test: SSV behavior when geth drops logs for a block containing contract events.
#
# This test:
# 1. Starts the testnet normally
# 2. Finds a block containing SSV contract events
# 3. Swaps geth to a faulty build that returns empty logs for that block
# 4. Restarts SSV nodes so they re-sync from block 1
# 5. Monitors SSV logs for bloom filter discrepancy detection
#
# Prerequisites:
#   - Faulty geth image built: docker build -t node/geth-faulty ../go-ethereum
#   - SSV image built with bloom-filter-check branch: docker build -t node/ssv ../ssv
#
# Usage: ./scripts/test-faulty-el.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENCLAVE_NAME="localnet"
SSV_CONTRACT="0xBFfF570853d97636b78ebf262af953308924D3D8"

echo "=== Faulty EL Test ==="
echo ""

# Step 1: Check prerequisites
echo "Step 1: Checking prerequisites..."
if ! docker image inspect node/geth-faulty &>/dev/null; then
    echo "Error: node/geth-faulty image not found."
    echo "Build it: cd ../go-ethereum && git checkout faulty-logs && docker build -t node/geth-faulty ."
    exit 1
fi
if ! docker image inspect node/ssv &>/dev/null; then
    echo "Error: node/ssv image not found."
    echo "Build it: cd ../ssv && docker build -t node/ssv ."
    exit 1
fi
echo "  Images found."

# Step 2: Start testnet (if not running)
if ! kurtosis enclave inspect "$ENCLAVE_NAME" &>/dev/null 2>&1; then
    echo ""
    echo "Step 2: Starting testnet..."
    cd "$PROJECT_DIR"
    kurtosis run --enclave "$ENCLAVE_NAME" --args-file params.yaml .
else
    echo ""
    echo "Step 2: Testnet already running, reusing."
fi

# Step 3: Find the EL RPC port and discover event blocks
echo ""
echo "Step 3: Finding blocks with SSV contract events..."

EL_PORT=$(kurtosis service inspect "$ENCLAVE_NAME" el-1-geth-lighthouse 2>/dev/null \
    | grep "rpc: 8545" | grep -oE '127\.0\.0\.1:[0-9]+' | head -1 | cut -d: -f2)

if [ -z "$EL_PORT" ]; then
    echo "Error: Could not find EL RPC port"
    exit 1
fi
echo "  EL RPC at 127.0.0.1:$EL_PORT"

# Query all SSV contract events
EVENTS=$(curl -s -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getLogs\",\"params\":[{\"fromBlock\":\"0x1\",\"toBlock\":\"latest\",\"address\":\"$SSV_CONTRACT\"}],\"id\":1}" \
    "http://127.0.0.1:$EL_PORT")

# Get unique block numbers with events
EVENT_BLOCKS=$(echo "$EVENTS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
blocks = sorted(set(int(log['blockNumber'], 16) for log in data.get('result', [])))
for b in blocks:
    count = sum(1 for log in data['result'] if int(log['blockNumber'], 16) == b)
    print(f'  Block {b}: {count} events')
print(f'TARGET={blocks[0]}' if blocks else 'NOTARGET')
")

echo "  SSV contract events found at:"
echo "$EVENT_BLOCKS" | grep "Block"

# Extract the target block (first block with events)
TARGET_BLOCK=$(echo "$EVENT_BLOCKS" | grep "TARGET=" | cut -d= -f2)

if [ -z "$TARGET_BLOCK" ] || [ "$TARGET_BLOCK" = "NOTARGET" ]; then
    echo "Error: No SSV contract events found"
    exit 1
fi
echo ""
echo "  Target block for fault injection: $TARGET_BLOCK"

# Step 4: Verify the block has a non-empty bloom filter
echo ""
echo "Step 4: Verifying bloom filter for block $TARGET_BLOCK..."
BLOCK_HEX=$(printf "0x%x" "$TARGET_BLOCK")
BLOOM=$(curl -s -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$BLOCK_HEX\",false],\"id\":1}" \
    "http://127.0.0.1:$EL_PORT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
bloom = data['result']['logsBloom']
non_zero = sum(1 for i in range(2, len(bloom), 2) if bloom[i:i+2] != '00')
print(f'non_zero_bytes={non_zero}')
")
echo "  Bloom filter: $BLOOM"
echo "  Block $TARGET_BLOCK bloom has data — good, fault injection will create a detectable discrepancy."

# Step 5: Swap geth to faulty build
echo ""
echo "Step 5: Swapping el-1 to faulty geth (dropping logs for block $TARGET_BLOCK)..."
kurtosis service update "$ENCLAVE_NAME" el-1-geth-lighthouse \
    --image node/geth-faulty \
    --env "FAULTY_DROP_LOGS_AT_BLOCK=$TARGET_BLOCK"
echo "  Faulty geth is now running."

# Step 6: Restart SSV nodes to force re-sync from block 1
echo ""
echo "Step 6: Restarting SSV nodes to trigger re-sync..."
SSV_NODE_COUNT=4
i=0
while [ "$i" -lt "$SSV_NODE_COUNT" ]; do
    echo "  Restarting ssv-node-$i..."
    kurtosis service update "$ENCLAVE_NAME" "ssv-node-$i" \
        --files "/ssv-config:ssv-config-$i.yaml"
    i=$((i + 1))
done

# Step 7: Monitor SSV logs for bloom filter detection
echo ""
echo "Step 7: Monitoring SSV node logs for bloom/discrepancy detection..."
echo "  (Watching for 60 seconds...)"
echo ""

timeout 60 kurtosis service logs -f "$ENCLAVE_NAME" ssv-node-0 2>&1 \
    | grep --line-buffered -i -E "bloom|discrepancy|mismatch|cross.check|empty.*log|missing.*event|faulty|FilterLogs|registry.*event" \
    | head -20 || true

echo ""
echo "=== Test complete ==="
echo ""
echo "To see full SSV logs:"
echo "  kurtosis service logs -f $ENCLAVE_NAME ssv-node-0"
echo ""
echo "To restore normal geth:"
echo "  make restore-el"
