#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${KEYCHAIN_SERVICE_NAME:-codex-OpenAI-auth}"
ACCOUNT_NAME="${KEYCHAIN_ACCOUNT_NAME:-device-auth-openAI}"
CONTAINER_CMD="${CONTAINER_CMD:-container}"

usage() {
  echo "Usage:"
  echo "  $0 store-from-container <container> [path_in_container]"
  echo "  $0 load-to-container    <container> [path_in_container]"
  echo "  $0 read"
  echo "  $0 write"
  echo "  $0 verify"
  exit 1
}

maybe_decode_hex() {
  local data
  data="$(cat)"
  if [[ "$data" =~ ^[0-9A-Fa-f]+$ ]] && (( ${#data} % 2 == 0 )); then
    # Some keychain entries return hex-encoded bytes.
    printf '%s' "$data" | xxd -r -p
    return
  fi
  printf '%s' "$data"
}

store_from_container() {
  local container="$1"
  local path_in_container="${2:-/home/coder/.codex/auth.json}"

  # Read file from container and store into Keychain.
  local data
  if ! data="$("$CONTAINER_CMD" exec "$container" cat "$path_in_container")"; then
    echo "Failed to read $path_in_container from $container" >&2
    exit 4
  fi
  echo "Storing auth in Keychain ($SERVICE_NAME)" >&2
  if security add-generic-password \
    -a "$ACCOUNT_NAME" \
    -s "$SERVICE_NAME" \
    -w "$data" \
    -U; then
    echo "Stored $path_in_container from $container in Keychain"
  else
    echo "Failed to store $path_in_container from $container in Keychain" >&2
    exit 5
  fi
}

load_to_container() {
  local container="$1"
  local path_in_container="${2:-/home/coder/.codex/auth.json}"

  local dir
  dir="$(dirname "$path_in_container")"

  # Read Keychain and write into container file.
  echo "Loading auth from Keychain ($SERVICE_NAME)" >&2
  if security find-generic-password \
    -a "$ACCOUNT_NAME" \
    -s "$SERVICE_NAME" \
    -w | maybe_decode_hex | "$CONTAINER_CMD" exec -i "$container" sh -c 'mkdir -p "$1" && cat > "$2"' sh "$dir" "$path_in_container"; then
    echo "Wrote Keychain item to $path_in_container in $container"
  else
    echo "Failed to write Keychain item to $path_in_container in $container" >&2
    exit 7
  fi
}

read_keychain() {
  echo "Reading auth from Keychain ($SERVICE_NAME)" >&2
  if security find-generic-password \
    -a "$ACCOUNT_NAME" \
    -s "$SERVICE_NAME" \
    -w | maybe_decode_hex; then
    return 0
  fi
  echo "Failed to read Keychain item for $SERVICE_NAME" >&2
  exit 6
}

write_keychain() {
  local data
  data="$(cat)"
  echo "Storing auth in Keychain ($SERVICE_NAME)" >&2
  if security add-generic-password \
    -a "$ACCOUNT_NAME" \
    -s "$SERVICE_NAME" \
    -w "$data" \
    -U; then
    echo "Stored auth blob in Keychain"
  else
    echo "Failed to store auth blob in Keychain" >&2
    exit 5
  fi
}

cmd="${1:-}"
case "$cmd" in
  store-from-container) [[ $# -ge 2 && $# -le 3 ]] || usage; store_from_container "$2" "${3:-}" ;;
  load-to-container) [[ $# -ge 2 && $# -le 3 ]] || usage; load_to_container "$2" "${3:-}" ;;
  read) [[ $# -eq 1 ]] || usage; read_keychain ;;
  write) [[ $# -eq 1 ]] || usage; write_keychain ;;
  verify)
    if security find-generic-password -a "$ACCOUNT_NAME" -s "$SERVICE_NAME" >/dev/null; then
      echo "Keychain item exists for $SERVICE_NAME"
    else
      echo "Keychain item missing for $SERVICE_NAME" >&2
      exit 1
    fi
    ;;
  *) usage ;;
esac
