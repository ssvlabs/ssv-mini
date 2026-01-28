#!/usr/bin/env bash
set -euo pipefail

MIN_VERSION="${1:-1.15.2}"

# Get CLI version
CLI_VERSION=$(kurtosis version 2>/dev/null | awk '/CLI Version:/ {print $3}' || echo "")
if [ -z "$CLI_VERSION" ]; then
  echo "ERROR: Kurtosis CLI not found. Install from https://docs.kurtosis.com/install/" >&2
  exit 1
fi

# Compare versions using sort -V (oldest first)
OLDEST=$(printf '%s\n%s' "$MIN_VERSION" "$CLI_VERSION" | sort -V | head -n1)
if [ "$OLDEST" != "$MIN_VERSION" ]; then
  echo "ERROR: Kurtosis CLI $CLI_VERSION < $MIN_VERSION required. Run: kurtosis engine restart after upgrade." >&2
  exit 1
fi
