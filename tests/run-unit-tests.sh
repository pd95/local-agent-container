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

test_run_profile_wires_selected_profile() {
  begin_test "run_cmd wires --profile into the launched runtime contract"

  load_codexctl_functions

  local captured_pre_exec=""
  local captured_cmd=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  run_container() {
    captured_pre_exec="$9"
    shift 12
    captured_cmd="$(printf '%s\n' "$*")"
  }

  run_cmd --name unit-test-container --workdir "$workdir" --profile gemma

  [ "$captured_pre_exec" = "local_model_pre_exec" ] || fail "Expected local_model_pre_exec, got: $captured_pre_exec"
  printf '%s\n' "$captured_cmd" | grep -Fxq '__agentctl_default_runtime__ local gemma' || fail "Expected runtime contract command to include local mode and profile gemma, got: $captured_cmd"
}

test_run_skips_local_model_preflight_for_non_local_runtime() {
  begin_test "run without --cmd skips local-model preflight when runtime does not support it"

  load_codexctl_functions

  local captured_pre_exec=""
  local captured_cmd=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_has_agent_contract() { return 0; }
  container_supports_capability() { return 1; }
  run_container() {
    captured_pre_exec="$9"
    shift 12
    captured_cmd="$(printf '%s\n' "$*")"
  }

  run_cmd --name unit-test-container --workdir "$workdir"

  [ -z "$captured_pre_exec" ] || fail "Expected no pre-exec hook for unsupported local-model mode, got: $captured_pre_exec"
  printf '%s\n' "$captured_cmd" | grep -Fxq '__agentctl_default_runtime__ local gpt-oss' || fail "Expected runtime contract command for default profile, got: $captured_cmd"
}

test_run_openai_rejected_for_non_openai_runtime() {
  begin_test "run --openai fails for runtimes without openai-mode support"

  load_codexctl_functions

  local status=0
  local out
  local out_file

  require_container() { return 0; }
  container_has_agent_contract() { return 0; }
  container_supports_capability() { return 1; }

  out_file="$(mktemp "${TMPDIR:-/tmp}/codexctl-openai-runtime.XXXXXX")"
  if (openai_pre_exec unit-test-container >"$out_file" 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || fail "Expected --openai command to fail, got status $status"
  out="$(cat "$out_file" 2>/dev/null || printf '')"
  rm -f "$out_file"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | grep -Fq "Selected runtime does not support --openai mode" \
      || fail "Expected unsupported openai-mode error, got: $out"
  fi
}

test_run_help_reports_profile_default() {
  begin_test "run help reports the actual default profile"

  run_capture "$CODEXCTL" run --help
  assert_status 0
  assert_contains "--profile NAME  Codex profile to use (default: gpt-oss)"
}

test_agentctl_wrapper_usage_banner() {
  begin_test "agentctl wrapper prints its own command name"

  run_capture "$TEST_ROOT/agentctl" --help
  assert_status 0
  assert_contains "Usage: agentctl <command> [options]"
}

test_agent_env_metadata_helpers() {
  begin_test "agent metadata helpers read values from agent.env"

  load_codexctl_functions

  CONTAINER_CMD=container
  container() {
    case "$1" in
      exec)
        shift
        if [ "$1" = "unit-test-container" ]; then
          shift
        fi
        while [ "$#" -gt 0 ] && [[ "$1" == setpriv* || "$1" == --* ]]; do
          shift
        done
        case "$1" in
          test)
            return 0
            ;;
          cat)
            cat <<'EOF'
AGENT_HOME_DIR=/home/coder/.codex
AGENT_CONFIG_DIR=/home/coder/.codex
AGENT_AUTH_PATH=/home/coder/.codex/auth.json
AGENT_IMAGE_DEFAULTS_DIR=/etc/agentctl/defaults
AGENT_KEYCHAIN_SERVICE=agentctl-codex-auth
AGENT_KEYCHAIN_ACCOUNT=device-auth-openai
AGENT_SUPPORTS_OPENAI_MODE=1
EOF
            ;;
          *)
            fail "Unexpected container exec: $*"
            ;;
        esac
        ;;
      ls)
        cat <<'EOF'
ID IMAGE
unit-test-container codex:latest
EOF
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  [ "$(container_agent_home_dir unit-test-container)" = "/home/coder/.codex" ] || fail "Expected AGENT_HOME_DIR metadata"
  [ "$(container_agent_defaults_dir unit-test-container)" = "/etc/agentctl/defaults" ] || fail "Expected AGENT_IMAGE_DEFAULTS_DIR metadata"
  [ "$(container_agent_keychain_service unit-test-container)" = "agentctl-codex-auth" ] || fail "Expected AGENT_KEYCHAIN_SERVICE metadata"
  container_supports_capability unit-test-container openai-mode || fail "Expected openai-mode capability"
}

test_container_auth_format_helpers() {
  begin_test "agent auth metadata helpers support AGENT_AUTH_FORMAT"

  load_codexctl_functions

  local current_format=""
  container_agent_env_value() {
    local _name="$1"
    local key="$2"
    local fallback="$3"
    if [ "$key" = "AGENT_AUTH_FORMAT" ] && [ -n "$current_format" ]; then
      printf '%s\n' "$current_format"
      return 0
    fi
    printf '%s\n' "$fallback"
  }

  current_format=""
  [ "$(container_auth_format unit-test-container)" = "json_refresh_token" ] || fail "Expected default auth format fallback"
  current_format="directory_tarball"
  [ "$(container_auth_format unit-test-container)" = "directory_tarball" ] || fail "Expected explicit AGENT_AUTH_FORMAT"
}

test_openai_auth_sync_opaque_format() {
  begin_test "openai auth sync path uses checksums for opaque auth formats"

  load_codexctl_functions

  local test_auth_format="opaque_blob"
  local container_payload="token-v1"
  local keychain_payload="token-v1"
  local load_calls=0
  local store_calls=0

  ensure_keychain() { return 0; }
  auth_signature() {
    cat | sha256sum | awk '{print $1}'
  }

  container_agent_env_value() {
    local key="$2"
    local fallback="$3"
    case "$key" in
      AGENT_AUTH_FORMAT) printf '%s\n' "${test_auth_format}" ;;
      AGENT_AUTH_PATH) printf '%s\n' "/home/coder/.codex/auth.json" ;;
      AGENT_KEYCHAIN_SERVICE) printf '%s\n' "${fallback}" ;;
      AGENT_KEYCHAIN_ACCOUNT) printf '%s\n' "${fallback}" ;;
      *) printf '%s\n' "$fallback" ;;
    esac
  }
  CONTAINER_CMD=container
  container() {
    if [ "$1" != "exec" ]; then
      fail "Unexpected container invocation: $*"
    fi
    shift
    if [ "$1" = "unit-test-container" ]; then
      shift
    fi
    while [ "$#" -gt 0 ] && [[ "$1" == setpriv* || "$1" == --* ]]; do
      shift
    done
    case "$1" in
      test)
        return 0
        ;;
      cat)
        printf '%s' "$container_payload"
        ;;
      *)
        fail "Unexpected container exec payload: $*"
        ;;
    esac
  }
  keychain_script_run() {
    local cmd="$3"
    case "$cmd" in
      read)
        printf '%s' "$keychain_payload"
        ;;
      load-to-container)
        load_calls=$((load_calls + 1))
        ;;
      store-from-container)
        store_calls=$((store_calls + 1))
        ;;
      verify)
        return 0
        ;;
      *)
        fail "Unexpected keychain action: $cmd"
        ;;
    esac
  }

  sync_openai_auth_to_container unit-test-container
  sync_openai_auth_from_container unit-test-container
  [ "$load_calls" -eq 0 ] || fail "Expected no container load with matching signatures, got: $load_calls"
  [ "$store_calls" -eq 0 ] || fail "Expected no keychain store with matching signatures, got: $store_calls"

  container_payload="token-v2"
  sync_openai_auth_to_container unit-test-container
  sync_openai_auth_from_container unit-test-container
  [ "$load_calls" -eq 1 ] || fail "Expected one container load after mismatch, got: $load_calls"
  [ "$store_calls" -eq 1 ] || fail "Expected one keychain store after mismatch, got: $store_calls"
}

test_codex_auth_wrapper_execs_generic_script() {
  begin_test "codex-auth-keychain wrapper delegates to the generic script"

  run_capture bash -c 'SCRIPT_DIR="$(pwd)"; PATH="$SCRIPT_DIR:$PATH"; export KEYCHAIN_SERVICE_NAME=test KEYCHAIN_ACCOUNT_NAME=test; sed -n "1,5p" codex-auth-keychain.sh | grep -F "agent-auth-keychain.sh"'
  assert_status 0
  assert_contains "agent-auth-keychain.sh"
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
unit-test-container              codex:latest
OUT
  exit 0
fi

exit 0
EOF
  chmod +x "$fake_container"

  PATH="$fake_dir:$old_path"

  run_capture "$CODEXCTL" run --name unit-test-container --workdir "$TEST_ROOT" --cpu 4 --mem 8G --cmd true
  assert_status 1
  assert_contains "Error: --cpu and --mem only apply when creating a new container."
  assert_contains "codexctl upgrade --name unit-test-container --image $DEFAULT_IMAGE --cpu 4 --mem 8G"
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
  log "Using codexctl at $CODEXCTL"

  test_run_profile_wires_selected_profile
  test_run_skips_local_model_preflight_for_non_local_runtime
  test_run_openai_rejected_for_non_openai_runtime
  test_run_help_reports_profile_default
  test_agentctl_wrapper_usage_banner
  test_agent_env_metadata_helpers
  test_container_auth_format_helpers
  test_openai_auth_sync_opaque_format
  test_codex_auth_wrapper_execs_generic_script
  test_ls_filters_non_codex_containers
  test_upgrade_backup_support_check
  test_run_rejects_resource_flags_for_existing_container
  test_upgrade_uses_explicit_resource_overrides
  test_cleanup_temp_dir_handles_read_only_trees

  log "PASS: all shell unit tests completed"
}

main "$@"
