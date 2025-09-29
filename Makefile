ENCLAVE_NAME=localnet
PARAMS_FILE=params.yaml
SSV_NODE_COUNT?=4
ENCLAVE_NAME?=localnet
SSV_COMMIT?=stage

default: run-with-prepare

# Run with prepare: Downloads latest repos (ssv stage, anchor unstable, ethereum2-monitor main) and builds Docker images
.PHONY: run-with-prepare
run-with-prepare: prepare
	kurtosis run --verbosity DETAILED --enclave ${ENCLAVE_NAME} . "$$(cat ${PARAMS_FILE})"

# Run without prepare: Uses existing local repos and Docker images (for custom branches/versions)
.PHONY: run
run:
	kurtosis run --verbosity DETAILED --enclave ${ENCLAVE_NAME} . "$$(cat ${PARAMS_FILE})"

# Reset with prepare: Clean and run with latest repos and fresh Docker images
.PHONY: reset-with-prepare
reset-with-prepare: prepare
	kurtosis clean -a
	kurtosis run --enclave ${ENCLAVE_NAME} . "$$(cat ${PARAMS_FILE})"

# Reset without prepare: Clean and run with existing local repos and Docker images
.PHONY: reset
reset:
	kurtosis clean -a
	kurtosis run --enclave ${ENCLAVE_NAME} . "$$(cat ${PARAMS_FILE})"

.PHONY: clean
clean:
	kurtosis clean -a

.PHONY: show
show:
	kurtosis enclave inspect ${ENCLAVE_NAME}

.PHONY: restart-ssv-nodes
restart-ssv-nodes:
	@echo "Updating SSV Node services. Count: $(SSV_NODE_COUNT) ..."
	@for i in $(shell seq 0 $(shell expr $(SSV_NODE_COUNT) - 1)); do \
		echo "Updating service: ssv-node-$$i"; \
		kurtosis service update $(ENCLAVE_NAME) ssv-node-$$i; \
	done

.PHONY: prepare
prepare:
	@echo "⏳ Preparing requirements..."
	@if [ ! -d "../ssv" ]; then \
		git clone https://github.com/ssvlabs/ssv.git ../ssv; \
	else \
		echo "✅ ssv repo already cloned."; \
		cd ../ssv && git fetch && git checkout ${SSV_COMMIT}; \
	fi
	@docker image inspect node/ssv >/dev/null 2>&1 || (cd ../ssv && docker build -t node/ssv . && echo "✅ SSV image built successfully.")
	@if [ ! -d "../anchor" ]; then \
		git clone https://github.com/sigp/anchor.git ../anchor; \
	else \
		echo "✅ anchor repo already cloned."; \
		cd ../anchor && git fetch && git checkout unstable; \
	fi
	@docker image inspect node/anchor >/dev/null 2>&1 || (cd ../anchor && docker build -f Dockerfile.devnet -t node/anchor . && echo "✅ Anchor image built successfully.")
	@if [ ! -d "../ethereum2-monitor" ]; then \
		git clone https://github.com/ssvlabs/ethereum2-monitor.git ../ethereum2-monitor; \
	else \
		echo "✅ ethereum2-monitor repo already cloned."; \
		cd ../ethereum2-monitor && git fetch && git checkout main; \
	fi
	@docker image inspect monitor >/dev/null 2>&1 || (cd ../ethereum2-monitor && docker build -t monitor . && echo "✅ Ethereum2 Monitor image built successfully.")
	@echo "✅ All requirements are prepared, spinning up the enclave..."

###### SCENARIOS ######


### Majority fork

PARAMS_FILE_MAJORITY_FORK=params-majority-fork.yaml

# Prepare images for the majority fork. Run the `prepare` step and build go-ethereum image.
.PHONY: prepare-majority-fork
prepare-majority-fork: prepare
	@if [ ! -d "../go-ethereum" ]; then \
		git clone https://github.com/ethereum/go-ethereum.git ../go-ethereum; \
	else \
		echo "✅ go-ethereum repo already cloned."; \
		cd ../go-ethereum && git fetch && git checkout master; \
	fi
	@docker image inspect geth >/dev/null 2>&1 || (cd ../go-ethereum && docker build -t node/ssv . && echo "✅ Geth image built successfully.")

# Run the majority fork scenario without prepare: Uses existing local repos and Docker images (for custom branches/versions).
# It must be prepared manually until its prepare step is implemented. Make sure all images are ready.
.PHONY: run-majority-fork
run-majority-fork:
	kurtosis run --verbosity DETAILED --enclave ${ENCLAVE_NAME} . "$$(cat ${PARAMS_FILE_MAJORITY_FORK})"

# Run the majority fork scenario with prepare:
# Downloads latest repos (ssv stage, anchor unstable, ethereum2-monitor main, go-ethereum) and builds Docker images
.PHONY: run-majority-fork-with-prepare
run-majority-fork-with-prepare: prepare
	kurtosis run --verbosity DETAILED --enclave ${ENCLAVE_NAME} . "$$(cat ${PARAMS_FILE_MAJORITY_FORK})"