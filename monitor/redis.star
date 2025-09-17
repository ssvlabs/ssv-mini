def start(plan, image):
    service_name = "redis"
    port = 6379

    plan.add_service(
        name=service_name,
        config=ServiceConfig(
            image=image,
            ports={
                "http": PortSpec(
                    number=port,
                    transport_protocol="TCP",
                )
            },
        ),
    )

    return service_name, port