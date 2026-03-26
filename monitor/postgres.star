def start(plan, image):
    service_name = "postgres"
    port = 5432

    plan.add_service(
        name=service_name,
        description="Starting PostgreSQL for monitor",
        config=ServiceConfig(
            image=image,
            env_vars={
                "POSTGRES_USER": "postgres",
                "POSTGRES_PASSWORD": "postgres",
                "POSTGRES_DB": "monitor",
            },
            ports={
                "postgres": PortSpec(
                    number=port,
                    transport_protocol="TCP",
                    application_protocol="postgresql",
                )
            },
            files={
                "/docker-entrypoint-initdb.d": plan.upload_files("schema.sql"),
            }
        ),
    )

    return service_name, port