ENCLAVE_NAME?=localnet
PARAMS_FILE?=params.yaml
SSV_NODE_COUNT?=4
SSV_COMMIT?=stage
ANCHOR_COMMIT?=unstable
FAULT_LOG_DIR?=.fault-logs
SSV_REPO?=../ssv
FAULT_BANNER_TIMEOUT?=180
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
# `kurtosis service logs` cannot read an ssv-node's JSON output (see README.md's "Reading ssv-node
# logs on `--env mini`"), so for ssv-node-* this shells out to `docker logs` directly instead —
# the only working read path for this service. Every other service still goes through kurtosis.
logs:
	@case "$(SERVICE)" in \
		ssv-node-*) \
			OP=$$(echo "$(SERVICE)" | sed 's/^ssv-node-//'); \
			ENCLAVE_UUID=$$(kurtosis enclave inspect $(ENCLAVE_NAME) --full-uuids 2>/dev/null | awk '/^UUID:/{print $$2}'); \
			CONTAINER=$$(docker ps --filter "label=kurtosis_service_name=ssv-node-$$OP" --filter "label=kurtosis_enclave_uuid=$$ENCLAVE_UUID" --format '{{.Names}}'); \
			if [ -z "$$CONTAINER" ]; then \
				echo "Error: no running container for ssv-node-$$OP in enclave $(ENCLAVE_NAME)."; \
				exit 1; \
			fi; \
			docker logs -f "$$CONTAINER" ;; \
		*) \
			kurtosis service logs -f $(ENCLAVE_NAME) $(SERVICE) ;; \
	esac

.PHONY: restart-ssv-nodes
# WARNING: this is a bare `kurtosis service update` over every node — unlike `make fault`/
# `fault-off`, it does NOT archive first. It destroys every operator's buffered log evidence,
# including the honest operators an M3 oracle reads. Do not run it mid-scenario; if you need it
# after that point, archive first by hand (see `make fault`'s ARCHIVE step for the pattern).
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

.PHONY: prepare-blindspot-proxy
prepare-blindspot-proxy:
	@echo "Building blindspot-proxy image..."
	@docker build -t blindspot-proxy tests/blindspot-proxy
	@echo "Done."

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

# ── M3 fault menu ────────────────────────────────────────────────────
# The instrumented node reads FAULT once at boot, so switching a fault means a
# `kurtosis service update`, which re-creates the container and destroys its log buffer. These
# targets therefore ARCHIVE the operator's logs first, then switch, then verify that the node came
# back reporting the fault that was asked for. A switch that silently did not apply looks exactly
# like a fault that fired and was correctly ignored — the one failure a test pass cannot detect
# from the honest side. See qa/FAULTS.md on the ssv branch qa/gloas-m3-fault-menu.
#
# Prerequisite: the enclave's SSV image must be the instrumented build — `node/ssv-fault`, built
# from the ssv branch `qa/gloas-m3-fault-menu` (a distinct tag so FAULT=none operators can keep
# running the plain node/ssv image; see qa/FAULTS.md §10) — and $(SSV_REPO) (default ../ssv) must
# be checked out on that same branch, because `go run ./qa/faults/cmd/list` below enumerates the
# menu from it. On a stock node FAULT is simply ignored: you get the boot-banner timeout below, not
# a clear error, so a missed prerequisite reads as flakiness rather than a setup mistake.
#
# Container resolution is label-based, not name-based: `docker ps --filter
# label=kurtosis_service_name=... --filter label=kurtosis_enclave_uuid=...` scopes the match to
# THIS enclave, so a co-tenant enclave running the same operator index (this repo supports
# co-tenant enclaves by design — see lines 85, 99-101) cannot be picked by accident. A match count
# other than 1 is always an error, never a "take the first" fallback.

.PHONY: fault-list
fault-list:
	@cd $(SSV_REPO) && go run ./qa/faults/cmd/list

.PHONY: fault
fault:
	@test -n "$(FAULT)" || { echo "Error: FAULT is required, e.g. make fault FAULT=vote-index-2 OP=5. Values: make fault-list"; exit 1; }
	@test -n "$(OP)" || { echo "Error: OP is required (0-indexed operator), e.g. make fault FAULT=$(FAULT) OP=5"; exit 1; }
	@MENU=$$( (cd $(SSV_REPO) && go run ./qa/faults/cmd/list) 2>&1 ); MENU_STATUS=$$?; \
	if [ "$$MENU_STATUS" -ne 0 ]; then \
		echo "Error: 'go run ./qa/faults/cmd/list' in \$$SSV_REPO=$(SSV_REPO) failed (exit $$MENU_STATUS)."; \
		echo "       That is the menu command itself failing — wrong branch checked out (needs"; \
		echo "       qa/gloas-m3-fault-menu), no Go toolchain, or a build error — NOT that '$(FAULT)' is"; \
		echo "       an unknown value. Raw output:"; \
		printf '%s\n' "$$MENU" | sed 's/^/       /'; \
		exit 1; \
	fi; \
	printf '%s\n' "$$MENU" | grep -qxF "$(FAULT)" || \
		{ echo "Error: '$(FAULT)' is not in the menu. Values: make fault-list"; exit 1; }
	@ENCLAVE_UUID=$$(kurtosis enclave inspect $(ENCLAVE_NAME) --full-uuids 2>/dev/null | awk '/^UUID:/{print $$2}'); \
	if [ -z "$$ENCLAVE_UUID" ]; then \
		echo "Error: enclave '$(ENCLAVE_NAME)' was not found. Nothing was archived or switched."; \
		echo "       Check: kurtosis enclave ls"; \
		exit 1; \
	fi; \
	MATCH=$$(docker ps --filter "label=kurtosis_service_name=ssv-node-$(OP)" --filter "label=kurtosis_enclave_uuid=$$ENCLAVE_UUID" --format '{{.Names}} {{.ID}}'); \
	MATCH_N=$$(printf '%s\n' "$$MATCH" | grep -c .); \
	if [ "$$MATCH_N" -ne 1 ]; then \
		echo "Error: expected exactly 1 running container for ssv-node-$(OP) in enclave $(ENCLAVE_NAME),"; \
		echo "       found $$MATCH_N. Likely causes: wrong OP, the container is gone, the enclave is"; \
		echo "       down, or a co-tenant enclave also runs an ssv-node-$(OP). Nothing was archived or"; \
		echo "       switched."; \
		echo "       Check: docker ps --filter \"label=kurtosis_service_name=ssv-node-$(OP)\""; \
		exit 1; \
	fi; \
	CONTAINER=$$(printf '%s' "$$MATCH" | awk '{print $$1}'); \
	PRE_SWITCH_ID=$$(printf '%s' "$$MATCH" | awk '{print $$2}'); \
	mkdir -p $(FAULT_LOG_DIR); \
	ARCHIVE="$(FAULT_LOG_DIR)/ssv-node-$(OP)-$$(date -u +%Y%m%dT%H%M%SZ).log"; \
	echo "──── Archiving ssv-node-$(OP) logs to $$ARCHIVE ────"; \
	docker logs "$$CONTAINER" > "$$ARCHIVE" 2>&1 || true; \
	if ! grep -q '^{' "$$ARCHIVE"; then \
		if [ -n "$(ALLOW_EMPTY_ARCHIVE)" ]; then \
			echo "  warning: no JSON log lines captured, continuing because ALLOW_EMPTY_ARCHIVE is set"; \
		else \
			echo "Error: no JSON log lines were captured, so the switch was NOT applied — it would destroy"; \
			echo "       the operator's log buffer with no usable copy kept."; \
			echo "       $$ARCHIVE may hold a docker/daemon error instead of real logs — check it: $$(head -c 200 "$$ARCHIVE")"; \
			echo "       Usual cause: the container is gone or docker is unreachable. If the enclave is wedged:"; \
			echo "         kurtosis clean -a && docker rm -f kurtosis-logs-aggregator && kurtosis engine restart"; \
			echo "       If the operator genuinely has no logs worth keeping: ALLOW_EMPTY_ARCHIVE=1 make fault FAULT=$(FAULT) OP=$(OP)"; \
			exit 1; \
		fi; \
	fi; \
	echo "──── Switching ssv-node-$(OP) to FAULT=$(FAULT) ────"; \
	# --env replaces the WHOLE env var list, so if nodes.ssv.enable_traces is on for this operator, \
	# the OTEL_EXPORTER_OTLP_TRACES_* pair set at bring-up is dropped here too (traces do not \
	# survive a fault switch). The node still boots only because commit 86f8750 moved --config= \
	# into the entrypoint instead of relying on this --env list; reverting that change would \
	# silently break every switch below. \
	kurtosis service update $(ENCLAVE_NAME) ssv-node-$(OP) \
		--env FAULT=$(FAULT) \
		--files "/ssv-config:ssv-config-$(OP).yaml" \
	|| { echo "Error: the switch command failed; the container was NOT replaced. Pre-switch logs are in $$ARCHIVE."; exit 1; }; \
	echo "──── Waiting for the boot banner (up to $(FAULT_BANNER_TIMEOUT)s) ────"; \
	DEADLINE=$$(( $$(date +%s) + $(FAULT_BANNER_TIMEOUT) )); \
	while [ "$$(date +%s)" -lt "$$DEADLINE" ]; do \
		MATCH=$$(docker ps --filter "label=kurtosis_service_name=ssv-node-$(OP)" --filter "label=kurtosis_enclave_uuid=$$ENCLAVE_UUID" --format '{{.Names}} {{.ID}}'); \
		MATCH_N=$$(printf '%s\n' "$$MATCH" | grep -c .); \
		if [ "$$MATCH_N" -ne 1 ]; then sleep 3; continue; fi; \
		CUR_CONTAINER=$$(printf '%s' "$$MATCH" | awk '{print $$1}'); \
		CUR_ID=$$(printf '%s' "$$MATCH" | awk '{print $$2}'); \
		if [ "$$CUR_ID" = "$$PRE_SWITCH_ID" ]; then sleep 3; continue; fi; \
		if docker logs "$$CUR_CONTAINER" 2>&1 | grep "QA FAULT INSTRUMENTATION ACTIVE" | tail -1 | grep -qF "$(FAULT)"; then \
			echo "──── ssv-node-$(OP) is running FAULT=$(FAULT) ────"; exit 0; \
		fi; \
		sleep 3; \
	done; \
	echo "Error: do not record a verdict for ssv-node-$(OP)'s window until its actual state is confirmed"; \
	echo "       by hand — ssv-node-$(OP) did not report FAULT=$(FAULT) within $(FAULT_BANNER_TIMEOUT)s."; \
	echo "       Most likely cause: the enclave is not running the instrumented image — on a stock node"; \
	echo "       FAULT is silently ignored, and this timeout is exactly what that looks like. Other"; \
	echo "       causes: an unknown value aborts the node's startup by design, as does a dropped config"; \
	echo "       mount; or the switch command above genuinely failed after passing its own exit check."; \
	echo "       Check: docker logs \$$(docker ps --filter \"label=kurtosis_service_name=ssv-node-$(OP)\" --format '{{.Names}}') | tail -40"; \
	echo "       The pre-switch logs are in $$ARCHIVE."; \
	exit 1

.PHONY: fault-off
fault-off:
	@test -n "$(OP)" || { echo "Error: OP is required, e.g. make fault-off OP=5"; exit 1; }
	@ENCLAVE_UUID=$$(kurtosis enclave inspect $(ENCLAVE_NAME) --full-uuids 2>/dev/null | awk '/^UUID:/{print $$2}'); \
	if [ -z "$$ENCLAVE_UUID" ]; then \
		echo "Error: enclave '$(ENCLAVE_NAME)' was not found. Nothing was archived or switched."; \
		echo "       Check: kurtosis enclave ls"; \
		exit 1; \
	fi; \
	MATCH=$$(docker ps --filter "label=kurtosis_service_name=ssv-node-$(OP)" --filter "label=kurtosis_enclave_uuid=$$ENCLAVE_UUID" --format '{{.Names}} {{.ID}}'); \
	MATCH_N=$$(printf '%s\n' "$$MATCH" | grep -c .); \
	if [ "$$MATCH_N" -ne 1 ]; then \
		echo "Error: expected exactly 1 running container for ssv-node-$(OP) in enclave $(ENCLAVE_NAME),"; \
		echo "       found $$MATCH_N. Likely causes: wrong OP, the container is gone, the enclave is"; \
		echo "       down, or a co-tenant enclave also runs an ssv-node-$(OP). Nothing was archived or"; \
		echo "       switched."; \
		echo "       Check: docker ps --filter \"label=kurtosis_service_name=ssv-node-$(OP)\""; \
		exit 1; \
	fi; \
	CONTAINER=$$(printf '%s' "$$MATCH" | awk '{print $$1}'); \
	PRE_SWITCH_ID=$$(printf '%s' "$$MATCH" | awk '{print $$2}'); \
	mkdir -p $(FAULT_LOG_DIR); \
	ARCHIVE="$(FAULT_LOG_DIR)/ssv-node-$(OP)-$$(date -u +%Y%m%dT%H%M%SZ).log"; \
	echo "──── Archiving ssv-node-$(OP) logs to $$ARCHIVE ────"; \
	docker logs "$$CONTAINER" > "$$ARCHIVE" 2>&1 || true; \
	if ! grep -q '^{' "$$ARCHIVE"; then \
		echo "  warning: no JSON log lines were captured in $$ARCHIVE. fault-off does not abort on this"; \
		echo "  (that would strand the operator faulted), but this archive is the evidence for the fault"; \
		echo "  window that is now ending — check it by hand: $$(head -c 200 "$$ARCHIVE")"; \
	fi; \
	echo "──── Clearing the fault on ssv-node-$(OP) ────"; \
	# --env replaces the WHOLE env var list, exactly as in `fault` above: if \
	# nodes.ssv.enable_traces is on for this operator, the OTEL_EXPORTER_OTLP_TRACES_* pair set \
	# at bring-up is dropped here too. Clearing a fault does NOT restore traces — only a fresh \
	# bring-up does. \
	kurtosis service update $(ENCLAVE_NAME) ssv-node-$(OP) \
		--env FAULT=none \
		--files "/ssv-config:ssv-config-$(OP).yaml" \
	|| { echo "Error: the switch command failed; the container was NOT replaced. Pre-switch logs are in $$ARCHIVE."; exit 1; }; \
	DEADLINE=$$(( $$(date +%s) + $(FAULT_BANNER_TIMEOUT) )); \
	while [ "$$(date +%s)" -lt "$$DEADLINE" ]; do \
		MATCH=$$(docker ps --filter "label=kurtosis_service_name=ssv-node-$(OP)" --filter "label=kurtosis_enclave_uuid=$$ENCLAVE_UUID" --format '{{.Names}} {{.ID}}'); \
		MATCH_N=$$(printf '%s\n' "$$MATCH" | grep -c .); \
		if [ "$$MATCH_N" -ne 1 ]; then sleep 3; continue; fi; \
		CUR_CONTAINER=$$(printf '%s' "$$MATCH" | awk '{print $$1}'); \
		CUR_ID=$$(printf '%s' "$$MATCH" | awk '{print $$2}'); \
		if [ "$$CUR_ID" = "$$PRE_SWITCH_ID" ]; then sleep 3; continue; fi; \
		if docker logs "$$CUR_CONTAINER" 2>&1 | grep -q "no fault active"; then \
			echo "──── ssv-node-$(OP) has no fault active ────"; exit 0; \
		fi; \
		sleep 3; \
	done; \
	echo "Error: do not record a verdict for ssv-node-$(OP)'s window until its actual state is confirmed"; \
	echo "       by hand — ssv-node-$(OP) did not report 'no fault active' within $(FAULT_BANNER_TIMEOUT)s."; \
	echo "       Most likely cause: the enclave is not running the instrumented image — on a stock node"; \
	echo "       FAULT is silently ignored, and this timeout is exactly what that looks like. Other"; \
	echo "       causes: a dropped config mount aborts the node's startup; or the switch command above"; \
	echo "       genuinely failed after passing its own exit check."; \
	echo "       The pre-switch logs are in $$ARCHIVE."; \
	exit 1

.PHONY: test-fault-switch
test-fault-switch:
	@./tests/fault-switch/run-test.sh

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
	@echo "Fault injection (M3, SSV node):"
	@echo "  make fault-list                           List available FAULT values"
	@echo "  make fault FAULT=vote-index-2 OP=3         Archive OP's logs, switch its fault, verify banner"
	@echo "  make fault-off OP=3                        Archive OP's logs, clear its fault, verify banner"
	@echo "  make test-fault-switch OP=3                Run the fault-switch integration test"
	@echo "  ALLOW_EMPTY_ARCHIVE=1 make fault ...        Skip the no-usable-logs abort (fault-off never aborts)"
	@echo ""
	@echo "Image building:"
	@echo "  make prepare         Build SSV image (default: stage branch)"
	@echo "  make prepare-anchor  Build Anchor image (default: unstable)"
	@echo "  make prepare-monitor Build Monitor image"
	@echo "  make prepare-all     Build all images"
	@echo "  make prepare-blindspot-proxy             Build the fork blind-spot proxy image"
	@echo ""
	@echo "Network scenarios:"
	@echo "  make run                             Default: Fulu at genesis"
	@echo "  make run-boole                       Boole fork, epoch 3 (BOOLE_FORK_EPOCH=N to retune)"
	@echo "  make run-boole-interop               Boole fork, 2 SSV + 2 Anchor committee (cross-client interop)"
	@echo "  make run-gloas                       Gloas/ePBS fork, epoch 2 (GLOAS_FORK_EPOCH=N to retune; devnet-6 images)"
	@echo "  make run-gloas-multibn                   Gloas with one beacon node per operator (P0.2)"
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
	@echo "  make test-topology                       Run the operator_pairs validation suite"

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

.PHONY: run-gloas-multibn
run-gloas-multibn:
	@echo "──── Starting SSV testnet (Gloas/ePBS, one BN per operator) ────"
	@$(MAKE) --no-print-directory run PARAMS_FILE=params-gloas-multibn.yaml

# ── Tests ────────────────────────────────────────────────────────────

.PHONY: test-faulty-el
test-faulty-el:
	@./tests/faulty-el/run-test.sh

.PHONY: test-topology
test-topology:
	@./tests/topology/run-tests.sh
