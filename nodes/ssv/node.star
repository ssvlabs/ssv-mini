utils = import_module("../../utils/utils.star")
constants = import_module("../../utils/constants.star")

SSV_API_PORT = 9232
SSV_API_PORT_NAME = "api"

SSV_METRICS_PORT_NAME = "metrics"
SSV_METRICS_PORT = 9240

def generate_config(
        plan,
        index,
        endpoints,
        operator_private_key,
        enr,
        is_exporter,
        args,
):
    boole_epoch = args.get("boole_epoch", constants.BOOLE_DORMANT_EPOCH)
    # Traces are opt-in (params key: nodes.ssv.enable_traces, default False). Nothing in this repo
    # provisions an OTLP collector, so a failed export prints a plain-text line to stdout — which
    # breaks Kurtosis's JSON log parser for the whole service (kurtosis service logs / scout.py
    # --env mini logs query then return nothing for that node). Anyone who wants traces must both
    # set this key to true AND run a collector reachable at the OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
    # in get_service_config below (no profile in this repo starts one). cli/operator/start_node.go's
    # buildObservabilityOptions only calls observability.WithTraces() when this config field is
    # true, so leaving it False here means the OTEL env vars are never read at all — the node never
    # attempts an export.
    enable_traces = args["nodes"].get("ssv", {}).get("enable_traces", False)
    discovery = ""
    if enr == "":
        discovery = "mdns"
    else:
        discovery = "discv5"

    # Prepare data for the template
    data = struct(
        LogLevel="debug",
        LogFormat="json",
        DBPath="./data/db/{}/".format(index),
        # go-SSV takes multiple endpoints as a SEMICOLON-separated list:
        # BeaconNodeAddr -> beacon/goclient/goclient.go:209, ETH1Addr -> cli/operator/node.go:123.
        # Anchor uses commas for the same idea, which is why the join lives here in the
        # client's own module rather than in topology.star.
        BeaconNodeAddr=";".join(endpoints.cl_urls),
        ETH1Addr=";".join(endpoints.el_ws_urls),
        Network="local-testnet", #if not set - default to "mainnet"
        NetworkName="testnet",  #relevant for interop with Anchor, otherwise getting mismatched subnets starting with Boole
        DomainType="0x00000000",
        NextDomainType="0x00000001",  #Boole specific, inert otherwise; deviates from SIPs but required for interop with Anchor
        RegistrySyncOffset="1",
        RegistryContractAddr=constants.SSV_NETWORK_PROXY_CONTRACT,
        OperatorPrivateKey=operator_private_key,
        DiscoveryProtocolID = "0x737376647635", # ssvdv5
        Discovery=discovery,
        ENR=enr,
        ExporterEnabled=is_exporter,
        # archive (not standard) also registers /v1/exporter/traces/* — the committee duty traces the
        # aetheria (boole) Step 12 reads; standard mode wouldn't. Inert for operator nodes (ExporterEnabled=False).
        ExporterMode="archive" if is_exporter else "standard",
        SSVAPIPort=SSV_API_PORT,
        MetricsAPIPort=SSV_METRICS_PORT,
        EnableTraces=enable_traces,
        BooleEpoch=boole_epoch,
    )

    ssv_config_template = read_file("config.yml.tmpl")
    file_name = "ssv-config-{}.yaml".format(index)

    # Render the template into a file artifact
    rendered_artifact = plan.render_templates(
        {
            file_name: utils.new_template_and_data(ssv_config_template, data),
        },
        name=file_name,
        description="Rendering SSV node {} config".format(index),
    )

    return rendered_artifact

SSV_CONFIG_DIR_PATH_ON_SERVICE = "/ssv-config"

def get_service_config(index, config_artifact, image, enable_traces = False, gas_limit = 0):
    """Returns a ServiceConfig for an SSV node without starting it (for use with plan.add_services)."""
    config_path = "{}/ssv-config-{}.yaml".format(SSV_CONFIG_DIR_PATH_ON_SERVICE, index)

    # CONFIG_PATH is always needed; the OTEL pair is added only when traces are on (see the
    # enable_traces comment in generate_config above) so a node started with traces off carries no
    # reference at all to the alloy endpoint nobody provisions.
    env_vars = {
        "CONFIG_PATH": config_path,
    }
    if enable_traces:
        env_vars["OTEL_EXPORTER_OTLP_TRACES_PROTOCOL"] = "grpc"
        env_vars["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] = "http://alloy:4317"
    # Per-operator MEV gas limit (params key: operator_gas_limits). Deliberately an ENV VAR and not
    # a config-file field, for one reason: passes doc M3 §6.5 step 5 restores the DEFAULT limit
    # mid-pass, and `make gas-limit OP=N VALUE=default` does that in one command without
    # re-rendering a config artifact. cleanenv reads env AFTER the YAML file, so the env value wins.
    # NOTE `kurtosis service update --env` MERGES rather than replacing the env list (measured on
    # 1.18.3, 2026-09-09), so it cannot UNSET this: VALUE=default sends an explicit 0, which the
    # node maps to DefaultGasLimit (36e6) in proposer_preferences.go:573 and
    # validator_registration.go:288. The merge also means a fault switch does NOT clobber this.
    # The node's own key is ssv.ValidatorOptions.ExperimentalGasLimit / EXPERIMENTAL_GAS_LIMIT
    # (src/ssv operator/validator/controller.go:99). `valOpts := cfg.SSVOptions.ValidatorOptions`
    # in cli/operator/node.go copies the parsed struct and only overwrites RUNTIME fields, so the
    # configured value survives and is not silently clobbered (checked, not assumed).
    # 0 means "leave it unset" -> the node's built-in default applies.
    if gas_limit > 0:
        env_vars["EXPERIMENTAL_GAS_LIMIT"] = str(gas_limit)

    return ServiceConfig(
        image=image,
        # Exec the binary directly rather than going through `make start-node`: that Makefile
        # target (src/ssv's Makefile:119-122,128) unconditionally echoes five plain-text lines
        # ("Build binary:", "Config path:", "Share config path:", "Command provided:", "Running
        # node on address:") to stdout before exec'ing ssvnode, whose own logger then switches to
        # JSON. Kurtosis's log stream is broken by even one non-JSON line for the whole service —
        # that was one of the causes that made `scout.py --env mini logs query` and `kurtosis
        # service logs` unusable for every ssv-node, independent of the traces fix above. The third
        # cause (Kurtosis's own reader could not decode the resulting per-line JSON) is FIXED as of
        # 2026-09-09 — in the developer's kurtosis-config.yml, not here; see README.md's "Reading
        # ssv-node logs on `--env mini`" and ssv-scout's docs/kurtosis-logging-options.md. This
        # mirrors exactly what the
        # Makefile target itself does (see its line 129, `${BUILD_PATH} start-node
        # ${NODE_COMMAND_ARGS}`, and the "Command provided:" line's own `--config=...` shape) minus
        # the plain-text preamble. Cost: the Makefile target also supported `SHARE_CONFIG`
        # (appended as `--share-config=...`) and `DEBUG_PORT` (routed through `dlv` instead of
        # exec'ing the binary directly) — neither is set anywhere in ssv-mini today, but bypassing
        # `make` means neither is supported here either. If ssv-mini ever wires either one up, add
        # it to this entrypoint list explicitly; it will not come back for free.
        entrypoint=[
            "/go/bin/ssvnode",
            "start-node",
            "--config=" + config_path,
        ],
        ports={
            SSV_API_PORT_NAME: PortSpec(
                number=SSV_API_PORT,
                transport_protocol="TCP",
                application_protocol="http",
            ),
            SSV_METRICS_PORT_NAME: PortSpec(
                number=SSV_METRICS_PORT,
                transport_protocol="TCP",
                application_protocol="http",
            ),
        },
        env_vars=env_vars,
        files={
            SSV_CONFIG_DIR_PATH_ON_SERVICE: config_artifact,
        },
        capabilities = ["NET_ADMIN"],
    )
