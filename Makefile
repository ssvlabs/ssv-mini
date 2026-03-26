ENCLAVE_NAME?=localnet
PARAMS_FILE?=params.yaml
SSV_NODE_COUNT?=4
SSV_COMMIT?=stage

default: run

# ── Quick start ──────────────────────────────────────────────────────
# Prerequisites: docker, kurtosis CLI
# First time:  make prepare && make run
# Subsequent:  make run (uses cached images)

.PHONY: run
run: ensure-keys
	@echo "──── Starting SSV testnet ────"
	kurtosis run --enclave $(ENCLAVE_NAME) --args-file $(PARAMS_FILE) .

.PHONY: reset
reset: clean run

.PHONY: clean
clean:
	kurtosis clean -a

.PHONY: show
show:
	kurtosis enclave inspect $(ENCLAVE_NAME)

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

.PHONY: prepare-ssv
prepare-ssv:
	@if [ ! -d "../ssv" ]; then \
		echo "Cloning SSV repo ($(SSV_COMMIT))..." && \
		git clone https://github.com/ssvlabs/ssv.git ../ssv; \
	fi
	@cd ../ssv && git fetch origin && git checkout $(SSV_COMMIT)
	@echo "Building SSV image..."
	@cd ../ssv && docker build -t node/ssv .

.PHONY: prepare-anchor
prepare-anchor:
	@if [ ! -d "../anchor" ]; then \
		echo "Cloning Anchor repo..." && \
		git clone https://github.com/sigp/anchor.git ../anchor; \
	fi
	@cd ../anchor && git fetch origin && git checkout origin/unstable
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
	@echo "  make prepare-anchor  Build Anchor image"
	@echo "  make prepare-all     Build all images"
	@echo ""
	@echo "Network scenarios:"
	@echo "  make run                             Default: Electra (pre-Boole)"
	@echo "  make run-boole                       Boole fork at epoch 3, Fulu at epoch 5"
	@echo "  make run PARAMS_FILE=custom.yaml     Custom params"
	@echo ""
	@echo "Configuration:"
	@echo "  SSV_COMMIT=main make prepare   Use a specific SSV branch"
	@echo ""
	@echo "Static keys:"
	@echo "  make generate-keys   Regenerate static operator keys + keyshares"
	@echo ""
	@echo "Tests:"
	@echo "  make test-faulty-el  Bloom filter cross-check test (needs bloom-check SSV)"

# ── Network scenarios ────────────────────────────────────────────────

.PHONY: run-boole
run-boole: ensure-keys
	@echo "──── Starting SSV testnet (Boole fork at epoch 3) ────"
	kurtosis run --enclave $(ENCLAVE_NAME) --args-file params-boole.yaml .

# ── Tests ────────────────────────────────────────────────────────────

.PHONY: test-faulty-el
test-faulty-el:
	@./tests/faulty-el/run-test.sh
