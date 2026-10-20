#!/bin/bash
# Inputs (uploaded by the simulator):
#   /hive/input/testnet/{config.yaml,genesis.ssz}
#   /hive/input/keys/<pubkey>/voting-keystore.json, /hive/input/secrets/<pubkey>   (eth2-val-tools layout)
# Env:
#   HIVE_SSV_BN_IP    beacon node to attach to
set -e

mkdir -p /data/testnet
cp /hive/input/testnet/config.yaml /hive/input/testnet/genesis.ssz /data/testnet/
echo 0 > /data/testnet/deploy_block.txt
echo 0 > /data/testnet/deposit_contract_block.txt
echo "[]" > /data/testnet/boot_enr.yaml
# lighthouse writes validator_definitions.yml next to the keystores, so they can't stay on the input mount.
cp -r /hive/input/keys /data/validators
cp -r /hive/input/secrets /data/secrets

exec lighthouse \
    --debug-level="${HIVE_SSV_LOG_LEVEL:-info}" \
    --datadir=/data/vc \
    --testnet-dir=/data/testnet \
    vc \
    --validators-dir=/data/validators \
    --secrets-dir=/data/secrets \
    --init-slashing-protection \
    --beacon-nodes="http://${HIVE_SSV_BN_IP}:4000" \
    --suggested-fee-recipient=0x8943545177806ED17B9F23F0a21ee5948eCaa776
