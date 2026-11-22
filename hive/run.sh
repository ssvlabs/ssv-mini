#!/usr/bin/env bash
# Runs the ssv hive simulator against a pinned hive checkout.
#
#   hive/run.sh                                   # node/ssv:latest, 12s slots
#   SSV_IMAGE=node/ssv:my-branch hive/run.sh      # any local ssv image
#   SLOT_SECONDS=6 hive/run.sh                    # faster chain
#   CHAIN=fresh hive/run.sh                       # replay the registrations on a new chain (no pre-mined history)
#   hive/run.sh --docker.output                   # extra args go to hive (e.g. stream client logs)
#
# hive only discovers clients/simulators inside its own tree, so this keeps a checkout in hive/.hive and
# syncs ours (plus the ssv-mini files the simulator shares with the Kurtosis package) into it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# constants.env defines SSV_IMAGE too; an explicit one from the caller wins.
CALLER_SSV_IMAGE="${SSV_IMAGE:-}"
source "$ROOT/constants.env"

HIVE_COMMIT=70c8df269bbda7ac9649da1d1738286f271a4ea3
HIVE_DIR="$ROOT/hive/.hive"
SSV_IMAGE="${CALLER_SSV_IMAGE:-$SSV_IMAGE}"
SLOT_SECONDS="${SLOT_SECONDS:-12}"
GENESIS_DELAY="${GENESIS_DELAY:-15}"
CHAIN="${CHAIN:-premined}"

if [ ! -d "$HIVE_DIR/.git" ]; then
  git clone -q https://github.com/ethereum/hive "$HIVE_DIR"
fi
if [ "$(git -C "$HIVE_DIR" rev-parse HEAD)" != "$HIVE_COMMIT" ]; then
  git -C "$HIVE_DIR" fetch -q origin "$HIVE_COMMIT"
  git -C "$HIVE_DIR" checkout -q "$HIVE_COMMIT"
  rm -f "$HIVE_DIR/hive"
fi
[ -x "$HIVE_DIR/hive" ] || (cd "$HIVE_DIR" && go build -o hive .)

for c in "$ROOT"/hive/clients/*/; do
  rsync -a --delete "$c" "$HIVE_DIR/clients/$(basename "$c")/"
done
SIM="$HIVE_DIR/simulators/ssv"
rsync -a --delete "$ROOT/hive/simulators/ssv/" "$SIM/"
cp "$ROOT/nodes/ssv/config.yml.tmpl" "$SIM/fixtures/ssv-config.yml.tmpl"

# The validator layout, from the constants main.star's layout guard uses (generate-static-keys.sh syncs them).
star_const() { sed -nE "s/^$1 = ([0-9]+).*/\1/p" "$ROOT/utils/constants.star"; }
VC_VALIDATORS=$(star_const SSV_SEED_START_INDEX)
POOL_VALIDATORS=$(star_const SSV_MANAGED_VALIDATOR_COUNT)
[ -n "$VC_VALIDATORS" ] && [ -n "$POOL_VALIDATORS" ] || { echo "can't read the validator layout from utils/constants.star"; exit 1; }
shares=$(jq '.shares | length' "$ROOT/static/keyshares/out.json")
[ "$shares" = "$POOL_VALIDATORS" ] || { echo "static/keyshares/out.json has $shares shares, utils/constants.star says $POOL_VALIDATORS: re-run scripts/generate-static-keys.sh"; exit 1; }

"$ROOT/scripts/record-txs.sh" --if-stale
cp "$ROOT/static/recorded/txs.json" "$SIM/fixtures/txs.json"
rsync -a "$ROOT/static/keys/" "$SIM/fixtures/keys/"

# The tag is whatever follows a ':' in the last path component; a registry port (host:5000/image) isn't one.
image_tag() { case "${1##*/}" in *:*) echo "${1##*:}" ;; *) echo latest ;; esac; }
image_name() { case "${1##*/}" in *:*) echo "${1%:*}" ;; *) echo "$1" ;; esac; }
cat > "$HIVE_DIR/ssv-clients.yaml" <<EOF
- client: go-ethereum
  build_args: {tag: "$(image_tag "$GETH_IMAGE")"}
- client: ssv-premine
  build_args: {tag: "$(image_tag "$GETH_IMAGE")"}
- client: ssv-lighthouse-bn
  build_args: {tag: "$(image_tag "$LIGHTHOUSE_IMAGE")"}
- client: ssv-lighthouse-vc
  build_args: {tag: "$(image_tag "$LIGHTHOUSE_IMAGE")"}
- client: ssv-node
  build_args: {baseimage: "$(image_name "$SSV_IMAGE")", tag: "$(image_tag "$SSV_IMAGE")"}
EOF

cd "$HIVE_DIR"
exec ./hive --sim ssv --client-file ssv-clients.yaml \
  --sim.buildarg SSV_SLOT_SECONDS="$SLOT_SECONDS" \
  --sim.buildarg SSV_GENESIS_DELAY="$GENESIS_DELAY" \
  --sim.buildarg SSV_CHAIN="$CHAIN" \
  --sim.buildarg SSV_VC_VALIDATORS="$VC_VALIDATORS" \
  --sim.buildarg SSV_POOL_VALIDATORS="$POOL_VALIDATORS" \
  "$@"
