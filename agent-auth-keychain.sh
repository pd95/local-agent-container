#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${KEYCHAIN_SERVICE_NAME:-agent-openai-auth}"
ACCOUNT_NAME="${KEYCHAIN_ACCOUNT_NAME:-device-auth-openAI}"
CONTAINER_CMD="${CONTAINER_CMD:-container}"

usage() {
  echo "Usage:"
  echo "  $0 store-from-container <container> <format> [path_in_container]"
  echo "  $0 load-to-container    <container> <format> [path_in_container]"
  echo "  $0 read [format]"
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
  local format="$2"
  local path_in_container="${3:-/home/coder/.codex/auth.json}"

  local data
  case "$format" in
    json_refresh_token|opaque_blob)
      if ! data="$("$CONTAINER_CMD" exec "$container" cat "$path_in_container")"; then
        echo "Failed to read $path_in_container from $container" >&2
        exit 4
      fi
      ;;
    directory_tarball)
      if ! data="$("$CONTAINER_CMD" exec "$container" sh -c 'path="$1"; cd -- "$path" && if tar --help 2>/dev/null | grep -q -- "--sort=name"; then tar --sort=name -cf - .; else tar -cf - .; fi' sh "$path_in_container" | xxd -p | tr -d '\n')"; then
        echo "Failed to read directory tarball from $path_in_container in $container" >&2
        exit 4
      fi
      ;;
    *)
      echo "Unsupported AGENT_AUTH_FORMAT: $format" >&2
      exit 6
      ;;
  esac
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
  local format="$2"
  local path_in_container="${3:-/home/coder/.codex/auth.json}"

  local dir
  dir="$(dirname "$path_in_container")"

  echo "Loading auth from Keychain ($SERVICE_NAME)" >&2
  case "$format" in
    json_refresh_token|opaque_blob)
      if security find-generic-password \
        -a "$ACCOUNT_NAME" \
        -s "$SERVICE_NAME" \
        -w | maybe_decode_hex | "$CONTAINER_CMD" exec -i "$container" sh -c 'mkdir -p "$1" && cat > "$2"' sh "$dir" "$path_in_container"; then
        echo "Wrote Keychain item to $path_in_container in $container"
      else
        echo "Failed to write Keychain item to $path_in_container in $container" >&2
        exit 7
      fi
      ;;
    directory_tarball)
      if security find-generic-password \
        -a "$ACCOUNT_NAME" \
        -s "$SERVICE_NAME" \
        -w | maybe_decode_hex | "$CONTAINER_CMD" exec -i "$container" sh -c 'rm -rf -- "$1" && mkdir -p "$1" && tar -x -C "$1"' sh "$path_in_container"; then
        echo "Wrote Keychain item to $path_in_container in $container"
      else
        echo "Failed to write Keychain item to $path_in_container in $container" >&2
        exit 7
      fi
      ;;
    *)
      echo "Unsupported AGENT_AUTH_FORMAT: $format" >&2
      exit 6
      ;;
  esac
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

cmd="${1:-}"
case "$cmd" in
  store-from-container)
    if [ "$#" -eq 3 ] && [[ "$3" != json_refresh_token && "$3" != opaque_blob && "$3" != directory_tarball ]]; then
      store_from_container "$2" "json_refresh_token" "$3"
    else
      [[ $# -ge 2 && $# -le 4 ]] || usage
      store_from_container "$2" "${3:-json_refresh_token}" "${4:-}"
    fi
    ;;
  load-to-container)
    if [ "$#" -eq 3 ] && [[ "$3" != json_refresh_token && "$3" != opaque_blob && "$3" != directory_tarball ]]; then
      load_to_container "$2" "json_refresh_token" "$3"
    else
      [[ $# -ge 2 && $# -le 4 ]] || usage
      load_to_container "$2" "${3:-json_refresh_token}" "${4:-}"
    fi
    ;;
  read) [[ $# -eq 1 || $# -eq 2 ]] || usage; read_keychain ;;
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
