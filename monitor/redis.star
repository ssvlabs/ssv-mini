utils = import_module("../utils/utils.star")

def start(plan, args):
    service_name = "redis"
    port = 6379

    plan.add_service(
        name=service_name,
        config=ServiceConfig(
            image=utils.get_redis_image(args),
            ports={
                "http": PortSpec(
                    number=port,
                    transport_protocol="TCP",
                )
            },
        ),
    )

    return service_name, port