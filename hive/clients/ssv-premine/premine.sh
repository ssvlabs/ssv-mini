#!/bin/sh
# Inputs: /genesis.json (uploaded by the simulator). Mines a block every second on top of it; the simulator
# feeds it the registration txs and reads the blocks back with debug_getRawBlock.
set -e
geth --datadir /data --state.scheme=path init /genesis.json
exec geth --datadir /data --state.scheme=path \
    --dev --dev.period 1 --networkid 3151908 --nodiscover --maxpeers 0 \
    --http --http.addr 0.0.0.0 --http.port 8545 --http.api eth,net,debug
