def start(plan, image):
    service_name = "redis"
    port = 6379

    plan.add_service(
        name=service_name,
        description="Starting Redis for monitor",
        config=ServiceConfig(
            image=image,
            ports={
                "redis": PortSpec(
                    number=port,
                    transport_protocol="TCP",
                    application_protocol="redis",
                )
            },
        ),
    )

    return service_name, port