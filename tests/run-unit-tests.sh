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

  run_capture env \
    HOME="$temp_home/home" \
    XDG_CONFIG_HOME="$temp_home/config" \
    PATH="$PATH" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$TEST_ROOT/runtimes.d" \
    AGENTCTL_RUNTIME_ADAPTER_DIR="$TEST_ROOT/runtimes" \
    "$TEST_ROOT/agent.sh" "$@"
}

test_run_profile_wires_selected_profile() {
  begin_test "run_cmd wires --profile into the launched agent.sh command"

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

  run_cmd --name unit-test-container --workdir "$workdir" --profile gemma

  [ "$captured_pre_exec" = "local_model_pre_exec" ] || fail "Expected local_model_pre_exec, got: $captured_pre_exec"
  printf '%s\n' "$captured_cmd" | grep -Fq 'AGENTCTL_RUN_MODE=' || fail "Expected agent.sh launch wrapper, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq 'AGENTCTL_DEFAULT_PROFILE=' || fail "Expected profile to be passed to agent.sh, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq '/usr/local/bin/agent.sh run --cd /workdir' || fail "Expected agent.sh run launch path, got: $captured_cmd"
}

test_run_help_reports_profile_default() {
  begin_test "run help reports the actual default profile"

  run_capture "$AGENTCTL" run --help
  assert_status 0
  assert_contains "--profile NAME  Codex profile to use (default: gpt-oss)"
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
  assert_contains "Usage: agentctl runtime <list|info|capabilities|install|update|reset-config> [options] [runtime]"
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
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and .install_method == "npm-global" and .default_config_dir == "/etc/codexctl" and (.auth_formats | index("json_refresh_token") != null)' >/dev/null || fail "Expected runtime info JSON for codex, got: $RUN_OUTPUT"
}

test_agent_sh_runtime_list_reports_installed_runtimes_only() {
  begin_test "agent.sh runtime list reports installed runtimes only"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" runtime list
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
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and (.commands | index("runtime install codex") != null) and (.commands | index("runtime capabilities codex") != null) and (.auth_formats | index("json_refresh_token") != null) and .capabilities.auth_login == true and .capabilities.auth_read == true and .capabilities.auth_write == true and .capabilities.openai_mode == true' >/dev/null || fail "Expected runtime capabilities JSON for codex, got: $RUN_OUTPUT"
}

test_agent_sh_claude_runtime_info_reports_skeleton_metadata() {
  begin_test "agent.sh runtime info reports claude skeleton metadata"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" runtime info claude
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "claude" and .installed == false and .install_method == "not-implemented" and (.commands | index("runtime install claude") != null)' >/dev/null || fail "Expected runtime info JSON for claude skeleton, got: $RUN_OUTPUT"
}

test_agent_sh_claude_runtime_install_fails_predictably() {
  begin_test "agent.sh claude runtime install fails predictably"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" runtime install claude
  assert_status 1
  assert_contains "runtime install not implemented yet for claude"
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
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" preferred set codex
  assert_status 0

  run_agent_sh_capture "$temp_home" preferred get
  assert_status 0
  assert_contains "codex"
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

  run_capture container_auth_info unit-test-container
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

  run_capture write_auth_blob_to_container unit-test-container '{"refresh_token":"write-token"}'
  assert_status 0
  grep -Fxq '{"refresh_token":"write-token"}' "$payload_file" || fail "Expected auth payload to be piped through agent.sh auth write"
  grep -Fq '/usr/local/bin/agent.sh auth write codex json_refresh_token' "$exec_log_file" || fail "Expected auth write via agent.sh"
}

test_run_auth_flow_uses_agent_sh_auth_contract() {
  begin_test "run_auth_flow uses agent.sh auth login and auth read"

  load_codexctl_functions

  local temp_dir
  local fake_keychain
  local stored_blob_file
  local exec_log_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-auth.XXXXXX")"
  register_dir_cleanup "$temp_dir"
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

  KEYCHAIN_SCRIPT="$fake_keychain"
  container_exists() { return 1; }
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
  grep -Fq 'bash /usr/local/bin/agent.sh runtime info codex' "$exec_log_file" || fail "Expected runtime info inspection before auth flow"
  grep -Fq 'bash -lc exec bash /usr/local/bin/agent.sh auth login codex' "$exec_log_file" || fail "Expected auth login via agent.sh"
  grep -Fq 'bash /usr/local/bin/agent.sh auth read codex json_refresh_token' "$exec_log_file" || fail "Expected auth read via agent.sh"
  [ -f "$stored_blob_file" ] || fail "Expected auth blob to be written to fake keychain"
  grep -Fq '"refresh_token":"auth-flow-token"' "$stored_blob_file" || fail "Expected auth blob from agent.sh auth read"
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
        printf '{"runtime":"claude","installed":false,"auth_formats":[],"capabilities":{"auth_login":false,"auth_read":false,"auth_write":false}}'
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
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  image_exists() { return 0; }
  codex_agents_state() { printf 'missing\n'; }
  backup_codex_config() { :; }
  restore_codex_config() { :; }
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
        cat >/dev/null || true
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
  log "Using codexctl implementation at $CODEXCTL"

  test_run_profile_wires_selected_profile
  test_run_help_reports_profile_default
  test_agentctl_wrapper_usage_banner
  test_refresh_help_reports_new_command
  test_system_manifest_help_reports_new_command
  test_runtime_help_reports_new_command
  test_use_help_reports_new_command
  test_rm_help_reports_force_option
  test_agent_sh_runtime_info_reports_registry_metadata
  test_agent_sh_runtime_list_reports_installed_runtimes_only
  test_agent_sh_runtime_capabilities_reports_manifest_commands
  test_agent_sh_claude_runtime_info_reports_skeleton_metadata
  test_agent_sh_claude_runtime_install_fails_predictably
  test_agent_sh_rejects_unknown_runtime
  test_agent_sh_preferred_round_trip
  test_agent_sh_preferred_set_rejects_uninstalled_runtime
  test_container_auth_info_uses_agent_sh_auth_read
  test_write_auth_blob_to_container_uses_agent_sh_auth_write
  test_run_auth_flow_uses_agent_sh_auth_contract
  test_run_auth_flow_rejects_runtime_without_host_auth_support
  test_rm_force_stops_running_container_before_remove
  test_image_ref_for_runtime_falls_back_to_legacy_when_present
  test_ls_filters_non_codex_containers
  test_upgrade_backup_support_check
  test_run_rejects_resource_flags_for_existing_container
  test_upgrade_uses_explicit_resource_overrides
  test_refresh_updates_managed_files_without_recreate
  test_refresh_container_file_streams_source_via_stdin
  test_system_manifest_starts_stopped_container_and_restores_state
  test_runtime_cmd_starts_stopped_container_and_restores_state
  test_runtime_cmd_propagates_exec_failures
  test_use_cmd_sets_preferred_runtime_in_stopped_container
  test_cleanup_temp_dir_handles_read_only_trees

  log "PASS: all shell unit tests completed"
}

main "$@"
