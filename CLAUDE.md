# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

SSV-Mini is a Kurtosis-based development environment for running local SSV (Secret Shared Validators) networks. It provides a complete testnet environment with Ethereum blockchain, SSV nodes, smart contracts, and monitoring tools for SSV protocol development and testing.

## Essential Commands

```bash
make help              # Show all available commands
make prepare           # Clone SSV repo + build Docker image (first time)
make run               # Start the testnet
make reset             # Clean + restart from genesis
make show              # Show running services and ports
make logs              # Tail ssv-node-0 logs (SERVICE=ssv-node-1 for others)
make clean             # Remove all enclaves
make restart-ssv-nodes # Rebuild and restart SSV nodes only
make generate-keys     # Regenerate static operator keys + keyshares
```

### ssv-mini CLI (from SSV repo)

```bash
# Install (from ssv-mini repo):
ln -sf "$(pwd)/scripts/ssv-mini" ~/bin/ssv-mini

# Usage (from SSV repo directory):
ssv-mini              # Create testnet or push code to running one
ssv-mini start        # Force start a new testnet
ssv-mini restart      # Rebuild SSV image and restart nodes only (~30s)
ssv-mini stop         # Stop the testnet
ssv-mini logs [N]     # Tail SSV node N logs
```

### Docker Image Prerequisites

```bash
# Automated (recommended):
make prepare                         # SSV only (default: stage branch)
SSV_COMMIT=main make prepare         # SSV from specific branch
make prepare-all                     # SSV + Anchor + Monitor

# Manual:
cd ../ssv && docker build -t node/ssv .
cd ../anchor && docker build -f Dockerfile.devnet -t node/anchor .
```

### Configuration

Network configuration is controlled via `params.yaml`:
- `nodes.ssv.count` / `nodes.anchor.count`: Node counts
- `use_static_keys`: Use pre-computed keys (default: true, ~40s faster)
- `boole_epoch`: Boole fork activation epoch
- `network.network_params.fulu_fork_epoch`: Set >0 to test Electra→Fulu transition
- `monitor.enabled`: Enable monitoring stack
- `images.*`: Docker image overrides

## Architecture

### Startup Pipeline (5 steps)

1. **Ethereum Network**: EL (geth) + CL (lighthouse) + validators via ethereum-package
2. **Contract Deployment**: SSV contracts deployed via Foundry (forge)
3. **Key Preparation**: Static keys loaded (or generated dynamically if `use_static_keys: false`)
4. **Registration**: Operators + validators registered on-chain
5. **SSV Nodes**: All nodes started in parallel via `plan.add_services()`

### Module Structure

- `main.star`: Orchestration entrypoint — coordinates all 5 steps
- `nodes/ssv/`: SSV node config template + service config
- `nodes/anchor/`: Anchor node startup (parallel for nodes 1+)
- `contract/`: `deployer.star` (deploy contracts), `interactions.star` (register operators/validators)
- `generators/`: `operator-keygen.star`, `validator-keygen.star`, `keysplit.star`
- `blockchain/`: `blocks.star` — block/epoch wait helpers
- `monitor/`: PostgreSQL + Redis + monitor daemon/API
- `utils/`: Constants, image helpers
- `static/`: Pre-computed operator keys + keyshares (committed to repo)
- `scripts/`: `ssv-mini` CLI, `generate-static-keys.sh`, shell helpers

### Key Dependencies

- SSV nodes require EL at block 16+ (Event Syncer needs mature chain)
- Contract deployment needs EL at block 1+
- Static keys assume 4 operators and 10 validators at indices 64-73
- Changing operator/validator counts requires `use_static_keys: false` or `make generate-keys`

## Health Checks

```bash
# Beacon chain sync status
curl -s http://127.0.0.1:33001/eth/v1/node/syncing | jq .

# Current slot
curl -s http://127.0.0.1:33001/eth/v1/beacon/headers/head | jq '.data.header.message.slot'

# Validator count
curl -s http://127.0.0.1:33001/eth/v1/beacon/states/head/validators | jq '.data | length'

# EL block number (port from `make show`)
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://127.0.0.1:<el-rpc-port> | jq -r '.result'
```

## Development Notes

- Starlark files: 4-space indent, snake_case functions, UPPER_SNAKE_CASE constants
- All `plan.*` calls should include a `description` parameter for readable progress output
- Network ID: `3151908`
- SSV nodes use mDNS discovery (local) or discv5 (with ENR bootnodes)
- Default: 4-operator clusters with Byzantine fault tolerance
- `tail -f /dev/null` for idle service entrypoints (not `sleep 99999`)

## Troubleshooting

- **Kurtosis version mismatch**: `brew upgrade kurtosis-tech/tap/kurtosis-cli && kurtosis engine restart`
- **Docker not running**: Start Docker Desktop / OrbStack first
- **Stale enclave**: `make clean && make run`
- **Resource constraints**: Docker needs 8+ CPUs, 16GB+ RAM recommended

## TODO

- [ ] Align SSV contracts to latest `ssvlabs/ssv-network` repo (currently using `Zacholme7/ssv-network` fork)
