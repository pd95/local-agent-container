#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=tests/testlib.sh
. "$SCRIPT_DIR/testlib.sh"

trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: ./tests/run-tests.sh [--tier smoke|full] [--filter TEXT] [--from TEXT]
       ./tests/run-tests.sh [TEXT]

Options:
  --tier TEXT    Run the smoke suite (default) or the full suite
  --filter TEXT  Run only tests whose function name or description contains TEXT
  --from TEXT    Run all tests starting at the first test whose function name or description contains TEXT

If a single positional TEXT argument is provided, it is treated like --filter TEXT.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tier)
      TEST_TIER="${2:-}"
      [ -n "$TEST_TIER" ] || fail "Missing value for --tier"
      shift 2
      ;;
    --filter)
      TEST_FILTER="${2:-}"
      [ -n "$TEST_FILTER" ] || fail "Missing value for --filter"
      shift 2
      ;;
    --from)
      TEST_START_FROM="${2:-}"
      [ -n "$TEST_START_FROM" ] || fail "Missing value for --from"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      fail "Unknown option: $1"
      ;;
    *)
      if [ -n "$TEST_FILTER" ]; then
        fail "Unexpected positional argument: $1"
      fi
      TEST_FILTER="$1"
      shift
      ;;
  esac
done

RUNTIME_FIXTURE_NAME=""
RUNTIME_FIXTURE_WORKDIR=""
FEATURE_FIXTURE_NAME=""
FEATURE_FIXTURE_WORKDIR=""

ensure_runtime_fixture() {
  if [ -n "$RUNTIME_FIXTURE_NAME" ] && container_exists "$RUNTIME_FIXTURE_NAME"; then
    return 0
  fi

  RUNTIME_FIXTURE_NAME="$(unique_name runtime-fixture)"
  RUNTIME_FIXTURE_WORKDIR="$(new_workdir)"
  register_container_cleanup "$RUNTIME_FIXTURE_NAME"

  run_capture "$AGENTCTL" run --name "$RUNTIME_FIXTURE_NAME" --image agent-plain --workdir "$RUNTIME_FIXTURE_WORKDIR" --cmd true
  assert_status 0
}

ensure_runtime_fixture_running() {
  ensure_runtime_fixture

  if container_running "$RUNTIME_FIXTURE_NAME"; then
    return 0
  fi

  run_capture "$AGENTCTL" start --name "$RUNTIME_FIXTURE_NAME"
  assert_status 0
}

ensure_feature_fixture() {
  if [ -n "$FEATURE_FIXTURE_NAME" ] && container_exists "$FEATURE_FIXTURE_NAME"; then
    return 0
  fi

  FEATURE_FIXTURE_NAME="$(unique_name feature-fixture)"
  FEATURE_FIXTURE_WORKDIR="$(new_workdir)"
  register_container_cleanup "$FEATURE_FIXTURE_NAME"

  run_capture "$AGENTCTL" run --name "$FEATURE_FIXTURE_NAME" --image agent-python --workdir "$FEATURE_FIXTURE_WORKDIR" --cmd true
  assert_status 0
}

test_temp_run_removes_container() {
  begin_test "run --temp removes the named container"
  local name
  local workdir

  name="$(unique_name temp)"
  workdir="$(new_workdir)"

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --temp --workdir "$workdir" --cmd true
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

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd true
  assert_status 0

  if ! container_exists "$name"; then
    fail "Named container was not preserved: $name"
  fi

  run_capture "$AGENTCTL" rm --name "$name"
  assert_status 0

  if container_exists "$name"; then
    fail "Named container still exists after rm: $name"
  fi
}

test_build_rebuild_stops_buildkit() {
  begin_test "build --rebuild stops buildkit after a successful build"

  run_capture "$AGENTCTL" build --image agent-plain --rebuild
  assert_status 0
  assert_contains "Building image tags: agent-plain,"

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

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd bash -lc 'mkdir -p /home/coder/.codex && echo upgrade-ok >/home/coder/.codex/upgrade-smoke.txt'
  assert_status 0

  run_capture "$AGENTCTL" upgrade --name "$name" --no-backup
  assert_status 0
  assert_contains "Skipping backup image export for $name"
  assert_contains "Upgrade complete: $name (backup skipped)"

  if [ -n "$(list_backup_images "$backup_base")" ]; then
    printf '%s\n' "$(list_backup_images "$backup_base")" >&2
    fail "Backup images were created unexpectedly for $name"
  fi

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd bash -lc 'cat /home/coder/.codex/upgrade-smoke.txt'
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

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd bash -lc 'mkdir -p /home/coder/.codex && echo backup-ok >/home/coder/.codex/backup-smoke.txt'
  assert_status 0

  run_capture "$AGENTCTL" upgrade --name "$name"
  assert_status 0
  backup_image="$(extract_backup_image)"
  [ -n "$backup_image" ] || fail "Could not parse backup image name from upgrade output"
  register_backup_cleanup "$backup_image"

  if ! image_exists "$backup_image"; then
    printf '%s\n' "$RUN_OUTPUT" >&2
    fail "Expected backup image to exist: $backup_image"
  fi

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd bash -lc 'cat /home/coder/.codex/backup-smoke.txt'
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

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd bash -lc 'mkdir -p /home/coder/.codex && echo intact >/home/coder/.codex/preflight.txt'
  assert_status 0

  run_capture "$AGENTCTL" upgrade --name "$name" --image does-not-exist
  assert_status 1
  assert_contains "Error: Image not found: does-not-exist"

  if ! container_exists "$name"; then
    fail "Container was removed after failed upgrade: $name"
  fi

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd bash -lc 'cat /home/coder/.codex/preflight.txt'
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

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd bash -lc 'mkdir -p /home/coder/.codex && printf "# legacy-config\n" >/home/coder/.codex/config.toml && rm -f /home/coder/.codex/local_models.json && rm -f /home/coder/.codex/AGENTS.md && printf "legacy-agents\n" >/home/coder/.codex/AGENTS.md'
  assert_status 0

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --reset-config --cmd bash -lc 'if diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml && diff -q /etc/codexctl/local_models.json /home/coder/.codex/local_models.json && test -L /home/coder/.codex/AGENTS.md && [ "$(readlink /home/coder/.codex/AGENTS.md)" = "/etc/codexctl/image.md" ]; then echo reset-config-ok; else exit 1; fi'
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

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd bash -lc 'mkdir -p /home/coder/.codex && printf "# PRE-OVERWRITE\n[ollama]\nhost = \"http://127.0.0.1:11434\"\n" >/home/coder/.codex/config.toml && rm -f /home/coder/.codex/local_models.json && rm -f /home/coder/.codex/AGENTS.md && printf "legacy-agents\n" >/home/coder/.codex/AGENTS.md'
  assert_status 0

  run_capture "$AGENTCTL" upgrade --name "$name" --overwrite-config --no-backup
  assert_status 0
  assert_contains "Overwriting config.toml, local_models.json in ~/.codex/ and recreating ~/.codex/AGENTS.md in $name"
  assert_contains "Upgrade complete: $name (backup skipped)"

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd bash -lc 'if diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml && diff -q /etc/codexctl/local_models.json /home/coder/.codex/local_models.json && test -L /home/coder/.codex/AGENTS.md && [ "$(readlink /home/coder/.codex/AGENTS.md)" = "/etc/codexctl/image.md" ]; then echo overwrite-config-ok; else exit 1; fi'
  assert_status 0
  assert_contains "overwrite-config-ok"
}

test_runtime_management_commands_work_for_existing_container() {
  begin_test "runtime list, info, capabilities, and use work for an existing container"
  local name

  ensure_runtime_fixture_running
  name="$RUNTIME_FIXTURE_NAME"

  run_capture "$AGENTCTL" runtime --name "$name" list
  assert_status 0
  assert_contains "codex"
  assert_not_contains "claude"

  run_capture "$AGENTCTL" runtime --name "$name" info codex
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and .install_method == "npm-global" and .preferred_runtime == "codex"' >/dev/null || fail "Expected runtime info JSON for codex, got: $RUN_OUTPUT"

  run_capture "$AGENTCTL" runtime --name "$name" capabilities codex
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and (.commands | index("runtime capabilities codex") != null) and (.commands | index("runtime install codex") != null)' >/dev/null || fail "Expected runtime capabilities JSON for codex, got: $RUN_OUTPUT"

  run_capture "$AGENTCTL" use --name "$name" codex
  assert_status 0
  assert_contains "Preferred runtime set to codex in $name"

  run_capture "$CONTAINER_CMD" exec "$name" setpriv --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs -- cat /home/coder/.config/agentctl/preferred-runtime
  assert_status 0
  assert_contains "codex"
}

test_refresh_pushes_runtime_registry_into_existing_container() {
  begin_test "refresh updates the runtime registry in an existing container"
  local name
  local workdir
  local sentinel_file

  ensure_runtime_fixture_running
  name="$RUNTIME_FIXTURE_NAME"
  workdir="$RUNTIME_FIXTURE_WORKDIR"
  sentinel_file="$workdir/runtime-registry.ok"
  rm -f "$sentinel_file"

  run_capture "$AGENTCTL" refresh --name "$name"
  assert_status 0
  assert_contains "Refresh complete: $name"

  run_capture "$CONTAINER_CMD" exec "$name" setpriv --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs -- bash -lc '
    bash /usr/local/bin/agent.sh runtime info codex \
      | jq -e '"'"'.runtime == "codex" and .install_method == "npm-global"'"'"' >/dev/null
    bash /usr/local/bin/agent.sh runtime info claude \
      | jq -e '"'"'.runtime == "claude" and .installed == false and .install_method == "native-installer" and .capabilities.install == true and .capabilities.update == true'"'"' >/dev/null
    printf "%s\n" runtime-registry-ok > /workdir/runtime-registry.ok
  '
  assert_status 0

  if ! [ -f "$sentinel_file" ]; then
    fail "Expected runtime registry sentinel file after refreshed container validation"
  fi
  if ! grep -Fxq "runtime-registry-ok" "$sentinel_file"; then
    cat "$sentinel_file" >&2
    fail "Expected runtime registry sentinel to report success"
  fi
}

test_runtime_info_claude_works_after_refresh_on_stopped_container() {
  begin_test "runtime info claude works after refresh when the container is stopped"
  local name

  ensure_runtime_fixture_running
  name="$RUNTIME_FIXTURE_NAME"

  run_capture "$AGENTCTL" refresh --name "$name"
  assert_status 0
  assert_contains "Refresh complete: $name"

  run_capture "$AGENTCTL" stop --name "$name"
  assert_status 0

  run_capture "$AGENTCTL" runtime --name "$name" info claude
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "claude" and .installed == false and .install_method == "native-installer" and .capabilities.install == true and .capabilities.update == true' >/dev/null || fail "Expected runtime info JSON for claude on stopped container after refresh, got: $RUN_OUTPUT"
}

test_feature_office_install_works_on_agent_python() {
  begin_test "feature install office works on agent-python"
  local name

  ensure_feature_fixture
  name="$FEATURE_FIXTURE_NAME"

  run_capture "$AGENTCTL" refresh --name "$name"
  assert_status 0
  assert_contains "Refresh complete: $name"

  run_capture "$AGENTCTL" feature --name "$name" list
  assert_status 0
  assert_contains "office"

  run_capture "$AGENTCTL" feature --name "$name" info office
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.feature == "office" and .installed == false and .capabilities.install == true' >/dev/null || fail "Expected feature info JSON for office before install, got: $RUN_OUTPUT"

  run_capture "$AGENTCTL" feature --name "$name" install office
  assert_status 0

  run_capture "$AGENTCTL" feature --name "$name" info office
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.feature == "office" and .installed == true and .capabilities.install == true' >/dev/null || fail "Expected feature info JSON for office after install, got: $RUN_OUTPUT"

  run_capture "$AGENTCTL" start --name "$name"
  assert_status 0
  run_capture "$AGENTCTL" exec --name "$name" -- bash -lc 'test -f /var/lib/agentctl/features/office/install-complete && test -f /etc/profile.d/node_path.sh && command -v pandoc >/dev/null && command -v tesseract >/dev/null'
  assert_status 0
}

test_bootstrap_works_on_existing_alpine_container() {
  begin_test "bootstrap works on an existing Alpine container"
  local name

  name="$(unique_name bootstrap-alpine)"
  register_raw_container_cleanup "$name"

  run_capture "$CONTAINER_CMD" create --name "$name" docker.io/library/alpine:latest sleep infinity
  assert_status 0

  run_capture "$CONTAINER_CMD" start "$name"
  assert_status 0

  run_capture "$AGENTCTL" bootstrap --name "$name"
  assert_status 0
  assert_contains "Bootstrap complete: $name"

  run_capture "$AGENTCTL" runtime --name "$name" info codex
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and .install_method == "npm-global"' >/dev/null || fail "Expected runtime info JSON for codex after bootstrap, got: $RUN_OUTPUT"

  run_capture "$AGENTCTL" runtime --name "$name" install codex
  assert_status 0

  run_capture "$AGENTCTL" runtime --name "$name" list
  assert_status 0
  assert_contains "codex"

  run_capture "$AGENTCTL" feature --name "$name" info office
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.feature == "office" and .capabilities.install == true and .installed == false' >/dev/null || fail "Expected feature info JSON for office after bootstrap, got: $RUN_OUTPUT"

  run_capture "$AGENTCTL" refresh --name "$name"
  assert_status 0
  assert_contains "Refresh complete: $name"

  run_capture "$CONTAINER_CMD" exec "$name" sh -lc 'test -f /etc/agentctl/bootstrap.json && test -x /usr/local/bin/agent.sh && test -f /etc/agentctl/runtimes.d/codex.json && test -f /etc/agentctl/features.d/office.json'
  assert_status 0
}

test_bootstrap_can_create_and_bootstrap_new_alpine_container() {
  begin_test "bootstrap can create and bootstrap a new Alpine container"
  local name
  local workdir

  name="$(unique_name bootstrap-create)"
  workdir="$(new_workdir)"
  register_raw_container_cleanup "$name"

  run_capture "$AGENTCTL" bootstrap --name "$name" --image docker.io/library/alpine:latest --workdir "$workdir"
  assert_status 0
  assert_contains "Bootstrap container ready: $name"
  assert_contains "Bootstrap complete: $name"

  if ! container_exists "$name"; then
    fail "Expected bootstrap-created container to exist: $name"
  fi
  if container_running "$name"; then
    fail "Expected bootstrap-created container to be stopped after bootstrap: $name"
  fi

  run_capture "$AGENTCTL" runtime --name "$name" info codex
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and .install_method == "npm-global"' >/dev/null || fail "Expected runtime info JSON for codex after create+bootstrap, got: $RUN_OUTPUT"

  run_capture "$AGENTCTL" feature --name "$name" info office
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.feature == "office" and .capabilities.install == true' >/dev/null || fail "Expected feature info JSON for office after create+bootstrap, got: $RUN_OUTPUT"
}

main() {
  require_host_prereqs

  log "Using agentctl at $AGENTCTL"
  log "Using codexctl implementation at $CODEXCTL"
  log "Using container runtime command $CONTAINER_CMD"
  log "Running host test tier: $TEST_TIER"
  if [ -n "$TEST_FILTER" ]; then
    log "Filtering host tests by: $TEST_FILTER"
  fi
  if [ -n "$TEST_START_FROM" ]; then
    log "Running host tests from: $TEST_START_FROM"
  fi

  run_selected_test test_temp_run_removes_container "run --temp removes the named container" smoke
  run_selected_test test_named_run_persists_until_rm "named run persists until explicit removal" smoke
  run_selected_test test_build_rebuild_stops_buildkit "build --rebuild stops buildkit after a successful build" full
  run_selected_test test_upgrade_no_backup_preserves_state "upgrade --no-backup preserves state without creating backup images" full
  run_selected_test test_upgrade_with_backup_creates_recovery_image "upgrade creates a backup image by default" full
  run_selected_test test_upgrade_preflight_failure_keeps_container "upgrade preflight failure leaves the original container intact" full
  run_selected_test test_run_reset_config_restores_image_defaults "run --reset-config restores config, models, and AGENTS symlink" smoke
  run_selected_test test_upgrade_overwrite_config_restores_image_defaults "upgrade --overwrite-config restores config, models, and AGENTS symlink" full
  run_selected_test test_runtime_management_commands_work_for_existing_container "runtime list, info, capabilities, and use work for an existing container" smoke
  run_selected_test test_refresh_pushes_runtime_registry_into_existing_container "refresh updates the runtime registry in an existing container" smoke
  run_selected_test test_runtime_info_claude_works_after_refresh_on_stopped_container "runtime info claude works after refresh when the container is stopped" smoke
  run_selected_test test_feature_office_install_works_on_agent_python "feature install office works on agent-python" full
  run_selected_test test_bootstrap_works_on_existing_alpine_container "bootstrap works on an existing Alpine container" full
  run_selected_test test_bootstrap_can_create_and_bootstrap_new_alpine_container "bootstrap can create and bootstrap a new Alpine container" full
  assert_selected_tests_ran

  log "PASS: all host integration tests completed"
}

main "$@"
