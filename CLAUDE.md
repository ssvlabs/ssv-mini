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
- `buildoor` / `spamoor` / `ssv_builders`: the Gloas builder rig (see "Gloas Builder Rig" below)
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

## SSV Node Fault Injection

- **Prerequisite**: the enclave's SSV image must be a fault-injection build of the node —
  `node/ssv-fault`, built from an ssv branch that carries the `qa/faults/` fault menu — and
  `$SSV_REPO` (default `../ssv`) must be checked out on that same branch, because `make fault-list`/`make fault` enumerate the menu from
  it (`go run ./qa/faults/cmd/list`). On a stock node `FAULT` is silently ignored, so a missed
  prerequisite shows up as the boot-banner timeout below, not a clear setup error.
- Switch a fault with `make fault FAULT=<value> OP=<n>` (`make fault-off OP=<n>` to clear it) —
  never a bare `kurtosis service update`. `make fault` archives the operator's logs first (the
  switch destroys them) and verifies the node reports the requested fault before returning; a bare
  `service update` skips both, and a switch that silently didn't apply looks identical to a fault
  that fired and was correctly ignored — the one failure a test run cannot detect otherwise.
- `FAULT` is read once at boot. There is no warm switch — every fault change recreates the
  container (~7 s to the boot banner, ~1 slot to the first injected fault). `nodes.ssv.enable_traces`
  does not survive a switch (`--env FAULT=...` replaces the whole env-var list, dropping the OTEL
  pair too).
- **Never run `make restart-ssv-nodes` mid-scenario.** It is a bare, unarchived `kurtosis service
  update` over every node — it destroys every operator's buffered log evidence, including the
  honest operators whose logs a fault test checks. Use it only between scenarios, after logs have
  already been read.
- `docker logs <container>` is the reliable read path for `ssv-node`. `kurtosis service logs` can
  return nothing for this service — a Kurtosis log-collection-engine limitation, not an
  `ssv-mini`/`ssv` defect (see README's "Reading ssv-node logs").

## Network Faults

- **Targets**: `make fault-latency OP=n MS=x`, `fault-loss OP=n PCT=x`, `fault-partition OP=n`,
  `restore-net OP=n`, `netem-show OP=n`, `netem-topology`, `stop-cl OP=n`, `start-cl OP=n`.
  Unit tests that need no enclave: `make test-netem`. Implementation: `scripts/netem`.
- **`TARGET` picks the link and matters.** `bn` (default) shapes the operator → its own beacon node;
  `p2p` shapes it → the other operators; `all` is a bare root qdisc over every egress packet. Only
  `all` is unfiltered. Shaping everything when a scenario meant one link is what makes a
  latency-against-convergence measurement unattributable, so state the link explicitly.
- **Do not shape by hand** with `kurtosis service exec ... tc qdisc add dev eth0 root ...`: a bare
  root qdisc shapes every egress packet (the same as `TARGET=all`), not the link the test is about.
  Use the make targets.
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

## Beacon-API Fault Proxy (cl-proxy)

`cl-proxy` (`tests/cl-proxy/proxy.go`) is a reverse proxy between chosen SSV operators and ONE beacon
node. Everything passes through unchanged until a rule is armed, and every request is access-logged. It
replaced the old `tests/blindspot-proxy` and runs both `blindspot_pairs` (spec strip, unchanged behaviour)
and `cl_proxy_pairs` (runtime produce rules). Built for BLD-B-05 (produceBlockV4 version skew).

- **Wiring (params)**: `cl_proxy_pairs: [{upstream: <real pair>}]` appends a pair after the real and
  blind-spot pairs; point operators at it with `operator_pairs`. On `params-gloas.yaml` (2 real pairs):
  `cl_proxy_pairs: [{upstream: 0}]` + `operator_pairs: [[2], [2], [2], [2]]`. Image: `make prepare-cl-proxy`
  (`prepare-blindspot-proxy` is an alias). Rules are not a params key; an unknown key fails the plan.
- **Rules** (produce route `/eth/v4/validator/blocks/{slot}` only; `SLOTS=a,b` limits one to those slots):
  - `post-405`: POST → 405 without reaching the CL, so the node falls back to
    `GET ...&include_payload=true&builder_boost_factor=<n>`. **Lodestar ≥ v1.49.0 has no GET route** (only
    the #630 POST), so by default the proxy serves that GET by forwarding it upstream as a POST with a
    neutral BuilderConfig carrying the GET's boost factor: a #580 GET-only CL, emulated. `TRANSLATE_GET=false`
    forwards the GET untouched instead → the CL's own 404 → a CL that serves neither shape.
  - `no-include-payload`: the CL does not get `include_payload=true` (POST or GET). Default `MODE=false`
    sends `include_payload=false`; a self-building CL then answers with the bare block
    (`Eth-Execution-Payload-Included: false`), i.e. a CL that ignores the flag. `MODE=remove` deletes the
    parameter instead, but **Lodestar v1.49.0 treats it as required** and answers 400 `must have required
    property 'include_payload'` (seen live 2026-10-20), so the node fails on the 400, not on the self-build
    check. Use `MODE=remove` only on a CL that defaults the parameter.
  - `version-header`: rewrites the 2xx produce response's `Eth-Consensus-Version` to `VALUE` (default `fulu`).
- **Runtime control, no node restart**: `make cl-proxy-rule RULE=<rule> STATE=on|off [SLOTS=..]
  [TRANSLATE_GET=..] [VALUE=..] [MODE=..]`, `make cl-proxy-reset`, `make cl-proxy-show` (state + per-rule hit counts),
  `make cl-proxy-log [N=50] [PRODUCE=1]`. `PROXY=cl-proxy-0` is the default. Implementation: `scripts/cl-proxy`
  (`docker exec <proxy> wget` against the proxy's own port, container resolved by enclave labels).
- **Access log** = the "CL access log" BLD-B-05 needs. One JSON line per request: `method path query status
  req_bytes resp_bytes dur_ms rules upstream_method upstream_query consensus_version payload_included`.
  `query` is what the NODE sent; `upstream_*` appear only when a rule changed what went to the CL. The last
  5000 requests are in `make cl-proxy-log`; the full history is `docker logs <proxy> | grep '^cl-proxy-access '`.
- **Arm with `SLOTS=<S>`, not open-ended.** Pick the cluster's next proposal slot `S` from the CL's proposer
  duties and arm for that slot only: the fault then fires exactly once per operator and every other slot stays
  a clean control. An open-ended `no-include-payload` / `version-header` fails EVERY cluster proposal.
- **Topology trap**: the node's produce goes through `firstClientResult`, so an operator with a fallback pair
  in `operator_pairs` would quietly retry the real CL after the proxied failure. Give proxied operators the
  proxy pair only.
- Tests (no enclave): `make test-cl-proxy` (Go rule tests against a fake POST-only CL + `scripts/cl-proxy`
  helpers); `make test-topology` covers `cl_proxy_pairs` validation.
- Limits: CL path only (the EL is the upstream pair's). It adds one local hop, so do not route timing
  scenarios through it.

## Gloas Builder Rig (buildoor)

- **Profile**: `params-gloas-builder.yaml`, `make run-gloas-builder`. Full procedure, measured timeline
  and proof commands: README "Gloas builder rig (buildoor)". Validation suite: `make test-builders`.
- **Modules**: `nodes/buildoor/buildoor.star` (builder, digest-pinned image), `nodes/buildoor/spamoor.star`
  (fixed-tip load), `utils/builders.star` (`ssv_builders` -> the node's top-level `Builders` block, rendered
  as JSON into `config.yml.tmpl`). All three are validated in `main.star` BEFORE ethereum-package starts.
- **Topology rule**: buildoor attaches to pair 1 (`cl-2`); SSV operators stay on `cl-1`. Lodestar >= v1.47
  does not add API-published bids to its own bid pool, so an operator on the builder's CL never sees its p2p
  bids. `buildoor.validate` fails the run on any operator (primary, fallback or blind-spot proxy) on that pair.
  `cl-2`'s own VC proposals always self-build; that is expected.
- **Do not bump ethereum-package off 6.1.0** to get its `mev_type: buildoor`; 6.1.0's integration predates the
  launcher fixes on its main. Bumping it moves every client default at once.
- **`Builders` is a bring-up parameter.** Never change it with `kurtosis service update` (drops file mounts,
  cold-resyncs the node). `overrides` REPLACES `shared` for one global operator index; `{}` = no block.
- **Timing**: builder registered at the fork (slot 64), active at epoch 4 (first win slot 129, first cluster
  win slot 135, ~27 min after genesis). Before that buildoor answers the builder API with
  `204 - no builder key active on chain`; that is not a wiring fault.
- **Runtime control**: `POST $(kurtosis port print localnet buildoor api)/api/buildoor/action-plan`, e.g.
  `{"updates":[{"slots":[N],"reveal":{"mode":"disabled"}}]}` withholds the payload -> slot N is Empty.
- **Start-up effect**: the proposer-preferences duties emitted in a node's first minutes can miss quorum
  (only the node's own partial arrives), so that epoch's proposals carry no request auth. Judge the overlay
  from the second post-start epoch on.

## Troubleshooting

- **Kurtosis version mismatch**: `brew upgrade kurtosis-tech/tap/kurtosis-cli && kurtosis engine restart`
- **Docker not running**: Start Docker Desktop / OrbStack first
- **Stale enclave**: `make clean && make run`
- **Resource constraints**: Docker needs 8+ CPUs, 16GB+ RAM recommended
