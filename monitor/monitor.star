constants = import_module("../utils/constants.star")
postgres = import_module("postgres.star")
redis = import_module("redis.star")

MONITOR_DOCKER_IMAGE = "monitor"

def start(plan, ssv_exporter_url, cl_url):
    plan.print("Starting postgres")
    postgres_service_name, postgres_port = postgres.start(plan)

    plan.print("Postgres started. Starting redis service")
    redis_service_name, redis_port = redis.start(plan)

    plan.print("Redis started. Starting realtime monitor")
    
    env_vars = shared_envs(postgres_service_name, postgres_port, redis_service_name, redis_port, ssv_exporter_url, cl_url)

    plan.print(
        "starting monitor services with environment variables: " + json.indent(json.encode(env_vars)))

    plan.add_service(
        name = "monitor-daemon",
        config = ServiceConfig( 
            image=MONITOR_DOCKER_IMAGE,
            cmd=["start", "realtime"],
            env_vars=env_vars,
        )
    )

    plan.print("Realtime monitor started. Starting API")

    env_vars["WEB_UI"] = "true"
    plan.add_service(
        name="monitor-api",
        config=ServiceConfig(
            image=MONITOR_DOCKER_IMAGE,
            cmd=["api"],
            env_vars=env_vars,
            ports={
                "api": PortSpec(
                    number=6090,
                    transport_protocol="TCP",
                    application_protocol="http",
                ),
                "ui": PortSpec(
                    number=8000,
                    transport_protocol="TCP",
                    application_protocol="http",
                )
            },
        )
    )
    

def shared_envs(
    postgres_service_name, 
    postgres_port, 
    redis_service_name, 
    redis_port, 
    ssv_exporter_url,
    cl_url):
    return {
        "NETWORK": "other",
        "BEACON_ADDR": cl_url,
        "DEFAULT_POOL": "ssv",
        "POOLS": '[{{"id":1,"name":"ssv","indices":[],"endpoint":"{}/v1/validators"}}]'.format(ssv_exporter_url),
        "POSTGRES_URL": "postgres://postgres:postgres@{}:{}/monitor?sslmode=disable".format(postgres_service_name, postgres_port),
        "REDIS_URL": "redis://{}:{}".format(redis_service_name, redis_port),
        "LOG_LEVEL": "debug",
        "RELAY_TRACKING": "false",
    }