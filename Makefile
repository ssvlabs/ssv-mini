# ssv-mini Makefile

# Core params
ENCLAVE_NAME ?= localnet
PARAMS_FILE ?= params.yaml
SSV_NODE_COUNT ?= 4
SSV_COMMIT ?= stage
MONITOR_ENABLED ?= false

# Git SSH settings (used for private repos; safe for public too)
GIT_SSH_COMMAND ?= ssh -F /dev/null -o StrictHostKeyChecking=accept-new

# Repos and refs (override as needed)
SSV_REPO ?= https://github.com/ssvlabs/ssv.git
SSV_REF  ?= $(SSV_COMMIT)

ANCHOR_REPO ?= https://github.com/sigp/anchor.git
ANCHOR_REF  ?= unstable

# Private repo: use SSH
E2M_REPO ?= git@github.com:ssvlabs/ethereum2-monitor.git
E2M_REF  ?= main

default: run-with-prepare

.PHONY: default run-with-prepare run reset-with-prepare reset clean show restart-ssv-nodes prepare

# Run with prepare: clone/update repos and build images
run-with-prepare: prepare
	kurtosis run --verbosity DETAILED --enclave ${ENCLAVE_NAME} . "$$(cat ${PARAMS_FILE})"

# Run without prepare: use existing repos and images
run:
	kurtosis run --verbosity DETAILED --enclave ${ENCLAVE_NAME} . "$$(cat ${PARAMS_FILE})"

# Reset with prepare: clean and run fresh
reset-with-prepare: prepare
	kurtosis clean -a
	kurtosis run --enclave ${ENCLAVE_NAME} . "$$(cat ${PARAMS_FILE})"

# Reset without prepare: clean and run with existing assets
reset:
	kurtosis clean -a
	kurtosis run --enclave ${ENCLAVE_NAME} . "$$(cat ${PARAMS_FILE})"

clean:
	kurtosis clean -a

show:
	kurtosis enclave inspect ${ENCLAVE_NAME}

restart-ssv-nodes:
	@echo "Updating SSV Node services. Count: $(SSV_NODE_COUNT) ..."
	@for i in $(shell seq 0 $(shell expr $(SSV_NODE_COUNT) - 1)); do \
		echo "Updating service: ssv-node-$$i"; \
		kurtosis service update $(ENCLAVE_NAME) ssv-node-$$i; \
	done

prepare:
	@echo "⏳ Preparing requirements..."

	# SSV (public)
	@if [ ! -d "../ssv" ]; then \
		echo "Cloning SSV..."; \
		git clone "$(SSV_REPO)" ../ssv; \
	else \
		echo "✅ ssv repo already cloned."; \
		cd ../ssv && \
		git remote set-url origin "$(SSV_REPO)" && \
		git fetch --all --tags && \
		git checkout "$(SSV_REF)" && \
		git pull origin "$(SSV_REF)"; \
	fi
	@docker image inspect node/ssv >/dev/null 2>&1 || (cd ../ssv && docker build -t node/ssv . && echo "✅ SSV image built successfully.")

	# Anchor (public)
	@if [ ! -d "../anchor" ]; then \
		echo "Cloning Anchor..."; \
		git clone "$(ANCHOR_REPO)" ../anchor; \
	else \
		echo "✅ anchor repo already cloned."; \
		cd ../anchor && \
		git remote set-url origin "$(ANCHOR_REPO)" && \
		git fetch --all --tags && \
		git checkout "$(ANCHOR_REF)" && \
		git pull origin "$(ANCHOR_REF)"; \
	fi
	@docker image inspect node/anchor >/dev/null 2>&1 || (cd ../anchor && docker build -f Dockerfile.devnet -t node/anchor . && echo "✅ Anchor image built successfully.")

	# ethereum2-monitor (private → use SSH) - only if MONITOR_ENABLED=true
	@if [ "$(MONITOR_ENABLED)" = "true" ]; then \
		if [ ! -d "../ethereum2-monitor" ]; then \
			echo "Cloning ethereum2-monitor..."; \
			GIT_SSH_COMMAND="$(GIT_SSH_COMMAND)" git clone "$(E2M_REPO)" ../ethereum2-monitor; \
		else \
			echo "✅ ethereum2-monitor repo already cloned."; \
			cd ../ethereum2-monitor && \
			git remote set-url origin "$(E2M_REPO)" && \
			GIT_SSH_COMMAND="$(GIT_SSH_COMMAND)" git fetch --all --tags && \
			GIT_SSH_COMMAND="$(GIT_SSH_COMMAND)" git checkout "$(E2M_REF)" && \
			GIT_SSH_COMMAND="$(GIT_SSH_COMMAND)" git pull origin "$(E2M_REF)"; \
		fi; \
		docker image inspect monitor >/dev/null 2>&1 || (cd ../ethereum2-monitor && docker build -t monitor . && echo "✅ Ethereum2 Monitor image built successfully."); \
	else \
		echo "⏭️  Skipping ethereum2-monitor (MONITOR_ENABLED=$(MONITOR_ENABLED))"; \
	fi

	@echo "✅ All requirements are prepared, spinning up the enclave..."
