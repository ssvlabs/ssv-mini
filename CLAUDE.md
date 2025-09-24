# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

SSV-Mini is a Kurtosis-based development environment for running local SSV (Secret Shared Validators) networks. It provides a complete testnet environment with Ethereum blockchain, SSV nodes, smart contracts, and monitoring tools for SSV protocol development and testing.

## Essential Commands

### Core Operations
```bash
# Prepare all required Docker images and dependencies (automated setup)
make prepare

# Start the complete SSV network (blockchain + SSV nodes + contracts)
make run

# View all running services and their status
make show

# Clean shutdown and restart from genesis
make reset

# Clean all Kurtosis enclaves
make clean

# Restart only SSV nodes (after rebuilding SSV Docker image)
make restart-ssv-nodes
```

### Docker Image Prerequisites
Before running the network, build required Docker images. Use `make prepare` for automated setup:

```bash
# Automated setup (recommended) - clones repos and builds all required images
make prepare

# Manual setup (alternative):
# SSV Node (required)
git clone https://github.com/ssvlabs/ssv.git
cd ssv && git checkout %YOUR_BRANCH%
docker build -t node/ssv .

# Anchor Node (if using anchor nodes)
git clone https://github.com/sigp/anchor.git
cd anchor && git checkout origin/unstable
docker build -f Dockerfile.devnet -t node/anchor .

# Monitor (if enabling monitoring)
git clone https://github.com/ssvlabs/ethereum2-monitor.git
cd ethereum2-monitor && docker build -t monitor .
```

### Service Logs and Debugging
```bash
# View logs for specific services
kurtosis service logs -f localnet {service-name}

# Examples:
kurtosis service logs -f localnet ssv-node-0
kurtosis service logs -f localnet anchor-node-0
kurtosis service logs -f localnet el-1-geth-lighthouse
```

### Configuration Management
Network configuration is controlled via `params.yaml`:
- Node counts (`nodes.ssv.count`, `nodes.anchor.count`)
- Validator distribution (`network.participants[].validator_count`)
- Monitoring (`monitor.enabled`)
- Network parameters (`network.network_params`)
- **Port configuration** (`ports.*`) - Predictable port mapping for key services

## Architecture Overview

### High-Level System Components

1. **Ethereum Network Layer** (`blockchain/`):
   - Geth (execution layer) + Lighthouse (consensus layer) 
   - Pre-configured with 74 validators across 2 nodes
   - Automated block production and finalization

2. **SSV Protocol Layer** (`nodes/ssv/`):
   - Configurable number of SSV operator nodes (default: 4)
   - Each node runs with unique operator keys
   - JSON logging, metrics, and API endpoints enabled
   - Custom network configuration for testnet operation

3. **Smart Contract Layer** (`contract/`):
   - Automated SSV contract deployment on network startup
   - Operator registration and validator registration flows
   - Integration with SSV token and cluster contracts

4. **Key Management** (`generators/`):
   - `operator-keygen.star`: Generates operator public/private keypairs
   - `validator-keygen.star`: Creates validator keystores from mnemonics
   - `keysplit.star`: Splits validator keys into keyshares for operators

5. **Monitoring & Observability** (`monitor/`):
   - Optional SSV network monitor with PostgreSQL + Redis
   - Real-time validator performance tracking
   - Grafana dashboards and metrics collection

### Data Flow and Dependencies

1. **Network Initialization**: Ethereum network starts → Smart contracts deploy
2. **Key Generation**: Operator keys generated → Validator keystores created
3. **Key Distribution**: Validator keys split into keyshares → Distributed to operators
4. **Registration**: Operators register on-chain → Validators register with clusters
5. **Operation**: SSV nodes start → Begin validator duties → Monitor tracks performance

### Critical Configuration Files

- `params.yaml`: Main network configuration (node counts, validators, features, ports)
- `main.star`: Main orchestration logic using Kurtosis framework
- `nodes/ssv/config.yml.tmpl`: SSV node configuration template with template variables
- `nodes/anchor/config/config.yaml`: Anchor consensus client configuration
- `utils/constants.star`: Smart contract addresses and network constants
- `kurtosis.yml`: Kurtosis package metadata and description

### Testing and Development Workflow

1. Make code changes to SSV node implementation
2. Rebuild Docker image: `docker build -t node/ssv .`
3. Restart SSV nodes: `make restart-ssv-nodes`
4. Monitor logs: `kurtosis service logs -f localnet ssv-node-0`
5. Use monitoring dashboard or direct API calls for validation

### Service Dependencies

- SSV nodes require mature EL client (waits for block 16+ before starting)
- Monitor requires at least one SSV node in exporter mode
- Contract deployment must complete before node startup
- Key generation and registration must complete before node configuration

## Port Configuration

### Internal Kubernetes Service Access
The following ports are exposed as container ports for internal Kubernetes service access only:

**Key Service Ports:**
- **SSV Node 0 API**: 30100
- **SSV Node 1 API**: 30102  
- **SSV Node 2 API**: 30104
- **SSV Node 3 API**: 30106
- **Ethereum Monitor API**: 30200
- **Ethereum EL RPC**: 30010
- **Ethereum CL API**: 30020

### Configuration Files
- `params.yaml`: Kurtosis port configuration
- `kubernetes/chart/ssv-mini/values.yaml`: Helm chart port configuration

### Kubernetes Service Access
Services expose these ports via ClusterIP for internal pod-to-pod communication:

```bash
# Access SSV Node APIs from within Kubernetes
curl http://<service-name>:30100/health    # SSV Node 0
curl http://<service-name>:30102/health    # SSV Node 1
curl http://<service-name>:30104/health    # SSV Node 2  
curl http://<service-name>:30106/health    # SSV Node 3

# Access Monitor API
curl http://<service-name>:30200/api/status

# Access Ethereum services
curl -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://<service-name>:30010

curl http://<service-name>:30020/eth/v1/node/health
```

## Development Notes

- All Starlark (`.star`) files use Kurtosis framework for service orchestration
- Main orchestration flow in `main.star` coordinates service startup dependencies
- Network ID `3151908` is used for consistent testnet configuration
- SSV nodes use discovery via mdns (local) or discv5 (with ENR bootnodes)
- Default setup creates 4-operator clusters with Byzantine fault tolerance
- Monitor provides PostgreSQL schema and Redis caching for performance data
- Port configuration enables predictable internal Kubernetes service access
- Template-based configuration system using `.tmpl` files for dynamic config generation

### Key Starlark Modules Structure
- `main.star`: Primary orchestration and service coordination
- `nodes/`: Node-specific configuration and startup logic (SSV, Anchor)
- `generators/`: Key generation utilities (operator keys, validator keys, keyshares)
- `contract/`: Smart contract deployment and interaction logic
- `utils/`: Shared utilities, constants, and helper functions
- `monitor/`: Monitoring stack deployment (PostgreSQL, Redis, Monitor)