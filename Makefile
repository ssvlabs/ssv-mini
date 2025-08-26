ENCLAVE_NAME=localnet
PARAMS_FILE=params.yaml
SSV_NODE_COUNT?=4
ENCLAVE_NAME?=localnet

default: run

.PHONY: run
run: prepare
	kurtosis run --verbosity DETAILED --enclave ${ENCLAVE_NAME} . "$$(cat ${PARAMS_FILE})"

.PHONY: reset
reset: prepare
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
		cd ../ssv && git fetch && git checkout stage; \
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