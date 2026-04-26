#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=tests/testlib.sh
. "$SCRIPT_DIR/testlib.sh"

trap cleanup EXIT

load_codexctl_functions() {
  local harness

  harness="$(mktemp "${TMPDIR:-/tmp}/codexctl-unit.XXXXXX")"
  register_dir_cleanup "$harness"

  sed -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=\"$TEST_ROOT\"#" \
    -e '/^cmd="${1:-}"/,$d' \
    "$CODEXCTL" >"$harness"
  # shellcheck source=/dev/null
  . "$harness"
}

run_agent_sh_capture() {
  local temp_home="$1"
  shift

  run_agent_sh_capture_env "$temp_home" -- "$@"
}

run_agent_sh_capture_env() {
  local temp_home="$1"
  shift
  local env_args=()
  local run_cmd_args=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --)
        shift
        break
        ;;
      *=*)
        env_args+=("$1")
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  run_cmd_args=(
    env -i
    "HOME=$temp_home/home"
    "XDG_CONFIG_HOME=$temp_home/config"
    "PATH=/usr/bin:/bin"
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d"
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes"
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d"
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features"
  )
  if [ "${#env_args[@]}" -gt 0 ]; then
    run_cmd_args+=("${env_args[@]}")
  fi
  run_cmd_args+=(/bin/bash "$TEST_ROOT/agent.sh" "$@")

  run_capture "${run_cmd_args[@]}"
}

make_fake_runtime_bin() {
  local temp_home="$1"
  local runtime="$2"
  local fake_bin="$temp_home/bin"

  mkdir -p "$fake_bin"
  cat >"$fake_bin/$runtime" <<EOF
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/$runtime"
  printf '%s\n' "$fake_bin"
}

test_run_config_wires_runtime_config_json() {
  begin_test "run_cmd wires repeated --config values into the launched agent.sh command"

  load_codexctl_functions

  local captured_pre_exec=""
  local captured_cmd=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  run_container() {
    captured_pre_exec="$9"
    shift 11
    captured_cmd="$(printf '%s\n' "$*")"
  }

  run_cmd --name unit-test-container --workdir "$workdir" -c profile=gemma -c dangerously-skip-permissions=true

  [ -z "$captured_pre_exec" ] || fail "Did not expect host-side pre_exec for local runtime config wiring, got: $captured_pre_exec"
  printf '%s\n' "$captured_cmd" | grep -Fq 'AGENTCTL_RUN_MODE=' || fail "Expected agent.sh launch wrapper, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq 'AGENTCTL_RUNTIME_CONFIG_JSON=' || fail "Expected runtime config JSON to be passed to agent.sh, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq '"profile":"gemma"' || fail "Expected profile launch config in runtime config JSON, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq '"dangerously-skip-permissions":"true"' || fail "Expected repeated runtime config entries in runtime config JSON, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq 'AGENTCTL_MODEL_OVERRIDE=' || fail "Expected model override env slot to be present, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq '/usr/local/bin/agent.sh run' || fail "Expected agent.sh run launch path, got: $captured_cmd"
  if printf '%s\n' "$captured_cmd" | grep -Fq -- '--cd /workdir'; then
    fail "Did not expect codex-specific --cd flag in generic host launch path: $captured_cmd"
  fi
}

test_run_help_reports_runtime_options() {
  begin_test "run help reports runtime selection options"

  run_capture "$AGENTCTL" run --help
  assert_status 0
  assert_contains "--runtime NAME  Preferred runtime to launch"
  assert_contains "--install-runtime  Install the selected runtime before launch"
  assert_contains "--model NAME    Override the launch model for the selected runtime"
  assert_contains "--online        Use the runtime's online/provider-backed mode"
}

test_run_model_wires_selected_model() {
  begin_test "run_cmd wires --model into the launched agent.sh command"

  load_codexctl_functions

  local captured_cmd=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  run_container() {
    shift 11
    captured_cmd="$(printf '%s\n' "$*")"
  }

  run_cmd --name unit-test-container --workdir "$workdir" --model qwen3:14b

  printf '%s\n' "$captured_cmd" | grep -Fq 'AGENTCTL_MODEL_OVERRIDE=' || fail "Expected model override to be passed to agent.sh, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq 'qwen3:14b' || fail "Expected selected model in launch wrapper, got: $captured_cmd"
}

test_build_help_reports_primary_base_images() {
  begin_test "build help reports the primary base images"

  run_capture "$AGENTCTL" build --help
  assert_status 0
  assert_contains "--runtimes"
  assert_contains "--default-runtime"
  assert_contains "agent-plain"
  assert_contains "agent-python"
  assert_contains "agent-swift"
  assert_contains "agent-office remains available only as a legacy compatibility image"
}

test_build_cmd_passes_runtime_list_build_args() {
  begin_test "build_cmd passes the configured runtime list into container builds"

  load_codexctl_functions

  local build_call=""

  require_container() { return 0; }
  image_exists() { return 1; }
  stop_buildkit_container() { :; }
  mock_container() {
    if [ "$1" = "build" ]; then
      build_call="$(printf '%s\n' "$*")"
    fi
  }
  CONTAINER_CMD="mock_container"

  run_capture build_cmd --image agent-plain --runtimes codex,claude --default-runtime claude
  assert_status 0
  printf '%s\n' "$build_call" | grep -Fq -- '--build-arg AGENT_RUNTIMES=codex,claude' || fail "Expected build arg for runtime list, got: $build_call"
  printf '%s\n' "$build_call" | grep -Fq -- '--build-arg AGENT_DEFAULT_RUNTIME=claude' || fail "Expected build arg for default runtime, got: $build_call"
}

test_build_cmd_uses_first_runtime_as_default_when_unspecified() {
  begin_test "build_cmd uses the first runtime as default when unspecified"

  load_codexctl_functions

  local build_call=""

  require_container() { return 0; }
  image_exists() { return 1; }
  stop_buildkit_container() { :; }
  mock_container() {
    if [ "$1" = "build" ]; then
      build_call="$(printf '%s\n' "$*")"
    fi
  }
  CONTAINER_CMD="mock_container"

  run_capture build_cmd --image agent-plain --runtimes claude,codex
  assert_status 0
  printf '%s\n' "$build_call" | grep -Fq -- '--build-arg AGENT_RUNTIMES=claude,codex' || fail "Expected build arg for runtime list, got: $build_call"
  printf '%s\n' "$build_call" | grep -Fq -- '--build-arg AGENT_DEFAULT_RUNTIME=claude' || fail "Expected first runtime to become default, got: $build_call"
}

test_build_cmd_default_runtime_alone_installs_only_that_runtime() {
  begin_test "build_cmd preserves single-runtime default-runtime behavior"

  load_codexctl_functions

  local build_call=""

  require_container() { return 0; }
  image_exists() { return 1; }
  stop_buildkit_container() { :; }
  mock_container() {
    if [ "$1" = "build" ]; then
      build_call="$(printf '%s\n' "$*")"
    fi
  }
  CONTAINER_CMD="mock_container"

  run_capture build_cmd --image agent-plain --default-runtime claude
  assert_status 0
  printf '%s\n' "$build_call" | grep -Fq -- '--build-arg AGENT_RUNTIMES=claude' || fail "Expected single-runtime list to follow --default-runtime, got: $build_call"
  printf '%s\n' "$build_call" | grep -Fq -- '--build-arg AGENT_DEFAULT_RUNTIME=claude' || fail "Expected default runtime build arg, got: $build_call"
}

test_build_cmd_rebuilds_existing_image_when_runtime_selection_is_overridden() {
  begin_test "build_cmd rebuilds when runtime selection is overridden"

  load_codexctl_functions

  local build_calls=0

  require_container() { return 0; }
  image_exists() { return 0; }
  stop_buildkit_container() { :; }
  mock_container() {
    if [ "$1" = "build" ]; then
      build_calls=$((build_calls + 1))
    fi
  }
  CONTAINER_CMD="mock_container"

  run_capture build_cmd --image agent-plain --runtimes codex,claude --default-runtime claude
  assert_status 0
  [ "$build_calls" -eq 1 ] || fail "Expected one build call when overriding the runtime selection, got: $build_calls"
}

test_run_cmd_runtime_selection_auto_installs_for_new_container() {
  begin_test "run_cmd auto-installs a selected runtime for a new container"

  load_codexctl_functions

  local captured_pre_exec=""
  local captured_mem=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  run_container() {
    captured_pre_exec="$9"
    captured_mem="$6"
  }

  container_exists() { return 1; }

  run_cmd --name unit-test-container --workdir "$workdir" --runtime claude --shell

  [ "$captured_pre_exec" = "run_pre_exec" ] || fail "Expected run_pre_exec, got: $captured_pre_exec"
  [ "$RUN_SELECTED_RUNTIME" = "claude" ] || fail "Expected runtime claude, got: $RUN_SELECTED_RUNTIME"
  [ "$RUN_INSTALL_RUNTIME" -eq 1 ] || fail "Expected runtime auto-install to be enabled"
  [ "$RUN_SYNC_RUNTIME_AUTH" -eq 0 ] || fail "Did not expect online auth sync for local Claude shell launch"
  [ "$RUN_LOCAL_MODEL_PREFLIGHT" -eq 0 ] || fail "Did not expect local-model preflight for Claude shell launch"
  [ "$captured_mem" = "4G" ] || fail "Expected Claude bootstrap run to request 4G, got: $captured_mem"
}

test_run_cmd_runtime_selection_does_not_auto_install_for_existing_container() {
  begin_test "run_cmd does not auto-install a selected runtime for an existing container"

  load_codexctl_functions

  local captured_pre_exec=""
  local captured_mem=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  run_container() {
    captured_pre_exec="$9"
    captured_mem="$6"
  }

  run_cmd --name unit-test-container --workdir "$workdir" --runtime claude --shell

  [ "$captured_pre_exec" = "run_pre_exec" ] || fail "Expected run_pre_exec, got: $captured_pre_exec"
  [ "$RUN_SELECTED_RUNTIME" = "claude" ] || fail "Expected runtime claude, got: $RUN_SELECTED_RUNTIME"
  [ "$RUN_INSTALL_RUNTIME" -eq 0 ] || fail "Did not expect runtime auto-install for an existing container"
  [ -z "$captured_mem" ] || fail "Did not expect Claude auto-install memory override for an existing container, got: $captured_mem"
}

test_run_cmd_warns_for_legacy_office_image() {
  begin_test "run_cmd warns when using the legacy office image"

  load_codexctl_functions

  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  run_container() { :; }

  run_capture run_cmd --name unit-test-container --workdir "$workdir" --image agent-office --shell
  assert_status 0
  assert_contains "legacy compatibility image"
  assert_contains "agent-python"
}

test_build_cmd_warns_for_legacy_office_image() {
  begin_test "build_cmd warns when building the legacy office image explicitly"

  load_codexctl_functions

  require_container() { return 0; }
  image_exists() { return 0; }
  stop_buildkit_container() { :; }
  mock_container() { :; }
  CONTAINER_CMD="mock_container"

  run_capture build_cmd --image agent-office --snapshot
  assert_status 0
  assert_contains "legacy compatibility image"
}

test_build_cmd_rejects_runtime_override_snapshot_combo() {
  begin_test "build_cmd rejects combining runtime overrides with snapshot"

  local temp_dir
  local unit_script

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-build-invalid.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$CODEXCTL"
require_container() { return 0; }
build_cmd --image agent-plain --runtimes codex,claude --default-runtime claude --snapshot
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "--runtimes and --default-runtime cannot be combined with --snapshot"
}

test_build_cmd_rejects_default_runtime_outside_runtime_list() {
  begin_test "build_cmd rejects a default runtime outside the runtime list"

  local temp_dir
  local unit_script

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-build-invalid.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$CODEXCTL"
require_container() { return 0; }
build_cmd --image agent-plain --runtimes codex --default-runtime claude
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "--default-runtime must be included in --runtimes"
}

test_run_cmd_rejects_invalid_runtime_config() {
  begin_test "run_cmd rejects malformed runtime config entries"

  local temp_dir
  local unit_script

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-run-invalid.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$CODEXCTL"
require_container() { return 0; }
run_cmd --runtime claude --config profile
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "Invalid runtime config: profile (expected key=value)"
}

test_run_cmd_rejects_install_runtime_without_runtime() {
  begin_test "run_cmd rejects --install-runtime without --runtime"

  local temp_dir
  local unit_script

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-run-invalid.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$CODEXCTL"
require_container() { return 0; }
run_cmd --install-runtime
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "--install-runtime requires --runtime"
}

test_run_cmd_rejects_auth_without_online() {
  begin_test "run_cmd rejects --auth without --online"

  local temp_dir
  local unit_script

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-run-invalid.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$CODEXCTL"
require_container() { return 0; }
run_cmd --runtime claude --auth
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "--auth requires --online"
}

test_run_pre_exec_syncs_selected_runtime_auth_when_available() {
  begin_test "run_pre_exec syncs selected runtime auth when online mode is enabled"

  load_codexctl_functions

  local call_log=""
  RUN_SELECTED_RUNTIME="claude"
  RUN_INSTALL_RUNTIME=1
  RUN_SYNC_RUNTIME_AUTH=1
  RUN_SYNC_POST_RUNTIME_AUTH=0
  RUN_FORCE_RUNTIME_AUTH=0
  RUN_LOCAL_MODEL_PREFLIGHT=0
  RUN_UPDATE_CODEX=0
  RUN_REQUESTED_IMAGE="agent-plain"

  run_agent_sh_in_container() {
    call_log="${call_log}$1:$2:$3"$'\n'
  }
  run_agent_sh_in_container_root() {
    call_log="${call_log}root:$1:$2:$3:$4"$'\n'
  }
  runtime_info_in_container() {
    printf '{"runtime":"claude","installed":true,"auth_formats":["claude_ai_oauth_json"],"capabilities":{"auth_login":true,"auth_read":true,"auth_write":true}}'
  }
  keychain_auth_info() { printf 'refresh-token\t1776462236852\n'; }
  sync_runtime_auth_to_container() { call_log="${call_log}sync:$1:$2:$3"$'\n'; }

  run_capture run_pre_exec unit-test-container
  assert_status 0
  printf '%s' "$call_log" | grep -Fq $'root:unit-test-container:runtime:install:claude' || fail "Expected root runtime install call, got: $call_log"
  printf '%s' "$call_log" | grep -Fq $'unit-test-container:preferred:set' || fail "Expected preferred set call, got: $call_log"
  printf '%s' "$call_log" | grep -Fq $'sync:unit-test-container:claude:claude_ai_oauth_json' || fail "Expected runtime auth sync call, got: $call_log"
}

test_run_pre_exec_updates_codex_via_runtime_helper() {
  begin_test "run_pre_exec updates codex via the runtime root helper"

  load_codexctl_functions

  local helper_log=""
  RUN_SELECTED_RUNTIME=""
  RUN_INSTALL_RUNTIME=0
  RUN_SYNC_RUNTIME_AUTH=0
  RUN_SYNC_POST_RUNTIME_AUTH=0
  RUN_FORCE_RUNTIME_AUTH=0
  RUN_LOCAL_MODEL_PREFLIGHT=0
  RUN_UPDATE_CODEX=1
  RUN_REQUESTED_IMAGE="agent-plain"

  run_agent_sh_in_container_root() {
    helper_log="${helper_log}root:$1:$2:$3:$4"$'\n'
  }

  run_capture run_pre_exec unit-test-container
  assert_status 0
  printf '%s' "$helper_log" | grep -Fq $'root:unit-test-container:runtime:update:codex' || fail "Expected runtime update root helper call, got: $helper_log"
}

test_run_container_reset_config_uses_runtime_helper() {
  begin_test "run_container reset-config uses the runtime reset helper"

  load_codexctl_functions

  local helper_log=""

  require_container() { return 0; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 0; }
  validate_mount_mode() { :; }
  local CONTAINER_CMD=mock_reset_config_container
  mock_reset_config_container() {
    case "$1" in
      start) : ;;
      stop) : ;;
      exec) : ;;
      *) fail "Unexpected container invocation: $*" ;;
    esac
  }
  reset_runtime_config_in_container() {
    helper_log="${helper_log}$1:$2"$'\n'
  }

  run_capture run_container unit-test-container agent-plain 0 0 "" "" 0 "$TEST_ROOT" "" "" 1 true
  assert_status 0
  printf '%s' "$helper_log" | grep -Fq $'unit-test-container:codex' || fail "Expected runtime reset-config helper call, got: $helper_log"
}

test_run_pre_exec_syncs_auth_for_preferred_runtime_when_unspecified() {
  begin_test "run_pre_exec syncs auth for the preferred runtime when online mode is enabled"

  load_codexctl_functions

  local call_log=""

  RUN_SELECTED_RUNTIME=""
  RUN_INSTALL_RUNTIME=0
  RUN_SYNC_RUNTIME_AUTH=1
  RUN_SYNC_POST_RUNTIME_AUTH=0
  RUN_FORCE_RUNTIME_AUTH=0
  RUN_LOCAL_MODEL_PREFLIGHT=0
  RUN_UPDATE_CODEX=0
  RUN_REQUESTED_IMAGE="agent-plain"

  run_agent_sh_in_container() {
    if [ "$2" = "preferred" ] && [ "$3" = "get" ]; then
      printf 'claude\n'
      return 0
    fi
    call_log="${call_log}$1:$2:$3"$'\n'
  }
  runtime_info_in_container() {
    printf '{"runtime":"claude","installed":true,"auth_formats":["claude_ai_oauth_json"],"capabilities":{"auth_login":true,"auth_read":true,"auth_write":true}}'
  }
  keychain_auth_info() { printf 'refresh-token\t1776462236852\n'; }
  sync_runtime_auth_to_container() { call_log="${call_log}sync:$1:$2:$3"$'\n'; }

  run_capture run_pre_exec unit-test-container
  assert_status 0
  printf '%s' "$call_log" | grep -Fq $'sync:unit-test-container:claude:claude_ai_oauth_json' || fail "Expected runtime auth sync for preferred claude, got: $call_log"
}

test_run_pre_exec_runs_local_model_preflight_for_preferred_claude() {
  begin_test "run_pre_exec leaves local-mode preflight to agent.sh for claude"

  load_codexctl_functions

  local preflight_called=0

  RUN_SELECTED_RUNTIME=""
  RUN_INSTALL_RUNTIME=0
  RUN_SYNC_RUNTIME_AUTH=0
  RUN_SYNC_POST_RUNTIME_AUTH=0
  RUN_FORCE_RUNTIME_AUTH=0
  RUN_LOCAL_MODEL_PREFLIGHT=1
  RUN_UPDATE_CODEX=0

  run_agent_sh_in_container() {
    if [ "$2" = "preferred" ] && [ "$3" = "get" ]; then
      printf 'claude\n'
      return 0
    fi
    return 0
  }
  local_runtime_preflight() {
    preflight_called=1
  }

  run_capture run_pre_exec unit-test-container
  assert_status 0
  [ "$preflight_called" -eq 0 ] || fail "Expected agent.sh to own local-mode preflight for claude"
}

test_run_pre_exec_runs_local_model_preflight_for_preferred_codex() {
  begin_test "run_pre_exec leaves local-mode preflight to agent.sh for codex"

  load_codexctl_functions

  local preflight_called=0

  RUN_SELECTED_RUNTIME=""
  RUN_INSTALL_RUNTIME=0
  RUN_SYNC_RUNTIME_AUTH=0
  RUN_SYNC_POST_RUNTIME_AUTH=0
  RUN_FORCE_RUNTIME_AUTH=0
  RUN_LOCAL_MODEL_PREFLIGHT=1
  RUN_UPDATE_CODEX=0

  run_agent_sh_in_container() {
    if [ "$2" = "preferred" ] && [ "$3" = "get" ]; then
      printf 'codex\n'
      return 0
    fi
    return 0
  }
  local_runtime_preflight() {
    preflight_called=1
  }

  run_capture run_pre_exec unit-test-container
  assert_status 0
  [ "$preflight_called" -eq 0 ] || fail "Expected agent.sh to own local-mode preflight for codex"
}

test_run_cmd_default_entrypoint_enables_local_runtime_preflight() {
  begin_test "run_cmd lets agent.sh handle local runtime preflight"

  load_codexctl_functions

  local captured_pre_exec=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  run_container() {
    captured_pre_exec="$9"
  }

  run_cmd --name unit-test-container --workdir "$workdir"

  [ -z "$captured_pre_exec" ] || fail "Did not expect host-side run_pre_exec for local preflight, got: $captured_pre_exec"
  [ "$RUN_SYNC_RUNTIME_AUTH" -eq 0 ] || fail "Did not expect online auth sync for local default run"
  [ "$RUN_LOCAL_MODEL_PREFLIGHT" -eq 0 ] || fail "Expected local-model preflight to be handled by agent.sh"
}

test_sync_runtime_auth_to_container_if_available_skips_missing_keychain() {
  begin_test "sync_runtime_auth_to_container_if_available skips runtimes without keychain auth"

  load_codexctl_functions

  local sync_called=0
  runtime_info_in_container() {
    printf '{"runtime":"claude","installed":true,"auth_formats":["claude_ai_oauth_json"],"capabilities":{"auth_read":true,"auth_write":true}}'
  }
  ensure_keychain() { return 1; }
  sync_runtime_auth_to_container() { sync_called=1; }

  run_capture sync_runtime_auth_to_container_if_available unit-test-container claude
  assert_status 0
  [ "$sync_called" -eq 0 ] || fail "Did not expect runtime auth sync without keychain auth"
}

test_auth_cmd_warns_for_legacy_office_image() {
  begin_test "auth_cmd warns when using the legacy office image"

  load_codexctl_functions

  require_container() { return 0; }
  default_name() { printf 'unit-auth-container\n'; }
  run_auth_flow() { :; }

  run_capture auth_cmd --image agent-office
  assert_status 0
  assert_contains "legacy compatibility image"
  assert_contains "agent-python"
}

test_feature_cmd_installs_via_root_helper() {
  begin_test "feature_cmd install uses the root helper path"

  load_codexctl_functions

  local helper_log=""

  require_container() { return 0; }
  default_name() { printf 'unit-feature-container\n'; }
  run_agent_sh_in_container() {
    helper_log="${helper_log}user:$1:$2:$3"$'\n'
  }
  run_agent_sh_in_container_root() {
    helper_log="${helper_log}root:$1:$2:$3"$'\n'
  }

  run_capture feature_cmd --name unit-feature-container install office
  assert_status 0
  printf '%s' "$helper_log" | grep -Fq $'root:unit-feature-container:feature:install' || fail "Expected root feature helper call, got: $helper_log"
}

test_runtime_cmd_install_uses_root_helper() {
  begin_test "runtime_cmd install uses the root helper path"

  load_codexctl_functions

  local helper_log=""

  require_container() { return 0; }
  default_name() { printf 'unit-runtime-container\n'; }
  run_agent_sh_in_container() {
    helper_log="${helper_log}user:$1:$2:$3:$4"$'\n'
  }
  run_agent_sh_in_container_root() {
    helper_log="${helper_log}root:$1:$2:$3:$4"$'\n'
  }

  run_capture runtime_cmd --name unit-runtime-container install codex
  assert_status 0
  printf '%s' "$helper_log" | grep -Fq $'root:unit-runtime-container:runtime:install:codex' || fail "Expected root runtime helper call, got: $helper_log"
}

test_runtime_cmd_install_claude_warns_on_undersized_container() {
  begin_test "runtime_cmd install claude warns on an undersized existing container"

  load_codexctl_functions

  local helper_log=""

  require_container() { return 0; }
  default_name() { printf 'unit-runtime-container\n'; }
  mock_container() {
    case "$1" in
      inspect)
        cat <<'JSON'
[{"configuration":{"resources":{"memoryInBytes":1073741824}}}]
JSON
        ;;
      *)
        echo "Unexpected container invocation: $*" >&2
        return 1
        ;;
    esac
  }
  CONTAINER_CMD="mock_container"
  run_agent_sh_in_container_root() {
    helper_log="${helper_log}root:$1:$2:$3:$4"$'\n'
  }

  run_capture runtime_cmd --name unit-runtime-container install claude
  assert_status 0
  assert_contains "Container unit-runtime-container is limited to 1G."
  assert_contains "Claude install may be killed by memory pressure"
  assert_contains "upgrade --name unit-runtime-container --mem 4G"
  printf '%s' "$helper_log" | grep -Fq $'root:unit-runtime-container:runtime:install:claude' || fail "Expected root runtime helper call, got: $helper_log"
}

test_runtime_cmd_install_claude_reports_memory_guidance_on_failure() {
  begin_test "runtime_cmd install claude reports memory guidance after an undersized failure"

  local harness
  local script

  harness="$(mktemp "${TMPDIR:-/tmp}/codexctl-unit.XXXXXX")"
  register_dir_cleanup "$harness"
  sed -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=\"$TEST_ROOT\"#" \
    -e '/^cmd="${1:-}"/,$d' \
    "$CODEXCTL" >"$harness"

  script="$(mktemp "${TMPDIR:-/tmp}/codexctl-unit-script.XXXXXX")"
  register_dir_cleanup "$script"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$harness"
require_container() { return 0; }
default_name() { printf 'unit-runtime-container\n'; }
mock_container() {
  case "\$1" in
    inspect)
      cat <<'JSON'
[{"configuration":{"resources":{"memoryInBytes":1073741824}}}]
JSON
      ;;
    *)
      echo "Unexpected container invocation: \$*" >&2
      return 1
      ;;
  esac
}
CONTAINER_CMD="mock_container"
run_agent_sh_in_container_root() {
  return 137
}
runtime_cmd --name unit-runtime-container install claude
EOF
  chmod +x "$script"

  run_capture bash "$script"
  assert_status 1
  assert_contains "Container unit-runtime-container is limited to 1G."
  assert_contains "Claude runtime install failed in unit-runtime-container."
  assert_contains "installer can be killed by memory pressure"
  assert_contains "upgrade --name unit-runtime-container --mem 4G"
}

test_runtime_cmd_update_uses_root_helper() {
  begin_test "runtime_cmd update uses the root helper path"

  load_codexctl_functions

  local helper_log=""

  require_container() { return 0; }
  default_name() { printf 'unit-runtime-container\n'; }
  run_agent_sh_in_container() {
    helper_log="${helper_log}user:$1:$2:$3:$4"$'\n'
  }
  run_agent_sh_in_container_root() {
    helper_log="${helper_log}root:$1:$2:$3:$4"$'\n'
  }

  run_capture runtime_cmd --name unit-runtime-container update codex
  assert_status 0
  printf '%s' "$helper_log" | grep -Fq $'root:unit-runtime-container:runtime:update:codex' || fail "Expected root runtime helper call, got: $helper_log"
}

test_bootstrap_cmd_bootstraps_alpine_container_and_restores_stopped_state() {
  begin_test "bootstrap_cmd bootstraps an Alpine container and restores stopped state"

  load_codexctl_functions

  local start_calls=0
  local stop_calls=0
  local exec_log=""

  require_container() { return 0; }
  default_name() { printf 'unit-bootstrap-container\n'; }
  container_exists() { [ "$1" = "unit-bootstrap-container" ]; }
  container_running() { return 1; }
  persist_container_system_manifest_baseline_from_live_state() { :; }
  refresh_container_file() { exec_log="${exec_log}file:$3"$'\n'; }
  refresh_container_tree() { exec_log="${exec_log}tree:$3"$'\n'; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      exec)
        shift
        if [ "${1:-}" = "-u" ]; then
          shift 2
        fi
        if [ "${1:-}" = "unit-bootstrap-container" ]; then
          shift
        fi
        exec_log="${exec_log}exec:$(printf '%s ' "$@")"$'\n'
        if [ "$*" = "sh -lc if command -v apk >/dev/null 2>&1; then echo apk; elif command -v apt-get >/dev/null 2>&1; then echo apt-get; else echo unsupported; fi" ]; then
          printf 'apk\n'
        fi
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture bootstrap_cmd --name unit-bootstrap-container
  assert_status 0
  assert_contains "Bootstrap complete: unit-bootstrap-container"
  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
  printf '%s\n' "$exec_log" | grep -Fq "apk add --no-cache bash zsh npm file curl git ripgrep jq util-linux bubblewrap" || fail "Expected root bootstrap install commands"
  printf '%s\n' "$exec_log" | grep -Fq "file:/usr/local/bin/agent.sh" || fail "Expected bootstrap to install agent.sh"
  printf '%s\n' "$exec_log" | grep -Fq "tree:/etc/agentctl/runtimes.d" || fail "Expected bootstrap to install runtime manifests"
  printf '%s\n' "$exec_log" | grep -Fq "tree:/etc/agentctl/features.d" || fail "Expected bootstrap to install feature manifests"
  printf '%s\n' "$exec_log" | grep -Fq "file:/etc/agentctl/image.md" || fail "Expected bootstrap to install image metadata"
}

test_bootstrap_cmd_creates_and_bootstraps_new_alpine_container() {
  begin_test "bootstrap_cmd can create and bootstrap a new Alpine container"

  load_codexctl_functions

  local start_calls=0
  local stop_calls=0
  local create_log=""
  local exec_log=""
  local workdir
  local expected_workdir

  workdir="$(new_workdir)"
  expected_workdir="$(CDPATH= cd -- "$workdir" && pwd)"

  require_container() { return 0; }
  container_exists() { return 1; }
  container_running() { return 1; }
  persist_container_system_manifest_baseline_from_live_state() { :; }
  refresh_container_file() { exec_log="${exec_log}file:$3"$'\n'; }
  refresh_container_tree() { exec_log="${exec_log}tree:$3"$'\n'; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      create)
        shift
        create_log="$(printf '%s ' "$@")"
        ;;
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      exec)
        shift
        if [ "${1:-}" = "-u" ]; then
          shift 2
        fi
        if [ "${1:-}" = "unit-bootstrap-container" ]; then
          shift
        fi
        exec_log="${exec_log}exec:$(printf '%s ' "$@")"$'\n'
        if [ "$*" = "sh -lc if command -v apk >/dev/null 2>&1; then echo apk; elif command -v apt-get >/dev/null 2>&1; then echo apt-get; else echo unsupported; fi" ]; then
          printf 'apk\n'
        fi
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture bootstrap_cmd --name unit-bootstrap-container --image docker.io/library/alpine:latest --workdir "$workdir" --cpu 2 --mem 3G
  assert_status 0
  assert_contains "Bootstrap container ready: unit-bootstrap-container"
  assert_contains "Bootstrap complete: unit-bootstrap-container"
  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
  printf '%s\n' "$create_log" | grep -Fq -- "--name unit-bootstrap-container" || fail "Expected create to include container name"
  printf '%s\n' "$create_log" | grep -Fq -- "--mount" || fail "Expected create to include a workdir mount"
  printf '%s\n' "$create_log" | grep -Fq -- "src=$expected_workdir" || fail "Expected create mount to include source workdir"
  printf '%s\n' "$create_log" | grep -Fq -- "dst=/workdir" || fail "Expected create mount to target /workdir"
  printf '%s\n' "$create_log" | grep -Fq -- "-c 2 -m 3G" || fail "Expected create to include cpu/mem settings"
  printf '%s\n' "$create_log" | grep -Fq -- "docker.io/library/alpine:latest sh -c sleep infinity" || fail "Expected create to use requested image"
  printf '%s\n' "$exec_log" | grep -Fq "file:/usr/local/bin/agent.sh" || fail "Expected bootstrap to install agent.sh"
}

test_bootstrap_cmd_bootstraps_apt_container() {
  begin_test "bootstrap_cmd bootstraps a Debian/Ubuntu container"

  load_codexctl_functions

  local start_calls=0
  local stop_calls=0
  local exec_log=""

  require_container() { return 0; }
  default_name() { printf 'unit-bootstrap-container\n'; }
  container_exists() { [ "$1" = "unit-bootstrap-container" ]; }
  container_running() { return 1; }
  persist_container_system_manifest_baseline_from_live_state() { :; }
  refresh_container_file() { exec_log="${exec_log}file:$3"$'\n'; }
  refresh_container_tree() { exec_log="${exec_log}tree:$3"$'\n'; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      exec)
        shift
        if [ "${1:-}" = "-u" ]; then
          shift 2
        fi
        if [ "${1:-}" = "unit-bootstrap-container" ]; then
          shift
        fi
        exec_log="${exec_log}exec:$(printf '%s ' "$@")"$'\n'
        if [ "$*" = "sh -lc if command -v apk >/dev/null 2>&1; then echo apk; elif command -v apt-get >/dev/null 2>&1; then echo apt-get; else echo unsupported; fi" ]; then
          printf 'apt-get\n'
        fi
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture bootstrap_cmd --name unit-bootstrap-container
  assert_status 0
  assert_contains "Bootstrap complete: unit-bootstrap-container"
  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
  printf '%s\n' "$exec_log" | grep -Fq "apt-get install -y --no-install-recommends bash zsh npm file curl git ripgrep jq util-linux bubblewrap ca-certificates" || fail "Expected apt bootstrap install commands"
  printf '%s\n' "$exec_log" | grep -Fq "file:/usr/local/bin/agent.sh" || fail "Expected bootstrap to install agent.sh"
  printf '%s\n' "$exec_log" | grep -Fq "tree:/etc/agentctl/runtimes.d" || fail "Expected bootstrap to install runtime manifests"
  printf '%s\n' "$exec_log" | grep -Fq "tree:/etc/agentctl/features.d" || fail "Expected bootstrap to install feature manifests"
}

test_bootstrap_cmd_rejects_unsupported_base() {
  begin_test "bootstrap_cmd rejects unsupported container bases"

  load_codexctl_functions

  require_container() { return 0; }
  default_name() { printf 'unit-bootstrap-container\n'; }
  container_exists() { [ "$1" = "unit-bootstrap-container" ]; }
  container_running() { return 0; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      start|stop)
        return 0
        ;;
      exec)
        shift
        if [ "${1:-}" = "-u" ]; then
          shift 2
        fi
        if [ "${1:-}" = "unit-bootstrap-container" ]; then
          shift
        fi
        if [ "$*" = "sh -lc if command -v apk >/dev/null 2>&1; then echo apk; elif command -v apt-get >/dev/null 2>&1; then echo apt-get; else echo unsupported; fi" ]; then
          printf 'unsupported\n'
          return 0
        fi
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  capture_bootstrap_unsupported() {
    ( bootstrap_cmd --name unit-bootstrap-container )
  }

  run_capture capture_bootstrap_unsupported
  assert_status 1
  assert_contains "Unsupported bootstrap container base for current bootstrap slice"
}

test_run_help_reports_generic_runtime_config() {
  begin_test "run help reports the generic runtime config flag"

  run_capture "$AGENTCTL" run --help
  assert_status 0
  assert_contains "-c, --config KEY=VALUE  Pass runtime-specific launch config (repeatable)"
}

test_agentctl_wrapper_usage_banner() {
  begin_test "agentctl wrapper prints its command name"

  run_capture "$AGENTCTL" --help
  assert_status 0
  assert_contains "Usage: agentctl <command> [options]"
}

test_refresh_help_reports_new_command() {
  begin_test "refresh help is available via the public CLI"

  run_capture "$AGENTCTL" refresh --help
  assert_status 0
  assert_contains "Usage: agentctl refresh [options]"
}

test_bootstrap_help_reports_new_command() {
  begin_test "bootstrap help is available via the public CLI"

  run_capture "$AGENTCTL" bootstrap --help
  assert_status 0
  assert_contains "Usage: agentctl bootstrap [options]"
  assert_contains "--image IMAGE   Create the container from IMAGE first if it does not exist"
  assert_contains "supports Alpine and Debian/Ubuntu-based containers"
}

test_system_manifest_help_reports_new_command() {
  begin_test "system-manifest help is available via the public CLI"

  run_capture "$AGENTCTL" system-manifest --help
  assert_status 0
  assert_contains "Usage: agentctl system-manifest [options]"
}

test_runtime_help_reports_new_command() {
  begin_test "runtime help is available via the public CLI"

  run_capture "$AGENTCTL" runtime --help
  assert_status 0
  assert_contains "Usage: agentctl runtime <list|info|capabilities|install|update|reset-config|use> [options] [runtime]"
  assert_contains "runtime use codex"
}

test_feature_help_reports_new_command() {
  begin_test "feature help is available via the public CLI"

  run_capture "$AGENTCTL" feature --help
  assert_status 0
  assert_contains "Usage: agentctl feature <list|info|install|remove|update> [options] [feature]"
}

test_use_help_reports_new_command() {
  begin_test "use help is available via the public CLI"

  run_capture "$AGENTCTL" use --help
  assert_status 0
  assert_contains "Usage: agentctl use <runtime> [options]"
}

test_rm_help_reports_force_option() {
  begin_test "rm help reports the force option"

  run_capture "$AGENTCTL" rm --help
  assert_status 0
  assert_contains '--force      For `rm`, stop the container first if it is running'
}

test_agent_sh_runtime_info_reports_registry_metadata() {
  begin_test "agent.sh runtime info reports registry metadata"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" runtime info codex
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and .install_method == "npm-global" and .default_config_dir == "/etc/codexctl" and (.auth_formats | index("json_refresh_token") != null) and .launch_configs.profile.type == "string" and .launch_configs.profile.default == "gpt-oss"' >/dev/null || fail "Expected runtime info JSON for codex, got: $RUN_OUTPUT"
}

test_agent_sh_feature_list_reports_declared_features() {
  begin_test "agent.sh feature list reports declared features"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" feature list
  assert_status 0
  assert_contains "office"
}

test_agent_sh_feature_info_reports_manifest_metadata() {
  begin_test "agent.sh feature info reports manifest metadata"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" feature info office
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.feature == "office" and .display_name == "Office Compatibility Tooling" and .installed == false and .capabilities.install == true and .install_method == "apk+npm+pip"' >/dev/null || fail "Expected feature info JSON for office, got: $RUN_OUTPUT"
}

test_agent_sh_feature_install_office_creates_feature_state() {
  begin_test "agent.sh feature install office creates feature state"

  local temp_home
  local fake_bin
  local venv_dir
  local profile_dir
  local state_dir
  local install_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  venv_dir="$temp_home/venv"
  profile_dir="$temp_home/profile.d"
  state_dir="$temp_home/state"
  install_log="$temp_home/install.log"
  mkdir -p "$fake_bin" "$venv_dir/bin" "$profile_dir" "$state_dir"

  cat >"$fake_bin/apk" <<EOF
#!/bin/sh
printf 'apk %s\n' "\$*" >>"$install_log"
exit 0
EOF
  cat >"$fake_bin/npm" <<EOF
#!/bin/sh
printf 'npm %s\n' "\$*" >>"$install_log"
exit 0
EOF
  cat >"$fake_bin/chown" <<EOF
#!/bin/sh
printf 'chown %s\n' "\$*" >>"$install_log"
exit 0
EOF
  cat >"$venv_dir/bin/pip" <<EOF
#!/bin/sh
printf 'pip %s\n' "\$*" >>"$install_log"
exit 0
EOF
  chmod +x "$fake_bin/apk" "$fake_bin/npm" "$fake_bin/chown" "$venv_dir/bin/pip"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_FEATURE_OFFICE_SKIP_ROOT_CHECK=1 \
    AGENTCTL_FEATURE_OFFICE_VENV_DIR="$venv_dir" \
    AGENTCTL_FEATURE_OFFICE_PROFILE_DIR="$profile_dir" \
    AGENTCTL_FEATURE_STATE_DIR="$state_dir" \
    -- feature install office
  assert_status 0
  [ -f "$state_dir/office/install-complete" ] || fail "Expected office feature marker file"
  [ -f "$profile_dir/node_path.sh" ] || fail "Expected office feature to write node_path profile"
  grep -Fq "apk add --no-cache" "$install_log" || fail "Expected office feature to install apk packages"
  grep -Fq "npm install -g pptxgenjs" "$install_log" || fail "Expected office feature to install pptxgenjs"
  grep -Fq "pip install --no-cache-dir python-docx python-pptx xlrd pdfplumber" "$install_log" || fail "Expected office feature to install pip packages"
}

test_agent_sh_feature_info_reports_installed_after_office_install() {
  begin_test "agent.sh feature info reports installed after office install"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  mkdir -p "$temp_home/state/office"
  printf '%s\n' installed >"$temp_home/state/office/install-complete"

  run_agent_sh_capture_env "$temp_home" \
    PATH="/usr/bin:/bin" \
    AGENTCTL_FEATURE_STATE_DIR="$temp_home/state" \
    -- feature info office
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.feature == "office" and .installed == true and .capabilities.install == true and .install_method == "apk+npm+pip"' >/dev/null || fail "Expected installed feature info JSON for office, got: $RUN_OUTPUT"
}

test_agent_sh_runtime_list_reports_installed_runtimes_only() {
  begin_test "agent.sh runtime list reports installed runtimes only"

  local temp_home
  local fake_bin
  local config_mtime_before
  local catalog_mtime_before
  local config_mtime_after
  local catalog_mtime_after
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$(make_fake_runtime_bin "$temp_home" codex)"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    -- runtime list
  assert_status 0
  assert_contains "codex"
  assert_not_contains "claude"
}

test_agent_sh_runtime_capabilities_reports_manifest_commands() {
  begin_test "agent.sh runtime capabilities reports manifest-backed commands"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" runtime capabilities codex
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and (.commands | index("runtime install codex") != null) and (.commands | index("runtime capabilities codex") != null) and (.auth_formats | index("json_refresh_token") != null) and .capabilities.auth_login == true and .capabilities.auth_read == true and .capabilities.auth_write == true and .capabilities.local_mode == true and .capabilities.online_mode == true and .launch_configs.profile.type == "string"' >/dev/null || fail "Expected runtime capabilities JSON for codex, got: $RUN_OUTPUT"
}

test_agent_sh_claude_runtime_info_reports_skeleton_metadata() {
  begin_test "agent.sh runtime info reports claude runtime metadata"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" runtime info claude
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "claude" and .installed == false and .install_method == "native-installer" and .capabilities.install == true and .capabilities.update == true and .capabilities.reset_config == true and .capabilities.auth_login == true and .capabilities.auth_read == true and .capabilities.auth_write == true and .capabilities.local_mode == true and .capabilities.online_mode == true and (.auth_formats | index("claude_ai_oauth_json") != null) and (.commands | index("runtime install claude") != null) and (.commands | index("auth login claude") != null)' >/dev/null || fail "Expected runtime info JSON for claude runtime, got: $RUN_OUTPUT"
}

test_agent_sh_system_manifest_includes_runtime_feature_and_preference_state() {
  begin_test "agent.sh system manifest includes installed runtimes, features, and preferred runtime state"

  local temp_home
  local fake_bin
  local state_dir
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$(make_fake_runtime_bin "$temp_home" codex)"
  make_fake_runtime_bin "$temp_home" claude >/dev/null
  state_dir="$temp_home/state"
  mkdir -p "$state_dir/office" "$temp_home/config/agentctl"
  printf '%s\n' installed >"$state_dir/office/install-complete"
  printf '%s\n' claude >"$temp_home/config/agentctl/preferred-runtime"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_FEATURE_STATE_DIR="$state_dir" \
    -- system manifest
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.installed_runtimes == ["claude","codex"] and .installed_features == ["office"] and .default_runtime == "codex" and .preferred_runtime == "claude"' >/dev/null || fail "Expected richer system manifest JSON, got: $RUN_OUTPUT"
}

test_agent_sh_claude_runtime_install_runs_native_installer() {
  begin_test "agent.sh claude runtime install runs the native installer"

  local temp_home
  local fake_bin
  local install_log
  local expected_owner
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  install_log="$temp_home/install.log"
  expected_owner="$(id -u):$(id -g)"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/apk" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$install_log"
if [ "\$1" = "info" ] && [ "\$2" = "-e" ]; then
  exit 0
fi
exit 1
EOF
  chmod +x "$fake_bin/apk"

  cat >"$fake_bin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$install_log"
cat <<'SCRIPT'
#!/bin/sh
echo installer-ran >/dev/null
SCRIPT
EOF
  chmod +x "$fake_bin/curl"

  cat >"$fake_bin/bash" <<EOF
#!/bin/sh
cat >/dev/null
printf '%s\n' 'installer-bash' >>"$install_log"
cat >"$fake_bin/claude" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x "$fake_bin/claude"
EOF
  chmod +x "$fake_bin/bash"

  cat >"$fake_bin/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ]; then
  printf '%s\n' 0
  exit 0
fi
exec /usr/bin/id "$@"
EOF
  chmod +x "$fake_bin/id"

  cat >"$fake_bin/chown" <<EOF
#!/bin/sh
printf 'chown %s\n' "\$*" >>"$install_log"
exit 0
EOF
  chmod +x "$fake_bin/chown"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    -- runtime install claude
  assert_status 0
  [ -x "$fake_bin/claude" ] || fail "Expected fake claude launcher to be created by installer"
  grep -Fq 'info -e libgcc' "$install_log" || fail "Expected Alpine dependency verification for libgcc"
  grep -Fq 'info -e libstdc++' "$install_log" || fail "Expected Alpine dependency verification for libstdc++"
  grep -Fq 'info -e ripgrep' "$install_log" || fail "Expected Alpine dependency verification for ripgrep"
  grep -Fq 'installer-bash' "$install_log" || fail "Expected native installer script to be piped into bash"
  grep -Fq "chown -R $expected_owner $temp_home/home/.claude" "$install_log" || fail "Expected Claude install to hand .claude ownership back to the container user"
  jq -er '.env.USE_BUILTIN_RIPGREP == "0"' "$temp_home/home/.claude/settings.json" >/dev/null || fail "Expected Claude settings.json to disable builtin ripgrep"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    -- preferred get
  assert_status 0
  assert_contains "claude"
}

test_agent_sh_claude_runtime_update_calls_claude_update() {
  begin_test "agent.sh claude runtime update calls claude update"

  local temp_home
  local fake_bin
  local update_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  update_log="$temp_home/update.log"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$update_log"
exit 0
EOF
  chmod +x "$fake_bin/claude"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    -- runtime update claude
  assert_status 0
  grep -Fxq 'update' "$update_log" || fail "Expected claude update to be invoked"
}

test_agent_sh_claude_runtime_reset_config_restores_settings() {
  begin_test "agent.sh claude runtime reset-config restores settings"

  local temp_home
  local fake_bin
  local install_log
  local expected_owner
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  install_log="$temp_home/install.log"
  expected_owner="$(id -u):$(id -g)"
  mkdir -p "$fake_bin"
  mkdir -p "$temp_home/home/.claude"
  printf '%s' '{"env":{"USE_BUILTIN_RIPGREP":"1"}}' >"$temp_home/home/.claude/settings.json"
  printf '%s' '{"hasCompletedOnboarding":true}' >"$temp_home/home/.claude.json"

  cat >"$fake_bin/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ]; then
  printf '%s\n' 0
  exit 0
fi
exec /usr/bin/id "$@"
EOF
  chmod +x "$fake_bin/id"

  cat >"$fake_bin/chown" <<EOF
#!/bin/sh
printf 'chown %s\n' "\$*" >>"$install_log"
exit 0
EOF
  chmod +x "$fake_bin/chown"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    -- runtime reset-config claude
  assert_status 0
  grep -Fq "chown -R $expected_owner $temp_home/home/.claude" "$install_log" || fail "Expected reset-config to hand .claude ownership back to the container user"
  grep -Fq "chown $expected_owner $temp_home/home/.claude.json" "$install_log" || fail "Expected reset-config to hand .claude.json ownership back to the container user"
  jq -er '.env.USE_BUILTIN_RIPGREP == "0"' "$temp_home/home/.claude/settings.json" >/dev/null || fail "Expected Claude settings reset to default ripgrep behavior"
}

test_agent_sh_codex_run_defaults_to_workdir_cd() {
  begin_test "agent.sh codex run injects --cd /workdir by default"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/codex-run.log"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/codex" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/codex"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_RUN_MODE=online \
    -- run
  assert_status 0
  grep -Fq -- '--cd /workdir' "$run_log" || fail "Expected codex run to include --cd /workdir"
}

test_agent_sh_codex_run_uses_runtime_profile_config() {
  begin_test "agent.sh codex run maps runtime config profile to --profile"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/codex-run.log"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/codex" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/codex"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_RUNTIME_CONFIG_JSON='{"profile":"gemma"}' \
    AGENTCTL_RUN_MODE=online \
    -- run
  assert_status 0
  grep -Fq -- '--profile gemma' "$run_log" || fail "Expected codex run to include --profile gemma"
  grep -Fq -- '--cd /workdir' "$run_log" || fail "Expected codex run to include --cd /workdir"
}

test_agent_sh_accepts_explicit_empty_runtime_config_json() {
  begin_test "agent.sh accepts explicit empty runtime config JSON"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/codex-run.log"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/codex" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/codex"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_RUNTIME_CONFIG_JSON='{}' \
    AGENTCTL_RUN_MODE=online \
    -- run
  assert_status 0
  grep -Fq -- '--cd /workdir' "$run_log" || fail "Expected codex run to include --cd /workdir"
}

test_agent_sh_codex_run_uses_model_override() {
  begin_test "agent.sh codex run maps the model override to -m"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/codex-run.log"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/codex" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/codex"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_MODEL_OVERRIDE="qwen3:14b" \
    AGENTCTL_RUN_MODE=online \
    -- run
  assert_status 0
  grep -Fq -- '-m qwen3:14b' "$run_log" || fail "Expected codex run to include -m qwen3:14b"
  grep -Fq -- '--cd /workdir' "$run_log" || fail "Expected codex run to keep --cd /workdir"
}

test_agent_sh_codex_online_run_skips_catalog_update() {
  begin_test "agent.sh codex online run skips local catalog update"

  local temp_home
  local fake_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/codex"
  cat >"$temp_home/home/.codex/config.toml" <<'EOF'
[model_providers.myollama]
name = "Ollama"
base_url = "http://old-host:11434/v1"

[profiles.gpt-oss]
model_provider = "myollama"
model = "gpt-oss:20b"
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_RUN_MODE=online \
    -- run
  assert_status 0
  [ ! -e "$temp_home/home/.codex/local_models.json" ] || fail "Did not expect online run to create local model catalog"
  grep -Fq 'base_url = "http://old-host:11434/v1"' "$temp_home/home/.codex/config.toml" || fail "Did not expect online run to update Codex local provider URL"
}

test_agent_sh_codex_local_run_updates_config_and_catalog() {
  begin_test "agent.sh codex local run updates Ollama config and model catalog"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/codex-run.log"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/codex"

  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/version'*)
    printf '{"version":"0.0.0"}\n'
    exit 0
    ;;
  *'/api/show'*)
    cat >/dev/null
    cat <<'JSON'
{
  "system": "local instructions",
  "capabilities": ["vision", "thinking"],
  "details": {"format": "gguf"},
  "model_info": {
    "llama.context_length": 4096,
    "qwen3.context_length": 8192
  },
  "parameters": "temperature 0.1\nnum_ctx 32768\n"
}
JSON
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$fake_bin/curl"

  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  cat >"$temp_home/home/.codex/config.toml" <<'EOF'
[model_providers.myollama]
name = "Ollama"
base_url = "http://old-host:11434/v1"
wire_api = "responses"

[profiles.gpt-oss]
model_provider = "myollama"
model = "gpt-oss:20b"
model_context_window = 131072
EOF

  cat >"$temp_home/home/.codex/local_models.json" <<'EOF'
{
  "models": [
    {
      "slug": "other:model",
      "unknown": "preserved"
    }
  ]
}
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  assert_contains "added model metadata: gpt-oss:20b"
  grep -Fq 'base_url = "http://192.168.0.1:11434/v1"' "$temp_home/home/.codex/config.toml" || fail "Expected Codex myollama base_url to be updated"
  grep -Fq 'wire_api = "responses"' "$temp_home/home/.codex/config.toml" || fail "Expected Codex config fields outside base_url to be preserved"
  jq -er '
    (.models | length) == 2 and
    (.models[] | select(.slug == "other:model").unknown == "preserved") and
    (.models[] | select(.slug == "gpt-oss:20b")
      | .display_name == "gpt-oss:20b"
      and .context_window == 32768
      and .base_instructions == "local instructions"
      and .input_modalities == ["text", "image"]
      and .supports_reasoning_summaries == true
      and (.supported_reasoning_levels | length) == 3)
  ' "$temp_home/home/.codex/local_models.json" >/dev/null || fail "Expected Codex model catalog metadata to be generated"
  grep -Fq -- '--profile gpt-oss --cd /workdir' "$run_log" || fail "Expected codex run to launch after local metadata update"
}

test_agent_sh_codex_local_metadata_status_uses_stderr() {
  begin_test "agent.sh codex local metadata status uses stderr"

  local temp_home
  local fake_bin
  local stdout_log
  local stderr_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  stdout_log="$temp_home/stdout.log"
  stderr_log="$temp_home/stderr.log"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
printf '{"type":"turn.completed"}\n'
exit 0
EOF
  chmod +x "$fake_bin/codex"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/version'*) printf '{"version":"0.0.0"}\n'; exit 0 ;;
  *'/api/show'*)
    cat >/dev/null
    printf '{"system":"","capabilities":[],"details":{"format":"safetensors"},"model_info":{"llama.context_length":4096}}\n'
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF
  cat >"$temp_home/home/.codex/config.toml" <<'EOF'
[model_providers.myollama]
name = "Ollama"

[profiles.gpt-oss]
model_provider = "myollama"
model = "gpt-oss:20b"
EOF

  env -i \
    "HOME=$temp_home/home" \
    "XDG_CONFIG_HOME=$temp_home/config" \
    "PATH=$fake_bin:/usr/bin:/bin" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    "AGENTCTL_OLLAMA_ROUTE_FILE=$temp_home/proc-net-route" \
    /bin/bash "$TEST_ROOT/agent.sh" run --json >"$stdout_log" 2>"$stderr_log"
  jq -c . "$stdout_log" >/dev/null || fail "Expected stdout to remain valid JSONL"
  if grep -Fq 'model metadata' "$stdout_log"; then
    fail "Did not expect model metadata status on stdout"
  fi
  grep -Fq 'added model metadata: gpt-oss:20b' "$stderr_log" || fail "Expected model metadata status on stderr"
}

test_agent_sh_codex_local_run_with_explicit_profile_updates_catalog() {
  begin_test "agent.sh codex local run with explicit profile updates catalog"

  local temp_home
  local fake_bin
  local request_log
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  request_log="$temp_home/request.json"
  run_log="$temp_home/codex-run.log"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/codex"
  cat >"$fake_bin/curl" <<EOF
#!/bin/sh
case "\$*" in
  *'/api/version'*) printf '{"version":"0.0.0"}\n'; exit 0 ;;
  *'/api/show'*)
    cat >"$request_log"
    cat <<'JSON'
{"system":"","capabilities":[],"details":{"format":"safetensors"},"model_info":{"llama.context_length":4096},"parameters":""}
JSON
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF
  cat >"$temp_home/home/.codex/config.toml" <<'EOF'
[model_providers.myollama]
name = "Ollama"

[profiles.gpt-oss]
model_provider = "myollama"
model = "default:model"

[profiles.gemma]
model_provider = "myollama"
model = "gemma:model"
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run --profile gemma
  assert_status 0
  jq -er '.model == "gemma:model"' "$request_log" >/dev/null || fail "Expected explicit profile model to be queried"
  jq -er '.models[0].slug == "gemma:model"' "$temp_home/home/.codex/local_models.json" >/dev/null || fail "Expected catalog to use explicit profile model"
  grep -Fq -- '--profile gemma' "$run_log" || fail "Expected explicit profile to be preserved in Codex launch args"
  grep -Fq -- '--cd /workdir' "$run_log" || fail "Expected Codex launch args to keep --cd /workdir"
}

test_agent_sh_codex_local_run_updates_stale_catalog_entry() {
  begin_test "agent.sh codex local run updates stale catalog metadata"

  local temp_home
  local fake_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/codex"

  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/version'*)
    printf '{"version":"0.0.0"}\n'
    exit 0
    ;;
  *'/api/show'*)
    cat >/dev/null
    cat <<'JSON'
{
  "system": "",
  "capabilities": [],
  "details": {"format": "safetensors"},
  "model_info": {
    "gemma3.context_length": 16384
  },
  "parameters": "num_ctx 32768\n"
}
JSON
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$fake_bin/curl"

  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  cat >"$temp_home/home/.codex/config.toml" <<'EOF'
[model_providers.myollama]
name = "Ollama"

[profiles.gpt-oss]
model_provider = "myollama"
model = "gpt-oss:20b"
EOF

  cat >"$temp_home/home/.codex/local_models.json" <<'EOF'
{
  "models": [
    {
      "slug": "gpt-oss:20b",
      "display_name": "old name",
      "context_window": 1,
      "custom": "keep"
    }
  ]
}
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  assert_contains "updated model metadata: gpt-oss:20b fields="
  jq -er '
    .models == [
      (.models[0])
    ] and
    .models[0].slug == "gpt-oss:20b" and
    .models[0].display_name == "gpt-oss:20b" and
    .models[0].context_window == 16384 and
    .models[0].custom == "keep" and
    .models[0].input_modalities == ["text"] and
    .models[0].supports_reasoning_summaries == false
  ' "$temp_home/home/.codex/local_models.json" >/dev/null || fail "Expected stale catalog entry to be updated without dropping unknown fields"
}

test_agent_sh_codex_local_run_reports_unchanged_catalog_entry() {
  begin_test "agent.sh codex local run reports unchanged catalog metadata"

  local temp_home
  local fake_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/codex"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/version'*) printf '{"version":"0.0.0"}\n'; exit 0 ;;
  *'/api/show'*)
    cat >/dev/null
    cat <<'JSON'
{"system":"","capabilities":[],"details":{"format":"safetensors"},"model_info":{"llama.context_length":4096},"parameters":""}
JSON
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF
  cat >"$temp_home/home/.codex/config.toml" <<'EOF'
[model_providers.myollama]
name = "Ollama"
base_url = "http://192.168.0.1:11434/v1"

[profiles.gpt-oss]
model_provider = "myollama"
model = "gpt-oss:20b"
EOF

  jq -n '{
    models: [
      {
        slug: "gpt-oss:20b",
        display_name: "gpt-oss:20b",
        context_window: 4096,
        apply_patch_tool_type: "function",
        shell_type: "default",
        visibility: "list",
        supported_in_api: true,
        priority: 0,
        truncation_policy: {mode: "bytes", limit: 10000},
        input_modalities: ["text"],
        base_instructions: "",
        support_verbosity: true,
        default_verbosity: "low",
        supports_parallel_tool_calls: false,
        supports_reasoning_summaries: false,
        supported_reasoning_levels: [],
        experimental_supported_tools: []
      }
    ]
	  }' >"$temp_home/home/.codex/local_models.json"
  config_mtime_before="$(stat -c %Y "$temp_home/home/.codex/config.toml")"
  catalog_mtime_before="$(stat -c %Y "$temp_home/home/.codex/local_models.json")"
  sleep 1

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  assert_contains "model metadata unchanged: gpt-oss:20b"
  config_mtime_after="$(stat -c %Y "$temp_home/home/.codex/config.toml")"
  catalog_mtime_after="$(stat -c %Y "$temp_home/home/.codex/local_models.json")"
  [ "$config_mtime_after" = "$config_mtime_before" ] || fail "Expected unchanged Codex config timestamp to be preserved"
  [ "$catalog_mtime_after" = "$catalog_mtime_before" ] || fail "Expected unchanged Codex model catalog timestamp to be preserved"
}

test_agent_sh_codex_local_run_uses_model_override_for_catalog() {
  begin_test "agent.sh codex local run uses model override for catalog metadata"

  local temp_home
  local fake_bin
  local request_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  request_log="$temp_home/request.json"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/codex"
  cat >"$fake_bin/curl" <<EOF
#!/bin/sh
case "\$*" in
  *'/api/version'*) printf '{"version":"0.0.0"}\n'; exit 0 ;;
  *'/api/show'*)
    cat >"$request_log"
    cat <<'JSON'
{"system":"","capabilities":[],"details":{"format":"safetensors"},"model_info":{"llama.context_length":4096},"parameters":""}
JSON
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF
  cat >"$temp_home/home/.codex/config.toml" <<'EOF'
[model_providers.myollama]
name = "Ollama"

[profiles.gpt-oss]
model_provider = "myollama"
model = "profile:model"
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    AGENTCTL_MODEL_OVERRIDE="override:model" \
    -- run
  assert_status 0
  jq -er '.model == "override:model"' "$request_log" >/dev/null || fail "Expected /api/show to use model override"
  jq -er '.models[0].slug == "override:model"' "$temp_home/home/.codex/local_models.json" >/dev/null || fail "Expected catalog slug to use model override"
}

test_agent_sh_codex_local_run_uses_explicit_model_arg_for_catalog() {
  begin_test "agent.sh codex local run uses explicit model arg for catalog metadata"

  local temp_home
  local fake_bin
  local request_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  request_log="$temp_home/request.json"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/codex"
  cat >"$fake_bin/curl" <<EOF
#!/bin/sh
case "\$*" in
  *'/api/version'*) printf '{"version":"0.0.0"}\n'; exit 0 ;;
  *'/api/show'*)
    cat >"$request_log"
    cat <<'JSON'
{"system":"","capabilities":[],"details":{"format":"safetensors"},"model_info":{"llama.context_length":4096},"parameters":""}
JSON
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF
  cat >"$temp_home/home/.codex/config.toml" <<'EOF'
[model_providers.myollama]
name = "Ollama"

[profiles.gpt-oss]
model_provider = "myollama"
model = "profile:model"
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    AGENTCTL_MODEL_OVERRIDE="override:model" \
    -- run -m=explicit:model
  assert_status 0
  jq -er '.model == "explicit:model"' "$request_log" >/dev/null || fail "Expected /api/show to use explicit model argument"
  jq -er '.models[0].slug == "explicit:model"' "$temp_home/home/.codex/local_models.json" >/dev/null || fail "Expected catalog slug to use explicit model argument"
}

test_agent_sh_codex_local_run_creates_missing_catalog() {
  begin_test "agent.sh codex local run creates missing model catalog"

  local temp_home
  local fake_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/codex"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/version'*) printf '{"version":"0.0.0"}\n'; exit 0 ;;
  *'/api/show'*)
    cat >/dev/null
    printf '{"system":"","capabilities":[],"details":{"format":"safetensors"},"model_info":{"llama.context_length":4096}}\n'
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF
  cat >"$temp_home/home/.codex/config.toml" <<'EOF'
[model_providers.myollama]
name = "Ollama"

[profiles.gpt-oss]
model_provider = "myollama"
model = "gpt-oss:20b"
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  assert_contains "added model metadata: gpt-oss:20b"
  jq -er '.models | length == 1 and .[0].slug == "gpt-oss:20b"' "$temp_home/home/.codex/local_models.json" >/dev/null || fail "Expected missing catalog to be created with model metadata"
}

test_agent_sh_codex_local_run_rejects_invalid_catalog_without_overwrite() {
  begin_test "agent.sh codex local run rejects invalid catalog without overwrite"

  local temp_home
  local fake_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/codex"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/version'*) printf '{"version":"0.0.0"}\n'; exit 0 ;;
  *'/api/show'*)
    cat >/dev/null
    printf '{"system":"","capabilities":[],"details":{"format":"safetensors"},"model_info":{"llama.context_length":4096}}\n'
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF
  cat >"$temp_home/home/.codex/config.toml" <<'EOF'
[model_providers.myollama]
name = "Ollama"

[profiles.gpt-oss]
model_provider = "myollama"
model = "gpt-oss:20b"
EOF
  printf '{ invalid json\n' >"$temp_home/home/.codex/local_models.json"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 1
  assert_contains "invalid Codex model catalog"
  grep -Fxq '{ invalid json' "$temp_home/home/.codex/local_models.json" || fail "Expected invalid catalog to remain untouched"
}

test_agent_sh_codex_local_run_rejects_missing_myollama_provider() {
  begin_test "agent.sh codex local run rejects missing myollama provider"

  local temp_home
  local fake_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/codex"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
printf '{"version":"0.0.0"}\n'
exit 0
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF
  cat >"$temp_home/home/.codex/config.toml" <<'EOF'
[profiles.gpt-oss]
model_provider = "myollama"
model = "gpt-oss:20b"
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 1
  assert_contains "missing Codex model provider in config: myollama"
  if grep -Fq '[model_providers.myollama]' "$temp_home/home/.codex/config.toml"; then
    fail "Did not expect missing provider to be created"
  fi
}

test_agent_sh_codex_local_run_api_show_failure_preserves_catalog() {
  begin_test "agent.sh codex local run preserves catalog when api show fails"

  local temp_home
  local fake_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/codex"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/version'*) printf '{"version":"0.0.0"}\n'; exit 0 ;;
  *'/api/show'*) cat >/dev/null; exit 22 ;;
esac
exit 1
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF
  cat >"$temp_home/home/.codex/config.toml" <<'EOF'
[model_providers.myollama]
name = "Ollama"

[profiles.gpt-oss]
model_provider = "myollama"
model = "gpt-oss:20b"
EOF
  printf '{"models":[{"slug":"keep"}]}\n' >"$temp_home/home/.codex/local_models.json"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 1
  assert_contains "failed to query Ollama model metadata for: gpt-oss:20b"
  jq -er '.models == [{"slug":"keep"}]' "$temp_home/home/.codex/local_models.json" >/dev/null || fail "Expected catalog to remain untouched after /api/show failure"
}

test_agent_sh_claude_run_uses_local_ollama_defaults() {
  begin_test "agent.sh claude run uses Anthropic-compatible Ollama defaults"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/claude-run.log"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl"
  printf '%s\n' claude >"$temp_home/config/agentctl/preferred-runtime"

  cat >"$fake_bin/claude" <<EOF
#!/bin/sh
printf 'AUTH=%s\n' "\${ANTHROPIC_AUTH_TOKEN:-}" >"$run_log"
printf 'API=%s\n' "\${ANTHROPIC_API_KEY:-}" >>"$run_log"
printf 'BASE=%s\n' "\${ANTHROPIC_BASE_URL:-}" >>"$run_log"
printf 'ARGS=%s\n' "\$*" >>"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/claude"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/curl"

  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  grep -Fq 'AUTH=ollama' "$run_log" || fail "Expected Claude local run to set ANTHROPIC_AUTH_TOKEN=ollama"
  grep -Fq 'API=' "$run_log" || fail "Expected Claude local run to clear ANTHROPIC_API_KEY"
  grep -Fq 'BASE=http://192.168.0.1:11434' "$run_log" || fail "Expected Claude local run to set the host gateway base URL"
  grep -Fq 'ARGS=--model gpt-oss:20b' "$run_log" || fail "Expected Claude local run to inject the default local model"
}

test_agent_sh_claude_run_respects_explicit_model() {
  begin_test "agent.sh claude run keeps an explicit model argument"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/claude-run.log"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl"
  printf '%s\n' claude >"$temp_home/config/agentctl/preferred-runtime"

  cat >"$fake_bin/claude" <<EOF
#!/bin/sh
printf 'ARGS=%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/claude"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/curl"

  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run --model llama3
  assert_status 0
  grep -Fq 'ARGS=--model llama3' "$run_log" || fail "Expected explicit Claude model to be preserved"
}

test_agent_sh_claude_run_uses_model_override() {
  begin_test "agent.sh claude run uses the generic model override"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/claude-run.log"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl"
  printf '%s\n' claude >"$temp_home/config/agentctl/preferred-runtime"

  cat >"$fake_bin/claude" <<EOF
#!/bin/sh
printf 'ARGS=%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/claude"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/curl"

  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_MODEL_OVERRIDE="qwen3:14b" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  grep -Fq 'ARGS=--model qwen3:14b' "$run_log" || fail "Expected Claude model override to replace the default local model"
}

test_agent_sh_claude_run_uses_runtime_flag_config() {
  begin_test "agent.sh claude run maps runtime config booleans to CLI flags"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/claude-run.log"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl"
  printf '%s\n' claude >"$temp_home/config/agentctl/preferred-runtime"

  cat >"$fake_bin/claude" <<EOF
#!/bin/sh
printf 'ARGS=%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/claude"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/curl"

  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_RUNTIME_CONFIG_JSON='{"dangerously-skip-permissions":"true"}' \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  grep -Fq 'ARGS=--model gpt-oss:20b --dangerously-skip-permissions' "$run_log" || fail "Expected Claude runtime config flag to be passed through"
}

test_agent_sh_rejects_unknown_runtime() {
  begin_test "agent.sh rejects unknown runtimes predictably"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" runtime info does-not-exist
  assert_status 1
  assert_contains "unsupported runtime: does-not-exist"
}

test_agent_sh_preferred_round_trip() {
  begin_test "agent.sh preferred set/get persists runtime selection"

  local temp_home
  local fake_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$(make_fake_runtime_bin "$temp_home" codex)"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    -- preferred set codex
  assert_status 0

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    -- preferred get
  assert_status 0
  assert_contains "codex"
}

test_agent_sh_preferred_set_as_root_repairs_ownership() {
  begin_test "agent.sh preferred set as root hands config ownership back to the container user"

  local temp_home
  local fake_bin
  local ownership_log
  local expected_owner
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  ownership_log="$temp_home/ownership.log"
  mkdir -p "$fake_bin" "$temp_home/home"
  expected_owner="$(stat -c '%u:%g' "$temp_home/home" 2>/dev/null || stat -f '%u:%g' "$temp_home/home")"
  make_fake_runtime_bin "$temp_home" codex >/dev/null

  cat >"$fake_bin/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ]; then
  printf '%s\n' 0
  exit 0
fi
exec /usr/bin/id "$@"
EOF
  chmod +x "$fake_bin/id"

  cat >"$fake_bin/chown" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$ownership_log"
exit 0
EOF
  chmod +x "$fake_bin/chown"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    -- preferred set codex
  assert_status 0
  grep -Fq "$expected_owner $temp_home/config/agentctl" "$ownership_log" || fail "Expected preferred set to repair config directory ownership"
  grep -Fq "$expected_owner $temp_home/config/agentctl/preferred-runtime" "$ownership_log" || fail "Expected preferred set to repair preferred-runtime ownership"
}

test_agent_sh_preferred_set_rejects_uninstalled_runtime() {
  begin_test "agent.sh preferred set rejects uninstalled runtimes"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" preferred set claude
  assert_status 1
  assert_contains "runtime not installed: claude"
}

test_agent_sh_auth_read_rejects_invalid_codex_auth() {
  begin_test "agent.sh auth read rejects invalid codex auth data"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  mkdir -p "$temp_home/home/.codex"
  printf '%s' '{"tokens":{"refresh_token":""}}' >"$temp_home/home/.codex/auth.json"

  run_agent_sh_capture "$temp_home" auth read codex json_refresh_token
  assert_status 1
  assert_contains "invalid auth state:"
}

test_agent_sh_auth_write_rejects_invalid_codex_auth() {
  begin_test "agent.sh auth write rejects invalid codex auth data"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture_env "$temp_home" \
    PATH="/usr/bin:/bin" \
    -- auth write codex json_refresh_token '{}'
  assert_status 1
  assert_contains "invalid auth payload for codex"
}

test_agent_sh_auth_write_codex_does_not_require_user_config_dir() {
  begin_test "agent.sh auth write for codex does not require ~/.config/agentctl"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  mkdir -p "$temp_home/home/.config"
  chmod 500 "$temp_home/home/.config"

  run_agent_sh_capture_env "$temp_home" \
    PATH="/usr/bin:/bin" \
    -- auth write codex json_refresh_token '{"refresh_token":"token"}'
  assert_status 0
  jq -er '.refresh_token == "token"' "$temp_home/home/.codex/auth.json" >/dev/null || fail "Expected Codex auth to be written without ~/.config/agentctl"
}

test_agent_sh_claude_auth_read_includes_optional_home_state() {
  begin_test "agent.sh auth read returns claude credentials and minimal home state"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  mkdir -p "$temp_home/home/.claude"
  printf '%s' '{"claudeAiOauth":{"accessToken":"access-token","refreshToken":"refresh-token","expiresAt":1776462236852}}' >"$temp_home/home/.claude/.credentials.json"
  printf '%s' '{"installMethod":"native","userID":"abc123","oauthAccount":{"emailAddress":"user@example.com"},"hasCompletedOnboarding":true}' >"$temp_home/home/.claude.json"

  run_agent_sh_capture "$temp_home" auth read claude claude_ai_oauth_json
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.claudeAiOauth.refreshToken == "refresh-token" and .claudeCodeState.oauthAccount.emailAddress == "user@example.com" and .claudeCodeState.hasCompletedOnboarding == true and (.claudeCodeState | has("installMethod") | not) and (.claudeCodeState | has("userID") | not)' >/dev/null || fail "Expected Claude auth payload with minimal home state, got: $RUN_OUTPUT"
}

test_agent_sh_claude_auth_read_rejects_invalid_credentials() {
  begin_test "agent.sh auth read rejects invalid claude auth data"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  mkdir -p "$temp_home/home/.claude"
  printf '%s' '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}' >"$temp_home/home/.claude/.credentials.json"

  run_agent_sh_capture "$temp_home" auth read claude claude_ai_oauth_json
  assert_status 1
  assert_contains "invalid auth state:"
}

test_agent_sh_claude_auth_write_restores_credentials_and_home_state() {
  begin_test "agent.sh auth write restores claude credentials and minimal home state"

  local temp_home
  local fake_bin
  local auth_log
  local expected_owner
  local payload
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  auth_log="$temp_home/auth.log"
  expected_owner="$(id -u):$(id -g)"
  mkdir -p "$fake_bin"
  payload='{"claudeAiOauth":{"accessToken":"access-token","refreshToken":"refresh-token","expiresAt":1776462236852},"claudeCodeState":{"oauthAccount":{"emailAddress":"user@example.com"},"hasCompletedOnboarding":true}}'

  cat >"$fake_bin/id" <<'EOF'
#!/bin/sh
if [ "$1" = "-u" ]; then
  printf '%s\n' 0
  exit 0
fi
exec /usr/bin/id "$@"
EOF
  chmod +x "$fake_bin/id"

  cat >"$fake_bin/chown" <<EOF
#!/bin/sh
printf 'chown %s\n' "\$*" >>"$auth_log"
exit 0
EOF
  chmod +x "$fake_bin/chown"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    -- auth write claude claude_ai_oauth_json "$payload"
  assert_status 0
  grep -Fq "chown -R $expected_owner $temp_home/home/.claude" "$auth_log" || fail "Expected auth write to hand .claude ownership back to the container user"
  grep -Fq "chown $expected_owner $temp_home/home/.claude.json" "$auth_log" || fail "Expected auth write to hand .claude.json ownership back to the container user"
  jq -er '(.claudeAiOauth.refreshToken == "refresh-token") and (has("claudeCodeState") | not)' "$temp_home/home/.claude/.credentials.json" >/dev/null || fail "Expected Claude credentials file to contain only auth payload"
  jq -er '.oauthAccount.emailAddress == "user@example.com" and .hasCompletedOnboarding == true and (has("installMethod") | not) and (has("userID") | not)' "$temp_home/home/.claude.json" >/dev/null || fail "Expected Claude home state file to be restored minimally"
}

test_agent_sh_claude_auth_write_rejects_invalid_payload() {
  begin_test "agent.sh auth write rejects invalid claude auth data"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture_env "$temp_home" \
    PATH="/usr/bin:/bin" \
    -- auth write claude claude_ai_oauth_json '{}'
  assert_status 1
  assert_contains "invalid auth payload for claude"
}

test_agent_sh_state_export_includes_known_user_state() {
  begin_test "agent.sh state export includes codex, agentctl, and claude state"

  local temp_home
  local tar_file
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  tar_file="$temp_home/state.tar"

  mkdir -p \
    "$temp_home/home/.codex" \
    "$temp_home/home/.config/agentctl" \
    "$temp_home/home/.claude"
  printf '%s' 'codex-auth' >"$temp_home/home/.codex/auth.json"
  printf '%s' 'claude' >"$temp_home/home/.config/agentctl/preferred-runtime"
  printf '%s' '{"claudeAiOauth":{"accessToken":"a","refreshToken":"b","expiresAt":1}}' >"$temp_home/home/.claude/.credentials.json"
  printf '%s' '{"hasCompletedOnboarding":true}' >"$temp_home/home/.claude.json"

  env -i \
    "HOME=$temp_home/home" \
    "XDG_CONFIG_HOME=$temp_home/home/.config" \
    "PATH=/usr/bin:/bin" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state export >"$tar_file"

  tar -tf "$tar_file" | grep -Fx '.codex/auth.json' >/dev/null || fail "Expected .codex/auth.json in exported state"
  tar -tf "$tar_file" | grep -Fx '.config/agentctl/preferred-runtime' >/dev/null || fail "Expected preferred runtime in exported state"
  tar -tf "$tar_file" | grep -Fx '.claude/.credentials.json' >/dev/null || fail "Expected Claude credentials in exported state"
  tar -tf "$tar_file" | grep -Fx '.claude.json' >/dev/null || fail "Expected Claude home state in exported state"
}

test_agent_sh_state_export_uses_installed_runtime_hooks() {
  begin_test "agent.sh state export uses installed runtime hooks instead of sweeping legacy runtime state"

  local temp_home
  local fake_bin
  local tar_file
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  tar_file="$temp_home/state.tar"
  fake_bin="$(make_fake_runtime_bin "$temp_home" codex)"

  mkdir -p \
    "$temp_home/home/.codex" \
    "$temp_home/home/.claude" \
    "$temp_home/home/.config/agentctl"
  printf '%s' 'codex-auth' >"$temp_home/home/.codex/auth.json"
  printf '%s' '{"claudeAiOauth":{"accessToken":"a","refreshToken":"b","expiresAt":1}}' >"$temp_home/home/.claude/.credentials.json"
  printf '%s' '{"hasCompletedOnboarding":true}' >"$temp_home/home/.claude.json"
  printf '%s' 'codex' >"$temp_home/home/.config/agentctl/preferred-runtime"

  env -i \
    "HOME=$temp_home/home" \
    "XDG_CONFIG_HOME=$temp_home/home/.config" \
    "PATH=$fake_bin:/usr/bin:/bin" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state export >"$tar_file"

  tar -tf "$tar_file" | grep -Fx '.codex/auth.json' >/dev/null || fail "Expected installed Codex runtime state in exported state"
  tar -tf "$tar_file" | grep -Fx '.config/agentctl/preferred-runtime' >/dev/null || fail "Expected generic agentctl state in exported state"
  if tar -tf "$tar_file" | grep -Fqx '.claude/.credentials.json'; then
    fail "Did not expect Claude legacy state to be exported when only Codex is installed"
  fi
  if tar -tf "$tar_file" | grep -Fqx '.claude.json'; then
    fail "Did not expect Claude home state to be exported when only Codex is installed"
  fi
}

test_agent_sh_state_import_restores_known_user_state() {
  begin_test "agent.sh state import restores codex, agentctl, and claude state"

  local source_home
  local target_home
  local tar_file
  source_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  target_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$source_home"
  register_dir_cleanup "$target_home"
  tar_file="$source_home/state.tar"

  mkdir -p \
    "$source_home/home/.codex" \
    "$source_home/home/.config/agentctl" \
    "$source_home/home/.claude"
  printf '%s' 'codex-auth' >"$source_home/home/.codex/auth.json"
  printf '%s' 'claude' >"$source_home/home/.config/agentctl/preferred-runtime"
  printf '%s' '{"claudeAiOauth":{"accessToken":"a","refreshToken":"b","expiresAt":1}}' >"$source_home/home/.claude/.credentials.json"
  printf '%s' '{"hasCompletedOnboarding":true}' >"$source_home/home/.claude.json"

  env -i \
    "HOME=$source_home/home" \
    "XDG_CONFIG_HOME=$source_home/home/.config" \
    "PATH=/usr/bin:/bin" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state export >"$tar_file"

  env -i \
    "HOME=$target_home/home" \
    "XDG_CONFIG_HOME=$target_home/home/.config" \
    "PATH=/usr/bin:/bin" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state import <"$tar_file"

  [ "$(cat "$target_home/home/.codex/auth.json")" = "codex-auth" ] || fail "Expected Codex auth to be restored"
  [ "$(cat "$target_home/home/.config/agentctl/preferred-runtime")" = "claude" ] || fail "Expected preferred runtime to be restored"
  jq -er '.claudeAiOauth.refreshToken == "b"' "$target_home/home/.claude/.credentials.json" >/dev/null || fail "Expected Claude credentials to be restored"
  jq -er '.hasCompletedOnboarding == true' "$target_home/home/.claude.json" >/dev/null || fail "Expected Claude home state to be restored"
}

test_agent_sh_state_import_uses_installed_runtime_hooks() {
  begin_test "agent.sh state import clears only installed runtime state plus generic agentctl state"

  local source_home
  local target_home
  local fake_bin
  local tar_file
  source_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  target_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$source_home"
  register_dir_cleanup "$target_home"
  tar_file="$source_home/state.tar"
  fake_bin="$(make_fake_runtime_bin "$target_home" codex)"

  mkdir -p \
    "$source_home/home/.codex" \
    "$source_home/home/.config/agentctl"
  printf '%s' 'codex-auth' >"$source_home/home/.codex/auth.json"
  printf '%s' 'codex' >"$source_home/home/.config/agentctl/preferred-runtime"

  env -i \
    "HOME=$source_home/home" \
    "XDG_CONFIG_HOME=$source_home/home/.config" \
    "PATH=/usr/bin:/bin" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state export >"$tar_file"

  mkdir -p "$target_home/home/.codex" "$target_home/home/.claude"
  printf '%s' 'stale-codex' >"$target_home/home/.codex/auth.json"
  printf '%s' '{"claudeAiOauth":{"accessToken":"stale","refreshToken":"keep","expiresAt":1}}' >"$target_home/home/.claude/.credentials.json"

  env -i \
    "HOME=$target_home/home" \
    "XDG_CONFIG_HOME=$target_home/home/.config" \
    "PATH=$fake_bin:/usr/bin:/bin" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state import <"$tar_file"

  [ "$(cat "$target_home/home/.codex/auth.json")" = "codex-auth" ] || fail "Expected installed Codex runtime state to be restored"
  [ "$(cat "$target_home/home/.config/agentctl/preferred-runtime")" = "codex" ] || fail "Expected generic agentctl state to be restored"
  jq -er '.claudeAiOauth.refreshToken == "keep"' "$target_home/home/.claude/.credentials.json" >/dev/null || fail "Expected unrelated Claude legacy state to remain untouched when Claude is not installed"
}

test_agent_sh_state_import_with_empty_stdin_preserves_existing_state() {
  begin_test "agent.sh state import with empty stdin preserves existing state"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  mkdir -p "$temp_home/home/.codex"
  printf '%s' 'keep-me' >"$temp_home/home/.codex/auth.json"

  env -i \
    "HOME=$temp_home/home" \
    "XDG_CONFIG_HOME=$temp_home/home/.config" \
    "PATH=/usr/bin:/bin" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state import </dev/null

  [ "$(cat "$temp_home/home/.codex/auth.json")" = "keep-me" ] || fail "Expected existing state to survive empty state import"
}

test_container_auth_info_uses_agent_sh_auth_read() {
  begin_test "container_auth_info reads auth via agent.sh auth read"

  load_codexctl_functions

  local temp_dir
  local exec_log_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-auth-read.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  exec_log_file="$temp_dir/exec.log"

  auth_info_from_json() { cat; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 0; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      start|stop)
        ;;
      exec)
        shift
        if [ "$1" = "unit-test-container" ]; then
          shift
        fi
        if [ "${1:-}" = "setpriv" ]; then
          shift 6
        fi
        printf '%s\n' "$*" >>"$exec_log_file"
        printf 'unit-token\t2026-04-17T00:00:00Z'
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture container_auth_info unit-test-container codex json_refresh_token
  assert_status 0
  assert_contains $'unit-token\t2026-04-17T00:00:00Z'
  grep -Fq '/usr/local/bin/agent.sh auth read codex json_refresh_token' "$exec_log_file" || fail "Expected auth read via agent.sh"
}

test_write_auth_blob_to_container_uses_agent_sh_auth_write() {
  begin_test "write_auth_blob_to_container writes auth via agent.sh auth write"

  load_codexctl_functions

  local temp_dir
  local exec_log_file
  local payload_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-auth-write.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  exec_log_file="$temp_dir/exec.log"
  payload_file="$temp_dir/payload.json"

  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 0; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      start|stop)
        ;;
      exec)
        shift
        if [ "$1" = "-i" ]; then
          shift
        fi
        if [ "$1" = "unit-test-container" ]; then
          shift
        fi
        if [ "${1:-}" = "setpriv" ]; then
          shift 6
        fi
        printf '%s\n' "$*" >>"$exec_log_file"
        cat >"$payload_file"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture write_auth_blob_to_container unit-test-container '{"refresh_token":"write-token"}' codex json_refresh_token
  assert_status 0
  grep -Fxq '{"refresh_token":"write-token"}' "$payload_file" || fail "Expected auth payload to be piped through agent.sh auth write"
  grep -Fq '/usr/local/bin/agent.sh auth write codex json_refresh_token' "$exec_log_file" || fail "Expected auth write via agent.sh"
}

test_write_auth_blob_to_container_falls_back_for_legacy_codex() {
  begin_test "write_auth_blob_to_container falls back for legacy codex auth writes"

  load_codexctl_functions

  local temp_dir
  local exec_log_file
  local fallback_payload_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-auth-write.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  exec_log_file="$temp_dir/exec.log"
  fallback_payload_file="$temp_dir/fallback.json"

  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 0; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      start|stop)
        ;;
      exec)
        shift
        local capture_stdin=0
        if [ "$1" = "-i" ]; then
          shift
          capture_stdin=1
        fi
        if [ "$1" = "-u" ]; then
          shift 2
        fi
        if [ "$1" = "unit-test-container" ]; then
          shift
        fi
        if [ "${1:-}" = "setpriv" ]; then
          shift 6
        fi
        printf '%s\n' "$*" >>"$exec_log_file"
        if [[ "$*" == "bash /usr/local/bin/agent.sh auth write codex json_refresh_token" ]]; then
          printf '%s\n' "mkdir: can't create directory '/home/coder/.config/agentctl': Permission denied" >&2
          cat >/dev/null
          return 1
        fi
        if [[ "$*" == "sh -lc mkdir -p /home/coder/.codex && cat > /home/coder/.codex/auth.json && chown -R coder:coder /home/coder/.codex" ]]; then
          cat >"$fallback_payload_file"
          return 0
        fi
        if [ "$capture_stdin" -eq 1 ]; then
          cat >/dev/null
        fi
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture write_auth_blob_to_container unit-test-container '{"refresh_token":"write-token"}' codex json_refresh_token
  assert_status 0
  assert_contains "Warning: Using legacy Codex auth refresh fallback for unit-test-container. Run: "
  assert_not_contains "Permission denied"
  grep -Fq '/usr/local/bin/agent.sh auth write codex json_refresh_token' "$exec_log_file" || fail "Expected initial auth write attempt via agent.sh"
  grep -Fq 'mkdir -p /home/coder/.codex && cat > /home/coder/.codex/auth.json' "$exec_log_file" || fail "Expected legacy codex auth fallback write"
  grep -Fxq '{"refresh_token":"write-token"}' "$fallback_payload_file" || fail "Expected fallback payload to be written"
}

test_write_auth_blob_to_container_does_not_fallback_on_non_legacy_error() {
  begin_test "write_auth_blob_to_container does not fall back on non-legacy auth write errors"

  load_codexctl_functions

  local temp_dir
  local exec_log_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-auth-write.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  exec_log_file="$temp_dir/exec.log"

  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 0; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      start|stop)
        ;;
      exec)
        shift
        if [ "$1" = "-i" ]; then
          shift
        fi
        if [ "$1" = "-u" ]; then
          shift 2
        fi
        if [ "$1" = "unit-test-container" ]; then
          shift
        fi
        if [ "${1:-}" = "setpriv" ]; then
          shift 6
        fi
        printf '%s\n' "$*" >>"$exec_log_file"
        if [[ "$*" == "bash /usr/local/bin/agent.sh auth write codex json_refresh_token" ]]; then
          printf '%s\n' "invalid auth payload for codex" >&2
          cat >/dev/null
          return 1
        fi
        if [[ "$*" == "sh -lc mkdir -p /home/coder/.codex && cat > /home/coder/.codex/auth.json && chown -R coder:coder /home/coder/.codex" ]]; then
          fail "Legacy fallback should not run for non-legacy auth write errors"
        fi
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture write_auth_blob_to_container unit-test-container '{"refresh_token":"write-token"}' codex json_refresh_token
  assert_status 1
  assert_contains "invalid auth payload for codex"
  assert_not_contains "Using legacy Codex auth refresh fallback"
}

test_sync_runtime_auth_to_container_uses_runtime_parameters() {
  begin_test "sync_runtime_auth_to_container uses runtime-specific auth parameters"

  load_codexctl_functions

  local observed_runtime=""
  local observed_format=""
  local observed_missing_message=""
  local written_payload=""

  ensure_keychain() {
    observed_runtime="$1"
    observed_format="$2"
    return 0
  }
  keychain_auth_info() {
    printf 'unit-token\t2026-04-17T00:00:00Z\n'
  }
  keychain_auth_blob() {
    printf '{"refresh_token":"unit-token","last_refresh":"2026-04-17T00:00:00Z"}'
  }
  container_auth_info() {
    printf '\t\n'
  }
  write_auth_blob_to_container() {
    local name="$1" payload="$2" runtime="$3" auth_format="$4"
    observed_runtime="$runtime"
    observed_format="$auth_format"
    written_payload="$payload"
    [ "$name" = "unit-test-container" ] || fail "Unexpected container name: $name"
  }

  run_capture sync_runtime_auth_to_container unit-test-container codex json_refresh_token "missing auth"
  assert_status 0
  [ "$observed_runtime" = "codex" ] || fail "Expected runtime codex, got: $observed_runtime"
  [ "$observed_format" = "json_refresh_token" ] || fail "Expected auth format json_refresh_token, got: $observed_format"
  printf '%s' "$written_payload" | jq -er '.refresh_token == "unit-token"' >/dev/null || fail "Expected runtime auth payload to be written"
}

test_sync_runtime_auth_from_container_uses_runtime_parameters() {
  begin_test "sync_runtime_auth_from_container uses runtime-specific auth parameters"

  load_codexctl_functions

  local temp_dir
  local observed_runtime=""
  local observed_format=""
  local written_blob_file=""

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-auth-sync-from.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  written_blob_file="$temp_dir/written-auth.json"

  container_auth_info() {
    printf 'unit-token\t2026-04-17T02:00:00Z\n'
  }
  ensure_keychain() {
    observed_runtime="$1"
    observed_format="$2"
    return 0
  }
  keychain_auth_info() {
    printf 'unit-token\t2026-04-17T01:00:00Z\n'
  }
  container_auth_blob() {
    local name="$1" runtime="$2" auth_format="$3"
    observed_runtime="$runtime"
    observed_format="$auth_format"
    [ "$name" = "unit-test-container" ] || fail "Unexpected container name: $name"
    printf '{"refresh_token":"unit-token","last_refresh":"2026-04-17T02:00:00Z"}'
  }
  write_keychain_auth_blob() {
    local runtime="$1" auth_format="$2"
    observed_runtime="$runtime"
    observed_format="$auth_format"
    cat >"$written_blob_file"
  }

  run_capture sync_runtime_auth_from_container unit-test-container codex json_refresh_token
  assert_status 0
  [ "$observed_runtime" = "codex" ] || fail "Expected runtime codex, got: $observed_runtime"
  [ "$observed_format" = "json_refresh_token" ] || fail "Expected auth format json_refresh_token, got: $observed_format"
  [ -f "$written_blob_file" ] || fail "Expected container auth blob to be written back to keychain"
  jq -er '.last_refresh == "2026-04-17T02:00:00Z"' "$written_blob_file" >/dev/null || fail "Expected container auth blob to be written back to keychain"
}

test_auth_info_from_json_parses_claude_oauth_payload() {
  begin_test "auth_info_from_json parses claude oauth payloads"

  load_codexctl_functions
  python_exec() {
    jq -r '
      . as $payload
      | ($payload.claudeAiOauth.refreshToken // "") as $token
      | ($payload.claudeAiOauth.expiresAt // "") as $expires_at
      | "\($token)\t\($expires_at)"
    '
  }

  RUN_OUTPUT="$(printf '%s' '{"claudeAiOauth":{"refreshToken":"claude-refresh","expiresAt":1776462236852}}' | auth_info_from_json)"
  RUN_STATUS=0
  [ "$RUN_OUTPUT" = $'claude-refresh\t1776462236852' ] || fail "Expected Claude auth info tuple, got: $RUN_OUTPUT"
}

test_run_auth_flow_uses_agent_sh_auth_contract() {
  begin_test "run_auth_flow uses agent.sh auth login and auth read"

  load_codexctl_functions

  local temp_dir
  local fake_keychain
  local stored_blob_file
  local exec_log_file
  local read_count_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-auth.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  fake_keychain="$temp_dir/fake-keychain.sh"
  stored_blob_file="$temp_dir/stored-auth.json"
  exec_log_file="$temp_dir/exec.log"
  read_count_file="$temp_dir/read-count"
  printf '0' >"$read_count_file"

  cat >"$fake_keychain" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  write)
    cat >"$stored_blob_file"
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$fake_keychain"

  KEYCHAIN_SCRIPT="$fake_keychain"
  local refresh_log_file
  refresh_log_file="$temp_dir/refresh.log"
  container_exists() { return 1; }
  refresh_container_file() { printf 'file %s -> %s\n' "$2" "$3" >>"$refresh_log_file"; }
  refresh_container_tree() { printf 'tree %s -> %s\n' "$2" "$3" >>"$refresh_log_file"; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      create|start|stop|rm)
        return 0
        ;;
      exec)
        shift
        if [ "$1" = "-it" ]; then
          shift
        fi
        if [ "$1" = "unit-auth-container" ]; then
          shift
        fi
        if [ "${1:-}" = "setpriv" ]; then
          shift 6
        fi
        printf '%s\n' "$*" >>"$exec_log_file"
        if [ "$*" = "bash /usr/local/bin/agent.sh runtime info codex" ]; then
          printf '{"runtime":"codex","installed":true,"auth_formats":["json_refresh_token"],"capabilities":{"auth_login":true,"auth_read":true,"auth_write":true}}'
        fi
        if [ "$*" = "bash /usr/local/bin/agent.sh auth read codex json_refresh_token" ]; then
          local read_count
          read_count="$(cat "$read_count_file")"
          read_count=$((read_count + 1))
          printf '%s' "$read_count" >"$read_count_file"
          if [ "$read_count" -eq 1 ]; then
            return 0
          fi
          printf '{"refresh_token":"auth-flow-token","last_refresh":"2026-04-17T01:02:03Z"}'
        fi
        return 0
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture run_auth_flow agent-plain unit-auth-container
  assert_status 0
  grep -Fq "file $SCRIPT_DIR/agent.sh -> /usr/local/bin/agent.sh" "$refresh_log_file" || fail "Expected auth container refresh of agent.sh"
  grep -Fq "tree $SCRIPT_DIR/runtimes.d -> /etc/agentctl/runtimes.d" "$refresh_log_file" || fail "Expected auth container refresh of runtime manifests"
  grep -Fq "tree $SCRIPT_DIR/features.d -> /etc/agentctl/features.d" "$refresh_log_file" || fail "Expected auth container refresh of feature manifests"
  grep -Fq 'bash /usr/local/bin/agent.sh runtime info codex' "$exec_log_file" || fail "Expected runtime info inspection before auth flow"
  grep -Fq 'bash -lc exec bash /usr/local/bin/agent.sh auth login codex' "$exec_log_file" || fail "Expected auth login via agent.sh"
  grep -Fq 'bash /usr/local/bin/agent.sh auth read codex json_refresh_token' "$exec_log_file" || fail "Expected auth read via agent.sh"
  [ -f "$stored_blob_file" ] || fail "Expected auth blob to be written to fake keychain"
  grep -Fq '"refresh_token":"auth-flow-token"' "$stored_blob_file" || fail "Expected auth blob from agent.sh auth read"
}

test_run_auth_flow_skips_keychain_write_when_auth_unchanged() {
  begin_test "run_auth_flow leaves Keychain untouched when auth state is unchanged"

  local temp_dir
  local unit_script
  local fake_keychain
  local stored_blob_file
  local exec_log_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-auth-unchanged.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"
  fake_keychain="$temp_dir/fake-keychain.sh"
  stored_blob_file="$temp_dir/stored-auth.json"
  exec_log_file="$temp_dir/exec.log"

  cat >"$fake_keychain" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  write)
    cat >"$stored_blob_file"
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$fake_keychain"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$CODEXCTL"
KEYCHAIN_SCRIPT="$fake_keychain"
refresh_container_file() { :; }
refresh_container_tree() { :; }
container_exists() { return 1; }
CONTAINER_CMD=container
container() {
  case "\$1" in
    create|start|stop|rm)
      return 0
      ;;
    exec)
      shift
      if [ "\$1" = "-it" ]; then
        shift
      fi
      if [ "\$1" = "unit-auth-container" ]; then
        shift
      fi
      if [ "\${1:-}" = "setpriv" ]; then
        shift 6
      fi
      printf '%s\n' "\$*" >>"$exec_log_file"
      if [ "\$*" = "bash /usr/local/bin/agent.sh runtime info codex" ]; then
        printf '{"runtime":"codex","installed":true,"auth_formats":["json_refresh_token"],"capabilities":{"auth_login":true,"auth_read":true,"auth_write":true}}'
      fi
      if [ "\$*" = "bash /usr/local/bin/agent.sh auth read codex json_refresh_token" ]; then
        printf '{"refresh_token":"same-token","last_refresh":"2026-04-17T01:02:03Z"}'
      fi
      return 0
      ;;
    *)
      echo "Unexpected container invocation: \$*" >&2
      exit 1
      ;;
  esac
}
run_auth_flow agent-plain unit-auth-container codex
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "Runtime auth state did not change; leaving Keychain untouched: codex"
  [ ! -f "$stored_blob_file" ] || fail "Did not expect Keychain write when auth is unchanged"
}

test_run_auth_flow_rejects_runtime_without_host_auth_support() {
  begin_test "run_auth_flow rejects runtimes without host auth support"

  local temp_dir
  local unit_script
  local fake_keychain
  local exec_log_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-auth-unsupported.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"
  fake_keychain="$temp_dir/fake-keychain.sh"
  exec_log_file="$temp_dir/exec.log"

  cat >"$fake_keychain" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$fake_keychain"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$CODEXCTL"
KEYCHAIN_SCRIPT="$fake_keychain"
refresh_container_file() { :; }
refresh_container_tree() { :; }
container_exists() { return 1; }
CONTAINER_CMD=container
container() {
  case "\$1" in
    create|start|stop|rm)
      return 0
      ;;
    exec)
      shift
      if [ "\$1" = "-it" ]; then
        shift
      fi
      if [ "\$1" = "unit-auth-container" ]; then
        shift
      fi
      if [ "\${1:-}" = "setpriv" ]; then
        shift 6
      fi
      printf '%s\n' "\$*" >>"$exec_log_file"
      if [ "\$*" = "bash /usr/local/bin/agent.sh runtime info claude" ]; then
        printf '{"runtime":"claude","installed":true,"auth_formats":[],"capabilities":{"install":false,"auth_login":false,"auth_read":false,"auth_write":false}}'
      fi
      return 0
      ;;
    *)
      echo "Unexpected container invocation: \$*" >&2
      exit 1
      ;;
  esac
}
run_auth_flow agent-plain unit-auth-container claude
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "Runtime does not support host-managed auth flow yet: claude"
  grep -Fq 'bash /usr/local/bin/agent.sh runtime info claude' "$exec_log_file" || fail "Expected runtime info inspection for unsupported runtime"
  if grep -Fq 'auth login claude' "$exec_log_file"; then
    fail "Did not expect auth login attempt for unsupported runtime"
  fi
}

test_run_auth_flow_installs_runtime_before_claude_auth() {
  begin_test "run_auth_flow installs claude before interactive auth when needed"

  local temp_dir
  local unit_script
  local fake_keychain
  local stored_blob_file
  local exec_log_file
  local create_log_file
  local runtime_info_count_file
  local auth_read_count_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-auth-claude.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"
  fake_keychain="$temp_dir/fake-keychain.sh"
  stored_blob_file="$temp_dir/stored-auth.json"
  exec_log_file="$temp_dir/exec.log"
  create_log_file="$temp_dir/create.log"
  runtime_info_count_file="$temp_dir/runtime-info-count"
  auth_read_count_file="$temp_dir/auth-read-count"
  printf '0' >"$runtime_info_count_file"
  printf '0' >"$auth_read_count_file"

  cat >"$fake_keychain" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  write)
    cat >"$stored_blob_file"
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$fake_keychain"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$CODEXCTL"
KEYCHAIN_SCRIPT="$fake_keychain"
refresh_container_file() { :; }
refresh_container_tree() { :; }
container_exists() { return 1; }
CONTAINER_CMD=container
container() {
  case "\$1" in
    create|start|stop|rm)
      if [ "\$1" = "create" ]; then
        printf '%s\n' "\$*" >>"$create_log_file"
      fi
      return 0
      ;;
    exec)
      shift
      if [ "\$1" = "-it" ]; then
        shift
      fi
      if [ "\$1" = "unit-auth-container" ]; then
        shift
      fi
      if [ "\${1:-}" = "setpriv" ]; then
        shift 6
      fi
      printf '%s\n' "\$*" >>"$exec_log_file"
      if [ "\$*" = "bash /usr/local/bin/agent.sh runtime info claude" ]; then
        runtime_info_calls="\$(cat "$runtime_info_count_file")"
        runtime_info_calls=\$((runtime_info_calls + 1))
        printf '%s' "\$runtime_info_calls" >"$runtime_info_count_file"
        if [ "\$runtime_info_calls" -eq 1 ]; then
          printf '{"runtime":"claude","installed":false,"auth_formats":["claude_ai_oauth_json"],"capabilities":{"install":true,"auth_login":true,"auth_read":true,"auth_write":true}}'
        else
          printf '{"runtime":"claude","installed":true,"auth_formats":["claude_ai_oauth_json"],"capabilities":{"install":true,"auth_login":true,"auth_read":true,"auth_write":true}}'
        fi
      fi
      if [ "\$*" = "bash /usr/local/bin/agent.sh auth read claude claude_ai_oauth_json" ]; then
        auth_read_calls="\$(cat "$auth_read_count_file")"
        auth_read_calls=\$((auth_read_calls + 1))
        printf '%s' "\$auth_read_calls" >"$auth_read_count_file"
        if [ "\$auth_read_calls" -ge 2 ]; then
          printf '{"claudeAiOauth":{"refreshToken":"claude-refresh","expiresAt":1776462236852}}'
        fi
      fi
      return 0
      ;;
    *)
      echo "Unexpected container invocation: \$*" >&2
      exit 1
      ;;
  esac
}
run_auth_flow agent-plain unit-auth-container claude
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 0
  grep -Fq -- 'create -t -m 4G --name unit-auth-container' "$create_log_file" || fail "Expected Claude auth container to request 4G memory"
  grep -Fq 'bash /usr/local/bin/agent.sh runtime install claude' "$exec_log_file" || fail "Expected runtime install before Claude auth flow"
  grep -Fq 'bash -lc exec bash /usr/local/bin/agent.sh auth login claude' "$exec_log_file" || fail "Expected Claude auth login via agent.sh"
  [ -f "$stored_blob_file" ] || fail "Expected Claude auth blob to be written to fake keychain"
  grep -Fq '"refreshToken":"claude-refresh"' "$stored_blob_file" || fail "Expected Claude auth blob in keychain write"
}

test_run_keychain_for_runtime_uses_runtime_specific_codex_slot() {
  begin_test "run_keychain_for_runtime uses the runtime-specific codex slot first"

  load_codexctl_functions

  local temp_dir
  local fake_keychain
  local env_log_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-keychain-codex.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  fake_keychain="$temp_dir/fake-keychain.sh"
  env_log_file="$temp_dir/env.log"

  cat >"$fake_keychain" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'service=%s\naccount=%s\ncmd=%s\n' "\${KEYCHAIN_SERVICE_NAME:-}" "\${KEYCHAIN_ACCOUNT_NAME:-}" "\${1:-}" >"$env_log_file"
case "\${1:-}" in
  verify) exit 0 ;;
  read) printf '{"refresh_token":"token"}' ;;
  write) cat >/dev/null ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$fake_keychain"

  KEYCHAIN_SCRIPT="$fake_keychain"
  run_capture run_keychain_for_runtime codex json_refresh_token verify
  assert_status 0
  grep -Fq 'service=agentctl-codex-json_refresh_token-auth' "$env_log_file" || fail "Expected runtime-specific codex keychain service name"
  grep -Fq 'account=runtime-codex-json_refresh_token-auth' "$env_log_file" || fail "Expected runtime-specific codex keychain account name"
}

test_run_keychain_for_runtime_uses_runtime_specific_slot() {
  begin_test "run_keychain_for_runtime uses runtime-specific keychain slots"

  load_codexctl_functions

  local temp_dir
  local fake_keychain
  local env_log_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-keychain-runtime.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  fake_keychain="$temp_dir/fake-keychain.sh"
  env_log_file="$temp_dir/env.log"

  cat >"$fake_keychain" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'service=%s\naccount=%s\ncmd=%s\n' "\${KEYCHAIN_SERVICE_NAME:-}" "\${KEYCHAIN_ACCOUNT_NAME:-}" "\${1:-}" >"$env_log_file"
case "\${1:-}" in
  verify) exit 0 ;;
  read) printf '{"refresh_token":"token"}' ;;
  write) cat >/dev/null ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$fake_keychain"

  KEYCHAIN_SCRIPT="$fake_keychain"
  run_capture run_keychain_for_runtime claude opaque_blob verify
  assert_status 0
  grep -Fq 'service=agentctl-claude-opaque_blob-auth' "$env_log_file" || fail "Expected runtime-specific keychain service name"
  grep -Fq 'account=runtime-claude-opaque_blob-auth' "$env_log_file" || fail "Expected runtime-specific keychain account name"
}

test_rm_force_stops_running_container_before_remove() {
  begin_test "rm --force stops a running container before remove"

  load_codexctl_functions

  local stop_calls=0
  local rm_calls=0

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_running() { [ "$1" = "unit-test-container" ]; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      rm)
        rm_calls=$((rm_calls + 1))
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture simple_name_cmd rm --name unit-test-container --force
  assert_status 0
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
  [ "$rm_calls" -eq 1 ] || fail "Expected 1 rm call, got: $rm_calls"
}

test_image_ref_for_runtime_falls_back_to_legacy_when_present() {
  begin_test "image_ref_for_runtime prefers canonical names but falls back to legacy refs"

  load_codexctl_functions

  image_exists() {
    [ "$1" = "codex" ]
  }

  [ "$(image_ref_for_runtime codex)" = "codex" ] || fail "Expected fallback to legacy codex image"
}

test_ls_filters_non_codex_containers() {
  begin_test "ls_cmd hides non-Codex runtime containers"

  load_codexctl_functions

  require_container() { return 0; }
  container_list_all() {
    cat <<'EOF'
ID                               IMAGE                                                OS     ARCH   STATE    ADDR              CPUS  MEMORY   STARTED
converter                        docker.io/library/debian:latest                      linux  amd64  stopped                    4     1024 MB
buildkit                         ghcr.io/apple/container-builder-shim/builder:0.11.0  linux  arm64  running  192.168.64.10/24  2     2048 MB  2026-04-06T10:40:58Z
codex-python                     codex-python:latest                                  linux  arm64  stopped                    4     1024 MB
codex-local-codex-container      codex:latest                                         linux  arm64  running  192.168.64.12/24  4     1024 MB  2026-04-06T10:59:42Z
codex-custom                     my-team/codex-custom:latest                          linux  arm64  stopped                    4     1024 MB
EOF
  }

  run_capture ls_cmd
  assert_status 0
  assert_contains "ID                               IMAGE"
  assert_contains "codex-python                     codex-python:latest"
  assert_contains "codex-local-codex-container      codex:latest"
  assert_contains "codex-custom                     my-team/codex-custom:latest"
  assert_not_contains "buildkit"
  assert_not_contains "converter"
}

test_upgrade_backup_support_check() {
  begin_test "upgrade backup support check requires export support"

  load_codexctl_functions

  local fake_dir
  local fake_container
  local old_path

  fake_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-fake-container.XXXXXX")"
  register_dir_cleanup "$fake_dir"
  fake_container="$fake_dir/container"
  old_path="$PATH"

  cat >"$fake_container" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = "export" ] && [ "${2:-}" = "--help" ]; then
  cat <<'OUT'
OVERVIEW: Export a container's filesystem as a tar archive
OPTIONS:
  -o, --output <output>   Pathname for the saved container filesystem
OUT
  exit 0
fi

exit 0
EOF
  chmod +x "$fake_container"

  PATH="$fake_dir:$old_path"
  CONTAINER_CMD=container
  unset -f container 2>/dev/null || true

  run_capture require_container_backup_support
  assert_status 0
}

test_run_rejects_resource_flags_for_existing_container() {
  begin_test "run rejects --cpu/--mem for existing containers"

  local fake_dir
  local fake_container
  local old_path

  fake_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-fake-container.XXXXXX")"
  register_dir_cleanup "$fake_dir"
  fake_container="$fake_dir/container"
  old_path="$PATH"

  cat >"$fake_container" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "ls" ] && [ "${2:-}" = "-a" ]; then
  cat <<'OUT'
ID                               IMAGE
unit-test-container              agent-plain:latest
OUT
  exit 0
fi

exit 0
EOF
  chmod +x "$fake_container"

  PATH="$fake_dir:$old_path"

  run_capture "$AGENTCTL" run --name unit-test-container --workdir "$TEST_ROOT" --cpu 4 --mem 8G --cmd true
  assert_status 1
  assert_contains "Error: --cpu and --mem only apply when creating a new container."
  assert_contains "agentctl upgrade --name unit-test-container --image $DEFAULT_IMAGE --cpu 4 --mem 8G"
}

test_upgrade_rejects_no_backup_for_legacy_source() {
  begin_test "upgrade rejects --no-backup for legacy source containers"

  local harness
  local script

  harness="$(mktemp "${TMPDIR:-/tmp}/codexctl-unit.XXXXXX")"
  register_dir_cleanup "$harness"
  sed -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=\"$TEST_ROOT\"#" \
    -e '/^cmd="${1:-}"/,$d' \
    "$CODEXCTL" >"$harness"

  script="$(mktemp "${TMPDIR:-/tmp}/codexctl-unit-script.XXXXXX")"
  register_dir_cleanup "$script"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$harness"
require_container() { return 0; }
default_name() { printf 'unit-test-container\n'; }
container_exists() { [ "\$1" = "unit-test-container" ]; }
container_running() { return 1; }
image_exists() { return 0; }
require_container_backup_support() { return 0; }
warn_upgrade_package_loss() { :; }
upgrade_added_runtimes_json() { printf '[]\n'; }
upgrade_added_features_json() { printf '[]\n'; }
image_system_manifest_json() { return 1; }
collect_upgrade_container_preflight() {
  UPGRADE_PREFLIGHT_CONTAINER_MANIFEST='{"package_manager":"apk","packages":[]}'
  UPGRADE_PREFLIGHT_BASELINE_MANIFEST=''
  UPGRADE_PREFLIGHT_SOURCE_SUPPORTS_STATE_CONTRACT=0
}
CONTAINER_CMD=container
container() {
  case "\$1" in
    inspect)
      printf 'placeholder\n'
      ;;
    *)
      echo "unexpected container invocation: \$*" >&2
      exit 1
      ;;
  esac
}
container_upgrade_info() {
  printf 'agent-plain\t%s\trw\t2\t4G\n' "$TEST_ROOT"
}
upgrade_cmd --name unit-test-container --no-backup
EOF
  chmod +x "$script"

  run_capture bash "$script"
  assert_status 1
  assert_contains "Legacy source containers require a backup image for upgrade safety. Re-run without --no-backup."
}

test_upgrade_uses_explicit_resource_overrides() {
  begin_test "upgrade prefers explicit --cpu/--mem over inspected values"

  load_codexctl_functions

  local create_args=""
  local start_calls=0
  local stop_calls=0
  local rm_calls=0

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  require_container_backup_support() { return 0; }
  container_supports_state_contract() { return 0; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  image_exists() { return 0; }
  codex_agents_state() { printf 'missing\n'; }
  backup_codex_config() { :; }
  restore_codex_config() { :; }
  persist_container_system_manifest_baseline() { :; }
  persist_container_system_manifest_baseline_from_image() { :; }
  collect_upgrade_container_preflight() {
    UPGRADE_PREFLIGHT_CONTAINER_MANIFEST='{"package_manager":"apk","packages":[]}'
    UPGRADE_PREFLIGHT_BASELINE_MANIFEST=''
    UPGRADE_PREFLIGHT_SOURCE_SUPPORTS_STATE_CONTRACT=1
  }
  image_system_manifest_json() { return 1; }
  sanitize_image_name() { printf '%s\n' "$1"; }
  build_backup_image_from_export() { :; }
  date() { printf '20260406120000\n'; }
  trap() { :; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      inspect)
        printf 'placeholder\n'
        ;;
      create)
        shift
        create_args="$(printf '%s\n' "$*")"
        ;;
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      rm)
        rm_calls=$((rm_calls + 1))
        ;;
      export)
        fail "export should not be called for --no-backup"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'codex\t%s\trw\t2\t4G\n' "$TEST_ROOT"
  }

  run_capture upgrade_cmd --name unit-test-container --cpu 6 --mem 12G --no-backup
  assert_status 0
  assert_contains "Upgrade complete: unit-test-container (backup skipped)"
  printf '%s\n' "$create_args" | grep -F -- "-c 6" >/dev/null || fail "Expected create args to include overridden cpu, got: $create_args"
  printf '%s\n' "$create_args" | grep -F -- "-m 12G" >/dev/null || fail "Expected create args to include overridden mem, got: $create_args"
  printf '%s\n' "$create_args" | grep -F -- "--name unit-test-container" >/dev/null || fail "Expected create args to include container name, got: $create_args"
  [ "$start_calls" -eq 2 ] || fail "Expected 2 start calls, got: $start_calls"
  [ "$stop_calls" -eq 2 ] || fail "Expected 2 stop calls, got: $stop_calls"
  [ "$rm_calls" -eq 1 ] || fail "Expected 1 rm call, got: $rm_calls"
}

test_upgrade_can_rename_container_during_recreation() {
  begin_test "upgrade can recreate the container under a new name"

  load_codexctl_functions

  local create_args=""
  local start_log=""
  local stop_log=""
  local rm_log=""
  local persisted_baseline_name=""
  local restored_name=""

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  require_container_backup_support() { return 0; }
  warn_upgrade_package_loss() { :; }
  container_supports_state_contract() { return 0; }
  container_exists() {
    case "$1" in
      unit-test-container) return 0 ;;
      renamed-container) return 1 ;;
      *) return 1 ;;
    esac
  }
  container_running() { return 1; }
  image_exists() { return 0; }
  codex_agents_state() { printf 'missing\n'; }
  backup_codex_config() { :; }
  restore_codex_config() { restored_name="$1"; }
  persist_container_system_manifest_baseline_from_image() { persisted_baseline_name="$1"; }
  collect_upgrade_container_preflight() {
    UPGRADE_PREFLIGHT_CONTAINER_MANIFEST='{"package_manager":"apk","packages":[]}'
    UPGRADE_PREFLIGHT_BASELINE_MANIFEST=''
    UPGRADE_PREFLIGHT_SOURCE_SUPPORTS_STATE_CONTRACT=1
  }
  image_system_manifest_json() { return 1; }
  sanitize_image_name() { printf '%s\n' "$1"; }
  build_backup_image_from_export() { :; }
  date() { printf '20260406120000\n'; }
  trap() { :; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      inspect)
        printf 'placeholder\n'
        ;;
      create)
        shift
        create_args="$(printf '%s\n' "$*")"
        ;;
      start)
        start_log="${start_log}${2}"$'\n'
        ;;
      stop)
        stop_log="${stop_log}${2}"$'\n'
        ;;
      rm)
        rm_log="${rm_log}${2}"$'\n'
        ;;
      export)
        fail "export should not be called for --no-backup"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'codex\t%s\trw\t2\t4G\n' "$TEST_ROOT"
  }

  run_capture upgrade_cmd --name unit-test-container --new-name renamed-container --no-backup
  assert_status 0
  assert_contains "Removing container: unit-test-container"
  assert_contains "Recreating container: renamed-container"
  assert_contains "Starting container: renamed-container"
  assert_contains "Restoring user state into renamed-container"
  assert_contains "Upgrade complete: renamed-container (backup skipped)"
  assert_contains "run --name renamed-container --reset-config"
  printf '%s\n' "$create_args" | grep -F -- "--name renamed-container" >/dev/null || fail "Expected create args to include renamed container, got: $create_args"
  printf '%s\n' "$rm_log" | grep -Fx -- "unit-test-container" >/dev/null || fail "Expected removal of source container, got: $rm_log"
  printf '%s\n' "$start_log" | grep -Fx -- "unit-test-container" >/dev/null || fail "Expected source container to start for backup, got: $start_log"
  printf '%s\n' "$start_log" | grep -Fx -- "renamed-container" >/dev/null || fail "Expected renamed container to start after recreation, got: $start_log"
  printf '%s\n' "$stop_log" | grep -Fx -- "unit-test-container" >/dev/null || fail "Expected source container to stop after backup, got: $stop_log"
  printf '%s\n' "$stop_log" | grep -Fx -- "renamed-container" >/dev/null || fail "Expected renamed container to stop after recreation, got: $stop_log"
  [ "$persisted_baseline_name" = "renamed-container" ] || fail "Expected baseline persistence on renamed container, got: $persisted_baseline_name"
  [ "$restored_name" = "renamed-container" ] || fail "Expected config restore on renamed container, got: $restored_name"
}

test_upgrade_copy_keeps_running_source_container() {
  begin_test "upgrade copy keeps the source container and creates a new target"

  load_codexctl_functions

  local create_args=""
  local start_log=""
  local stop_log=""
  local rm_log=""
  local persisted_baseline_name=""
  local restored_name=""

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  warn_upgrade_package_loss() { :; }
  container_supports_state_contract() { return 0; }
  container_exists() {
    case "$1" in
      unit-test-container) return 0 ;;
      copied-container) return 1 ;;
      *) return 1 ;;
    esac
  }
  container_running() {
    [ "$1" = "unit-test-container" ]
  }
  image_exists() { return 0; }
  backup_codex_config() { :; }
  restore_codex_config() { restored_name="$1"; }
  persist_container_system_manifest_baseline_from_image() { persisted_baseline_name="$1"; }
  collect_upgrade_container_preflight() {
    UPGRADE_PREFLIGHT_CONTAINER_MANIFEST='{"package_manager":"apk","packages":[]}'
    UPGRADE_PREFLIGHT_BASELINE_MANIFEST=''
    UPGRADE_PREFLIGHT_SOURCE_SUPPORTS_STATE_CONTRACT=1
  }
  image_system_manifest_json() { return 1; }
  sanitize_image_name() { printf '%s\n' "$1"; }
  build_backup_image_from_export() { fail "copy mode should not build a backup image"; }
  trap() { :; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      inspect)
        printf 'placeholder\n'
        ;;
      create)
        shift
        create_args="$(printf '%s\n' "$*")"
        ;;
      start)
        start_log="${start_log}${2}"$'\n'
        ;;
      stop)
        stop_log="${stop_log}${2}"$'\n'
        ;;
      rm)
        rm_log="${rm_log}${2}"$'\n'
        ;;
      export)
        fail "copy mode should not export a backup image"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'codex\t%s\trw\t2\t4G\n' "$TEST_ROOT"
  }

  run_capture upgrade_cmd --name unit-test-container --new-name copied-container --copy
  assert_status 0
  assert_contains "Backing up user state from unit-test-container"
  assert_contains "Creating copy: copied-container"
  assert_contains "Starting container: copied-container"
  assert_contains "Restoring user state into copied-container"
  assert_contains "Copy complete: copied-container (source preserved)"
  printf '%s\n' "$create_args" | grep -F -- "--name copied-container" >/dev/null || fail "Expected create args to include copied container, got: $create_args"
  [ -z "$rm_log" ] || fail "Expected source container to remain present, got rm log: $rm_log"
  if printf '%s\n' "$stop_log" | grep -Fx -- "unit-test-container" >/dev/null; then
    fail "Expected running source container to remain running during copy"
  fi
  printf '%s\n' "$start_log" | grep -Fx -- "copied-container" >/dev/null || fail "Expected copied container to start, got: $start_log"
  [ "$persisted_baseline_name" = "copied-container" ] || fail "Expected baseline persistence on copied container, got: $persisted_baseline_name"
  [ "$restored_name" = "copied-container" ] || fail "Expected restore on copied container, got: $restored_name"
}

test_upgrade_copy_requires_new_name() {
  begin_test "upgrade copy requires a new target name"

  local harness
  local script

  harness="$(mktemp "${TMPDIR:-/tmp}/codexctl-unit.XXXXXX")"
  register_dir_cleanup "$harness"
  sed -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=\"$TEST_ROOT\"#" \
    -e '/^cmd="${1:-}"/,$d' \
    "$CODEXCTL" >"$harness"

  script="$(mktemp "${TMPDIR:-/tmp}/codexctl-unit-script.XXXXXX")"
  register_dir_cleanup "$script"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "$harness"
require_container() { return 0; }
default_name() { printf 'unit-test-container\n'; }
upgrade_cmd --name unit-test-container --copy
EOF
  chmod +x "$script"

  run_capture bash "$script"
  assert_status 1
  assert_contains "Copy mode requires --new-name."
}

test_upgrade_dry_run_reports_plan_without_recreating_container() {
  begin_test "upgrade dry-run reports the plan without recreating the container"

  load_codexctl_functions

  local create_calls=0
  local export_calls=0
  local start_calls=0
  local stop_calls=0
  local rm_calls=0

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  require_container_backup_support() { return 0; }
  container_exists() {
    case "$1" in
      unit-test-container) return 0 ;;
      renamed-container) return 1 ;;
      *) return 1 ;;
    esac
  }
  container_running() { return 1; }
  image_exists() { return 0; }
  sanitize_image_name() { printf '%s\n' "$1"; }
  date() { printf '20260406120000\n'; }
  trap() { :; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      inspect)
        printf 'placeholder\n'
        ;;
      create)
        create_calls=$((create_calls + 1))
        ;;
      export)
        export_calls=$((export_calls + 1))
        ;;
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      rm)
        rm_calls=$((rm_calls + 1))
        ;;
      exec)
        fail "dry-run should not exec into the source container when the original workdir is missing"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'agent-python:latest\t/does/not/exist\tro\t2\t4294967296\n'
  }

  run_capture upgrade_cmd --name unit-test-container --new-name renamed-container --image agent-python --workdir "$TEST_ROOT" --dry-run
  assert_status 0
  assert_contains "Preparing upgrade preflight: unit-test-container -> renamed-container"
  assert_contains "Warning: Skipping package-loss warning because original /workdir source does not exist and unit-test-container is stopped"
  assert_contains "Dry run: upgrade plan for unit-test-container -> renamed-container"
  assert_contains "  Source image: agent-python"
  assert_contains "  Target image: agent-python"
  assert_contains "  Source workdir: /does/not/exist"
  assert_contains "  Target workdir: $TEST_ROOT"
  assert_contains "  Mount mode: read-only"
  assert_contains "  CPU: 2 -> 2"
  assert_contains "  Memory: 4G -> 4G"
  assert_contains "  Config backup: export existing container filesystem and recover user state from it"
  assert_contains "  Backup image: renamed-container-backup-20260406120000"
  assert_contains "  Actions: remove unit-test-container and recreate it as renamed-container"
  assert_contains "Dry run complete: no container changes applied"
  [ "$create_calls" -eq 0 ] || fail "Expected no create calls during dry-run, got: $create_calls"
  [ "$export_calls" -eq 0 ] || fail "Expected no export calls during dry-run, got: $export_calls"
  [ "$start_calls" -eq 0 ] || fail "Expected no start calls during dry-run, got: $start_calls"
  [ "$stop_calls" -eq 0 ] || fail "Expected no stop calls during dry-run, got: $stop_calls"
  [ "$rm_calls" -eq 0 ] || fail "Expected no rm calls during dry-run, got: $rm_calls"
}

test_upgrade_copy_dry_run_reports_copy_plan() {
  begin_test "upgrade copy dry-run reports copy actions without recreating containers"

  load_codexctl_functions

  local create_calls=0
  local export_calls=0
  local start_calls=0
  local stop_calls=0
  local rm_calls=0

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  warn_upgrade_package_loss() { :; }
  collect_upgrade_container_preflight() {
    UPGRADE_PREFLIGHT_CONTAINER_MANIFEST='{"package_manager":"apk","packages":[]}'
    UPGRADE_PREFLIGHT_BASELINE_MANIFEST=''
    UPGRADE_PREFLIGHT_SOURCE_SUPPORTS_STATE_CONTRACT=1
  }
  image_system_manifest_json() { return 1; }
  container_exists() {
    case "$1" in
      unit-test-container) return 0 ;;
      copied-container) return 1 ;;
      *) return 1 ;;
    esac
  }
  container_running() { [ "$1" = "unit-test-container" ]; }
  image_exists() { return 0; }
  sanitize_image_name() { printf '%s\n' "$1"; }
  trap() { :; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      inspect)
        printf 'placeholder\n'
        ;;
      create)
        create_calls=$((create_calls + 1))
        ;;
      export)
        export_calls=$((export_calls + 1))
        ;;
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      rm)
        rm_calls=$((rm_calls + 1))
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'agent-python:latest\t%s\tro\t2\t4294967296\n' "$TEST_ROOT"
  }

  run_capture upgrade_cmd --name unit-test-container --new-name copied-container --copy --image agent-python --dry-run
  assert_status 0
  assert_contains "Preparing upgrade preflight: unit-test-container -> copied-container"
  assert_contains "Dry run: upgrade plan for unit-test-container -> copied-container"
  assert_contains "  Backup image: not needed (source preserved)"
  assert_contains "  Actions: keep unit-test-container and create copied-container as a copy"
  assert_contains "Dry run complete: no container changes applied"
  [ "$create_calls" -eq 0 ] || fail "Expected no create calls during dry-run, got: $create_calls"
  [ "$export_calls" -eq 0 ] || fail "Expected no export calls during dry-run, got: $export_calls"
  [ "$start_calls" -eq 0 ] || fail "Expected no start calls during dry-run, got: $start_calls"
  [ "$stop_calls" -eq 0 ] || fail "Expected no stop calls during dry-run, got: $stop_calls"
  [ "$rm_calls" -eq 0 ] || fail "Expected no rm calls during dry-run, got: $rm_calls"
}

test_upgrade_warns_about_added_packages_missing_from_target_image() {
  begin_test "upgrade warns only for extra packages absent from the target image"

  load_codexctl_functions

  local create_log=""
  local start_calls=0
  local stop_calls=0
  local rm_calls=0

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  require_container_backup_support() { return 0; }
  container_supports_state_contract() { return 0; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  image_exists() {
    case "$1" in
      agent-plain|agent-python) return 0 ;;
      *) return 1 ;;
    esac
  }
  codex_agents_state() { printf 'missing\n'; }
  backup_codex_config() { :; }
  restore_codex_config() { :; }
  persist_container_system_manifest_baseline() { :; }
  persist_container_system_manifest_baseline_from_image() { :; }
  collect_upgrade_container_preflight() {
    UPGRADE_PREFLIGHT_CONTAINER_MANIFEST='{"package_manager":"apk","packages":["bash","git","curl","ripgrep"]}'
    UPGRADE_PREFLIGHT_BASELINE_MANIFEST=''
    UPGRADE_PREFLIGHT_SOURCE_SUPPORTS_STATE_CONTRACT=1
  }
  sanitize_image_name() { printf '%s\n' "$1"; }
  build_backup_image_from_export() { :; }
  temporary_system_manifest_container_name() {
    case "$1" in
      target) printf 'target-manifest\n' ;;
      source) printf 'source-manifest\n' ;;
      *) printf 'manifest-%s\n' "$1" ;;
    esac
  }
  trap() { :; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      inspect)
        printf 'placeholder\n'
        ;;
      create)
        create_log="${create_log}$(printf '%s\n' "$*")"$'\n'
        ;;
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      rm)
        rm_calls=$((rm_calls + 1))
        ;;
      exec)
        case "$2" in
          unit-test-container)
            printf '{"package_manager":"apk","packages":["bash","git","curl","ripgrep"]}\n'
            ;;
          source-manifest)
            printf '{"package_manager":"apk","packages":["bash","git"]}\n'
            ;;
          target-manifest)
            printf '{"package_manager":"apk","packages":["bash","git","curl","python3"]}\n'
            ;;
          *)
            fail "Unexpected manifest exec target: $2"
            ;;
        esac
        ;;
      export)
        fail "export should not be called for --no-backup"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'agent-plain\t%s\trw\t2\t4G\n' "$TEST_ROOT"
  }

  run_capture upgrade_cmd --name unit-test-container --image agent-python --no-backup
  assert_status 0
  assert_contains "Upgrade will remove 1 extra apk package(s) not present in agent-python:"
  assert_contains "  - ripgrep"
  assert_not_contains "  - curl"
  assert_not_contains "  - bash"
  assert_contains "Upgrade complete: unit-test-container (backup skipped)"
  printf '%s\n' "$create_log" | grep -F -- "--name unit-test-container" >/dev/null || fail "Expected recreate call for unit-test-container, got: $create_log"
  [ "$start_calls" -eq 2 ] || fail "Expected 2 persisted start calls, got: $start_calls"
  [ "$stop_calls" -eq 2 ] || fail "Expected 2 persisted stop calls, got: $stop_calls"
  [ "$rm_calls" -eq 1 ] || fail "Expected 1 persisted rm call, got: $rm_calls"
}

test_upgrade_reinstalls_added_runtimes_and_features_in_target() {
  begin_test "upgrade reinstalls added runtimes and features in the target container"

  load_codexctl_functions

  local create_log=""
  local start_log=""
  local stop_log=""
  local rm_log=""
  local root_call_log=""

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  warn_upgrade_package_loss() { :; }
  upgrade_added_runtimes_json() { printf '["claude"]\n'; }
  upgrade_added_features_json() { printf '["office"]\n'; }
  container_supports_state_contract() { return 0; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  image_exists() { return 0; }
  codex_agents_state() { printf 'missing\n'; }
  backup_codex_config() { :; }
  restore_codex_config() { :; }
  persist_container_system_manifest_baseline() { :; }
  persist_container_system_manifest_baseline_from_image() { :; }
  collect_upgrade_container_preflight() {
    UPGRADE_PREFLIGHT_CONTAINER_MANIFEST='{"package_manager":"apk","packages":[]}'
    UPGRADE_PREFLIGHT_BASELINE_MANIFEST=''
    UPGRADE_PREFLIGHT_SOURCE_SUPPORTS_STATE_CONTRACT=1
  }
  image_system_manifest_json() { return 1; }
  sanitize_image_name() { printf '%s\n' "$1"; }
  build_backup_image_from_export() { :; }
  run_agent_sh_in_container() {
    if [ "$2" = "runtime" ] && [ "$3" = "info" ] && [ "$4" = "claude" ]; then
      printf '{"runtime":"claude","installed":false,"capabilities":{"install":true}}\n'
      return 0
    fi
    if [ "$2" = "feature" ] && [ "$3" = "info" ] && [ "$4" = "office" ]; then
      printf '{"feature":"office","installed":false,"capabilities":{"install":true}}\n'
      return 0
    fi
    fail "Unexpected run_agent_sh_in_container call: $*"
  }
  run_agent_sh_in_container_root() {
    root_call_log="${root_call_log}$2 $3 $4"$'\n'
  }
  trap() { :; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      inspect)
        printf 'placeholder\n'
        ;;
      create)
        create_log="${create_log}$(printf '%s\n' "$*")"$'\n'
        ;;
      start)
        start_log="${start_log}${2}"$'\n'
        ;;
      stop)
        stop_log="${stop_log}${2}"$'\n'
        ;;
      rm)
        rm_log="${rm_log}${2}"$'\n'
        ;;
      export)
        fail "export should not be called for --no-backup"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'agent-plain\t%s\trw\t2\t4G\n' "$TEST_ROOT"
  }

  run_capture upgrade_cmd --name unit-test-container --image agent-python --no-backup
  assert_status 0
  assert_contains "Reinstalling added runtime in unit-test-container: claude"
  assert_contains "Reinstalling added feature in unit-test-container: office"
  printf '%s\n' "$root_call_log" | grep -Fx -- "runtime install claude" >/dev/null || fail "Expected runtime reinstall call, got: $root_call_log"
  printf '%s\n' "$root_call_log" | grep -Fx -- "feature install office" >/dev/null || fail "Expected feature reinstall call, got: $root_call_log"
  assert_contains "Upgrade complete: unit-test-container (backup skipped)"
  printf '%s\n' "$create_log" | grep -F -- "--name unit-test-container" >/dev/null || fail "Expected recreate call for unit-test-container, got: $create_log"
  printf '%s\n' "$rm_log" | grep -Fx -- "unit-test-container" >/dev/null || fail "Expected removal of source container, got: $rm_log"
  printf '%s\n' "$start_log" | grep -Fx -- "unit-test-container" >/dev/null || fail "Expected source container start for backup, got: $start_log"
  printf '%s\n' "$start_log" | grep -Fx -- "unit-test-container" >/dev/null || fail "Expected target container start after recreation, got: $start_log"
  printf '%s\n' "$stop_log" | grep -Fx -- "unit-test-container" >/dev/null || fail "Expected source container stop after backup, got: $stop_log"
}

test_upgrade_warns_and_clears_missing_preferred_runtime() {
  begin_test "upgrade warns and clears a preferred runtime that is unavailable in the target"

  load_codexctl_functions

  local cleared_name=""

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  warn_upgrade_package_loss() { :; }
  upgrade_added_runtimes_json() { printf '[]\n'; }
  upgrade_added_features_json() { printf '[]\n'; }
  container_preferred_runtime() { printf 'claude\n'; }
  target_default_runtime_for_upgrade() { printf 'codex\n'; }
  container_supports_state_contract() { return 0; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  image_exists() { return 0; }
  codex_agents_state() { printf 'missing\n'; }
  backup_codex_config() { :; }
  restore_codex_config() { :; }
  clear_preferred_runtime_override_in_container() { cleared_name="$1"; }
  persist_container_system_manifest_baseline_from_image() { :; }
  collect_upgrade_container_preflight() {
    UPGRADE_PREFLIGHT_CONTAINER_MANIFEST='{"package_manager":"apk","packages":[]}'
    UPGRADE_PREFLIGHT_BASELINE_MANIFEST=''
    UPGRADE_PREFLIGHT_SOURCE_SUPPORTS_STATE_CONTRACT=1
  }
  image_system_manifest_json() { return 1; }
  sanitize_image_name() { printf '%s\n' "$1"; }
  build_backup_image_from_export() { :; }
  run_agent_sh_in_container() {
    if [ "$2" = "runtime" ] && [ "$3" = "info" ] && [ "$4" = "claude" ]; then
      printf '{"runtime":"claude","installed":false,"capabilities":{"install":false}}\n'
      return 0
    fi
    fail "Unexpected run_agent_sh_in_container call: $*"
  }
  trap() { :; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      inspect)
        printf 'placeholder\n'
        ;;
      create|start|stop|rm)
        ;;
      export)
        fail "export should not be called for --no-backup"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'agent-plain\t%s\trw\t2\t4G\n' "$TEST_ROOT"
  }

  run_capture upgrade_cmd --name unit-test-container --image agent-python --no-backup
  assert_status 0
  assert_contains "Warning: Preferred runtime claude is not available after upgrade; cleared the user override so unit-test-container will use codex"
  [ "$cleared_name" = "unit-test-container" ] || fail "Expected preferred runtime override clear on target container, got: $cleared_name"
}

test_upgrade_uses_stored_baseline_when_current_image_is_missing() {
  begin_test "upgrade uses the stored baseline manifest when the current image is unavailable"

  load_codexctl_functions

  local create_log=""
  local start_calls=0
  local stop_calls=0
  local rm_calls=0

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  require_container_backup_support() { return 0; }
  container_supports_state_contract() { return 0; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  image_exists() {
    case "$1" in
      agent-python) return 0 ;;
      *) return 1 ;;
    esac
  }
  codex_agents_state() { printf 'missing\n'; }
  backup_codex_config() { :; }
  restore_codex_config() { :; }
  persist_container_system_manifest_baseline() { :; }
  persist_container_system_manifest_baseline_from_image() { :; }
  collect_upgrade_container_preflight() {
    UPGRADE_PREFLIGHT_CONTAINER_MANIFEST='{"package_manager":"apk","packages":["bash","git","curl","ripgrep"]}'
    UPGRADE_PREFLIGHT_BASELINE_MANIFEST='{"schema_version":2,"baseline_source":"image","image_ref":"agent-plain","package_manager":"apk","packages":["bash","git"],"installed_runtimes":["codex"],"installed_features":[],"default_runtime":"codex","preferred_runtime":"codex"}'
    UPGRADE_PREFLIGHT_SOURCE_SUPPORTS_STATE_CONTRACT=1
  }
  container_baseline_manifest_json() {
    printf '{"schema_version":2,"baseline_source":"image","image_ref":"agent-plain","package_manager":"apk","packages":["bash","git"],"installed_runtimes":["codex"],"installed_features":[],"default_runtime":"codex","preferred_runtime":"codex"}\n'
  }
  sanitize_image_name() { printf '%s\n' "$1"; }
  build_backup_image_from_export() { :; }
  temporary_system_manifest_container_name() {
    case "$1" in
      target) printf 'target-manifest\n' ;;
      source) printf 'source-manifest\n' ;;
      *) printf 'manifest-%s\n' "$1" ;;
    esac
  }
  trap() { :; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      inspect)
        printf 'placeholder\n'
        ;;
      create)
        create_log="${create_log}$(printf '%s\n' "$*")"$'\n'
        ;;
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      rm)
        rm_calls=$((rm_calls + 1))
        ;;
      exec)
        case "$2" in
          unit-test-container)
            printf '{"package_manager":"apk","packages":["bash","git","curl","ripgrep"]}\n'
            ;;
          target-manifest)
            printf '{"package_manager":"apk","packages":["bash","git","curl","python3"]}\n'
            ;;
          source-manifest)
            fail "Stored baseline should avoid source image inspection"
            ;;
          *)
            fail "Unexpected manifest exec target: $2"
            ;;
        esac
        ;;
      export)
        fail "export should not be called for --no-backup"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'agent-plain\t%s\trw\t2\t4G\n' "$TEST_ROOT"
  }

  run_capture upgrade_cmd --name unit-test-container --image agent-python --no-backup
  assert_status 0
  assert_contains "Upgrade will remove 1 extra apk package(s) not present in agent-python:"
  assert_contains "  - ripgrep"
  assert_not_contains "Current image agent-plain is not available locally"
  assert_contains "Upgrade complete: unit-test-container (backup skipped)"
  printf '%s\n' "$create_log" | grep -F -- "--name unit-test-container" >/dev/null || fail "Expected recreate call for unit-test-container, got: $create_log"
  [ "$start_calls" -eq 2 ] || fail "Expected 2 start calls, got: $start_calls"
  [ "$stop_calls" -eq 2 ] || fail "Expected 2 stop calls, got: $stop_calls"
  [ "$rm_calls" -eq 1 ] || fail "Expected 1 rm call, got: $rm_calls"
}

test_upgrade_accepts_workdir_override_when_original_mount_is_missing() {
  begin_test "upgrade can replace a missing workdir mount source"

  load_codexctl_functions

  local create_args=""
  local export_calls=0
  local start_calls=0
  local stop_calls=0
  local rm_calls=0

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  require_container_backup_support() { return 0; }
  export_root_supports_state_contract() { return 0; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  image_exists() { return 0; }
  backup_codex_config() { fail "backup_codex_config should not be used when the original workdir is missing"; }
  backup_codex_config_from_export() {
    local extract_root="$3"
    mkdir -p "$extract_root/home/coder/.codex"
    ln -sf /etc/codexctl/image.md "$extract_root/home/coder/.codex/AGENTS.md"
  }
  extract_export_root() {
    local extract_root="$2"
    mkdir -p "$extract_root/home/coder/.codex"
  }
  restore_codex_config() { :; }
  persist_container_system_manifest_baseline_from_image() { :; }
  sanitize_image_name() { printf '%s\n' "$1"; }
  build_backup_image_from_export() { :; }
  trap() { :; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      inspect)
        printf 'placeholder\n'
        ;;
      create)
        shift
        create_args="$(printf '%s\n' "$*")"
        ;;
      export)
        export_calls=$((export_calls + 1))
        ;;
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      rm)
        rm_calls=$((rm_calls + 1))
        ;;
      exec)
        fail "upgrade should not exec into the stopped source container during export-backed recovery"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'agent-plain\t/does/not/exist\trw\t2\t4G\n'
  }

  run_capture upgrade_cmd --name unit-test-container --workdir "$TEST_ROOT" --no-backup
  assert_status 0
  assert_contains "Warning: Skipping package-loss warning because original /workdir source does not exist and unit-test-container is stopped"
  assert_contains "Exporting container filesystem for state backup: unit-test-container"
  assert_contains "Upgrade complete: unit-test-container (backup skipped)"
  printf '%s\n' "$create_args" | grep -F -- "src=$TEST_ROOT,dst=/workdir" >/dev/null || fail "Expected recreated mount to use override workdir, got: $create_args"
  [ "$export_calls" -eq 1 ] || fail "Expected 1 export call, got: $export_calls"
  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call for recreated container, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call for recreated container, got: $stop_calls"
  [ "$rm_calls" -eq 1 ] || fail "Expected 1 rm call, got: $rm_calls"
}

test_upgrade_allows_no_backup_for_modern_export_source() {
  begin_test "upgrade allows --no-backup for a modern export-backed source"

  load_codexctl_functions

  local create_args=""
  local export_calls=0
  local start_calls=0
  local stop_calls=0
  local rm_calls=0
  local export_root
  export_root="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-export-root.XXXXXX")"
  register_dir_cleanup "$export_root"
  mkdir -p "$export_root/usr/local/bin"
  cat >"$export_root/usr/local/bin/agent.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'HELP'
Usage:
  agent.sh help
  agent.sh state export
  agent.sh state import
HELP
EOF
  chmod +x "$export_root/usr/local/bin/agent.sh"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  require_container_backup_support() { return 0; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  image_exists() { return 0; }
  backup_codex_config() { fail "backup_codex_config should not be used when the original workdir is missing"; }
  restore_codex_config() { :; }
  persist_container_system_manifest_baseline_from_image() { :; }
  sanitize_image_name() { printf '%s\n' "$1"; }
  build_backup_image_from_export() { :; }
  trap() { :; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      inspect)
        printf 'placeholder\n'
        ;;
      create)
        shift
        create_args="$(printf '%s\n' "$*")"
        ;;
      export)
        export_calls=$((export_calls + 1))
        tar -C "$export_root" -cf "$4" .
        ;;
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      rm)
        rm_calls=$((rm_calls + 1))
        ;;
      exec)
        fail "upgrade should not exec into the stopped source container during export-backed recovery"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'agent-plain\t/does/not/exist\trw\t2\t4G\n'
  }

  run_capture upgrade_cmd --name unit-test-container --workdir "$TEST_ROOT" --no-backup
  assert_status 0
  assert_contains "Exporting container filesystem for state backup: unit-test-container"
  assert_contains "Upgrade complete: unit-test-container (backup skipped)"
  assert_not_contains "Legacy source containers require a backup image for upgrade safety"
  printf '%s\n' "$create_args" | grep -F -- "src=$TEST_ROOT,dst=/workdir" >/dev/null || fail "Expected recreated mount to use override workdir, got: $create_args"
  [ "$export_calls" -eq 1 ] || fail "Expected 1 export call, got: $export_calls"
  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call for recreated container, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call for recreated container, got: $stop_calls"
  [ "$rm_calls" -eq 1 ] || fail "Expected 1 rm call, got: $rm_calls"
}

test_container_baseline_manifest_starts_stopped_container_and_restores_state() {
  begin_test "container_baseline_manifest_json starts a stopped container and restores stopped state"

  load_codexctl_functions

  local start_calls=0
  local stop_calls=0

  CONTAINER_CMD=container
  container() {
    case "$1" in
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      exec)
        shift
        if [ "${1:-}" = "unit-test-container" ]; then
          shift
        fi
        if [ "${1:-}" = "setpriv" ]; then
          shift 6
        fi
        case "$*" in
          "test -f /etc/agentctl/system-manifest.json")
            return 0
            ;;
          "cat /etc/agentctl/system-manifest.json")
            printf '{"package_manager":"apk","packages":["bash"]}\n'
            ;;
          *)
            fail "Unexpected container exec invocation: $*"
            ;;
        esac
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }

  run_capture container_baseline_manifest_json unit-test-container
  assert_status 0
  assert_contains '"package_manager":"apk"'
  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
}

test_collect_upgrade_container_preflight_starts_stopped_container_once() {
  begin_test "collect_upgrade_container_preflight reuses one start for manifest, baseline, and capability checks"

  load_codexctl_functions

  local start_calls=0
  local stop_calls=0
  local exec_log
  exec_log="$(mktemp "${TMPDIR:-/tmp}/codexctl-preflight-exec.XXXXXX")"
  register_dir_cleanup "$exec_log"

  CONTAINER_CMD=container
  container() {
    case "$1" in
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      exec)
        printf '%s\n' "$*" >>"$exec_log"
        shift
        if [ "${1:-}" = "unit-test-container" ]; then
          shift
        fi
        if [ "${1:-}" = "setpriv" ]; then
          shift 6
        fi
        case "$*" in
          "bash /usr/local/bin/agent.sh system manifest")
            printf '{"package_manager":"apk","packages":["bash"]}\n'
            ;;
          "test -f /etc/agentctl/system-manifest.json")
            return 0
            ;;
          "cat /etc/agentctl/system-manifest.json")
            printf '{"schema_version":2,"package_manager":"apk","packages":["bash"]}\n'
            ;;
          "bash /usr/local/bin/agent.sh help")
            printf 'Usage:\n  agent.sh help\n  agent.sh state export\n'
            ;;
          *)
            fail "Unexpected container exec invocation: $*"
            ;;
        esac
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_running() { return 1; }

  collect_upgrade_container_preflight unit-test-container

  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
  [ "$(wc -l <"$exec_log" | tr -d '[:space:]')" = "4" ] || fail "Expected 4 exec calls, got: $(cat "$exec_log")"
  [ "$UPGRADE_PREFLIGHT_SOURCE_SUPPORTS_STATE_CONTRACT" -eq 1 ] || fail "Expected state contract support to be detected"
  printf '%s' "$UPGRADE_PREFLIGHT_CONTAINER_MANIFEST" | jq -e '.packages == ["bash"]' >/dev/null 2>&1 || fail "Expected cached container manifest, got: $UPGRADE_PREFLIGHT_CONTAINER_MANIFEST"
  printf '%s' "$UPGRADE_PREFLIGHT_BASELINE_MANIFEST" | jq -e '.schema_version == 2' >/dev/null 2>&1 || fail "Expected cached baseline manifest, got: $UPGRADE_PREFLIGHT_BASELINE_MANIFEST"
}

test_refresh_updates_managed_files_without_recreate() {
  begin_test "refresh updates managed files and preserves stopped state"

  load_codexctl_functions

  local start_calls=0
  local stop_calls=0
  local exec_log=""

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      exec)
        shift
        if [ "$1" = "-u" ]; then
          shift 2
        fi
        if [ "$1" = "unit-test-container" ]; then
          shift
        fi
        if [ "${1:-}" = "setpriv" ]; then
          shift 5
        fi
        exec_log="${exec_log}$(printf '%s\n' "$*")"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture refresh_cmd --name unit-test-container
  assert_status 0
  assert_contains "Refresh complete: unit-test-container"
  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
  printf '%s\n' "$exec_log" | grep -Fq "/etc/agentctl/config.toml" || fail "Expected refresh to update /etc/agentctl/config.toml"
  printf '%s\n' "$exec_log" | grep -Fq "/etc/codexctl/config.toml" || fail "Expected refresh to update /etc/codexctl/config.toml"
  printf '%s\n' "$exec_log" | grep -Fq "/usr/local/bin/agent.sh" || fail "Expected refresh to update agent.sh"
  printf '%s\n' "$exec_log" | grep -Fq "/usr/local/lib/agentctl/runtimes" || fail "Expected refresh to update runtime adapters"
  printf '%s\n' "$exec_log" | grep -Fq "/etc/agentctl/runtimes.d" || fail "Expected refresh to update runtime registry"
  printf '%s\n' "$exec_log" | grep -Fq "/usr/local/lib/agentctl/features" || fail "Expected refresh to update feature adapters"
  printf '%s\n' "$exec_log" | grep -Fq "/etc/agentctl/features.d" || fail "Expected refresh to update feature registry"
}

test_refresh_container_file_streams_source_via_stdin() {
  begin_test "refresh_container_file uses interactive exec for stdin streaming"

  load_codexctl_functions

  local source_file
  local exec_log=""

  source_file="$(mktemp "${TMPDIR:-/tmp}/codexctl-refresh-file.XXXXXX")"
  register_dir_cleanup "$source_file"
  printf 'hello-refresh\n' >"$source_file"

  CONTAINER_CMD=container
  container() {
    case "$1" in
      exec)
        shift
        exec_log="${exec_log}$(printf '%s\n' "$*")"
        if [ "${1:-}" = "-i" ]; then
          cat >/dev/null || true
        fi
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  refresh_container_file unit-test-container "$source_file" /usr/local/bin/agent.sh root:root 755
  printf '%s\n' "$exec_log" | grep -Fq -- '-i -u 0 unit-test-container sh -lc cat > '\''/usr/local/bin/agent.sh'\''' || fail "Expected refresh_container_file to use exec -i for stdin streaming, got: $exec_log"
}

test_system_manifest_starts_stopped_container_and_restores_state() {
  begin_test "system-manifest starts a stopped container and restores stopped state"

  load_codexctl_functions

  local start_calls=0
  local stop_calls=0

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      exec)
        printf '{"package_manager":"apk","packages":["bash"]}\n'
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture system_manifest_cmd --name unit-test-container
  assert_status 0
  assert_contains '"package_manager":"apk"'
  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
}

test_runtime_cmd_starts_stopped_container_and_restores_state() {
  begin_test "runtime list starts a stopped container and restores stopped state"

  load_codexctl_functions

  local start_calls=0
  local stop_calls=0
  local exec_log=""

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      exec)
        shift
        if [ "$1" = "unit-test-container" ]; then
          shift
        fi
        if [ "${1:-}" = "setpriv" ]; then
          shift 5
        fi
        exec_log="${exec_log}$(printf '%s\n' "$*")"
        printf 'codex\n'
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture runtime_cmd --name unit-test-container list
  assert_status 0
  assert_contains "codex"
  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
  printf '%s\n' "$exec_log" | grep -Fq '/usr/local/bin/agent.sh runtime list' || fail "Expected runtime list to invoke agent.sh, got: $exec_log"
}

test_runtime_cmd_propagates_exec_failures() {
  begin_test "runtime commands propagate container exec failures"

  load_codexctl_functions

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 0; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      exec)
        return 17
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture runtime_cmd --name unit-test-container info codex
  assert_status 17
}

test_use_cmd_sets_preferred_runtime_in_stopped_container() {
  begin_test "use sets the preferred runtime inside a stopped container"

  load_codexctl_functions

  local start_calls=0
  local stop_calls=0
  local exec_log=""

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      exec)
        shift
        if [ "$1" = "unit-test-container" ]; then
          shift
        fi
        if [ "${1:-}" = "setpriv" ]; then
          shift 5
        fi
        exec_log="${exec_log}$(printf '%s\n' "$*")"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture use_cmd --name unit-test-container codex
  assert_status 0
  assert_contains "Preferred runtime set to codex in unit-test-container"
  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
  printf '%s\n' "$exec_log" | grep -Fq '/usr/local/bin/agent.sh preferred set codex' || fail "Expected use to invoke agent.sh preferred set, got: $exec_log"
}

test_runtime_use_cmd_sets_preferred_runtime_in_stopped_container() {
  begin_test "runtime use sets the preferred runtime inside a stopped container"

  load_codexctl_functions

  local start_calls=0
  local stop_calls=0
  local exec_log=""

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      exec)
        shift
        if [ "$1" = "unit-test-container" ]; then
          shift
        fi
        if [ "${1:-}" = "setpriv" ]; then
          shift 5
        fi
        exec_log="${exec_log}$(printf '%s\n' "$*")"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture runtime_cmd --name unit-test-container use codex
  assert_status 0
  assert_contains "Preferred runtime set to codex in unit-test-container"
  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
  printf '%s\n' "$exec_log" | grep -Fq '/usr/local/bin/agent.sh preferred set codex' || fail "Expected runtime use to invoke agent.sh preferred set, got: $exec_log"
}

test_cleanup_temp_dir_handles_read_only_trees() {
  begin_test "cleanup_temp_dir removes read-only extracted trees"

  load_codexctl_functions

  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-cleanup.XXXXXX")"
  register_dir_cleanup "$temp_dir"

  mkdir -p "$temp_dir/rootfs/pkg"
  : >"$temp_dir/rootfs/pkg/file.txt"
  chmod 500 "$temp_dir/rootfs" "$temp_dir/rootfs/pkg"
  chmod 400 "$temp_dir/rootfs/pkg/file.txt"

  cleanup_temp_dir "$temp_dir"

  [ ! -e "$temp_dir" ] || fail "Expected cleanup_temp_dir to remove $temp_dir"
}

main() {
  log "Using agentctl at $AGENTCTL"
  log "Using agentctl implementation at $AGENTCTL_IMPL"

  test_run_config_wires_runtime_config_json
  test_run_help_reports_generic_runtime_config
  test_run_help_reports_runtime_options
  test_run_model_wires_selected_model
  test_build_help_reports_primary_base_images
  test_build_cmd_passes_runtime_list_build_args
  test_build_cmd_uses_first_runtime_as_default_when_unspecified
  test_build_cmd_default_runtime_alone_installs_only_that_runtime
  test_build_cmd_rebuilds_existing_image_when_runtime_selection_is_overridden
  test_run_cmd_runtime_selection_auto_installs_for_new_container
  test_run_cmd_runtime_selection_does_not_auto_install_for_existing_container
  test_build_cmd_warns_for_legacy_office_image
  test_build_cmd_rejects_runtime_override_snapshot_combo
  test_build_cmd_rejects_default_runtime_outside_runtime_list
  test_run_cmd_rejects_invalid_runtime_config
  test_run_cmd_rejects_install_runtime_without_runtime
  test_run_cmd_rejects_auth_without_online
  test_run_pre_exec_syncs_selected_runtime_auth_when_available
  test_run_pre_exec_updates_codex_via_runtime_helper
  test_run_container_reset_config_uses_runtime_helper
  test_run_pre_exec_syncs_auth_for_preferred_runtime_when_unspecified
  test_run_pre_exec_runs_local_model_preflight_for_preferred_claude
  test_run_pre_exec_runs_local_model_preflight_for_preferred_codex
  test_run_cmd_default_entrypoint_enables_local_runtime_preflight
  test_sync_runtime_auth_to_container_if_available_skips_missing_keychain
  test_auth_cmd_warns_for_legacy_office_image
  test_feature_cmd_installs_via_root_helper
  test_runtime_cmd_install_uses_root_helper
  test_runtime_cmd_install_claude_warns_on_undersized_container
  test_runtime_cmd_install_claude_reports_memory_guidance_on_failure
  test_runtime_cmd_update_uses_root_helper
  test_bootstrap_cmd_bootstraps_alpine_container_and_restores_stopped_state
  test_bootstrap_cmd_creates_and_bootstraps_new_alpine_container
  test_bootstrap_cmd_bootstraps_apt_container
  test_bootstrap_cmd_rejects_unsupported_base
  test_agentctl_wrapper_usage_banner
  test_refresh_help_reports_new_command
  test_bootstrap_help_reports_new_command
  test_system_manifest_help_reports_new_command
  test_runtime_help_reports_new_command
  test_feature_help_reports_new_command
  test_use_help_reports_new_command
  test_rm_help_reports_force_option
  test_agent_sh_runtime_info_reports_registry_metadata
  test_agent_sh_feature_list_reports_declared_features
  test_agent_sh_feature_info_reports_manifest_metadata
  test_agent_sh_feature_install_office_creates_feature_state
  test_agent_sh_feature_info_reports_installed_after_office_install
  test_agent_sh_runtime_list_reports_installed_runtimes_only
  test_agent_sh_runtime_capabilities_reports_manifest_commands
  test_agent_sh_claude_runtime_info_reports_skeleton_metadata
  test_agent_sh_system_manifest_includes_runtime_feature_and_preference_state
  test_agent_sh_claude_runtime_install_runs_native_installer
  test_agent_sh_claude_runtime_update_calls_claude_update
  test_agent_sh_claude_runtime_reset_config_restores_settings
  test_agent_sh_codex_run_defaults_to_workdir_cd
  test_agent_sh_codex_run_uses_runtime_profile_config
  test_agent_sh_accepts_explicit_empty_runtime_config_json
  test_agent_sh_codex_run_uses_model_override
  test_agent_sh_codex_online_run_skips_catalog_update
  test_agent_sh_codex_local_run_updates_config_and_catalog
  test_agent_sh_codex_local_metadata_status_uses_stderr
  test_agent_sh_codex_local_run_with_explicit_profile_updates_catalog
  test_agent_sh_codex_local_run_updates_stale_catalog_entry
  test_agent_sh_codex_local_run_reports_unchanged_catalog_entry
  test_agent_sh_codex_local_run_uses_model_override_for_catalog
  test_agent_sh_codex_local_run_uses_explicit_model_arg_for_catalog
  test_agent_sh_codex_local_run_creates_missing_catalog
  test_agent_sh_codex_local_run_rejects_invalid_catalog_without_overwrite
  test_agent_sh_codex_local_run_rejects_missing_myollama_provider
  test_agent_sh_codex_local_run_api_show_failure_preserves_catalog
  test_agent_sh_claude_run_uses_local_ollama_defaults
  test_agent_sh_claude_run_respects_explicit_model
  test_agent_sh_claude_run_uses_model_override
  test_agent_sh_claude_run_uses_runtime_flag_config
  test_agent_sh_rejects_unknown_runtime
  test_agent_sh_preferred_round_trip
  test_agent_sh_preferred_set_as_root_repairs_ownership
  test_agent_sh_preferred_set_rejects_uninstalled_runtime
  test_agent_sh_auth_read_rejects_invalid_codex_auth
  test_agent_sh_auth_write_rejects_invalid_codex_auth
  test_agent_sh_auth_write_codex_does_not_require_user_config_dir
  test_agent_sh_claude_auth_read_includes_optional_home_state
  test_agent_sh_claude_auth_read_rejects_invalid_credentials
  test_agent_sh_claude_auth_write_restores_credentials_and_home_state
  test_agent_sh_claude_auth_write_rejects_invalid_payload
  test_agent_sh_state_export_includes_known_user_state
  test_agent_sh_state_export_uses_installed_runtime_hooks
  test_agent_sh_state_import_restores_known_user_state
  test_agent_sh_state_import_uses_installed_runtime_hooks
  test_agent_sh_state_import_with_empty_stdin_preserves_existing_state
  test_container_auth_info_uses_agent_sh_auth_read
  test_write_auth_blob_to_container_uses_agent_sh_auth_write
  test_write_auth_blob_to_container_falls_back_for_legacy_codex
  test_write_auth_blob_to_container_does_not_fallback_on_non_legacy_error
  test_sync_runtime_auth_to_container_uses_runtime_parameters
  test_sync_runtime_auth_from_container_uses_runtime_parameters
  test_auth_info_from_json_parses_claude_oauth_payload
  test_run_auth_flow_uses_agent_sh_auth_contract
  test_run_auth_flow_skips_keychain_write_when_auth_unchanged
  test_run_auth_flow_rejects_runtime_without_host_auth_support
  test_run_auth_flow_installs_runtime_before_claude_auth
  test_run_keychain_for_runtime_uses_runtime_specific_codex_slot
  test_run_keychain_for_runtime_uses_runtime_specific_slot
  test_rm_force_stops_running_container_before_remove
  test_image_ref_for_runtime_falls_back_to_legacy_when_present
  test_ls_filters_non_codex_containers
  test_upgrade_backup_support_check
  test_run_rejects_resource_flags_for_existing_container
  test_upgrade_rejects_no_backup_for_legacy_source
  test_upgrade_uses_explicit_resource_overrides
  test_upgrade_can_rename_container_during_recreation
  test_upgrade_copy_keeps_running_source_container
  test_upgrade_copy_requires_new_name
  test_upgrade_dry_run_reports_plan_without_recreating_container
  test_upgrade_copy_dry_run_reports_copy_plan
  test_upgrade_warns_about_added_packages_missing_from_target_image
  test_upgrade_reinstalls_added_runtimes_and_features_in_target
  test_upgrade_warns_and_clears_missing_preferred_runtime
  test_upgrade_uses_stored_baseline_when_current_image_is_missing
  test_upgrade_accepts_workdir_override_when_original_mount_is_missing
  test_upgrade_allows_no_backup_for_modern_export_source
  test_container_baseline_manifest_starts_stopped_container_and_restores_state
  test_collect_upgrade_container_preflight_starts_stopped_container_once
  test_refresh_updates_managed_files_without_recreate
  test_refresh_container_file_streams_source_via_stdin
  test_system_manifest_starts_stopped_container_and_restores_state
  test_runtime_cmd_starts_stopped_container_and_restores_state
  test_runtime_cmd_propagates_exec_failures
  test_use_cmd_sets_preferred_runtime_in_stopped_container
  test_runtime_use_cmd_sets_preferred_runtime_in_stopped_container
  test_cleanup_temp_dir_handles_read_only_trees

  log "PASS: all shell unit tests completed"
}

main "$@"
