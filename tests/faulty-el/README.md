# Faulty EL Test — Bloom Filter Cross-Check

Tests SSV's bloom filter cross-check feature by injecting an RPC proxy between
SSV nodes and geth that silently drops logs for a specific block.

## How it works

```
SSV Node ──ws──► Faulty EL Proxy ──ws──► Geth (el-1)
                      │
                      ├─ First request for target block → drops logs (fault)
                      ├─ Retry requests → passes through honestly (recovery)
                      └─ Control API: /fault/set?block=N, /fault/clear, /fault/status
```

1. Proxy intercepts `eth_getLogs` responses over WebSocket
2. For the target block, the first request returns empty logs
3. SSV's bloom check sees: bloom filter has bits set, but 0 logs returned
4. SSV retries with a single-block query → proxy passes it through → logs recovered
5. Test verifies the fault→retry→recovery sequence in proxy logs

## Quick start

```bash
# Prerequisite: SSV image built from bloom-filter-cross-check branch
cd ../ssv && git checkout bloom-filter-cross-check && docker build -t node/ssv .

# Start testnet
cd ../ssv-mini && make run

# Run the test
make test-faulty-el
```

## Manual control

```bash
# Check proxy status
curl http://127.0.0.1:<proxy-port>/fault/status

# Set fault for a specific block
curl -X POST http://127.0.0.1:<proxy-port>/fault/set?block=200

# Clear fault
curl -X POST http://127.0.0.1:<proxy-port>/fault/clear

# View proxy logs
make logs SERVICE=faulty-el-proxy

# Restore SSV nodes to direct geth connection
make restart-ssv-nodes
```

## What PASS means

The proxy logs show this sequence:
```
PROXY: FAULT INJECTED — dropped 2 logs from block N
PROXY: single-block RETRY for block N — passing through (recovery)
```

This proves SSV detected the bloom filter mismatch and successfully recovered the missing logs.
