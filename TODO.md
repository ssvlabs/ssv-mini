# TODO

## High Priority

- [ ] **Align SSV contracts to latest `ssvlabs/ssv-network` repo** — currently using `Zacholme7/ssv-network` fork in `contract/Dockerfile.contract`. Need to switch to the official repo and update deployment scripts.

- [ ] **Pre-built SSV image on Docker Hub** — publish a default `ssvlabs/ssv-node:latest` image so `make run` works without `make prepare`. First-time users shouldn't need to clone and build the SSV repo.

- [ ] **Idempotent `make run`** — currently fails if enclave already exists. Should auto-detect running enclave and either reuse it or prompt to clean.

## Medium Priority

- [ ] **Extract shared constants** — `OWNER_ADDRESS`, `SSV_CONTRACT`, image digests, and mnemonic are duplicated between `generate-static-keys.sh`, `utils/constants.star`, `run-test.sh`, and `params.yaml`. Create a single source of truth (e.g., `constants.env` or parse from `params.yaml`).

- [ ] **`ssv-mini` CLI should delegate to `make`** — currently reimplements kurtosis commands (`clean`, `run`, `service update`). Should call `make -C "$SSV_MINI_REPO" run` etc. to keep logic in one place.

- [ ] **CI pipeline** — run `make prepare && make run` on PR to verify the testnet starts. Could use GitHub Actions with Docker-in-Docker or a self-hosted runner with Kurtosis.

- [ ] **Pre-bake contracts in genesis** — embed SSV contract bytecode into genesis allocations via `additional_preloaded_contracts`. Would eliminate the 48s deploy step + 28s block-1 wait, cutting startup by ~76s.

## Low Priority

- [ ] **Reduce genesis delay** — currently 20s. Reducing to 5-10s saves ~15s on startup.

- [ ] **Lower block 16 threshold** — SSV nodes wait for block 16 before starting. Investigate if a lower threshold (e.g., 8) is sufficient for the Event Syncer.

- [ ] **Pin Kurtosis version** — document minimum required version and add a version check in `make check-deps`.

- [ ] **Parallelize `generate-static-keys.sh`** — keysplit processes 10 validator keys sequentially. Could run in parallel for ~4x speedup.

- [ ] **Health check target** — `make health` that verifies testnet is running: checks enclave status, beacon sync, EL block number, SSV node connectivity.
