def is_valid_cluster_size(node_count):
    if node_count < 4 or node_count > 13 or node_count % 3 != 1:
        return False
    return True