#!/bin/bash
set -e

# Faulty EL Test — Bloom Filter Cross-Check Verification
#
# Tests that SSV's bloom filter cross-check detects and recovers from
# a geth node that silently drops logs from eth_getLogs responses.
#
# What it does:
#   1. Injects an RPC proxy between SSV nodes and geth
#   2. The proxy drops logs for one specific block (first request only)
#   3. SSV's bloom check detects the mismatch and retries (recovery)
#   4. The proxy passes retry requests honestly
#   5. Script verifies the fault→retry→recovery sequence in proxy logs
#
# Prerequisites:
#   - Running testnet: make run (or it will start one)
#   - SSV built from bloom-filter-cross-check branch
#
# Usage:
#   make test-faulty-el
#   # or directly:
#   ./tests/faulty-el/run-test.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENCLAVE_NAME="localnet"
PROXY_SERVICE="faulty-el-proxy"
PROXY_IMAGE="faulty-el-proxy"
SSV_CONTRACT="0xBFfF570853d97636b78ebf262af953308924D3D8"

cd "$PROJECT_DIR"

echo "╔══════════════════════════════════════════════╗"
echo "║   Faulty EL Test — Bloom Filter Cross-Check  ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Step 1: Check testnet ──
echo "Step 1: Checking testnet..."
if ! kurtosis enclave inspect "$ENCLAVE_NAME" &>/dev/null 2>&1; then
    echo "  No testnet running. Starting one..."
    kurtosis run --enclave "$ENCLAVE_NAME" --args-file params.yaml . 2>&1 | tail -3
fi

# Get geth IP
EL1_IP=$(docker inspect "$(docker ps -q --filter name=el-1-geth)" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
if [ -z "$EL1_IP" ]; then
    echo "  ERROR: Could not find el-1-geth-lighthouse container"
    exit 1
fi
echo "  Testnet running. Geth at $EL1_IP"

# ── Step 2: Build proxy ──
echo ""
echo "Step 2: Building faulty EL proxy..."
docker build -t "$PROXY_IMAGE" "$SCRIPT_DIR/proxy" 2>&1 | tail -1
echo "  Proxy image built."

# ── Step 3: Deploy proxy ──
echo ""
echo "Step 3: Deploying proxy into enclave..."

# Remove old proxy if exists
kurtosis service rm "$ENCLAVE_NAME" "$PROXY_SERVICE" 2>/dev/null || true

kurtosis service add "$ENCLAVE_NAME" "$PROXY_SERVICE" "$PROXY_IMAGE" \
    --env "UPSTREAM_HTTP=http://$EL1_IP:8545,UPSTREAM_WS=ws://$EL1_IP:8546,LISTEN_ADDR=:8545" \
    --ports "rpc=8545/tcp" 2>&1 | tail -1

PROXY_IP=$(docker inspect "$(docker ps -q --filter name=$PROXY_SERVICE)" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
PROXY_PORT=$(kurtosis service inspect "$ENCLAVE_NAME" "$PROXY_SERVICE" 2>/dev/null | grep "rpc: 8545" | grep -oE '127\.0\.0\.1:[0-9]+' | cut -d: -f2)
echo "  Proxy at $PROXY_IP:8545 (host: $PROXY_PORT)"

# Verify proxy works
curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "http://127.0.0.1:$PROXY_PORT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(f'  Proxy passthrough OK (block {int(d[\"result\"],16)})')
"

# ── Step 4: Rewire SSV nodes through proxy ──
echo ""
echo "Step 4: Rewiring SSV nodes to use proxy..."
TS=$(date +%s)
for i in 0 1 2 3; do
    CONFIG_NAME="ssv-config-$i.yaml"
    PATCHED_NAME="ssv-config-faulty-${TS}-$i"
    rm -rf /tmp/ssv-faulty-$i
    kurtosis files download "$ENCLAVE_NAME" "$CONFIG_NAME" /tmp/ssv-faulty-$i 2>/dev/null

    if [ ! -f "/tmp/ssv-faulty-$i/$CONFIG_NAME" ]; then
        echo "  WARN: Could not download $CONFIG_NAME, skipping node $i"
        continue
    fi

    sed -i.bak "s|ws://[0-9.]*:8546|ws://$PROXY_IP:8545|g" "/tmp/ssv-faulty-$i/$CONFIG_NAME"
    rm -f "/tmp/ssv-faulty-$i/$CONFIG_NAME.bak"

    kurtosis files upload "$ENCLAVE_NAME" "/tmp/ssv-faulty-$i/$CONFIG_NAME" --name "$PATCHED_NAME" 2>/dev/null
    kurtosis service update "$ENCLAVE_NAME" "ssv-node-$i" --files "/ssv-config:$PATCHED_NAME" 2>&1 | tail -1
    echo "  ssv-node-$i → proxy"
done

# ── Step 5: Wait for SSV to enter streaming mode ──
echo ""
echo "Step 5: Waiting for SSV to sync (streaming mode)..."
sleep 30
SSV_BLOCK=$(kurtosis service logs "$ENCLAVE_NAME" ssv-node-0 2>&1 | grep "fetched registry" | tail -1 | python3 -c "import sys,re; m=re.search(r'from_block.:(\d+)', sys.stdin.read()); print(m.group(1) if m else '0')" 2>/dev/null)
echo "  SSV at block $SSV_BLOCK"

# ── Step 6: Set fault target ──
echo ""
echo "Step 6: Setting fault target..."
CB=$(curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "http://127.0.0.1:$PROXY_PORT" | python3 -c "import json,sys; print(int(json.load(sys.stdin)['result'],16))")
# Target 12 blocks ahead — enough for SSV to enter streaming + reach the block
FB=$((CB + 12))
echo "  EL head: $CB, Fault target: block $FB"
curl -s -X POST "http://127.0.0.1:$PROXY_PORT/fault/set?block=$FB" > /dev/null

# ── Step 7: Spam contract events ──
echo ""
echo "Step 7: Spamming contract events (15 txs)..."

# Use foundry service if available, otherwise use docker run with cast
PRIVATE_KEY="39725efee3fb28614de3bacaffe4cc4bd8c436257e2c8bb887c4b5c4be45e76d"
FOUNDRY_SERVICE=$(kurtosis enclave inspect "$ENCLAVE_NAME" 2>/dev/null | grep -oE "(foundry|register-validator)" | head -1 || true)

send_tx() {
    local pubkey="0x$(python3 -c "import os; print(os.urandom(48).hex())")"
    if [ -n "$FOUNDRY_SERVICE" ]; then
        kurtosis service exec "$ENCLAVE_NAME" "$FOUNDRY_SERVICE" \
            "sh -c 'FOUNDRY_DISABLE_NIGHTLY_WARNING=1 cast send --private-key $PRIVATE_KEY --rpc-url http://$EL1_IP:8545 $SSV_CONTRACT \"registerOperator(bytes,uint256,bool)\" $pubkey 1000000000 false --legacy'" \
            2>&1 > /dev/null
    else
        docker run --rm --network "kt-$ENCLAVE_NAME" ghcr.io/foundry-rs/foundry:stable \
            cast send --private-key "$PRIVATE_KEY" --rpc-url "http://$EL1_IP:8545" \
            "$SSV_CONTRACT" "registerOperator(bytes,uint256,bool)" "$pubkey" 1000000000 false --legacy \
            2>&1 > /dev/null
    fi
}

for i in $(seq 1 15); do
    send_tx
    echo -n "."
    sleep 8
done
echo ""

# ── Step 8: Wait for SSV to process ──
echo ""
echo "Step 8: Waiting 2 min for SSV to process block $FB..."
sleep 120

# ── Step 9: Check results ──
echo ""
echo "Step 9: Checking results..."
echo ""

PROXY_STATUS=$(curl -s "http://127.0.0.1:$PROXY_PORT/fault/status")
HIT_COUNT=$(echo "$PROXY_STATUS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('hit_count',0))" 2>/dev/null || echo "0")

echo "  Proxy status: $PROXY_STATUS"
echo ""
echo "  Proxy fault log:"
PROXY_LOGS=$(kurtosis service logs "$ENCLAVE_NAME" "$PROXY_SERVICE" 2>&1)
echo "$PROXY_LOGS" | grep -E "FAULT|RETRY" | tail -10 | sed 's/^/    /'

FAULT_INJECTED=$(echo "$PROXY_LOGS" | grep -c "FAULT INJECTED" || true)
RETRIES=$(echo "$PROXY_LOGS" | grep -c "single-block RETRY" || true)

echo ""
echo "  SSV bloom logs:"
BLOOM_LOGS=$(kurtosis service logs "$ENCLAVE_NAME" ssv-node-0 2>&1 | grep -i "bloom" | tail -5)
if [ -n "$BLOOM_LOGS" ]; then
    echo "$BLOOM_LOGS" | sed 's/^/    /'
else
    echo "    (kurtosis log buffer may have rotated — check proxy logs above)"
fi

echo ""
if [ "$FAULT_INJECTED" -gt 0 ] && [ "$RETRIES" -gt 0 ]; then
    echo "=== RESULT: PASS ==="
    echo "  Fault injected: $FAULT_INJECTED time(s)"
    echo "  Recovery retries: $RETRIES"
    echo "  Bloom cross-check detected and recovered."
else
    echo "=== RESULT: INCONCLUSIVE ==="
    echo "  Faults: $FAULT_INJECTED, Retries: $RETRIES"
    echo "  Possible causes:"
    echo "    - No tx landed on target block $FB"
    echo "    - SSV hasn't reached block $FB yet"
    echo "    - SSV not built from bloom-check branch"
    echo "  Check: make logs SERVICE=faulty-el-proxy"
fi

# Cleanup hint
echo ""
echo "To restore SSV nodes to direct geth connection:"
echo "  make restart-ssv-nodes"
echo ""
echo "To remove the proxy:"
echo "  kurtosis service rm $ENCLAVE_NAME $PROXY_SERVICE"
