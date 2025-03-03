def get_eth_urls(all_participants):
    # TODO: get all addresses to dstribute between operators
    el_ip_addr = all_participants[
        0
    ].el_context.ip_addr
    el_ws_port = all_participants[
        0
    ].el_context.ws_port_num
    el_rpc_port = all_participants[
        0
    ].el_context.rpc_port_num
    el_rpc_uri = "http://{0}:{1}".format(el_ip_addr, el_rpc_port)
    el_ws_uri = "ws://{0}:{1}".format(el_ip_addr, el_ws_port)
    cl_ip_addr = all_participants[
        0
    ].cl_context.ip_addr
    cl_http_port_num = all_participants[
        0
    ].cl_context.http_port
    cl_uri = "http://{0}:{1}".format(cl_ip_addr, cl_http_port_num)

    return (cl_uri, el_rpc_uri, el_ws_uri)

def get_eth_service_names(all_participants):
    cl_service_name = all_participants[
        0
    ].cl_context.beacon_service_name
    el_service_name = all_participants[
        0
    ].el_context.service_name

    return (cl_service_name, el_service_name)


def new_template_and_data(template, template_data_json):
    return struct(template=template, data=template_data_json)
