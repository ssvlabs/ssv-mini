utils = import_module("../utils/utils.star")

def start(plan, args):
    service_name = "postgres"
    port = 5432

    plan.add_service(
        name=service_name,
        config=ServiceConfig(
            image=utils.get_postgres_image(args),
            env_vars={
                "POSTGRES_USER": "postgres",
                "POSTGRES_PASSWORD": "postgres",
                "POSTGRES_DB": "monitor",
            },
            ports={
                "http": PortSpec(
                    number=port,
                    transport_protocol="TCP",
                    application_protocol="http",
                )
            },
            files={
                "/docker-entrypoint-initdb.d": plan.upload_files("schema.sql"),
            }
        ),
    )

    return service_name, port