# SSV-Mini

Local SSV testnet in ~4 minutes. Kurtosis-based devnet for developing and testing SSV nodes.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (or [OrbStack](https://orbstack.dev/) on macOS)
- [Kurtosis CLI](https://docs.kurtosis.com/install) (`brew install kurtosis-tech/tap/kurtosis-cli`)

**Recommended:** 8+ CPU cores, 16GB+ RAM allocated to Docker.

## Quick Start

```bash
git clone https://github.com/ssvlabs/ssv-mini.git && cd ssv-mini
make prepare    # Clone SSV repo + build Docker image (~5 min first time)
make run        # Start the testnet (~4 min)
```

That's it. Run `make show` to see services and ports, `make logs` to tail SSV node logs.

### Test a specific SSV branch

```bash
SSV_COMMIT=my-feature-branch make prepare
make run
```

### Push code changes to a running testnet (~30s)

```bash
cd ../ssv && docker build -t node/ssv .
cd ../ssv-mini && make restart-ssv-nodes
```

Or use the `ssv-mini` CLI tool from the SSV repo:

```bash
# Install (one time, from ssv-mini repo):
ln -sf "$(pwd)/scripts/ssv-mini" ~/bin/ssv-mini

# Then from the SSV repo:
ssv-mini              # Create testnet or push code to running one
ssv-mini restart      # Rebuild + restart SSV nodes only
ssv-mini logs         # Tail SSV node 0 logs
```

## All Commands

```
make help
```

| Command | Description |
|---------|-------------|
| `make run` | Start testnet (default: Fulu at genesis) |
| `make run-boole` | Start with Boole fork at epoch 3 |
| `make run-gloas` | Start with Gloas/ePBS (EIP-7732) fork at epoch 2 (devnet-6 images) |
| `make reset` | Clean + restart from genesis |
| `make show` | Show running services and ports |
| `make logs` | Tail ssv-node-0 logs (`SERVICE=ssv-node-1` for others) |
| `make clean` | Remove all enclaves |
| `make restart-ssv-nodes` | Restart SSV nodes (after rebuilding image) |
| `make prepare` | Clone SSV repo + build Docker image |
| `make prepare-anchor` | Clone Anchor repo + build Docker image; useful when using custom branch |
| `make prepare-monitor` | Clone E2M repo + build Docker image |
| `make prepare-all` | Build SSV + Anchor + Monitor images |
| `make generate-keys` | Regenerate static operator keys + keyshares |

### Fault Injection

| Command | Description |
|---------|-------------|
| `make stop-el` | Stop geth (simulate EL crash) |
| `make start-el` | Restart stopped geth |
| `make swap-el EL_IMAGE=<img>` | Hot-swap geth to custom image |
| `make restore-el` | Restore default geth |
| `make test-faulty-el` | Bloom filter cross-check test |

Use `EL_SERVICE=el-2-geth-lighthouse` to target the second EL node.

## Configuration

Edit `params.yaml` to customize the network:

```yaml
nodes:
  ssv:
    count: 4      # Valid: 4, 7, 10, 13 (3f+1 for BFT)
  anchor:
    count: 0      # Anchor consensus client nodes

images:
  ssv: "node/ssv"
  anchor: "sigp/anchor:v1.2.0"  # needs to be changed to node/anchor when using local built anchor image

network:
  network_params:
    fulu_fork_epoch: 0  # 0 = active at genesis (default); set large (e.g. 100000) to defer

boole_epoch: 3          # Omit for pre-Boole

use_static_keys: true   # false = regenerate keys at runtime (~40s slower)
```

Pre-built configs:
- `params.yaml` — Fulu at genesis (default)
- `params-boole.yaml` — Alan→Boole fork transitions; needs `SSV_COMMIT=integration/boole-convergence make prepare`
- `params-gloas.yaml` — Fulu→Gloas (ePBS/EIP-7732) transition; needs `SSV_COMMIT=epbs-gloas make prepare` and ethpandaops glamsterdam-devnet-6 client images (digest-pinned; monitor/E2M enabled - prepare it beforehand)
- `params-gloas-multibn.yaml` — same Gloas transition, but each operator gets its own beacon/execution node pair instead of sharing one (see `operator_pairs` below); needs the same `SSV_COMMIT=epbs-gloas make prepare`

```bash
make run PARAMS_FILE=params-boole.yaml
```

### Per-operator beacon and execution nodes (`operator_pairs`)

By default every SSV and Anchor operator shares one beacon node and one execution node.
`operator_pairs` maps each operator onto its own CL/EL pair.

```yaml
operator_pairs:
  - [0]           # op0: pair 0 only
  - [1]           # op1: pair 1 only
  - [2, 0, 1, 3]  # op2: pair 2 primary, then 0, 1, 3 as failover
  - [3]           # op3: pair 3 only
```

- The index is the **global operator index**: Anchor nodes come first, then SSV nodes.
- A pair index selects one `network.participants` entry — its CL **and** its EL.
- Pair indices are **0-based**; the kurtosis service names are **1-based** (`pair 0` is
  `cl-1-...`).
- Omit the key entirely and every operator goes to pair 0, which is the historical behaviour.
- The archive exporter is not an operator and needs no entry.
- go-SSV receives the list `;`-joined (`BeaconNodeAddr`, `ETH1Addr`); Anchor receives it
  `,`-joined (`--beacon-nodes`, `--execution-rpc`) and takes only the primary for
  `--execution-ws`.

**Validator budget.** Every participant group runs its own validator client, and
`main.star` fails the run if `validator_count × count` summed across all groups exceeds 64
— indices 64-73 belong to the aetheria seed, and an overlap would make the VCs and the SSV
operators sign with the same keys. With four pairs use `validator_count: 16` each.

Run the validation suite for this map with `make test-topology`.

### Fork blind spot (`blindspot_pairs`)

`blindspot_pairs` starts a spec-rewriting proxy in front of an existing pair's beacon node
and appends the proxy as a NEW pair index, right after the real participants (pair 0 always
stays a real pair — `infra`, the contract deploy, the block-height gates, the keysplit,
validator registration and the monitor never see a rewritten spec).

```yaml
blindspot_pairs:
  - upstream: 3               # pair 3's CL is proxied; its EL is untouched
    strip: [GLOAS_FORK_EPOCH]
operator_pairs: [[0], [1], [2], [4]]  # op3 now points at pair 4, the proxy
```

- The proxy **deletes** the listed spec key; it never rewrites it to a far-future value. A
  far-future value makes the node log the INFO "fork scheduled" line instead, which is the
  wrong oracle for TRN-04 (the alert watches for the *missing* Info line).
- Limits: the proxy only sits on the CL path (the EL is the upstream pair's, untouched), and
  it adds a network hop — never route timing or fault-injection scenarios through it.
- Requires `make prepare-blindspot-proxy` before bring-up. See the commented example in
  `params-gloas-multibn.yaml` for the full block plus the TRN-05 passthrough call.

## Architecture

```
┌─────────────┐     ┌─────────────┐
│  Geth (EL)  │────▶│ Lighthouse  │
│   ×2 nodes  │     │  (CL) ×2   │
└──────┬──────┘     └──────┬──────┘
       │                   │
  ┌────┴────┐        ┌────┴────┐
  │  SSV    │        │Validator│
  │ Contracts│       │ Clients │
  └────┬────┘        └─────────┘
       │
  ┌────┴──────────────────┐
  │    SSV Nodes ×4       │
  │  (operator clusters)  │
  └───────────────────────┘
```

- **Ethereum layer**: 2× Geth + 2× Lighthouse + validators (74 total)
- **SSV layer**: 4 operator nodes in a BFT cluster with 10 SSV validators
- **Contracts**: SSV Network contracts deployed via Hardhat (ssv-network v2.0.0)

See [CLAUDE.md](CLAUDE.md) for detailed architecture and development notes.

![Architecture](./docs/architecture.png)
