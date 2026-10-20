#!/bin/bash
# Inputs (uploaded by the simulator):
#   /hive/input/testnet/{config.yaml,genesis.ssz}   chain config + genesis state
# Env:
#   HIVE_SSV_EL_IP    execution client to drive over the engine API (hive's fixed JWT secret)
set -e

mkdir -p /data/testnet
cp /hive/input/testnet/config.yaml /hive/input/testnet/genesis.ssz /data/testnet/
echo 0 > /data/testnet/deploy_block.txt
echo 0 > /data/testnet/deposit_contract_block.txt
echo "[]" > /data/testnet/boot_enr.yaml
echo -n 0x7365637265747365637265747365637265747365637265747365637265747365 > /jwtsecret

ip=$(hostname -i | awk '{print $1}')
exec lighthouse \
    --debug-level="${HIVE_SSV_LOG_LEVEL:-info}" \
    --datadir=/data/beacon \
    --testnet-dir=/data/testnet \
    bn \
    --execution-endpoint="http://${HIVE_SSV_EL_IP}:8551" \
    --execution-jwt=/jwtsecret \
    --enr-address="$ip" --disable-enr-auto-update \
    --port=9000 --disable-quic \
    --target-peers=0 \
    --subscribe-all-subnets --supernode \
    --disable-peer-scoring --disable-packet-filter \
    --http --http-address=0.0.0.0 --http-port=4000 --http-allow-origin='*' \
    --metrics --metrics-address=0.0.0.0 --metrics-port=5054 --metrics-allow-origin='*'
