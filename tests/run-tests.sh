#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=tests/testlib.sh
. "$SCRIPT_DIR/testlib.sh"

trap cleanup EXIT

test_temp_run_removes_container() {
  begin_test "run --temp removes the named container"
  local name
  local workdir

  name="$(unique_name temp)"
  workdir="$(new_workdir)"

  run_capture "$CODEXCTL" run --name "$name" --image agent-codex --temp --workdir "$workdir" --cmd true
  assert_status 0

  if container_exists "$name"; then
    fail "Temporary container still exists: $name"
  fi
}

test_named_run_persists_until_rm() {
  begin_test "named run persists until explicit removal"
  local name
  local workdir

  name="$(unique_name persistent)"
  workdir="$(new_workdir)"
  register_container_cleanup "$name"

  run_capture "$CODEXCTL" run --name "$name" --image agent-codex --workdir "$workdir" --cmd true
  assert_status 0

  if ! container_exists "$name"; then
    fail "Named container was not preserved: $name"
  fi

  run_capture "$CODEXCTL" rm --name "$name"
  assert_status 0

  if container_exists "$name"; then
    fail "Named container still exists after rm: $name"
  fi
}

test_build_rebuild_stops_buildkit() {
  begin_test "build --rebuild stops buildkit after a successful build"

  run_capture "$CODEXCTL" build --image agent-codex --rebuild
  assert_status 0
  assert_contains "Building image tags: agent-codex,"

  if ! "$CONTAINER_CMD" ls -a 2>/dev/null | grep -q -E '^buildkit[[:space:]]+.*[[:space:]]stopped([[:space:]]|$)'; then
    printf '%s\n' "$RUN_OUTPUT" >&2
    fail "Expected buildkit to be stopped after codexctl build"
  fi
}

test_upgrade_no_backup_preserves_state() {
  begin_test "upgrade --no-backup preserves state without creating backup images"
  local name
  local workdir
  local backup_base

  name="$(unique_name upgrade-no-backup)"
  workdir="$(new_workdir)"
  register_container_cleanup "$name"
  backup_base="$(printf '%s\n' "${name}-backup" | tr '[:upper:]' '[:lower:]')"

  run_capture "$CODEXCTL" run --name "$name" --image agent-codex --workdir "$workdir" --cmd bash -lc 'mkdir -p /home/coder/.codex && echo upgrade-ok >/home/coder/.codex/upgrade-smoke.txt'
  assert_status 0

  run_capture "$CODEXCTL" upgrade --name "$name" --no-backup
  assert_status 0
  assert_contains "Skipping backup image export for $name"
  assert_contains "Upgrade complete: $name (backup skipped)"

  if [ -n "$(list_backup_images "$backup_base")" ]; then
    printf '%s\n' "$(list_backup_images "$backup_base")" >&2
    fail "Backup images were created unexpectedly for $name"
  fi

  run_capture "$CODEXCTL" run --name "$name" --image agent-codex --workdir "$workdir" --cmd bash -lc 'cat /home/coder/.codex/upgrade-smoke.txt'
  assert_status 0
  assert_contains "upgrade-ok"
}

test_upgrade_with_backup_creates_recovery_image() {
  begin_test "upgrade creates a backup image by default"
  local name
  local workdir
  local backup_image

  name="$(unique_name upgrade-backup)"
  workdir="$(new_workdir)"
  register_container_cleanup "$name"

  run_capture "$CODEXCTL" run --name "$name" --image agent-codex --workdir "$workdir" --cmd bash -lc 'mkdir -p /home/coder/.codex && echo backup-ok >/home/coder/.codex/backup-smoke.txt'
  assert_status 0

  run_capture "$CODEXCTL" upgrade --name "$name"
  assert_status 0
  backup_image="$(extract_backup_image)"
  [ -n "$backup_image" ] || fail "Could not parse backup image name from upgrade output"
  register_backup_cleanup "$backup_image"

  if ! image_exists "$backup_image"; then
    printf '%s\n' "$RUN_OUTPUT" >&2
    fail "Expected backup image to exist: $backup_image"
  fi

  run_capture "$CODEXCTL" run --name "$name" --image agent-codex --workdir "$workdir" --cmd bash -lc 'cat /home/coder/.codex/backup-smoke.txt'
  assert_status 0
  assert_contains "backup-ok"
}

test_upgrade_preflight_failure_keeps_container() {
  begin_test "upgrade preflight failure leaves the original container intact"
  local name
  local workdir

  name="$(unique_name upgrade-preflight)"
  workdir="$(new_workdir)"
  register_container_cleanup "$name"

  run_capture "$CODEXCTL" run --name "$name" --image agent-codex --workdir "$workdir" --cmd bash -lc 'mkdir -p /home/coder/.codex && echo intact >/home/coder/.codex/preflight.txt'
  assert_status 0

  run_capture "$CODEXCTL" upgrade --name "$name" --image does-not-exist
  assert_status 1
  assert_contains "Error: Image not found: does-not-exist"

  if ! container_exists "$name"; then
    fail "Container was removed after failed upgrade: $name"
  fi

  run_capture "$CODEXCTL" run --name "$name" --image agent-codex --workdir "$workdir" --cmd bash -lc 'cat /home/coder/.codex/preflight.txt'
  assert_status 0
  assert_contains "intact"
}

test_run_reset_config_restores_image_defaults() {
  begin_test "run --reset-config restores config, models, and AGENTS symlink"
  local name
  local workdir

  name="$(unique_name reset-config)"
  workdir="$(new_workdir)"
  register_container_cleanup "$name"

  run_capture "$CODEXCTL" run --name "$name" --image agent-codex --workdir "$workdir" --cmd bash -lc 'mkdir -p /home/coder/.codex && printf "# legacy-config\n" >/home/coder/.codex/config.toml && rm -f /home/coder/.codex/local_models.json && rm -f /home/coder/.codex/AGENTS.md && printf "legacy-agents\n" >/home/coder/.codex/AGENTS.md'
  assert_status 0

  run_capture "$CODEXCTL" run --name "$name" --image agent-codex --workdir "$workdir" --reset-config --cmd bash -lc 'if diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml && diff -q /etc/codexctl/local_models.json /home/coder/.codex/local_models.json && test -L /home/coder/.codex/AGENTS.md && ([ "$(readlink /home/coder/.codex/AGENTS.md)" = "/etc/codexctl/image.md" ] || [ "$(readlink /home/coder/.codex/AGENTS.md)" = "/etc/agentctl/image.md" ]); then echo reset-config-ok; else exit 1; fi'
  assert_status 0
  assert_contains "reset-config-ok"
}

test_upgrade_overwrite_config_restores_image_defaults() {
  begin_test "upgrade --overwrite-config restores config, models, and AGENTS symlink"
  local name
  local workdir

  name="$(unique_name overwrite-config)"
  workdir="$(new_workdir)"
  register_container_cleanup "$name"

  run_capture "$CODEXCTL" run --name "$name" --image agent-codex --workdir "$workdir" --cmd bash -lc 'mkdir -p /home/coder/.codex && printf "# PRE-OVERWRITE\n[ollama]\nhost = \"http://127.0.0.1:11434\"\n" >/home/coder/.codex/config.toml && rm -f /home/coder/.codex/local_models.json && rm -f /home/coder/.codex/AGENTS.md && printf "legacy-agents\n" >/home/coder/.codex/AGENTS.md'
  assert_status 0

  run_capture "$CODEXCTL" upgrade --name "$name" --overwrite-config --no-backup
  assert_status 0
  assert_contains "Overwriting config.toml, local_models.json in ~/.codex/ and recreating ~/.codex/AGENTS.md in $name"
  assert_contains "Upgrade complete: $name (backup skipped)"

  run_capture "$CODEXCTL" run --name "$name" --image agent-codex --workdir "$workdir" --cmd bash -lc 'if diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml && diff -q /etc/codexctl/local_models.json /home/coder/.codex/local_models.json && test -L /home/coder/.codex/AGENTS.md && ([ "$(readlink /home/coder/.codex/AGENTS.md)" = "/etc/codexctl/image.md" ] || [ "$(readlink /home/coder/.codex/AGENTS.md)" = "/etc/agentctl/image.md" ]); then echo overwrite-config-ok; else exit 1; fi'
  assert_status 0
  assert_contains "overwrite-config-ok"
}

main() {
  require_host_prereqs

  local from_filter=""
  local run_mode="${1:-}"
  if [ "$run_mode" = "unit" ]; then
    shift
  elif [ -n "$run_mode" ]; then
    shift
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from)
        from_filter="$2"
        shift 2
        ;;
      --from=*)
        from_filter="${1#*=}"
        shift
        ;;
      --help|-h)
        echo "Usage: $0 [unit] [--from <test-name-or-index>]"
        echo "  <test-name-or-index> matches function name, description, or 1-based test index"
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done

  log "Using codexctl at $CODEXCTL"
  log "Using container runtime command $CONTAINER_CMD"

  local run_from=1
  local -a test_cases=(
    "test_temp_run_removes_container|run --temp removes the named container"
    "test_named_run_persists_until_rm|named run persists until explicit removal"
    "test_build_rebuild_stops_buildkit|build --rebuild stops buildkit after a successful build"
    "test_upgrade_no_backup_preserves_state|upgrade --no-backup preserves state without creating backup images"
    "test_upgrade_with_backup_creates_recovery_image|upgrade creates a backup image by default"
    "test_upgrade_preflight_failure_keeps_container|upgrade preflight failure leaves the original container intact"
    "test_run_reset_config_restores_image_defaults|run --reset-config restores config, models, and AGENTS symlink"
    "test_upgrade_overwrite_config_restores_image_defaults|upgrade --overwrite-config restores config, models, and AGENTS symlink"
  )

  if [ -n "$from_filter" ]; then
    local idx=1
    local matched=0
    for case_entry in "${test_cases[@]}"; do
      local test_fn="${case_entry%%|*}"
      local test_label="${case_entry#*|}"
      if [ "$idx" = "$from_filter" ] \
        || [ "$test_fn" = "$from_filter" ] \
        || [ "$test_label" = "$from_filter" ]; then
        run_from="$idx"
        matched=1
        break
      fi
      idx=$((idx + 1))
    done
    if [ "$matched" -eq 0 ]; then
      log "Could not match --from filter '$from_filter'; running full suite"
      run_from=1
    fi
  fi

  local idx=1
  for case_entry in "${test_cases[@]}"; do
    local test_fn="${case_entry%%|*}"
    if [ "$idx" -ge "$run_from" ]; then
      "$test_fn"
    fi
    idx=$((idx + 1))
  done

  log "PASS: all host integration tests completed"
}

main "$@"
