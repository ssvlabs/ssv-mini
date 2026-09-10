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
- `pre_register_validators`: Bulk-register the full static keyshare set on-chain at bring-up under the deployer's owner (default: false; needed for per-validator fork-transition coverage, aetheria#141 A2). Registering the FULL set is incompatible with the executor's validator-registering suites (`(event)`/`(ptc)`/`(proposer)`/`(p2p)`) on the same enclave — both register the same pubkeys → `ValidatorAlreadyExists`. To share one enclave, partition the pool with `pre_register_count` below
- `pre_register_count`: Partition the static keyshare pool when `pre_register_validators` is true — register only the first N keyshares (cohort P = indices [64, 64+N)), leaving [64+N, 64+SSV_MANAGED_VALIDATOR_COUNT) for the executor to register as its own cohort D. The index-partitioned P⊎D split lets pre-registration and a validator-registering suite share one enclave (aetheria#176). 0 (default) registers the full set (no split); a positive count must be < the pool size so cohort D is non-empty. Only a CONTIGUOUS prefix is nonce-safe (the sharesData nonce sequence is 0-based; ssvlabs/ssv-mini#36). The actual N (plus the cohort P/D pubkey partition and the registration context — owner, operatorIds, SSVNetwork address) is published at bring-up as the `pre-registered.json` enclave artifact (`kurtosis files download <enclave> pre-registered.json`) — the shared source of truth that lets the executor read N and that context instead of re-declaring them across repos (ssvlabs/ssv-mini#53)
- `unsafe_skip_validator_layout_guard`: Bypass main.star's 64/74 validator-layout guard so a **standalone** base-chain liveness probe can run >64 baseline validators (Gloas devnet stall investigation, ssvlabs/ssv-mini#38). Default false. Safe **only** when no SSV-managed validators are adopted on the enclave (bare run: `pre_register_validators: false` + no executor); combining with `pre_register_validators: true` is rejected in code, and it must not be set against an executor validator suite either, or the extra VCs overlap the seed at 64–73 → double-sign → slashing. See `params-gloas.yaml` for the full contract
- `boole_epoch`: Boole fork activation epoch
- `network.network_params.fulu_fork_epoch`: Fulu activation epoch (default 0 = at genesis; set a small epoch >0 to test the Electra→Fulu transition)
- `monitor.enabled`: Enable monitoring stack
- `images.*`: Docker image overrides

Make-level overrides (substituted into a generated copy of `PARAMS_FILE`, sources untouched):
- `GLOAS_FORK_EPOCH=N`: retune the ePBS fork epoch (gloas params only)
- `BOOLE_FORK_EPOCH=N`: retune the SSV Boole fork epoch (boole params only)
- `PRE_REGISTER_VALIDATORS=true|false`: toggle the flag above without editing the file
- `PRE_REGISTER_COUNT=N`: partition the pool (cohort P = first N keyshares), leaving D for a registering suite — the aetheria#176 split (requires `PRE_REGISTER_VALIDATORS=true`; validated at plan time)

```bash
make reset PARAMS_FILE=params-gloas.yaml GLOAS_FORK_EPOCH=4 PRE_REGISTER_VALIDATORS=true
```

## Architecture

### Startup Pipeline (5 steps)

1. **Ethereum Network**: EL (geth) + CL (lighthouse) + validators via ethereum-package
2. **Contract Deployment**: SSV contracts deployed via Hardhat (ssv-network v2.0.0)
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
- Static keys assume 4 operators and `SSV_MANAGED_VALIDATOR_COUNT` validators at indices [64, 64+that); scale with `SSV_VALIDATOR_COUNT=N ./scripts/generate-static-keys.sh` (regenerate the aetheria seed to the same N)
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

## M3 Fault Injection

- **Prerequisite**: the enclave's SSV image must be the instrumented build — `node/ssv-fault`,
  built from the ssv branch `qa/gloas-m3-fault-menu` — and `$SSV_REPO` (default `../ssv`) must be
  checked out on that same branch, because `make fault-list`/`make fault` enumerate the menu from
  it (`go run ./qa/faults/cmd/list`). On a stock node `FAULT` is silently ignored, so a missed
  prerequisite shows up as the boot-banner timeout below, not a clear setup error.
- Switch a fault with `make fault FAULT=<value> OP=<n>` (`make fault-off OP=<n>` to clear it) —
  never a bare `kurtosis service update`. `make fault` archives the operator's logs first (the
  switch destroys them) and verifies the node reports the requested fault before returning; a bare
  `service update` skips both, and a switch that silently didn't apply looks identical to a fault
  that fired and was correctly ignored — the one failure a test pass cannot detect otherwise.
- `FAULT` is read once at boot. There is no warm switch — every fault change recreates the
  container (~7 s to the boot banner, ~1 slot to the first injected fault). `nodes.ssv.enable_traces`
  does not survive a switch (`--env FAULT=...` replaces the whole env-var list, dropping the OTEL
  pair too).
- **Never run `make restart-ssv-nodes` mid-scenario.** It is a bare, unarchived `kurtosis service
  update` over every node — it destroys every operator's buffered log evidence, including the
  honest operators an M3 oracle reads. Use it only between scenarios, after logs have already been
  read.
- `docker logs <container>` is the only working read path for `ssv-node` on `--env mini`.
  `scout.py --env mini logs query` returns nothing for this service here — a Kurtosis
  log-collection-engine limitation, not an `ssv-mini`/`ssv` defect (see README's "Reading ssv-node
  logs on `--env mini`"). Translate any M3 scenario-card oracle written as a scout query into a
  `docker logs` grep by hand.

## Network Faults (P0.4)

- **Targets**: `make fault-latency OP=n MS=x`, `fault-loss OP=n PCT=x`, `fault-partition OP=n`,
  `restore-net OP=n`, `netem-show OP=n`, `netem-topology`, `stop-cl OP=n`, `start-cl OP=n`.
  Unit tests that need no enclave: `make test-netem`. Implementation: `scripts/netem`.
- **`TARGET` picks the link and matters.** `bn` (default) shapes the operator → its own beacon node;
  `p2p` shapes it → the other operators; `all` is a bare root qdisc over every egress packet. Only
  `all` is unfiltered. Shaping everything when a scenario meant one link is what makes a
  latency-against-convergence measurement unattributable, so state the link explicitly.
- **`tc` comes from a `nicolaka/netshoot` sidecar** sharing the target's network namespace, not from
  the node image — so no image carries `iproute2`, and the same path reaches CL/EL containers, which
  an in-container install cannot (several client images ship neither apt nor tc).
- **Delay is ONE-WAY egress.** `MS=200` gives ≈200 ms RTT, not 400. Record it as injected one-way
  delay. Shaping the return leg would need an `ifb` redirect, deliberately not implemented.
- **Apply is idempotent** — the root qdisc is cleared first, so a 200/500/1000 ms ladder is three
  calls and can never stack two netem qdiscs on one interface. No `tc qdisc change` needed.
- **`stop-cl`/`start-cl` address the OPERATOR**, resolving its beacon node from that operator's
  rendered config (so `operator_pairs` fallbacks are honoured). They **refuse** when that CL also
  backs another operator; `FORCE=1` overrides. The default profiles put every operator on pair 0, so
  the guard fires there — that is deliberate, because "stop operator 3's CL" quietly taking the rest
  of the committee with it is how a BN-outage result gets misattributed.
- **`EL_SERVICE` has no correct default across profiles** — the service name embeds the CL it is
  paired with, so Gloas profiles need `EL_SERVICE=el-1-geth-lodestar`. And **never run `restore-el`
  on a Gloas enclave**: it swaps in stock geth, which has no EIP-7732; the target now refuses on a
  gloas params file unless handed an image explicitly.
- Verify a fault landed with `make netem-show OP=n`, and prove the scoping by pinging the shaped and
  an unshaped host from inside the operator's namespace rather than assuming.

## Running QA pass M4

Full reproducible procedure, including the Docker-memory floor and the P2P pre-flight check:
**`ssv-scout/docs/qa-glamsterdam-m4-runbook.md`**. Read it before following any
`ssv-scout/scenarios/gloas/*.md` card — several card procedures predate this tooling and prescribe a
root-qdisc `kurtosis service exec ... tc` command that shapes the wrong thing.

## Troubleshooting

- **Kurtosis version mismatch**: `brew upgrade kurtosis-tech/tap/kurtosis-cli && kurtosis engine restart`
- **Docker not running**: Start Docker Desktop / OrbStack first
- **Stale enclave**: `make clean && make run`
- **Resource constraints**: Docker needs 8+ CPUs, 16GB+ RAM recommended
