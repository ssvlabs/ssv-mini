# ssv-mini on hive (experiment)

A [hive](https://github.com/ethereum/hive) simulator that boots a minimal SSV devnet and checks the SSV cluster
performs its duties end to end, as a faster alternative to booting the Kurtosis package for e2e tests.

```
geth ── lighthouse BN ── lighthouse VC (validators 0-63)
 │            │
 └── 4× ssv-node (operators 1-4, validators 64-73 from static/keyshares)
```

```bash
hive/run.sh                                   # node/ssv (constants.env), 12s slots
SSV_IMAGE=node/ssv:my-branch hive/run.sh      # any local ssv image
SLOT_SECONDS=4 hive/run.sh                    # faster chain (flaky for timing-sensitive tests, see below)
CHAIN=fresh hive/run.sh                       # no pre-mining: replay registrations on a new chain
hive/run.sh --docker.output                   # stream client logs; any extra args go to hive
hive/run.sh --sim.limit 'ssv/cluster-attests' # run only matching tests
```

Needs Go and Docker. `run.sh` keeps a hive checkout pinned in `hive/.hive` and syncs these clients and the
simulator into it. Results and per-client logs land in `hive/.hive/workspace/logs`; browse them with
`cd hive/.hive && go run ./cmd/hiveview --serve`.

The one test today, `ssv/cluster-attests`, passes once every SSV-managed validator has been live (attested or
proposed, per the beacon node's liveness API) in some epoch.

## Hive or Kurtosis?

| Use | Pick | Why |
|---|---|---|
| A devnet you poke at by hand: scout (`--env mini`), dora, e2m, aetheria | **Kurtosis** (`make run PARAMS_FILE=params-fast.yaml`) | Stays up until you remove it, every tool discovers it, full ethereum-package feature set (monitor, extra CL/EL clients, Anchor, port publishing) |
| "Does my branch still attest / recover / upgrade?" as a repeatable pass/fail check | **Hive** | SSV nodes run 15s after start instead of ~3 min; a test is code with assertions and a result, not a manual log read |
| Many scenarios against one build (faults, partitions, mixed versions) | **Hive** | Subtests share one network; pause, stop, restart and re-network containers from Go |
| CI | **Hive** | One command, exits non-zero on failure, logs per client per test |
| Fork transitions, multiple CL clients, CL p2p, MEV | **Kurtosis** | The hive simulator has one BN + VC and no CL peers yet |
| Reproducing a bug in one function | Neither | A Go unit test in `src/ssv` is faster and deterministic |

Both share the recorded contract txs (`static/recorded/`, made by `scripts/record-txs.sh`), so contract
behaviour is the same in both.

## How hive works

Hive is a test runner for Ethereum clients. Three pieces:

- **The `hive` binary** runs on the host. It builds every image, starts the simulator container, and serves
  an HTTP API the simulator uses to start, stop and connect containers. All containers of a run sit on one
  Docker network.
- **Clients** (`clients/<name>/`): a `Dockerfile` plus an entrypoint script. A client is configured only
  through `HIVE_*` environment variables and files the simulator copies in at start (`WithStaticFiles`).
  `run.sh` writes `.hive/ssv-clients.yaml` to pick the image tag of each one (from `constants.env`, or
  `SSV_IMAGE` for the SSV node).
- **The simulator** (`simulators/ssv/`): a Go program, built into its own container. It is the test suite:
  it renders genesis, starts clients through the
  [`hivesim`](https://pkg.go.dev/github.com/ethereum/hive/hivesim) API, makes assertions, and reports
  pass/fail per test. Clients started inside a test are removed when that test ends.

Clients here:

| Client | What | Notes |
|---|---|---|
| `go-ethereum` | hive's stock geth | Imports `/chain.rlp` (the pre-mined history) before starting |
| `ssv-premine` | `geth --dev`, throwaway | Mines the registrations plus the 8-block follow distance at 1s blocks, then is stopped |
| `ssv-lighthouse-bn` / `-vc` | Lighthouse | Our own: hive's `lighthouse-bn` is stale for Lighthouse v8 |
| `ssv-node` | `FROM node/ssv:<tag>` | Runs `ssvnode start-node --config /hive/input/config.yaml` |

A run of `cluster-attests` (`cluster.go`), with the times of a 12s run:

1. **+0–11s pre-mine.** Start `ssv-premine` on the committed EL genesis, replay the 29 recorded txs, mine
   until they are 9 blocks deep, export blocks 1..head as `chain.rlp`, stop it.
2. **+11s genesis.** Render the CL genesis in-process (`genesis.go`: `eth-genesis-state-generator` +
   `eth2-val-tools`, ~0.5s), shadow-forked onto the pre-mined head and timed one epoch in the past, so the
   chain opens at the end of epoch 0.
3. **+12–15s clients.** geth (with `chain.rlp`), BN, VC (64 validators), then the 4 SSV nodes at once: the
   registry events are already past the follow distance.
4. **+40s first SSV attestation**, in epoch 1 (SSV can't attest in epoch 0).
5. **Pass** when each of the 10 SSV validators was live in some epoch. At 12s that's the end of epoch 1,
   ~6.5 min in.

Why each step is there:

1. **Kurtosis overhead (~4 min before genesis on the default package).** Starlark planning,
   ethereum-package's genesis containers, the deployer image build and a files-artifact container per
   service. Here genesis is rendered in-process from committed templates (`fixtures/genesis`, from
   ethereum-package), and hive starts plain containers in ~1s each.
2. **Contract deployment (~7 min with hardhat).** Hardhat and the ethers scripts wait for a receipt per tx on
   12s blocks. Everything they send is deterministic (same deployer key, nonces, chain id and static keys), so
   `scripts/record-txs.sh` runs them once against anvil and stores the 29 signed txs. Re-record after
   changing the ssv-network version or the static keys.
3. **SSV's 8-block follow distance.** SSV nodes read registry *events*, which can't be put in a genesis
   alloc, and a node exits if its event syncer has nothing to process yet (`event-syncer: last processed
   block is not set`). That's the real reason behind ssv-mini's "wait for block 16". It's hardcoded
   (`DefaultFollowDistance` in ssv), so it's pre-mined. This has to happen per run: SSV rejects a history
   sync whose last block is more than 5 minutes old (`defaultStalenessThreshold`).
4. **Epoch 0.** An SSV node refuses to attest while source == target == genesis
   (`qbft-decide: input data invalid: attestation data source >= target`) and panics if started before
   genesis, hence the genesis one epoch back.
5. **Slot time.** After that, what's left is chain time. `SLOT_SECONDS=4` cuts it by 3×, and SSV picks the
   slot time up from the beacon spec. But QBFT round timeouts are absolute: at 4s every node logged ~340
   round timeouts in one run, and a validator missed epoch 1. Use 12s for anything timing-sensitive.

## Writing tests

Tests are `hivesim.TestSpec`s added to the suite in `main.go`. Each gets a name (`ssv/<name>`), a result and
its own client logs in hiveview. Build-time knobs (`SSV_SLOT_SECONDS`, `SSV_CHAIN`, …) are `ARG`s in the
simulator's `Dockerfile`, passed by `run.sh` as `--sim.buildarg`.

**What you can do to a running network**, from the
[`hivesim`](https://pkg.go.dev/github.com/ethereum/hive/hivesim) API:

| To | Use |
|---|---|
| Start a client with config | `t.StartClient(type, hivesim.Params{...}, hivesim.WithStaticFiles(files))` |
| Freeze / resume a node (keeps its DB, like a hang) | `client.Pause()`, `client.Unpause()` |
| Kill a node | `t.Sim.StopClient(t.SuiteID, t.TestID, client.Container)` |
| Restart with a wiped DB | Stop it, then start a new container with the same config |
| Run a command inside a node (grep logs, read files) | `client.Exec("sh", "-c", "...")` |
| Partition the network | `t.Sim.CreateNetwork`, `ConnectContainer`, `DisconnectContainer` |
| Send txs (more validators, removals, liquidations) | `client.RPC()` on geth, or record more txs with `record-txs.sh` |
| Read chain state | `beaconAPI` in `beacon.go` (head slot, liveness); add endpoints as needed |
| Run another SSV build next to `ssv-node` | Add a second client entry in `run.sh`'s `ssv-clients.yaml` (e.g. `ssv-node-old` with its own image tag) and start some operators with it |

**Share one boot between scenarios.** Booting takes ~15s, but each scenario needs at least an epoch of chain
time (6.4 min at 12s), so scenarios should run against one network rather than each boot their own. A
parent test that starts the clients can run subtests with `t.Run`; it waits for each, and the parent's
clients stay up throughout. Today the boot is inline in `runClusterAttests`: factor it into a function
that returns the clients (`startSSVNodes` currently drops the SSV containers' IDs, so return them too).
A sketch:

```go
suite.Add(hivesim.TestSpec{Name: "cluster", Run: func(t *hivesim.T) {
	c := bootCluster(t) // genesis, geth, BN, VC, SSV nodes; waits until all SSV validators are live
	t.Run(hivesim.TestSpec{Name: "one-operator-down", Run: func(st *hivesim.T) {
		c.ssv[3].Pause()
		defer c.ssv[3].Unpause()
		c.waitLiveFor(st, 2 /* epochs */) // 3 of 4 operators still reach QBFT quorum
	}})
	t.Run(hivesim.TestSpec{Name: "operator-restart", Run: func(st *hivesim.T) { ... }})
}})
```

Order scenarios so ones that leave damage (wiped DB, partition) run last, or give them their own network.

**Assertions.** Prefer chain outcomes over log lines: the beacon liveness API answers "did each validator
attest in epoch N". Pass on "live at least once" rather than "all live in one epoch", since single misses
are normal. For SSV internals (round changes, leader), `Exec` a grep of the node's log, or scrape
`:15000/metrics`.

**Timeouts.** `SSV_TIMEOUT` (default 15 min) bounds a test. Fail fast on start-up problems instead of
waiting it out, as `cluster-attests` does for "no beacon block within 4 slots".

## Results

One machine (OrbStack, 10 CPUs), ssv `stage` @ `0878266ae`, cached images, back to back, single runs, with
another Kurtosis enclave running. Seconds from start:

| | Kurtosis default | Kurtosis `params-fast.yaml` | hive 12s | Kurtosis fast 4s | hive 4s |
|---|---|---|---|---|---|
| SSV nodes running | 464 | 173 | **15** | 73 | **15** |
| first SSV validator live | 591 | 232 | **40** | 95 | **41** |
| every SSV validator live | 1157 | 556 | **389** | **188** | 260 |

The hive 4s run was slower than Kurtosis 4s only because one validator missed epoch 1 (QBFT round
timeouts, see step 5 above): 4s results are noisy in both. Unloaded the day before, hive reached "every SSV
validator live" in 330s at 12s and 148s at 4s.

Kurtosis `params-fast.yaml` gets close to its floor at 12s (~150s to SSV running): ~40s of
Kurtosis/ethereum-package setup and ~110s of live blocks for the follow distance, which ethereum-package
can't pre-mine. "Every validator live" is the end of epoch 1 in both, so the gap is the head start (~2.5 min).

## Findings worth upstreaming

- **ssv: history sync progress can be dropped.** If `SyncHistory` processes blocks and then fails retryably
  (e.g. "block too old"), and its retry returns `ErrNothingToSync`, the joined error matches
  `errors.Is(err, ErrNothingToSync)` in `cli/operator/node.go`. The caller then keeps the *original*
  `fromBlock`, ongoing sync replays the processed blocks, and the node exits with `ErrInferiorBlock`
  ("block is not higher than the last processed block"). Seen here with a pre-mined chain older than 5 minutes.
- **ssv: the follow distance isn't configurable.** Exposing `WithFollowDistance` in the node config would
  let devnets (Kurtosis included) skip most of the block wait.
- **hive's own `lighthouse-bn` client** is stale for Lighthouse v8 (`--execution-endpoints`, `--jwt-secrets`,
  `--disable-enr-auto-update=true`), hence `clients/ssv-lighthouse-*`. Its `go-ethereum` client works as is.

## Limitations / next steps

- Single BN + VC (no CL peers), mDNS discovery, no Anchor, no exporter, no monitor/E2M. Adding a client is a
  `clients/<name>` directory plus a `StartClient` call.
- One test today; the shared-network refactor above is the next step for scenarios.
- `scout.py --env mini` doesn't know about hive containers; read client logs in hiveview or
  `hive/.hive/workspace/logs`.
