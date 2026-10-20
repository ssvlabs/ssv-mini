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
SLOT_SECONDS=4 hive/run.sh                    # faster chain
CHAIN=fresh hive/run.sh                       # no pre-mining: replay registrations on a new chain
hive/run.sh --docker.output                   # stream client logs; any extra args go to hive
```

Needs Go and Docker. `run.sh` keeps a hive checkout pinned in `hive/.hive` and syncs these clients and the
simulator into it. Results and per-client logs land in `hive/.hive/workspace/logs`; browse them with
`cd hive/.hive && go run ./cmd/hiveview --serve`.

The test, `ssv/cluster-attests`, passes once every SSV-managed validator has been live (attested or proposed,
per the beacon node's liveness API) in some epoch.

## Results

Same machine (OrbStack, 10 CPUs), ssv `stage` @ `0878266ae`, cached images.

| | Kurtosis (`make run`) | hive, `CHAIN=fresh`, 12s | hive, premined, 12s | hive, premined, 4s |
|---|---|---|---|---|
| all clients up | ~4m20s | 5s | 21s (incl. 12s pre-mine) | 17s |
| SSV contracts deployed + registered | ~11m50s (hardhat, 12s blocks) | 39s | pre-mined | pre-mined |
| SSV nodes started | ~12m05s (slot 37) | 2m27s | 21s | 17s |
| first SSV validator live | not captured | 6m04s | **31s** | **28s** |
| all 10 SSV validators live | — | not reached (stopped) | 5m30s | **2m28s** |
| whole run (`hive/run.sh`) | — | — | 6m08s | **2m34s** |

The Kurtosis column is read off a `pop-qbft` enclave's container timestamps, so it's indicative only: an ssv
image build was running at the same time.

## Where the time goes, and what this does about it

1. **Kurtosis overhead (~4 min before genesis).** Starlark planning, ethereum-package's genesis containers,
   the deployer image build and a files-artifact container per service. Here the simulator renders genesis
   in-process from committed templates (`fixtures/genesis`, from ethereum-package): it patches the timestamps,
   then runs `eth-genesis-state-generator` and `eth2-val-tools` (~0.5s). hive starts plain containers in ~1s each.
2. **Contract deployment (~7 min).** Hardhat and the ethers scripts wait for a receipt per tx on 12s blocks.
   Everything they send is deterministic (same deployer key, nonces, chain id and static keys), so
   `scripts/record-txs.sh` runs them once against anvil and stores the 29 signed txs in `static/recorded/txs.json` (shared with the Kurtosis `use_recorded_txs` path). The
   simulator just replays them, and they fit in one block. Re-record after changing the ssv-network version or
   the static keys.
3. **SSV's 8-block follow distance.** SSV nodes read registry *events*, which can't be put in a genesis alloc,
   and a node exits if its event syncer has nothing to process yet (`event-syncer: last processed block is not
   set`). That is the real reason behind ssv-mini's "wait for block 16". The premined mode has a throwaway
   `geth --dev` (client `ssv-premine`) mine the registrations plus padding at 1s blocks. The real geth imports
   that chain, and the beacon chain is shadow-forked onto its head. This has to happen per run: SSV rejects a
   history sync whose last block is more than 5 minutes old (`defaultStalenessThreshold`).
4. **Epoch 0.** An SSV node refuses to attest while source == target == genesis
   (`qbft-decide: input data invalid: attestation data source >= target`), so a fresh chain gives it nothing to
   do for its whole first epoch. It also panics if started before genesis. The premined mode puts the beacon
   genesis one epoch in the past, so the chain opens at the end of epoch 0 and the SSV nodes start straight into
   epoch 1.
5. **Slot time.** After that, what's left is real chain time. `SLOT_SECONDS=4` cuts it by 3×, and SSV picks the
   slot time up from the beacon spec. QBFT round timeouts are absolute, though, so at 4s they take a much larger
   share of the slot: use 12s for anything timing-sensitive.

## Findings worth upstreaming

- **ssv: history sync progress can be dropped.** If `SyncHistory` processes blocks and then fails retryably
  (e.g. "block too old"), and its retry returns `ErrNothingToSync`, the joined error matches
  `errors.Is(err, ErrNothingToSync)` in `cli/operator/node.go`. The caller then keeps the *original*
  `fromBlock`, ongoing sync replays the processed blocks, and the node exits with `ErrInferiorBlock`
  ("block is not higher than the last processed block"). Seen here with a pre-mined chain older than 5 minutes.
- **hive's own `lighthouse-bn` client** is stale for Lighthouse v8 (`--execution-endpoints`, `--jwt-secrets`,
  `--disable-enr-auto-update=true`), hence `clients/ssv-lighthouse-*`. Its `go-ethereum` client works as is.

## Limitations / next steps

- Single BN + VC (no CL peers), mDNS discovery, no Anchor, no exporter, no monitor/E2M. Adding a client is a
  `clients/<name>` directory plus a `StartClient` call.
- One test today. hive's strength is many tests against one simulator run; a shared network with several
  test cases (QBFT faults, operator restarts, fork transitions) would amortise the boot.
- `scout.py --env mini` doesn't know about hive containers yet; the client logs are in the workspace instead.
