ENCLAVE_NAME?=localnet
PARAMS_FILE?=params.yaml
SSV_NODE_COUNT?=4
SSV_COMMIT?=stage
ANCHOR_COMMIT?=unstable
# Minimum free disk (GiB) in the Docker VM before a run. Geth self-terminates below its
# ~1.62GiB low-disk safety threshold, which freezes the chain mid-run (EL gone → CL gets no
# payloads). Guarded with headroom by check-deps; override for tiny/large runs.
MIN_DISK_GIB?=10

default: run

# ── Quick start ──────────────────────────────────────────────────────
# Prerequisites: docker, kurtosis CLI
# First time:  make prepare && make run
# Subsequent:  make run (uses cached images)

.PHONY: check-deps
check-deps:
	@command -v docker >/dev/null 2>&1 || { echo "Error: docker not found. Install: https://docs.docker.com/get-docker/"; exit 1; }
	@command -v kurtosis >/dev/null 2>&1 || { echo "Error: kurtosis not found. Install: https://docs.kurtosis.com/install"; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "Error: Docker daemon not running. Start Docker/OrbStack first."; exit 1; }
# Approximate free space in the Docker storage backend: the alpine overlay and Kurtosis volumes
# (where geth's chaindata lives) share the VM data-root on Docker Desktop/OrbStack, so this is a
# good proxy rather than an exact volume measurement. Fails open — if `docker run` can't execute
# (offline, registry/proxy blocked) avail is empty and the check is skipped, not failed.
	@avail=$$(docker run --rm alpine df -P / 2>/dev/null | awk 'NR==2{printf "%d", $$4/1024/1024}'); \
	if [ -n "$$avail" ] && [ "$$avail" -lt "$(MIN_DISK_GIB)" ]; then \
		echo "Error: Docker storage backend has only ~$${avail}GiB free (need >= $(MIN_DISK_GIB)GiB)."; \
		echo "  Geth self-terminates below ~1.62GiB free (low-disk safety), freezing the chain mid-run."; \
		echo "  Free space:  docker builder prune -af && docker system prune -f   (or raise Docker Desktop's disk image size)."; \
		exit 1; \
	fi

# Optional params overrides, substituted into a generated copy of PARAMS_FILE (the sources stay
# untouched). GLOAS_FORK_EPOCH retunes the ePBS fork (gloas params only); BOOLE_FORK_EPOCH retunes
# the SSV Boole fork (boole params only); PRE_REGISTER_VALIDATORS bulk-registers the static
# keyshares at bring-up (see main.star Step 4), and PRE_REGISTER_COUNT registers only the first N of
# them — the aetheria#176 pool split, leaving the rest for the executor's committee suites (cohort D).
# SSV_COUNT / ANCHOR_COUNT override nodes.ssv.count /
# nodes.anchor.count to run a mixed SSV+Anchor committee (e.g. SSV_COUNT=2 ANCHOR_COUNT=2 for the
# aetheria (boole) cross-client interop run); their sum must be a valid cluster size (4/7/10/13).
# (SSV_COUNT sets the bring-up node count; the separate SSV_NODE_COUNT above only drives the
# restart-ssv-nodes helper.)
GLOAS_FORK_EPOCH?=
BOOLE_FORK_EPOCH?=
PRE_REGISTER_VALIDATORS?=
PRE_REGISTER_COUNT?=
SSV_COUNT?=
ANCHOR_COUNT?=
GENERATED_PARAMS=.params.generated.yaml

.PHONY: run
run: check-deps ensure-keys
	@PARAMS="$(PARAMS_FILE)"; \
	if [ -n "$(GLOAS_FORK_EPOCH)" ] || [ -n "$(BOOLE_FORK_EPOCH)" ] || [ -n "$(PRE_REGISTER_VALIDATORS)" ] || [ -n "$(PRE_REGISTER_COUNT)" ] || [ -n "$(SSV_COUNT)" ] || [ -n "$(ANCHOR_COUNT)" ]; then \
		cp "$(PARAMS_FILE)" "$(GENERATED_PARAMS)"; \
		if [ -n "$(GLOAS_FORK_EPOCH)" ]; then \
			grep -q '^[[:space:]]*gloas_fork_epoch:' "$(GENERATED_PARAMS)" || { echo "Error: GLOAS_FORK_EPOCH set but $(PARAMS_FILE) has no gloas_fork_epoch key"; exit 1; }; \
			sed -E 's|^([[:space:]]*gloas_fork_epoch:)[[:space:]]*[0-9]+.*|\1 $(GLOAS_FORK_EPOCH)|' "$(GENERATED_PARAMS)" > "$(GENERATED_PARAMS).tmp" && mv "$(GENERATED_PARAMS).tmp" "$(GENERATED_PARAMS)"; \
		fi; \
		if [ -n "$(BOOLE_FORK_EPOCH)" ]; then \
			grep -q '^[[:space:]]*boole_epoch:' "$(GENERATED_PARAMS)" || { echo "Error: BOOLE_FORK_EPOCH set but $(PARAMS_FILE) has no boole_epoch key"; exit 1; }; \
			sed -E 's|^([[:space:]]*boole_epoch:)[[:space:]]*[0-9]+.*|\1 $(BOOLE_FORK_EPOCH)|' "$(GENERATED_PARAMS)" > "$(GENERATED_PARAMS).tmp" && mv "$(GENERATED_PARAMS).tmp" "$(GENERATED_PARAMS)"; \
		fi; \
		if [ -n "$(PRE_REGISTER_VALIDATORS)" ]; then \
			grep -q '^pre_register_validators:' "$(GENERATED_PARAMS)" || { echo "Error: PRE_REGISTER_VALIDATORS set but $(PARAMS_FILE) has no pre_register_validators key"; exit 1; }; \
			sed -E 's|^(pre_register_validators:).*|\1 $(PRE_REGISTER_VALIDATORS)|' "$(GENERATED_PARAMS)" > "$(GENERATED_PARAMS).tmp" && mv "$(GENERATED_PARAMS).tmp" "$(GENERATED_PARAMS)"; \
		fi; \
		if [ -n "$(PRE_REGISTER_COUNT)" ]; then \
			grep -q '^pre_register_count:' "$(GENERATED_PARAMS)" || { echo "Error: PRE_REGISTER_COUNT set but $(PARAMS_FILE) has no pre_register_count key"; exit 1; }; \
			case "$(PRE_REGISTER_COUNT)" in ''|*[!0-9]*|0?*) echo "Error: PRE_REGISTER_COUNT must be a non-negative integer with no leading zeros (a leading 0 could parse as octal in YAML 1.1), got: '$(PRE_REGISTER_COUNT)'"; exit 1;; esac; \
			sed -E 's|^(pre_register_count:).*|\1 $(PRE_REGISTER_COUNT)|' "$(GENERATED_PARAMS)" > "$(GENERATED_PARAMS).tmp" && mv "$(GENERATED_PARAMS).tmp" "$(GENERATED_PARAMS)"; \
		fi; \
		if [ -n "$(SSV_COUNT)" ]; then \
			grep -qE '^[[:space:]]*ssv:[[:space:]]*$$' "$(GENERATED_PARAMS)" || { echo "Error: SSV_COUNT set but $(PARAMS_FILE) has no nodes.ssv block"; exit 1; }; \
			sed -E '/^[[:space:]]*ssv:[[:space:]]*$$/,/count:/ s|^([[:space:]]*count:)[[:space:]]*[0-9]+.*|\1 $(SSV_COUNT)|' "$(GENERATED_PARAMS)" > "$(GENERATED_PARAMS).tmp" && mv "$(GENERATED_PARAMS).tmp" "$(GENERATED_PARAMS)"; \
		fi; \
		if [ -n "$(ANCHOR_COUNT)" ]; then \
			grep -qE '^[[:space:]]*anchor:[[:space:]]*$$' "$(GENERATED_PARAMS)" || { echo "Error: ANCHOR_COUNT set but $(PARAMS_FILE) has no nodes.anchor block"; exit 1; }; \
			sed -E '/^[[:space:]]*anchor:[[:space:]]*$$/,/count:/ s|^([[:space:]]*count:)[[:space:]]*[0-9]+.*|\1 $(ANCHOR_COUNT)|' "$(GENERATED_PARAMS)" > "$(GENERATED_PARAMS).tmp" && mv "$(GENERATED_PARAMS).tmp" "$(GENERATED_PARAMS)"; \
		fi; \
		PARAMS="$(GENERATED_PARAMS)"; \
		echo "──── Params overrides applied ($$PARAMS): GLOAS_FORK_EPOCH=$(GLOAS_FORK_EPOCH) BOOLE_FORK_EPOCH=$(BOOLE_FORK_EPOCH) PRE_REGISTER_VALIDATORS=$(PRE_REGISTER_VALIDATORS) PRE_REGISTER_COUNT=$(PRE_REGISTER_COUNT) SSV_COUNT=$(SSV_COUNT) ANCHOR_COUNT=$(ANCHOR_COUNT) ────"; \
	fi; \
	echo "──── Starting SSV testnet ────"; \
	kurtosis run --enclave $(ENCLAVE_NAME) --args-file "$$PARAMS" .

# reset rebuilds OUR enclave only: scoped teardown (ssv-mini-down) then run. Uses ssv-mini-down
# rather than `clean` so a re-run on a shared host/CI runner doesn't wipe co-tenant enclaves.
.PHONY: reset
reset: ssv-mini-down run

# clean is the engine-wide nuke: `kurtosis clean -a` removes ALL enclaves on the host, not just
# ours. Kept as a manual escape hatch; automated setup/teardown use the scoped ssv-mini-down below.
.PHONY: clean
clean:
	kurtosis clean -a

.PHONY: show
show:
	kurtosis enclave inspect $(ENCLAVE_NAME)

# ssv-mini-down: scoped teardown of OUR enclave only (vs `clean`, which is engine-wide). Used by
# `reset` and the aetheria orchestrator's TeardownLocalTestnet. `|| true` keeps it idempotent so a
# repeat teardown (or teardown after a failed bring-up, when the enclave never came up) doesn't error.
.PHONY: ssv-mini-down
ssv-mini-down:
	kurtosis enclave rm -f $(ENCLAVE_NAME) 2>/dev/null || true

SERVICE?=ssv-node-0
.PHONY: logs
logs:
	kurtosis service logs -f $(ENCLAVE_NAME) $(SERVICE)

.PHONY: restart-ssv-nodes
restart-ssv-nodes:
	@echo "Restarting $(SSV_NODE_COUNT) SSV nodes..."
	@i=0; while [ "$$i" -lt "$(SSV_NODE_COUNT)" ]; do \
		echo "  Updating ssv-node-$$i..."; \
		kurtosis service update $(ENCLAVE_NAME) ssv-node-$$i \
			--files "/ssv-config:ssv-config-$$i.yaml"; \
		i=$$((i + 1)); \
	done

# ── Image preparation ────────────────────────────────────────────────

.PHONY: prepare
prepare: prepare-ssv

# prepare-ssv builds node/ssv at the FRESHEST commit for SSV_COMMIT (branch, tag, or commit).
# For a branch we detach at origin/<branch>; a plain `git checkout <branch>` lands on a local
# branch that `git fetch` does not fast-forward — that is how a stale (v2.3.1) node got rebuilt.
.PHONY: prepare-ssv
prepare-ssv:
	@if [ ! -d "../ssv" ]; then \
		echo "Cloning SSV repo ($(SSV_COMMIT))..." && \
		git clone https://github.com/ssvlabs/ssv.git ../ssv; \
	fi
	@echo "Checking out SSV $(SSV_COMMIT) at its freshest commit..."
	@cd ../ssv && git fetch origin --tags --force && \
		( git checkout --detach "origin/$(SSV_COMMIT)" 2>/dev/null || git checkout --detach "$(SSV_COMMIT)" )
	@echo "Building SSV image..."
	@cd ../ssv && docker build -t node/ssv .

# prepare-anchor builds node/anchor at the FRESHEST commit for ANCHOR_COMMIT
# (branch, tag, or commit). Same detach-at-origin pattern as prepare-ssv.
.PHONY: prepare-anchor
prepare-anchor:
	@if [ ! -d "../anchor" ]; then \
		echo "Cloning Anchor repo ($(ANCHOR_COMMIT))..." && \
		git clone https://github.com/sigp/anchor.git ../anchor; \
	fi
	@echo "Checking out Anchor $(ANCHOR_COMMIT) at its freshest commit..."
	@cd ../anchor && git fetch origin --tags --force && \
		( git checkout --detach "origin/$(ANCHOR_COMMIT)" 2>/dev/null || git checkout --detach "$(ANCHOR_COMMIT)" )
	@echo "Building Anchor image..."
	@cd ../anchor && docker build -f Dockerfile.devnet -t node/anchor .

.PHONY: prepare-monitor
prepare-monitor:
	@if [ ! -d "../ethereum2-monitor" ]; then \
		echo "Cloning Monitor repo..." && \
		git clone https://github.com/ssvlabs/ethereum2-monitor.git ../ethereum2-monitor; \
	fi
	@cd ../ethereum2-monitor && git fetch origin && git checkout origin/main
	@echo "Building Monitor image..."
	@cd ../ethereum2-monitor && docker build -t monitor .

.PHONY: prepare-all
prepare-all: prepare-ssv prepare-anchor prepare-monitor

# ── Fault injection (EL node management) ─────────────────────────────

EL_SERVICE?=el-1-geth-lighthouse
EL_IMAGE?=node/geth-faulty

# Swap EL node to a custom image (e.g. faulty geth build)
# Usage: make swap-el EL_IMAGE=node/geth-faulty
#        make swap-el EL_IMAGE=ethereum/client-go:v1.15.0 EL_SERVICE=el-2-geth-lighthouse
.PHONY: swap-el
swap-el:
	@echo "Swapping $(EL_SERVICE) to image: $(EL_IMAGE)"
	kurtosis service update $(ENCLAVE_NAME) $(EL_SERVICE) --image $(EL_IMAGE)
	@echo "Done. $(EL_SERVICE) is now running $(EL_IMAGE)"

# Restore EL node to the default geth image from params.yaml
.PHONY: restore-el
restore-el:
	@echo "Restoring $(EL_SERVICE) to default geth image..."
	kurtosis service update $(ENCLAVE_NAME) $(EL_SERVICE) --image ethereum/client-go:v1.16.7
	@echo "Done. $(EL_SERVICE) restored."

# Stop an EL node (simulate crash)
.PHONY: stop-el
stop-el:
	@echo "Stopping $(EL_SERVICE)..."
	kurtosis service stop $(ENCLAVE_NAME) $(EL_SERVICE)
	@echo "$(EL_SERVICE) stopped."

# Start a previously stopped EL node
.PHONY: start-el
start-el:
	@echo "Starting $(EL_SERVICE)..."
	kurtosis service start $(ENCLAVE_NAME) $(EL_SERVICE)
	@echo "$(EL_SERVICE) started."

# ── Static key generation ────────────────────────────────────────────

.PHONY: generate-keys
generate-keys:
	@./scripts/generate-static-keys.sh

# Auto-generate static keys if missing (called by run)
.PHONY: ensure-keys
ensure-keys:
	@if [ ! -f static/keyshares/out.json ]; then \
		echo "Static keys not found. Generating..."; \
		./scripts/generate-static-keys.sh; \
	fi

# ── Help ─────────────────────────────────────────────────────────────

.PHONY: help
help:
	@echo "SSV-Mini — Local SSV testnet environment"
	@echo ""
	@echo "Quick start:"
	@echo "  make prepare    Clone SSV repo + build Docker image"
	@echo "  make run        Start the testnet"
	@echo ""
	@echo "Common commands:"
	@echo "  make run        Start testnet (uses existing images)"
	@echo "  make reset      Clean + start fresh"
	@echo "  make clean      Remove all enclaves"
	@echo "  make show       Show running services"
	@echo "  make logs       Tail ssv-node-0 logs (SERVICE=ssv-node-1 for others)"
	@echo ""
	@echo "Node management:"
	@echo "  make restart-ssv-nodes   Rebuild and restart SSV nodes"
	@echo ""
	@echo "Fault injection (EL):"
	@echo "  make swap-el EL_IMAGE=node/geth-faulty   Swap EL to custom image"
	@echo "  make restore-el                          Restore EL to default geth"
	@echo "  make stop-el                             Stop EL (simulate crash)"
	@echo "  make start-el                            Restart stopped EL"
	@echo "  EL_SERVICE=el-2-geth-lighthouse make stop-el   Target specific EL"
	@echo ""
	@echo "Image building:"
	@echo "  make prepare         Build SSV image (default: stage branch)"
	@echo "  make prepare-anchor  Build Anchor image (default: unstable)"
	@echo "  make prepare-monitor Build Monitor image"
	@echo "  make prepare-all     Build all images"
	@echo ""
	@echo "Network scenarios:"
	@echo "  make run                             Default: Fulu at genesis"
	@echo "  make run-boole                       Boole fork, epoch 3 (BOOLE_FORK_EPOCH=N to retune)"
	@echo "  make run-boole-interop               Boole fork, 2 SSV + 2 Anchor committee (cross-client interop)"
	@echo "  make run-gloas                       Gloas/ePBS fork, epoch 2 (GLOAS_FORK_EPOCH=N to retune; devnet-6 images)"
	@echo "  make run PARAMS_FILE=custom.yaml     Custom params"
	@echo ""
	@echo "Configuration:"
	@echo "  SSV_COMMIT=main make prepare             Use a specific SSV branch"
	@echo "  ANCHOR_COMMIT=main make prepare-anchor   Use a specific Anchor ref"
	@echo ""
	@echo "Static keys:"
	@echo "  make generate-keys   Regenerate static operator keys + keyshares"
	@echo ""
	@echo "Tests:"
	@echo "  make test-faulty-el  Bloom filter cross-check test (needs bloom-check SSV)"

# ── Network scenarios ────────────────────────────────────────────────

.PHONY: run-boole
run-boole:
	@echo "──── Starting SSV testnet (Boole fork) ────"
	@$(MAKE) --no-print-directory run PARAMS_FILE=params-boole.yaml

# 2 SSV + 2 Anchor mixed committee for the aetheria (boole) cross-client interop run. Add
# BOOLE_FORK_EPOCH=N / PRE_REGISTER_VALIDATORS=true like any run-boole run to widen the pre-fork
# window and give the per-validator steps teeth.
.PHONY: run-boole-interop
run-boole-interop:
	@echo "──── Starting SSV+Anchor testnet (Boole fork, 2 SSV + 2 Anchor interop) ────"
	@$(MAKE) --no-print-directory run PARAMS_FILE=params-boole.yaml SSV_COUNT=2 ANCHOR_COUNT=2

.PHONY: run-gloas
run-gloas:
	@echo "──── Starting SSV testnet (Gloas/ePBS fork) ────"
	@$(MAKE) --no-print-directory run PARAMS_FILE=params-gloas.yaml

# ── Tests ────────────────────────────────────────────────────────────

.PHONY: test-faulty-el
test-faulty-el:
	@./tests/faulty-el/run-test.sh
