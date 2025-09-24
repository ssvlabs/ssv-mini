#!/bin/bash
set -e

# Check if jq is installed
if ! command -v jq &> /dev/null
then
    echo "jq is not installed. Installing..."
    apt update -y
    apt install -y jq
else
    echo "jq is already installed."
fi


cast send $SSV_TOKEN_ADDRESS "approve(address,uint256)" $SSV_NETWORK_ADDRESS 1000000000000000000 --private-key $PRIVATE_KEY --rpc-url $ETH_RPC_URL --legacy --silent

# Extract data from JSON file
JSON_FILE="script/keyshares/out.json"

# Get the number of shares in the array
SHARES_COUNT=$(jq '.shares | length' "$JSON_FILE")
echo "Found $SHARES_COUNT validators to register"

PUBLIC_KEYS=$(jq -r "[.shares[].payload.publicKey] | join(\",\")" "$JSON_FILE")
SHARES_DATA=$(jq -r "[.shares[].payload.sharesData] |  join(\",\")" "$JSON_FILE")
OPERATOR_IDS=$(jq -r ".shares[0].payload.operatorIds | join(\",\")" "$JSON_FILE")

# Run the forge command with automatic splitting if the OS reports
# "Argument list too long". This keeps PUBLIC_KEYS and SHARES_DATA aligned.

join_slice_csv() {
  # join_slice_csv <array_name> <start> <length>
  # Emits a comma-separated slice of the given array
  local -n __arr_ref=$1
  local __start=$2
  local __len=$3
  local __end=$((__start + __len))
  local __out=""
  local i
  for (( i=__start; i<__end; i++ )); do
    if [ -n "$__out" ]; then
      __out+=",${__arr_ref[i]}"
    else
      __out="${__arr_ref[i]}"
    fi
  done
  printf '%s' "$__out"
}

register_chunk() {
  # register_chunk <public_keys_csv> <shares_data_csv>
  local keys_csv="$1"
  local shares_csv="$2"

  # Attempt the forge call and capture stderr/stdout
  local output
  output=$(forge script /app/script/register-validator/RegisterValidators.s.sol:RegisterValidator \
    --sig "run(address,bytes[],bytes[],uint64[])" \
    "$SSV_NETWORK_ADDRESS" "[${keys_csv}]" "[${shares_csv}]" "[${OPERATOR_IDS}]" \
    --broadcast --rpc-url "$ETH_RPC_URL" --private-key "$PRIVATE_KEY" --legacy --silent 2>&1)
  local status=$?

  if [ $status -eq 0 ]; then
    return 0
  fi

  # Echo the failure for visibility
  echo "$output" >&2

  # If the failure is due to OS arg limit, split and retry recursively
  if echo "$output" | grep -qi "Argument list too long"; then
    # Split both CSV lists in half, preserving alignment
    local IFS=','
    local -a keys_arr shares_arr
    read -r -a keys_arr   <<< "$keys_csv"
    read -r -a shares_arr <<< "$shares_csv"

    if [ ${#keys_arr[@]} -ne ${#shares_arr[@]} ]; then
      echo "Mismatch between PUBLIC_KEYS and SHARES_DATA lengths (${#keys_arr[@]} != ${#shares_arr[@]})." >&2
      return 1
    fi

    # Base case: cannot split further
    if [ ${#keys_arr[@]} -le 1 ]; then
      echo "Cannot split further (single validator still exceeds OS arg limit)." >&2
      return 1
    fi

    local mid=$(( ${#keys_arr[@]} / 2 ))
    local left_keys right_keys left_shares right_shares
    left_keys=$(join_slice_csv keys_arr 0 $mid)
    right_keys=$(join_slice_csv keys_arr $mid $(( ${#keys_arr[@]} - mid )))
    left_shares=$(join_slice_csv shares_arr 0 $mid)
    right_shares=$(join_slice_csv shares_arr $mid $(( ${#shares_arr[@]} - mid )))

    echo "Argument list too long; splitting batch into ${mid} + $(( ${#keys_arr[@]} - mid )) and retrying..." >&2

    # Recurse on each half; both must succeed
    register_chunk "$left_keys" "$left_shares" && \
    register_chunk "$right_keys" "$right_shares"
    return $?
  fi

  # Some other error
  return $status
}

# Kick off registration with automatic splitting
if [ "$SHARES_COUNT" -eq 0 ]; then
  echo "No validators to register."
else
  echo "Attempting to register $SHARES_COUNT validators in batch..."
  if register_chunk "$PUBLIC_KEYS" "$SHARES_DATA"; then
    echo "All validators have been registered"
  else
    echo "Registration failed." >&2
    exit 1
  fi
fi