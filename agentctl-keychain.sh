#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${KEYCHAIN_SERVICE_NAME:-agentctl-codex-json_refresh_token-auth}"
ACCOUNT_NAME="${KEYCHAIN_ACCOUNT_NAME:-runtime-codex-json_refresh_token-auth}"
CONTAINER_CMD="${CONTAINER_CMD:-container}"

usage() {
  echo "Usage:"
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
