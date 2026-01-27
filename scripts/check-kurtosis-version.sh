#!/usr/bin/env bash
set -euo pipefail

MIN_VERSION="${1:-1.15.2}"

normalize_version() {
  # Keep only the semver core (e.g. "v1.15.2-beta.1" -> "1.15.2")
  local v="${1:-}"
  v="${v#v}"
  v="${v%%-*}"
  echo "$v"
}

version_ge() {
  # Returns 0 if $1 >= $2 (semver-ish comparison; ignores pre-release/build metadata).
  local a b IFS=.
  local -a av bv

  a="$(normalize_version "$1")"
  b="$(normalize_version "$2")"

  read -r -a av <<<"$a"
  read -r -a bv <<<"$b"

  # Pad to 3 parts
  while [ "${#av[@]}" -lt 3 ]; do av+=("0"); done
  while [ "${#bv[@]}" -lt 3 ]; do bv+=("0"); done

  for i in 0 1 2; do
    local ai="${av[$i]:-0}"
    local bi="${bv[$i]:-0}"
    if ((10#$ai > 10#$bi)); then return 0; fi
    if ((10#$ai < 10#$bi)); then return 1; fi
  done
  return 0
}

cli_version_raw="$(kurtosis version 2>/dev/null | awk '/CLI Version:/ {print $3}')"
if [ -z "${cli_version_raw:-}" ]; then
  echo "ERROR: Unable to determine Kurtosis CLI version (is 'kurtosis' installed and on PATH?)." >&2
  exit 1
fi

cli_version="$(normalize_version "$cli_version_raw")"
if ! version_ge "$cli_version" "$MIN_VERSION"; then
  cat >&2 <<EOF
ERROR: Kurtosis CLI ${cli_version} is too old for this package.
Required: >= ${MIN_VERSION}

Symptom: ServiceConfig: unexpected keyword argument "publish_udp" when running.

Fix:
  - Upgrade Kurtosis to >= ${MIN_VERSION}
  - Then restart the Kurtosis engine so the new Starlark API is picked up:
      kurtosis engine restart
    NOTE: Restarting the engine will stop running enclaves/services.
EOF
  exit 1
fi

# Best-effort engine version check (only fails if we can parse a running engine version).
engine_status_out="$(kurtosis engine status 2>&1 || true)"
engine_version_raw="$(echo "$engine_status_out" | awk '/Engine Version:/ {print $3; exit}')"
if [ -n "${engine_version_raw:-}" ]; then
  engine_version="$(normalize_version "$engine_version_raw")"
  if ! version_ge "$engine_version" "$MIN_VERSION"; then
    cat >&2 <<EOF
ERROR: Kurtosis engine ${engine_version} is too old for this package.
Required: >= ${MIN_VERSION}

Fix:
  kurtosis engine restart

NOTE: Restarting the engine will stop running enclaves/services.
EOF
    exit 1
  fi
fi

exit 0
