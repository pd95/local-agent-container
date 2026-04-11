#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CODEXCTL="${CODEXCTL:-$TEST_ROOT/codexctl}"
CONTAINER_CMD="${CONTAINER_CMD:-container}"

TEST_STATUS=0
RUN_STATUS=0
RUN_OUTPUT=""
RUN_LOG=""

CLEANUP_CONTAINERS=""
CLEANUP_BACKUP_IMAGES=""
CLEANUP_DIRS=""

log() {
  printf '[test] %s\n' "$*"
}

fail() {
  printf '[test] FAIL: %s\n' "$*" >&2
  exit 1
}

require_host_prereqs() {
  command -v "$CODEXCTL" >/dev/null 2>&1 || fail "Missing codexctl: $CODEXCTL"
  command -v "$CONTAINER_CMD" >/dev/null 2>&1 || fail "Missing container runtime command: $CONTAINER_CMD"
  if [ "$(uname -s)" != "Darwin" ]; then
    fail "These host integration tests must run on macOS"
  fi
}

unique_name() {
  local suffix="$1"
  printf 'codexctl-test-%s-%s-%s' "$suffix" "$(date -u +%Y%m%d%H%M%S)" "$$"
}

new_workdir() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-test.XXXXXX")"
  register_dir_cleanup "$dir"
  printf '%s\n' "$dir"
}

register_container_cleanup() {
  local name="$1"
  case " $CLEANUP_CONTAINERS " in
    *" $name "*) return 0 ;;
  esac
  CLEANUP_CONTAINERS="$CLEANUP_CONTAINERS $name"
}

register_backup_cleanup() {
  local image_ref="$1"
  case " $CLEANUP_BACKUP_IMAGES " in
    *" $image_ref "*) return 0 ;;
  esac
  CLEANUP_BACKUP_IMAGES="$CLEANUP_BACKUP_IMAGES $image_ref"
}

register_dir_cleanup() {
  local path="$1"
  case " $CLEANUP_DIRS " in
    *" $path "*) return 0 ;;
  esac
  CLEANUP_DIRS="$CLEANUP_DIRS $path"
}

container_exists() {
  "$CONTAINER_CMD" ls -a 2>/dev/null | grep -q -E "(^|[[:space:]])$1([[:space:]]|$)"
}

image_exists() {
  "$CONTAINER_CMD" image inspect "$1" >/dev/null 2>&1
}

list_backup_images() {
  "$CODEXCTL" images --backup --image "$1" 2>/dev/null || true
}

run_capture() {
  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/codexctl-test-log.XXXXXX")"
  if "$@" >"$log_file" 2>&1; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
  RUN_OUTPUT="$(cat "$log_file")"
  RUN_LOG="$log_file"
}

assert_status() {
  local expected="$1"
  if [ "$RUN_STATUS" -ne "$expected" ]; then
    printf '%s\n' "$RUN_OUTPUT" >&2
    fail "Expected exit status $expected but got $RUN_STATUS"
  fi
}

assert_contains() {
  local needle="$1"
  if ! printf '%s' "$RUN_OUTPUT" | grep -Fq -- "$needle"; then
    printf '%s\n' "$RUN_OUTPUT" >&2
    fail "Expected output to contain: $needle"
  fi
}

assert_not_contains() {
  local needle="$1"
  if printf '%s' "$RUN_OUTPUT" | grep -Fq -- "$needle"; then
    printf '%s\n' "$RUN_OUTPUT" >&2
    fail "Did not expect output to contain: $needle"
  fi
}

extract_backup_image() {
  printf '%s\n' "$RUN_OUTPUT" | sed -n 's/^Upgrade complete: .* (backup image: \(.*\))$/\1/p' | tail -n 1
}

cleanup() {
  local image_ref
  local name
  local path

  for image_ref in $CLEANUP_BACKUP_IMAGES; do
    "$CODEXCTL" images prune --backup --image "$image_ref" --keep 0 >/dev/null 2>&1 || true
  done

  for name in $CLEANUP_CONTAINERS; do
    if container_exists "$name"; then
      "$CODEXCTL" rm --name "$name" >/dev/null 2>&1 || true
    fi
  done

  for path in $CLEANUP_DIRS; do
    rm -rf "$path" >/dev/null 2>&1 || true
  done

  if [ -n "$RUN_LOG" ] && [ -f "$RUN_LOG" ]; then
    rm -f "$RUN_LOG" >/dev/null 2>&1 || true
  fi
}

begin_test() {
  log "$1"
  RUN_STATUS=0
  RUN_OUTPUT=""
  unset -f \
    container \
    require_container \
    default_name \
    run_container \
    container_list_all \
    container_upgrade_info \
    container_running \
    build_backup_image_from_export \
    sanitize_image_name \
    backup_codex_config \
    restore_codex_config \
    codex_agents_state \
    date \
    trap \
    2>/dev/null || true
  if [ -n "$RUN_LOG" ] && [ -f "$RUN_LOG" ]; then
    rm -f "$RUN_LOG" >/dev/null 2>&1 || true
  fi
  RUN_LOG=""
}
