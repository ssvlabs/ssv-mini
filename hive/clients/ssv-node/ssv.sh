#!/bin/sh
# The simulator renders the whole node config (see simulators/ssv/ssv.go) and uploads it, so all this
# client does is start the node on it.
set -e
exec /go/bin/ssvnode start-node --config /hive/input/config.yaml
