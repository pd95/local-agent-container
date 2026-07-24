#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTCTL="${AGENTCTL:-$TEST_ROOT/agentctl}"
AGENTCTL_IMPL="${AGENTCTL_IMPL:-$TEST_ROOT/agentctl}"
CONTAINER_CMD="${CONTAINER_CMD:-container}"
TEST_FILTER="${TEST_FILTER:-}"
TEST_START_FROM="${TEST_START_FROM:-}"
TEST_TIER="${TEST_TIER:-smoke}"
TEST_START_ACTIVE=0
TESTS_RUN=0

TEST_STATUS=0
RUN_STATUS=0
RUN_OUTPUT=""
RUN_LOG=""

CLEANUP_CONTAINERS=""
CLEANUP_RAW_CONTAINERS=""
CLEANUP_IMAGES=""
CLEANUP_BACKUP_IMAGES=""
CLEANUP_NETWORKS=""
CLEANUP_PIDS=""
CLEANUP_MCP_CREDENTIALS=""
CLEANUP_DIRS=""
LEAK_TRACKING_DIR=""

log() {
  printf '[test] %s\n' "$*"
}

fail() {
  printf '[test] FAIL: %s\n' "$*" >&2
  exit 1
}

require_host_prereqs() {
  command -v "$AGENTCTL" >/dev/null 2>&1 || fail "Missing agentctl: $AGENTCTL"
  command -v "$AGENTCTL_IMPL" >/dev/null 2>&1 || fail "Missing agentctl implementation: $AGENTCTL_IMPL"
  command -v "$CONTAINER_CMD" >/dev/null 2>&1 || fail "Missing container runtime command: $CONTAINER_CMD"
  if [ "$(uname -s)" != "Darwin" ]; then
    fail "These host integration tests must run on macOS"
  fi
}

unique_name() {
  local suffix="$1"
  printf 'agentctl-test-%s-%s-%s' "$suffix" "$(date -u +%Y%m%d%H%M%S)" "$$"
}

new_workdir() {
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-test.XXXXXX")"
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

register_raw_container_cleanup() {
  local name="$1"
  case " $CLEANUP_RAW_CONTAINERS " in
    *" $name "*) return 0 ;;
  esac
  CLEANUP_RAW_CONTAINERS="$CLEANUP_RAW_CONTAINERS $name"
}

register_backup_cleanup() {
  local image_ref="$1"
  case " $CLEANUP_BACKUP_IMAGES " in
    *" $image_ref "*) return 0 ;;
  esac
  CLEANUP_BACKUP_IMAGES="$CLEANUP_BACKUP_IMAGES $image_ref"
}

register_image_cleanup() {
  local image_ref="$1"
  case " $CLEANUP_IMAGES " in
    *" $image_ref "*) return 0 ;;
  esac
  CLEANUP_IMAGES="$CLEANUP_IMAGES $image_ref"
}

register_network_cleanup() {
  local name="$1"
  case " $CLEANUP_NETWORKS " in
    *" $name "*) return 0 ;;
  esac
  CLEANUP_NETWORKS="$CLEANUP_NETWORKS $name"
}

register_pid_cleanup() {
  local pid="$1"
  case " $CLEANUP_PIDS " in
    *" $pid "*) return 0 ;;
  esac
  CLEANUP_PIDS="$CLEANUP_PIDS $pid"
}

register_mcp_credential_cleanup() {
  local credential="$1"
  case " $CLEANUP_MCP_CREDENTIALS " in *" $credential "*) return 0 ;; esac
  CLEANUP_MCP_CREDENTIALS="$CLEANUP_MCP_CREDENTIALS $credential"
}

register_dir_cleanup() {
  local path="$1"
  CLEANUP_DIRS="${CLEANUP_DIRS}${path}"$'\n'
}

container_exists() {
  "$CONTAINER_CMD" ls -a 2>/dev/null | grep -q -E "(^|[[:space:]])$1([[:space:]]|$)"
}

container_running() {
  "$CONTAINER_CMD" ls 2>/dev/null | grep -q -E "(^|[[:space:]])$1([[:space:]]|$)"
}

snapshot_container_names() {
  "$CONTAINER_CMD" ls -a 2>/dev/null | awk 'NR > 1 && NF > 0 { print $1 }' | sort -u
}

snapshot_image_refs() {
  "$CONTAINER_CMD" image ls 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $1 ":" $2 }' | sort -u
}

start_leak_tracking() {
  LEAK_TRACKING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-leak-tracking.XXXXXX")"
  snapshot_container_names >"$LEAK_TRACKING_DIR/containers.before"
  snapshot_image_refs >"$LEAK_TRACKING_DIR/images.before"
}

report_resource_leaks() {
  local leaked_containers=""
  local leaked_images=""

  [ -n "$LEAK_TRACKING_DIR" ] || return 0
  [ -d "$LEAK_TRACKING_DIR" ] || return 0

  snapshot_container_names >"$LEAK_TRACKING_DIR/containers.after"
  snapshot_image_refs >"$LEAK_TRACKING_DIR/images.after"

  leaked_containers="$(comm -13 "$LEAK_TRACKING_DIR/containers.before" "$LEAK_TRACKING_DIR/containers.after" || true)"
  leaked_images="$(comm -13 "$LEAK_TRACKING_DIR/images.before" "$LEAK_TRACKING_DIR/images.after" || true)"

  if [ -n "$leaked_containers" ]; then
    printf '[test] Warning: possible leaked container(s) created during this run:\n' >&2
    printf '%s\n' "$leaked_containers" | sed 's/^/[test]   - /' >&2
    printf '[test] Inspect with: container inspect <name>\n' >&2
    printf '[test] Remove with: container rm <name> or agentctl rm --name <name> --force\n' >&2
  fi

  if [ -n "$leaked_images" ]; then
    printf '[test] Warning: possible leaked image(s) created during this run:\n' >&2
    printf '%s\n' "$leaked_images" | sed 's/^/[test]   - /' >&2
    printf '[test] Inspect with: container image inspect <ref>\n' >&2
    printf '[test] Remove with: container image rm <ref>\n' >&2
  fi

  rm -rf "$LEAK_TRACKING_DIR" >/dev/null 2>&1 || true
  LEAK_TRACKING_DIR=""
}

cleanup_and_report() {
  cleanup
  report_resource_leaks
}

image_exists() {
  "$CONTAINER_CMD" image inspect "$1" >/dev/null 2>&1
}

list_backup_images() {
  "$AGENTCTL" images --backup --image "$1" 2>/dev/null || true
}

run_capture() {
  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/agentctl-test-log.XXXXXX")"
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

assert_matches() {
  local pattern="$1"
  if ! printf '%s' "$RUN_OUTPUT" | grep -Eq -- "$pattern"; then
    printf '%s\n' "$RUN_OUTPUT" >&2
    fail "Expected output to match regex: $pattern"
  fi
}

extract_backup_image() {
  printf '%s\n' "$RUN_OUTPUT" | sed -n 's/^Upgrade complete: .* (backup image: \(.*\))$/\1/p' | tail -n 1
}

cleanup() {
  local image_ref
  local name
  local path
  local cleanup_log

  for name in $CLEANUP_PIDS; do
    if kill -0 "$name" >/dev/null 2>&1; then
      kill "$name" >/dev/null 2>&1 || true
      wait "$name" >/dev/null 2>&1 || true
    fi
  done

  for name in $CLEANUP_MCP_CREDENTIALS; do
    "$AGENTCTL" mcp credential delete "$name" >/dev/null 2>&1 || true
  done

  for name in $CLEANUP_CONTAINERS; do
    if container_exists "$name"; then
      cleanup_log="$(mktemp "${TMPDIR:-/tmp}/agentctl-cleanup.XXXXXX")"
      if ! "$AGENTCTL" rm --name "$name" --force >"$cleanup_log" 2>&1; then
        printf '[test] cleanup failed for container %s:\n' "$name" >&2
        cat "$cleanup_log" >&2
      fi
      rm -f "$cleanup_log" >/dev/null 2>&1 || true
    fi
  done

  for name in $CLEANUP_RAW_CONTAINERS; do
    if "$CONTAINER_CMD" ls 2>/dev/null | grep -q -E "(^|[[:space:]])$name([[:space:]]|$)"; then
      cleanup_log="$(mktemp "${TMPDIR:-/tmp}/agentctl-cleanup.XXXXXX")"
      if ! "$CONTAINER_CMD" stop "$name" >"$cleanup_log" 2>&1; then
        printf '[test] cleanup failed stopping raw container %s:\n' "$name" >&2
        cat "$cleanup_log" >&2
      fi
      rm -f "$cleanup_log" >/dev/null 2>&1 || true
    fi
    if "$CONTAINER_CMD" ls -a 2>/dev/null | grep -q -E "(^|[[:space:]])$name([[:space:]]|$)"; then
      cleanup_log="$(mktemp "${TMPDIR:-/tmp}/agentctl-cleanup.XXXXXX")"
      if ! "$CONTAINER_CMD" rm "$name" >"$cleanup_log" 2>&1; then
        printf '[test] cleanup failed removing raw container %s:\n' "$name" >&2
        cat "$cleanup_log" >&2
      fi
      rm -f "$cleanup_log" >/dev/null 2>&1 || true
    fi
  done

  for image_ref in $CLEANUP_BACKUP_IMAGES; do
    cleanup_log="$(mktemp "${TMPDIR:-/tmp}/agentctl-cleanup.XXXXXX")"
    if ! "$AGENTCTL" images prune --backup --image "$image_ref" --keep 0 >"$cleanup_log" 2>&1; then
      if ! "$CONTAINER_CMD" image rm "$image_ref" >>"$cleanup_log" 2>&1 \
        && ! "$CONTAINER_CMD" image rm "${image_ref}:latest" >>"$cleanup_log" 2>&1; then
        printf '[test] cleanup failed for backup image %s:\n' "$image_ref" >&2
        cat "$cleanup_log" >&2
      fi
    fi
    rm -f "$cleanup_log" >/dev/null 2>&1 || true
  done

  for image_ref in $CLEANUP_IMAGES; do
    cleanup_log="$(mktemp "${TMPDIR:-/tmp}/agentctl-cleanup.XXXXXX")"
    if ! "$CONTAINER_CMD" image rm "$image_ref" >"$cleanup_log" 2>&1; then
      printf '[test] cleanup failed for image %s:\n' "$image_ref" >&2
      cat "$cleanup_log" >&2
    fi
    rm -f "$cleanup_log" >/dev/null 2>&1 || true
  done

  for name in $CLEANUP_NETWORKS; do
    if ! "$CONTAINER_CMD" network inspect "$name" >/dev/null 2>&1; then
      continue
    fi
    cleanup_log="$(mktemp "${TMPDIR:-/tmp}/agentctl-cleanup.XXXXXX")"
    if ! "$AGENTCTL" network rm "$name" >"$cleanup_log" 2>&1; then
      printf '[test] cleanup failed for network %s:\n' "$name" >&2
      cat "$cleanup_log" >&2
    fi
    rm -f "$cleanup_log" >/dev/null 2>&1 || true
  done

  printf '%s' "$CLEANUP_DIRS" | while IFS= read -r path; do
    [ -n "$path" ] || continue
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
  if [ -n "$RUN_LOG" ] && [ -f "$RUN_LOG" ]; then
    rm -f "$RUN_LOG" >/dev/null 2>&1 || true
  fi
  RUN_LOG=""
}

test_matches_filter() {
  local name="$1"
  local description="$2"
  local normalized_filter=""
  local normalized_name=""
  local normalized_description=""

  normalized_filter="$(printf '%s' "$TEST_FILTER" | tr '[:upper:]' '[:lower:]')"
  normalized_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  normalized_description="$(printf '%s' "$description" | tr '[:upper:]' '[:lower:]')"
  normalized_filter="${normalized_filter//-/_}"
  normalized_name="${normalized_name//-/_}"
  normalized_description="${normalized_description//-/_}"

  normalized_filter="${normalized_filter// /_}"
  normalized_name="${normalized_name// /_}"
  normalized_description="${normalized_description// /_}"

  if [ -z "$TEST_FILTER" ]; then
    return 0
  fi

  case "$name"$'\n'"$description" in
    *"$TEST_FILTER"*) return 0 ;;
  esac
  case "$normalized_name"$'\n'"$normalized_description" in
    *"$normalized_filter"*) return 0 ;;
    *) return 1 ;;
  esac
}

test_matches_start_from() {
  local name="$1"
  local description="$2"
  local normalized_start_from=""
  local normalized_name=""
  local normalized_description=""

  normalized_start_from="$(printf '%s' "$TEST_START_FROM" | tr '[:upper:]' '[:lower:]')"
  normalized_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  normalized_description="$(printf '%s' "$description" | tr '[:upper:]' '[:lower:]')"
  normalized_start_from="${normalized_start_from//-/_}"
  normalized_name="${normalized_name//-/_}"
  normalized_description="${normalized_description//-/_}"

  normalized_start_from="${normalized_start_from// /_}"
  normalized_name="${normalized_name// /_}"
  normalized_description="${normalized_description// /_}"

  if [ -z "$TEST_START_FROM" ]; then
    return 0
  fi
  if [ "$TEST_START_ACTIVE" -eq 1 ]; then
    return 0
  fi

  case "$name"$'\n'"$description" in
    *"$TEST_START_FROM"*)
      TEST_START_ACTIVE=1
      return 0
      ;;
  esac
  case "$normalized_name"$'\n'"$normalized_description" in
    *"$normalized_start_from"*)
      TEST_START_ACTIVE=1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_selected_test() {
  local name="$1"
  local description="$2"
  local tier="${3:-smoke}"
  local start_seconds
  local elapsed_seconds

  test_matches_start_from "$name" "$description" || return 0
  test_matches_filter "$name" "$description" || return 0
  case "$TEST_TIER" in
    full) ;;
    smoke)
      [ "$tier" = "smoke" ] || return 0
      ;;
    *)
      fail "Unknown test tier: $TEST_TIER"
      ;;
  esac

  TESTS_RUN=$((TESTS_RUN + 1))
  start_seconds=$SECONDS
  "$name"
  elapsed_seconds=$((SECONDS - start_seconds))
  log "Completed in ${elapsed_seconds}s: $description"
}

assert_selected_tests_ran() {
  if [ "$TESTS_RUN" -eq 0 ]; then
    if [ -n "$TEST_FILTER" ] && [ -n "$TEST_START_FROM" ]; then
      fail "No tests matched --from \"$TEST_START_FROM\" with filter \"$TEST_FILTER\""
    fi
    if [ -n "$TEST_FILTER" ]; then
      fail "No tests matched filter: $TEST_FILTER"
    fi
    if [ -n "$TEST_START_FROM" ]; then
      fail "No tests matched --from: $TEST_START_FROM"
    fi
    fail "No tests were executed"
  fi
}
