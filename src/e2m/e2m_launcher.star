shared_utils = import_module("github.com/ethpandaops/ethereum-package/src/shared_utils/shared_utils.star")

postgres = import_module("github.com/kurtosis-tech/postgres-package/main.star")
redis = import_module("github.com/kurtosis-tech/redis-package/main.star")

IMAGE_NAME_E2M = "bloxstaking/ethereum2-monitor" ## TODO: get e2m v2

SERVICE_NAME_E2M = "e2m"
SERVICE_NAME_E2M_REALTIME = "e2m-realtime"
SERVICE_NAME_E2M_RETRO = "e2m-retro"
SERVICE_NAME_E2M_API = "e2m-api"

HTTP_PORT_ID = "http"
HTTP_PORT_NUMBER = 6090

BLOCKSCOUT_MIN_CPU = 100
BLOCKSCOUT_MAX_CPU = 1000
BLOCKSCOUT_MIN_MEMORY = 1024
BLOCKSCOUT_MAX_MEMORY = 2048

USED_PORTS = {
    HTTP_PORT_ID: shared_utils.new_port_spec(
        HTTP_PORT_NUMBER,
        shared_utils.TCP_PROTOCOL,
        shared_utils.HTTP_APPLICATION_PROTOCOL,
    )
    
}



def launch_e2m(
    plan,
    cl_url,
):
    plan.print("Launching Postgres and Redis for E2M...")
    seed_artifact = plan.upload_files("./e2m_db.sql")
    postgres_output = postgres.run(
        plan,
        service_name="{}-postgres".format(SERVICE_NAME_E2M),
        database="validator_center",
        extra_configs=["max_connections=1000"],
        seed_file_artifact_name=seed_artifact
        # persistent=persistent,
        # node_selectors=global_node_selectors,
    )
    redis_output = redis.run(
        plan,
        service_name="{}-redis".format(SERVICE_NAME_E2M),
    )


    api_cfg = get_config_backend(
        postgres_output,
        redis_output,
        cl_url,
        "api"
    ) 
    realtime_cfg = get_config_backend(
        postgres_output,
        redis_output,
        cl_url,
        "realtime"
    )
    retro_cfg = get_config_backend(
        postgres_output,
        redis_output,
        cl_url,
        "retro"
    )


    retro_service = plan.add_service(SERVICE_NAME_E2M_RETRO, retro_cfg)
    realtime_service = plan.add_service(SERVICE_NAME_E2M_REALTIME, realtime_cfg)
    api_service = plan.add_service(SERVICE_NAME_E2M_API, api_cfg)

    plan.print(api_service)

    e2m_url = "http://{}:{}".format(
        api_service.hostname, api_service.ports["http"].number
    )

    return e2m_url


def get_config_backend(
    postgres_output, redis_output, cl_url, strategy
):
    redis_url = "redis://{}:{}".format(redis_output.hostname, redis_output.port_number)

    web = True

    ports = USED_PORTS

    if strategy != "api":
        strategy = "start " + strategy
        web = True
        ports = {}

    return ServiceConfig(
        image=IMAGE_NAME_E2M,
        ports=ports,
        cmd=[
            strategy
        ],
        env_vars={
            "POOLS":"""[{"id":1,"name":"ssv","indices":[1,2,3,4,5,6,7,8,9,10],"endpoint":""}]""", ## TODO set endpoint to persistent ssv node hostname
            "DEFAULT_POOL": "ssv",
            "DEFAULT_NETWORK": "ssv",
            "BEACON_ADDR": cl_url,
            "NETWORK": "localnet",
            "REDIS_URL": redis_url,
            "POSTGRES_URL": postgres_output.url,
            "DEFAULT_PROVIDER": "ssv",
            "VALIDATOR_CENTER": "false",
            "VALIDATOR_PROVIDERS": """{"ssv":{"indices":[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119],"endpoint":null}}""",
            "WEB_UI": str(web)
        },
        min_cpu=BLOCKSCOUT_MIN_CPU,
        max_cpu=BLOCKSCOUT_MAX_CPU,
        min_memory=BLOCKSCOUT_MIN_MEMORY,
        max_memory=BLOCKSCOUT_MAX_MEMORY,
    )
