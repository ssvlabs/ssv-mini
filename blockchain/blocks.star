BLOCK_NUMBER_FIELD = "block-number"
BLOCK_HASH_FIELD = "block-hash"
JQ_PAD_HEX_FILTER = """{} | ascii_upcase | split("") | map({{"x": 0, "0": 0, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7, "8": 8, "9": 9, "A": 10, "B": 11, "C": 12, "D": 13, "E": 14, "F": 15}}[.]) | reduce .[] as $item (0; . * 16 + $item)"""

# Consensus client constants
CURRENT_EPOCH_FIELD = "current-epoch"
CURRENT_SLOT_FIELD = "current-slot"
HEAD_SLOT_GENERIC = "head"

def wait_until_node_reached_block(plan, el_service_name, target_block):
    plan.wait(
        recipe=get_block_recipe("latest"),
        field="extract." + BLOCK_NUMBER_FIELD,
        assertion=">=",
        target_value=target_block,
        timeout="20m",  # Ethereum nodes can take a while to get in good shapes, especially at the beginning
        service_name=el_service_name,
    )

# Constructs an rpc request to get the block receipt 
def get_block_recipe(block_number_hex):
    request_body = """{{
    "method": "eth_getBlockByNumber",
    "params":[
        "{}",
        true
    ],
    "id":1,
    "jsonrpc":"2.0"
}}""".format(
        block_number_hex
    )
    return PostHttpRequestRecipe(
        port_id="rpc",
        endpoint="/",
        content_type="application/json",
        body=request_body,
        extract={
            BLOCK_NUMBER_FIELD: JQ_PAD_HEX_FILTER.format(".result.number"),
            BLOCK_HASH_FIELD: ".result.hash",
        },
    )

def wait_until_node_reached_epoch(plan, cl_service_name, target_epoch):
    plan.wait(
        recipe=get_consensus_epoch_recipe(),
        field="extract." + CURRENT_EPOCH_FIELD,
        assertion=">=",
        target_value=target_epoch,
        timeout="20m",  # Consensus clients can take a while to sync, especially at the beginning
        service_name=cl_service_name,
    )


# Constructs a REST request to get the current epoch from consensus client
def get_consensus_epoch_recipe():
    return GetHttpRequestRecipe(
        port_id="http",
        endpoint="/eth/v1/beacon/headers/" + HEAD_SLOT_GENERIC,
        extract={
            CURRENT_SLOT_FIELD: ".data.header.message.slot | tonumber",
            CURRENT_EPOCH_FIELD: "(.data.header.message.slot | tonumber) / 32 | floor",  # Each epoch has 32 slots
        },
    )
