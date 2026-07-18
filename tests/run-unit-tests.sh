#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=tests/testlib.sh
. "$SCRIPT_DIR/testlib.sh"

trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: ./tests/run-unit-tests.sh [--filter TEXT] [--from TEXT]
       ./tests/run-unit-tests.sh [TEXT]

Options:
  --filter TEXT  Run only tests whose function name or description contains TEXT
  --from TEXT    Run all tests starting at the first test whose function name or description contains TEXT

If a single positional TEXT argument is provided, it is treated like --filter TEXT.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
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

load_agentctl_functions() {
  local harness

  harness="$(mktemp "${TMPDIR:-/tmp}/agentctl-unit.XXXXXX")"
  register_dir_cleanup "$harness"

  sed -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=\"$TEST_ROOT\"#" \
    -e '/^cmd="${1:-}"/,$d' \
    "$AGENTCTL_IMPL" >"$harness"
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
    "AGENTCTL_TOOLS_HOME=$temp_home/tools"
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

file_mtime() {
  local path="$1"

  stat -c %Y "$path" 2>/dev/null \
    || stat -f %m "$path"
}

test_run_config_wires_runtime_config_json() {
  begin_test "run_cmd wires repeated --config values into the launched agent.sh command"

  load_agentctl_functions

  local captured_pre_exec=""
  local captured_cmd=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  run_container() {
    captured_pre_exec="${10}"
    shift 12
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

test_run_cmd_wires_ollama_host_to_custom_command() {
  begin_test "run_cmd wires Ollama host config and env into custom command"

  load_agentctl_functions

  local captured_cmd=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  run_container() {
    shift 13
    captured_cmd="$(printf '%s\n' "$*")"
  }

  OLLAMA_HOST=http://192.168.64.1:11439 run_cmd \
    --name unit-test-container \
    --workdir "$workdir" \
    -c ollama_host=http://192.168.64.1:11439 \
    --cmd agent.sh run exec

  printf '%s\n' "$captured_cmd" | grep -Fq 'env' || fail "Expected custom command to be wrapped with env, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq 'OLLAMA_HOST=http://192.168.64.1:11439' || fail "Expected OLLAMA_HOST to be forwarded, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq 'AGENTCTL_RUNTIME_CONFIG_JSON=' || fail "Expected runtime config JSON to be passed to custom command, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq '"ollama_host":"http://192.168.64.1:11439"' || fail "Expected ollama_host launch config in custom command env, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq 'agent.sh' || fail "Expected custom command to be preserved, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq 'run' || fail "Expected custom command args to be preserved, got: $captured_cmd"
}

test_run_help_reports_runtime_options() {
  begin_test "run help reports runtime selection options"

  run_capture "$AGENTCTL" run --help
  assert_status 0
  assert_contains "--runtime NAME  Preferred runtime to launch"
  assert_contains "--home PATH     Host directory to mount at /home/coder"
  assert_contains "--install-runtime  Install the selected runtime before launch"
  assert_contains "--model NAME    Override the launch model for the selected runtime"
  assert_contains "--online        Use the runtime's online/provider-backed mode"
  assert_contains "--stdio         With --cmd, keep stdin open without a TTY"
}

test_exec_help_reports_stdio_option() {
  begin_test "exec help reports stdio protocol option"

  run_capture "$AGENTCTL" exec --help
  assert_status 0
  assert_contains "--stdio      Keep stdin open without a TTY"
  assert_contains "With --stdio, provide an explicit command after --"
}

test_run_cmd_wires_home_mount() {
  begin_test "run_cmd wires --home into container creation"

  load_agentctl_functions

  local workdir
  local home_mount
  local expected_home_mount
  local captured_home_mount=""

  workdir="$(new_workdir)"
  home_mount="$(new_workdir)"
  expected_home_mount="$(CDPATH= cd -- "$home_mount" && pwd)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { return 1; }
  run_container() {
    captured_home_mount="$9"
  }

  run_cmd --name unit-test-container --workdir "$workdir" --home "$home_mount" --cmd true

  [ "$captured_home_mount" = "$expected_home_mount" ] || fail "Expected home mount $expected_home_mount, got: $captured_home_mount"
}

test_doctor_help_reports_fix_option() {
  begin_test "doctor help reports state repair options"

  run_capture "$AGENTCTL" doctor --help
  assert_status 0
  assert_contains "Usage: agentctl doctor [options]"
  assert_contains "--fix"
  assert_contains "--host"
  assert_contains "user-state ownership"
}

test_agentctl_version_matches_version_file() {
  begin_test "agentctl version matches the repository VERSION file"

  local expected_version
  expected_version="$(cat "$TEST_ROOT/VERSION")"

  run_capture "$AGENTCTL" --version
  assert_status 0
  [ "$RUN_OUTPUT" = "agentctl $expected_version" ] \
    || fail "Expected agentctl $expected_version, got: $RUN_OUTPUT"

  run_capture "$AGENTCTL" version
  assert_status 0
  [ "$RUN_OUTPUT" = "agentctl $expected_version" ] \
    || fail "Expected version subcommand to report agentctl $expected_version, got: $RUN_OUTPUT"
}

test_doctor_host_reports_runtime_and_capabilities() {
  begin_test "doctor --host reports runtime and capabilities"

  load_agentctl_functions

  require_container() { return 0; }
  command() {
    if [ "$1" = "-v" ] && [ "$2" = "mock_container" ]; then
      printf '/opt/homebrew/bin/container\n'
      return 0
    fi
    builtin command "$@"
  }
  mock_container() {
    case "$*" in
      "--version")
        printf 'container CLI version 1.1.0 (build: release, commit: test)\n'
        ;;
      "system version --format json")
        printf '[{"name":"container-apiserver","version":"1.1.0"}]\n'
        ;;
      "list --help")
        printf '%s\n' '  --quiet' '  --format <format>'
        ;;
      "export --help")
        printf '%s\n' '  --output <output>'
        ;;
      "run --help")
        printf '%s\n' '  --ssh' '  --publish-socket <spec>' '  --shm-size <size>'
        ;;
      "--help")
        printf '%s\n' '  copy, cp  Copy files' '  machine  Manage machines'
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  CONTAINER_CMD="mock_container"

  run_capture doctor_cmd --host
  assert_status 0
  assert_contains "/opt/homebrew/bin/container"
  assert_contains "Host JSON processor"
  assert_contains "supported                yes"
  assert_contains "container CLI version 1.1.0"
  assert_contains '"container-apiserver"'
  assert_contains "container copy           yes"
  assert_contains "SSH agent forwarding     yes"
  assert_contains "container machine        yes"
  CONTAINER_CMD=container
  unset -f command
}

test_jq_dependency_version_checks() {
  begin_test "host jq dependency rejects missing and unsupported versions"

  load_agentctl_functions
  jq_version_supported "1.6"
  jq_version_supported "1.7.1-apple"
  ! jq_version_supported "1.5"
  ! jq_version_supported "not-a-version"

  command() {
    if [ "$1" = "-v" ] && [ "$2" = "jq" ]; then return 1; fi
    builtin command "$@"
  }
  require_jq_wrapper() { ( require_jq ); }
  run_capture require_jq_wrapper
  assert_status 1
  assert_contains "Missing 'jq' command"
  unset -f command

  jq_version() { printf '1.5\n'; }
  run_capture require_jq_wrapper
  assert_status 1
  assert_contains "Unsupported jq version: 1.5"
}

test_host_address_reads_container_1_1_gateway() {
  begin_test "host-address reads the Apple container 1.1 network gateway"

  load_agentctl_functions

  local output
  CONTAINER_CMD=container
  container() {
    case "$*" in
      "--version") return 0 ;;
      "network inspect default")
        printf '%s\n' '[{"id":"default","configuration":{},"status":{"ipv4Subnet":"192.168.65.0/24","ipv4Gateway":"192.168.65.1"}}]'
        ;;
      *) fail "Unexpected container invocation: $*" ;;
    esac
  }

  output="$(host_address_cmd)"
  [ "$output" = "192.168.65.1" ] || fail "Expected 192.168.65.1, got: $output"
  unset -f container
}

test_host_address_supports_custom_network_subnet_fallback() {
  begin_test "host-address supports custom networks and subnet fallback"

  load_agentctl_functions

  local output
  CONTAINER_CMD=container
  container() {
    case "$*" in
      "--version") return 0 ;;
      "network inspect mcp")
        printf '%s\n' '{"id":"mcp","status":{"ipv4Subnet":"10.42.7.0/24"}}'
        ;;
      *) fail "Unexpected container invocation: $*" ;;
    esac
  }

  output="$(host_address_cmd --network mcp)"
  [ "$output" = "10.42.7.1" ] || fail "Expected 10.42.7.1, got: $output"
  unset -f container
}

test_host_address_handles_non_24_and_rejects_malformed_networks() {
  begin_test "host-address calculates non-/24 networks and rejects malformed input"

  load_agentctl_functions
  require_container() { return 0; }
  CONTAINER_CMD=container
  container() {
    case "$*" in
      "network inspect broad") printf '%s\n' '{"status":{"ipv4Subnet":"10.42.7.99/20"}}' ;;
      "network inspect malformed") printf '%s\n' '{"status":{"ipv4Subnet":"10.42.7.0/not-a-prefix"}}' ;;
      "network inspect empty") printf '%s\n' 'not-json' ;;
      *) fail "Unexpected container invocation: $*" ;;
    esac
  }
  [ "$(host_address_cmd --network broad)" = "10.42.0.1" ] || fail "Expected /20 network host address"
  host_address_wrapper() { ( host_address_cmd "$@" ); }
  run_capture host_address_wrapper --network malformed
  assert_status 1
  assert_contains "no usable IPv4 gateway"
  run_capture host_address_wrapper --network empty
  assert_status 1
  assert_contains "no usable IPv4 gateway"
  unset -f container
}

test_inspect_json_helpers_handle_schema_shapes_and_invalid_input() {
  begin_test "inspect JSON helpers handle objects, arrays, and invalid input"

  load_agentctl_functions
  [ "$(printf '%s' '{"configuration":{"mounts":[{"destination":"/workdir","options":"ro"}]}}' | container_mount_mode)" = "ro" ] \
    || fail "Expected object inspect mount mode"
  [ "$(printf '%s' '[{"mounts":[{"dst":"/workdir","options":[]}]}]' | container_mount_mode)" = "rw" ] \
    || fail "Expected array inspect mount mode"
  [ "$(printf '%s' 'not-json' | container_mount_mode)" = "unknown" ] || fail "Expected invalid inspect fallback"
  [ "$(printf '%s' '[{"configuration":{"image":{"name":"agent-plain:latest"},"resources":{"cpus":2,"memoryInBytes":4294967296},"mounts":[{"target":"/workdir","src":"/tmp/work","options":["readonly"]}]}}]' | container_upgrade_info)" = $'agent-plain:latest\t/tmp/work\tro\t2\t4294967296' ] \
    || fail "Expected upgrade inspect tuple"
  [ "$(printf '%s' '' | container_upgrade_info)" = $'\t\t\t\t' ] || fail "Expected empty inspect tuple"
}

test_configure_container_host_alias_replaces_stale_entry() {
  begin_test "container host alias replaces a stale gateway entry"

  load_agentctl_functions

  local temp_dir
  local hosts_file
  local update_script=""
  local update_address=""
  local update_hostname=""
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-host-alias.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  hosts_file="$temp_dir/hosts"
  printf '%s\n' \
    '127.0.0.1 localhost' \
    '192.168.64.1 host.container.internal old-alias' \
    '10.0.0.2 unrelated.internal' >"$hosts_file"

  container_network_host_address() { printf '%s\n' 192.168.65.1; }
  CONTAINER_CMD=container
  container() {
    [ "$1" = "exec" ] || fail "Expected container exec, got: $*"
    [ "$2" = "--user" ] && [ "$3" = "root" ] || fail "Expected root exec, got: $*"
    [ "$4" = "unit-test-container" ] || fail "Expected target container, got: $*"
    update_script="$7"
    update_address="$9"
    update_hostname="${10}"
  }

  configure_container_host_alias unit-test-container
  sh -c "$update_script" sh "$update_address" "$update_hostname" "$hosts_file"

  awk '$1 == "192.168.65.1" && $2 == "host.container.internal" { found = 1 } END { exit !found }' "$hosts_file" \
    || fail "Expected refreshed host alias: $(cat "$hosts_file")"
  if grep -Fq '192.168.64.1' "$hosts_file"; then
    fail "Did not expect stale host gateway: $(cat "$hosts_file")"
  fi
  grep -Fqx '10.0.0.2 unrelated.internal' "$hosts_file" \
    || fail "Expected unrelated host entry to remain"
  unset -f container
}

test_migrate_legacy_runtime_config_files() {
  begin_test "legacy runtime defaults migrate into the agentctl layout"

  load_agentctl_functions

  local temp_root
  local fake_bin
  local migration_script=""
  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-legacy-codex.XXXXXX")"
  register_dir_cleanup "$temp_root"
  mkdir -p "$temp_root/etc/codexctl" "$temp_root/etc/claudectl" \
    "$temp_root/etc/opencodectl" "$temp_root/etc/qwenctl" "$temp_root/etc/pictl" \
    "$temp_root/etc/agentctl/codex" "$temp_root/home/coder/.codex"
  printf '%s\n' legacy-image >"$temp_root/etc/codexctl/image.md"
  printf '%s\n' legacy-codex-config >"$temp_root/etc/codexctl/config.toml"
  printf '%s\n' custom-unknown >"$temp_root/etc/codexctl/custom.txt"
  printf '%s\n' canonical-codex-config >"$temp_root/etc/agentctl/codex/config.toml"
  printf '%s\n' legacy-config >"$temp_root/etc/agentctl/config.toml"
  ln -s "$temp_root/etc/codexctl/image.md" "$temp_root/etc/agentctl/image.md"
  ln -s /etc/codexctl/image.md "$temp_root/home/coder/.codex/AGENTS.md"
  printf '%s\n' claude-default >"$temp_root/etc/claudectl/settings.json"
  mkdir -p "$temp_root/etc/agentctl/claude"
  printf '%s\n' canonical-claude >"$temp_root/etc/agentctl/claude/settings.json"
  printf '%s\n' opencode-default >"$temp_root/etc/opencodectl/config.json"
  printf '%s\n' qwen-default >"$temp_root/etc/qwenctl/settings.json"
  printf '%s\n' pi-default >"$temp_root/etc/pictl/config.json"

  CONTAINER_CMD=container
  container() {
    [ "$1" = "exec" ] || fail "Expected container exec, got: $*"
    migration_script="$7"
  }

  migrate_legacy_runtime_config_files unit-test-container
  run_capture sh -c "$migration_script" sh "$temp_root"
  assert_status 0
  assert_contains "preserved legacy Codex defaults at /etc/agentctl/migration-backups/codexctl"
  assert_contains "preserved conflicting legacy defaults at /etc/agentctl/migration-backups/claudectl"

  [ ! -e "$temp_root/etc/codexctl" ] || fail "Expected legacy /etc/codexctl to be removed"
  [ "$(cat "$temp_root/etc/agentctl/codex/config.toml")" = "canonical-codex-config" ] \
    || fail "Expected canonical Codex config to win migration conflicts"
  [ "$(cat "$temp_root/etc/agentctl/migration-backups/codexctl/config.toml")" = "legacy-codex-config" ] \
    || fail "Expected conflicting legacy Codex config to be preserved"
  [ "$(cat "$temp_root/etc/agentctl/migration-backups/codexctl/custom.txt")" = "custom-unknown" ] \
    || fail "Expected unknown legacy Codex files to be preserved"
  [ ! -e "$temp_root/etc/agentctl/config.toml" ] || fail "Expected misplaced generic Codex config to be removed"
  [ ! -L "$temp_root/etc/agentctl/image.md" ] || fail "Expected image metadata symlink to become a regular file"
  [ "$(cat "$temp_root/etc/agentctl/image.md")" = "legacy-image" ] || fail "Expected image metadata to survive migration"
  [ "$(readlink "$temp_root/home/coder/.codex/AGENTS.md")" = "/etc/agentctl/image.md" ] \
    || fail "Expected legacy AGENTS.md symlink to use the agentctl image path"
  [ "$(cat "$temp_root/etc/agentctl/claude/settings.json")" = "canonical-claude" ] \
    || fail "Expected canonical Claude defaults to win migration conflicts"
  [ "$(cat "$temp_root/etc/agentctl/migration-backups/claudectl/settings.json")" = "claude-default" ] \
    || fail "Expected conflicting legacy Claude defaults to be preserved in a backup"
  [ "$(cat "$temp_root/etc/agentctl/opencode/config.json")" = "opencode-default" ] \
    || fail "Expected OpenCode defaults to migrate"
  [ "$(cat "$temp_root/etc/agentctl/qwen/settings.json")" = "qwen-default" ] \
    || fail "Expected Qwen defaults to migrate"
  [ "$(cat "$temp_root/etc/agentctl/pi/config.json")" = "pi-default" ] \
    || fail "Expected Pi defaults to migrate"
  for legacy_dir in claudectl opencodectl qwenctl pictl; do
    [ ! -e "$temp_root/etc/$legacy_dir" ] || fail "Expected legacy /etc/$legacy_dir to be removed"
  done
  unset -f container
}

test_migrate_legacy_runtime_config_files_preserves_source_on_copy_failure() {
  begin_test "legacy runtime migration preserves source after copy failure"

  load_agentctl_functions

  local temp_root
  local migration_script=""
  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-legacy-failure.XXXXXX")"
  register_dir_cleanup "$temp_root"
  fake_bin="$temp_root/bin"
  mkdir -p "$fake_bin" "$temp_root/etc/opencodectl" "$temp_root/etc/agentctl/opencode" "$temp_root/home/coder/.codex"
  printf '%s\n' irreplaceable >"$temp_root/etc/opencodectl/config.json"
  printf '%s\n' canonical >"$temp_root/etc/agentctl/opencode/config.json"
  cat >"$fake_bin/cp" <<'EOF'
#!/bin/sh
exit 73
EOF
  chmod +x "$fake_bin/cp"

  CONTAINER_CMD=container
  container() {
    [ "$1" = "exec" ] || fail "Expected container exec, got: $*"
    migration_script="$7"
  }

  migrate_legacy_runtime_config_files unit-test-container
  run_capture env PATH="$fake_bin:/usr/bin:/bin" sh -c "$migration_script" sh "$temp_root"
  [ "$RUN_STATUS" -ne 0 ] || fail "Expected migration copy failure"
  [ -e "$temp_root/etc/opencodectl/config.json" ] \
    || fail "Expected legacy source to remain after copy failure"
  [ "$(cat "$temp_root/etc/agentctl/opencode/config.json")" = "canonical" ] \
    || fail "Expected canonical target to remain intact after copy failure"
  unset -f container
}

test_runtime_default_files_apply_local_overrides() {
  begin_test "runtime defaults apply ignored host-local overrides"

  load_agentctl_functions

  local temp_dir
  local refresh_log=""
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-local-defaults.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  DEFAULTS_DIR="$temp_dir/defaults"
  LOCAL_DEFAULTS_DIR="$temp_dir/defaults.local"
  mkdir -p "$DEFAULTS_DIR/codex" "$DEFAULTS_DIR/claude" \
    "$DEFAULTS_DIR/opencode" "$DEFAULTS_DIR/qwen" "$DEFAULTS_DIR/pi" \
    "$LOCAL_DEFAULTS_DIR/codex" "$LOCAL_DEFAULTS_DIR/claude" \
    "$LOCAL_DEFAULTS_DIR/opencode" "$LOCAL_DEFAULTS_DIR/qwen" "$LOCAL_DEFAULTS_DIR/pi"
  printf '%s\n' baseline >"$DEFAULTS_DIR/codex/config.toml"
  printf '%s\n' profile >"$DEFAULTS_DIR/codex/base.config.toml"
  printf '%s\n' models >"$DEFAULTS_DIR/codex/local_models.json"
  printf '%s\n' local >"$LOCAL_DEFAULTS_DIR/codex/config.toml"
  printf '%s\n' custom-profile >"$LOCAL_DEFAULTS_DIR/codex/custom.config.toml"
  printf '%s\n' baseline-claude >"$DEFAULTS_DIR/claude/settings.json"
  printf '%s\n' local-claude >"$LOCAL_DEFAULTS_DIR/claude/settings.json"
  printf '%s\n' local-opencode >"$LOCAL_DEFAULTS_DIR/opencode/opencode.json"
  printf '%s\n' local-qwen >"$LOCAL_DEFAULTS_DIR/qwen/settings.json"
  printf '%s\n' local-pi >"$LOCAL_DEFAULTS_DIR/pi/models.json"

  refresh_container_file() {
    refresh_log="${refresh_log}$2 -> $3\n"
  }

  refresh_codex_config_files unit-test-container /etc/agentctl/codex root:root
  refresh_optional_runtime_default_files unit-test-container

  printf '%b' "$refresh_log" | grep -Fq "$DEFAULTS_DIR/codex/config.toml -> /etc/agentctl/codex/config.toml" \
    || fail "Expected tracked Codex baseline to be refreshed"
  printf '%b' "$refresh_log" | grep -Fq "$LOCAL_DEFAULTS_DIR/codex/config.toml -> /etc/agentctl/codex/config.toml" \
    || fail "Expected local Codex config to override the baseline"
  printf '%b' "$refresh_log" | grep -Fq "$LOCAL_DEFAULTS_DIR/codex/custom.config.toml -> /etc/agentctl/codex/custom.config.toml" \
    || fail "Expected additional local Codex profiles to be refreshed"
  [ "$(runtime_default_file claude settings.json)" = "$LOCAL_DEFAULTS_DIR/claude/settings.json" ] \
    || fail "Expected local Claude settings to override the baseline"
  printf '%b' "$refresh_log" | grep -Fq "$LOCAL_DEFAULTS_DIR/opencode/opencode.json -> /etc/agentctl/opencode/opencode.json" \
    || fail "Expected local OpenCode defaults to be refreshed"
  printf '%b' "$refresh_log" | grep -Fq "$LOCAL_DEFAULTS_DIR/qwen/settings.json -> /etc/agentctl/qwen/settings.json" \
    || fail "Expected local Qwen defaults to be refreshed"
  printf '%b' "$refresh_log" | grep -Fq "$LOCAL_DEFAULTS_DIR/pi/models.json -> /etc/agentctl/pi/models.json" \
    || fail "Expected local Pi defaults to be refreshed"
  unset -f refresh_container_file
}

test_run_container_refreshes_host_alias_before_exec() {
  begin_test "run_container refreshes the host alias before agent exec"

  load_agentctl_functions

  local configured_name=""
  require_container() { :; }
  container_exists() { return 0; }
  container_running() { return 0; }
  validate_mount_mode() { :; }
  configure_container_host_alias() { configured_name="$1"; }
  warn_if_container_agentctl_versions_differ() { :; }
  CONTAINER_CMD=container
  container() {
    [ "$1" = "exec" ] || fail "Expected agent exec, got: $*"
  }

  run_capture run_container unit-test-container agent-plain 0 0 "" "" 0 "$TEST_ROOT" "" "" "" 0 0 true
  assert_status 0
  [ "$configured_name" = "unit-test-container" ] \
    || fail "Expected host alias refresh before exec, got: $configured_name"
  unset -f container
}

test_container_agentctl_version_warning_distinguishes_image_and_tooling() {
  begin_test "container version warning distinguishes image and refreshed tooling"

  load_agentctl_functions

  local current_version
  current_version="$(cat "$TEST_ROOT/VERSION")"
  CONTAINER_CMD=container
  container() {
    case "$*" in
      *tooling-version*) printf '%s\n' "$current_version" ;;
      *image-version*) printf '%s\n' 0.1.0 ;;
      *) return 1 ;;
    esac
  }

  run_capture warn_if_container_agentctl_versions_differ unit-test-container
  assert_status 0
  assert_not_contains "uses agentctl tooling"
  assert_contains "was built with agentctl 0.1.0"
  assert_contains "Consider rebuilding and upgrading its image"

  container() {
    case "$*" in
      *tooling-version*|*image-version*) printf '%s\n' __missing__ ;;
      *) return 1 ;;
    esac
  }
  run_capture warn_if_container_agentctl_versions_differ unit-test-container
  assert_contains "predates agentctl version tracking"
  assert_contains "has no image build version"

  container() {
    case "$*" in
      *tooling-version*) printf '%s\n' 0.1.0 ;;
      *image-version*) printf '%s\n' "$current_version" ;;
      *) return 1 ;;
    esac
  }
  run_capture warn_if_container_agentctl_versions_differ unit-test-container
  assert_contains "uses agentctl tooling 0.1.0"
  assert_contains "refresh --name unit-test-container"
  unset -f container
}

test_new_container_launch_checks_agentctl_versions() {
  begin_test "new container launch checks image and tooling versions"

  load_agentctl_functions

  local checked_name=""
  container_exists() { return 1; }
  container_running() { return 1; }
  persist_container_system_manifest_baseline_from_image() { :; }
  configure_container_host_alias() { :; }
  warn_if_container_agentctl_versions_differ() { checked_name="$1"; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      create|start|stop) return 0 ;;
      exec) return 0 ;;
      *) fail "Unexpected container invocation: $*" ;;
    esac
  }

  run_capture run_container unit-test-container agent-plain 0 0 "" "" 0 "$TEST_ROOT" "" "" "" 0 0 true
  assert_status 0
  assert_contains "Creating container..."
  assert_contains "Starting container: unit-test-container"
  assert_contains "Stopping container: unit-test-container"
  [ "$checked_name" = "unit-test-container" ] \
    || fail "Expected version check on first launch, got: ${checked_name:-none}"
  unset -f container
}

test_start_and_restart_refresh_host_alias() {
  begin_test "start and restart refresh the container host alias"

  load_agentctl_functions

  local action_log=""
  local alias_log=""
  require_container() { :; }
  configure_container_host_alias() { alias_log="${alias_log}$1"$'\n'; }
  CONTAINER_CMD=container
  container() { action_log="${action_log}$1:$2"$'\n'; }

  simple_name_cmd start --name unit-test-container
  simple_name_cmd restart --name unit-test-container

  [ "${action_log%$'\n'}" = $'start:unit-test-container\nrestart:unit-test-container' ] \
    || fail "Expected start and restart actions, got: $action_log"
  [ "${alias_log%$'\n'}" = $'unit-test-container\nunit-test-container' ] \
    || fail "Expected alias refresh after both actions, got: $alias_log"
  unset -f container
}

test_rescue_help_reports_backup_image_options() {
  begin_test "rescue help reports backup image options"

  run_capture "$AGENTCTL" rescue --help
  assert_status 0
  assert_contains "Usage: agentctl rescue --image IMAGE"
  assert_contains "--keep"
  assert_contains "--cmd ..."
  assert_contains "backup image"
}

test_run_model_wires_selected_model() {
  begin_test "run_cmd wires --model into the launched agent.sh command"

  load_agentctl_functions

  local captured_cmd=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  run_container() {
    shift 12
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

  load_agentctl_functions

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
  printf '%s\n' "$build_call" | grep -Eq -- '--build-arg BUILD_TIME=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' || fail "Expected shared build time build arg, got: $build_call"
}

test_build_cmd_expands_all_registered_runtimes() {
  begin_test "build_cmd expands all registered runtimes"

  load_agentctl_functions

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

  run_capture build_cmd --image agent-plain --runtimes all
  assert_status 0
  printf '%s\n' "$build_call" | grep -Fq -- '--build-arg AGENT_RUNTIMES=codex,claude,opencode,pi,qwen' \
    || fail "Expected every registered runtime in the build arg, got: $build_call"
  printf '%s\n' "$build_call" | grep -Fq -- '--build-arg AGENT_DEFAULT_RUNTIME=codex' \
    || fail "Expected the normal default runtime to remain codex, got: $build_call"
}

test_build_cmd_all_rejects_manifest_filename_id_mismatch() {
  begin_test "build_cmd all rejects runtime manifest filename and id mismatch"

  local temp_dir
  local unit_script
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-runtime-manifest.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"
  mkdir -p "$temp_dir/runtimes.d"
  printf '%s\n' '{"id":"different"}' >"$temp_dir/runtimes.d/example.json"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$AGENTCTL_IMPL"
SCRIPT_DIR="$temp_dir"
build_cmd --image agent-plain --runtimes all
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "Runtime manifest filename must match id 'different'"
}

test_build_cmd_uses_first_runtime_as_default_when_unspecified() {
  begin_test "build_cmd uses the first runtime as default when unspecified"

  load_agentctl_functions

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

  load_agentctl_functions

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

  load_agentctl_functions

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

test_build_cmd_rebuilds_and_snapshots_local_dependencies() {
  begin_test "build_cmd rebuilds and snapshots local image dependencies"

  load_agentctl_functions

  local build_calls=""
  local build_times=""
  local tag_calls=""

  require_container() { return 0; }
  image_exists() { return 0; }
  stop_buildkit_container() { :; }
  mock_container() {
    case "$*" in
      build\ -t\ agent-plain\ *)
        build_calls="${build_calls}agent-plain"$'\n'
        build_times="${build_times}$(printf '%s\n' "$*" | sed -n 's/.*--build-arg BUILD_TIME=\([^ ]*\).*/\1/p')"$'\n'
        printf '%s\n' "$*" | grep -Fq -- '--no-cache' || fail "Expected agent-plain rebuild to use --no-cache, got: $*"
        ;;
      build\ -t\ agent-python\ *)
        build_calls="${build_calls}agent-python"$'\n'
        build_times="${build_times}$(printf '%s\n' "$*" | sed -n 's/.*--build-arg BUILD_TIME=\([^ ]*\).*/\1/p')"$'\n'
        printf '%s\n' "$*" | grep -Fq -- '--no-cache' || fail "Expected agent-python rebuild to use --no-cache, got: $*"
        ;;
      image\ tag\ agent-plain\ agent-plain:*)
        tag_calls="${tag_calls}agent-plain"$'\n'
        ;;
      image\ tag\ agent-python\ agent-python:*)
        tag_calls="${tag_calls}agent-python"$'\n'
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  CONTAINER_CMD="mock_container"

  run_capture build_cmd --image agent-python --rebuild
  assert_status 0
  [ "$build_calls" = $'agent-plain\nagent-python\n' ] || fail "Expected agent-plain then agent-python rebuilds, got: $build_calls"
  [ "$tag_calls" = $'agent-plain\nagent-python\n' ] || fail "Expected timestamp tags for both rebuilt images, got: $tag_calls"
  [ "$(printf '%s' "$build_times" | sort -u | wc -l | tr -d ' ')" = "1" ] || fail "Expected one shared build time across rebuilt images, got: $build_times"
  CONTAINER_CMD=container
}

test_build_cmd_snapshots_existing_image_when_timestamp_missing() {
  begin_test "build_cmd snapshots existing image when latest has no timestamp tag"

  load_agentctl_functions

  local tag_call=""

  require_container() { return 0; }
  image_exists() { return 0; }
  stop_buildkit_container() { :; }
  mock_container() {
    case "$*" in
      "image ls --format json")
        cat <<'EOF'
[
  {"descriptor":{"digest":"sha256:plain-latest"},"reference":"agent-plain:latest"},
  {"descriptor":{"digest":"sha256:older"},"reference":"docker.io/library/agent-plain:20260607-150156"}
]
EOF
        ;;
      image\ tag\ agent-plain\ agent-plain:*)
        tag_call="$(printf '%s\n' "$*")"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  CONTAINER_CMD="mock_container"

  run_capture build_cmd --image agent-plain
  assert_status 0
  assert_contains "Snapshotting missing image tag: agent-plain, agent-plain:"
  printf '%s\n' "$tag_call" | grep -Eq '^image tag agent-plain agent-plain:[0-9]{8}-[0-9]{6}$' || fail "Expected snapshot tag call, got: $tag_call"
  CONTAINER_CMD=container
}

test_build_cmd_skips_existing_image_when_timestamp_matches() {
  begin_test "build_cmd skips existing image when latest already has a timestamp tag"

  load_agentctl_functions

  local tag_calls=0

  require_container() { return 0; }
  image_exists() { return 0; }
  stop_buildkit_container() { :; }
  mock_container() {
    case "$*" in
      "image ls --format json")
        cat <<'EOF'
[
  {"descriptor":{"digest":"sha256:plain-latest"},"reference":"agent-plain:latest"},
  {"descriptor":{"digest":"sha256:plain-latest"},"reference":"docker.io/library/agent-plain:20260607-150156"}
]
EOF
        ;;
      image\ tag*)
        tag_calls=$((tag_calls + 1))
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  CONTAINER_CMD="mock_container"

  run_capture build_cmd --image agent-plain
  assert_status 0
  assert_contains "Image already exists: agent-plain (use --rebuild to rebuild)"
  [ "$tag_calls" -eq 0 ] || fail "Did not expect snapshot tag call, got $tag_calls"
  CONTAINER_CMD=container
}

test_build_cmd_recognizes_container_1_image_snapshot_schema() {
  begin_test "build_cmd recognizes timestamp tags in container 1 image JSON"

  load_agentctl_functions

  local tag_calls=0

  require_container() { return 0; }
  image_exists() { return 0; }
  stop_buildkit_container() { :; }
  mock_container() {
    case "$*" in
      "image ls --format json")
        cat <<'EOF'
[
  {
    "configuration":{"name":"agent-plain:latest","descriptor":{"digest":"sha256:plain-latest"}},
    "variants":[{"digest":"sha256:plain-variant","platform":{"architecture":"arm64","os":"linux"}}]
  },
  {
    "configuration":{"name":"docker.io/library/agent-plain:20260718-120000","descriptor":{"digest":"sha256:plain-latest"}},
    "variants":[{"digest":"sha256:plain-variant","platform":{"architecture":"arm64","os":"linux"}}]
  }
]
EOF
        ;;
      image\ tag*)
        tag_calls=$((tag_calls + 1))
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  CONTAINER_CMD="mock_container"

  run_capture build_cmd --image agent-plain
  assert_status 0
  assert_contains "Image already exists: agent-plain (use --rebuild to rebuild)"
  [ "$tag_calls" -eq 0 ] || fail "Did not expect snapshot tag call, got $tag_calls"
  CONTAINER_CMD=container
}

test_container_lookup_uses_quiet_exact_ids() {
  begin_test "container lookup uses quiet output and exact IDs"

  load_agentctl_functions

  mock_container() {
    case "$*" in
      "ls -a --quiet")
        printf '%s\n' agent-project agent-project-copy
        ;;
      "ls --quiet")
        printf '%s\n' agent-project-copy
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  CONTAINER_CMD="mock_container"

  container_exists agent-project || fail "Expected exact container ID to exist"
  if container_exists project; then
    fail "Did not expect a partial container ID to match"
  fi
  container_running agent-project-copy || fail "Expected running container ID"
  if container_running agent-project; then
    fail "Did not expect stopped container to be reported as running"
  fi
  CONTAINER_CMD=container
}

test_run_cmd_runtime_selection_does_not_auto_install_for_new_container() {
  begin_test "run_cmd does not auto-install a selected runtime for a new container"

  load_agentctl_functions

  local captured_pre_exec=""
  local captured_mem=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  run_container() {
    captured_pre_exec="${10}"
    captured_mem="$6"
  }

  container_exists() { return 1; }

  run_cmd --name unit-test-container --workdir "$workdir" --runtime claude --shell

  [ "$captured_pre_exec" = "run_pre_exec" ] || fail "Expected run_pre_exec, got: $captured_pre_exec"
  [ "$RUN_SELECTED_RUNTIME" = "claude" ] || fail "Expected runtime claude, got: $RUN_SELECTED_RUNTIME"
  [ "$RUN_INSTALL_RUNTIME" -eq 0 ] || fail "Did not expect runtime auto-install for a new container"
  [ "$RUN_SYNC_RUNTIME_AUTH" -eq 0 ] || fail "Did not expect online auth sync for local Claude shell launch"
  [ "$RUN_LOCAL_MODEL_PREFLIGHT" -eq 0 ] || fail "Did not expect local-model preflight for Claude shell launch"
  [ -z "$captured_mem" ] || fail "Did not expect Claude install memory override without explicit install, got: $captured_mem"
}

test_run_cmd_runtime_selection_does_not_auto_install_for_existing_container() {
  begin_test "run_cmd does not auto-install a selected runtime for an existing container"

  load_agentctl_functions

  local captured_pre_exec=""
  local captured_mem=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  run_container() {
    captured_pre_exec="${10}"
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

  load_agentctl_functions

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

  load_agentctl_functions

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

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-build-invalid.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$AGENTCTL_IMPL"
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

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-build-invalid.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$AGENTCTL_IMPL"
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

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-run-invalid.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$AGENTCTL_IMPL"
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

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-run-invalid.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$AGENTCTL_IMPL"
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

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-run-invalid.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$AGENTCTL_IMPL"
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

  load_agentctl_functions

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
    call_log="${call_log}user:$1:$2:${3:-}:${4:-}"$'\n'
  }
  runtime_info_in_container() {
    printf '{"runtime":"claude","installed":true,"auth_formats":["claude_ai_oauth_json"],"capabilities":{"auth_login":true,"auth_read":true,"auth_write":true}}'
  }
  keychain_auth_info() { printf 'refresh-token\t1776462236852\n'; }
  sync_runtime_auth_to_container() { call_log="${call_log}sync:$1:$2:$3"$'\n'; }

  run_capture run_pre_exec unit-test-container
  assert_status 0
  printf '%s' "$call_log" | grep -Fq $'user:unit-test-container:runtime:install:claude' || fail "Expected user runtime install call, got: $call_log"
  printf '%s' "$call_log" | grep -Fq $'user:unit-test-container:preferred:set' || fail "Expected preferred set call, got: $call_log"
  printf '%s' "$call_log" | grep -Fq $'sync:unit-test-container:claude:claude_ai_oauth_json' || fail "Expected runtime auth sync call, got: $call_log"
}

test_exec_cmd_no_tty_omits_interactive_flags() {
  begin_test "exec --no-tty omits interactive container flags"

  load_agentctl_functions

  local exec_log=""
  local old_container_cmd="$CONTAINER_CMD"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_running() { [ "$1" = "unit-test-container" ]; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      exec)
        shift
        exec_log="$(printf '%s\n' "$*")"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture exec_cmd --name unit-test-container --no-tty -- bash -lc 'true'
  assert_status 0
  if printf '%s\n' "$exec_log" | grep -Fq -- '-it'; then
    fail "Did not expect -it for --no-tty exec, got: $exec_log"
  fi
  printf '%s\n' "$exec_log" | grep -Fq -- 'unit-test-container' || fail "Expected exec target container, got: $exec_log"
  printf '%s\n' "$exec_log" | grep -Fq -- 'bash' || fail "Expected exec command, got: $exec_log"
  CONTAINER_CMD="$old_container_cmd"
}

test_exec_cmd_stdio_uses_interactive_without_tty() {
  begin_test "exec --stdio keeps stdin open without tty flags"

  load_agentctl_functions

  local exec_log=""
  local old_container_cmd="$CONTAINER_CMD"

  require_container() { return 0; }
  container_running() { [ "$1" = "unit-test-container" ]; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      exec)
        shift
        exec_log="$(printf '%s\n' "$*")"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture exec_cmd --name unit-test-container --stdio -- sh -lc 'printf ok'
  assert_status 0
  printf '%s\n' "$exec_log" | grep -Fq -- '--interactive' || fail "Expected --interactive for --stdio exec, got: $exec_log"
  if printf '%s\n' "$exec_log" | grep -Eq -- '(^|[[:space:]])(-it|-t|--tty)([[:space:]]|$)'; then
    fail "Did not expect tty flags for --stdio exec, got: $exec_log"
  fi
  printf '%s\n' "$exec_log" | grep -Fq -- 'unit-test-container' || fail "Expected exec target container, got: $exec_log"
  printf '%s\n' "$exec_log" | grep -Fq -- 'sh' || fail "Expected explicit command, got: $exec_log"
  printf '%s\n' "$exec_log" | grep -Fq -- 'printf ok' || fail "Expected command arguments to be preserved, got: $exec_log"
  CONTAINER_CMD="$old_container_cmd"
}

test_exec_cmd_stdio_requires_delimiter_and_command() {
  begin_test "exec --stdio requires command after delimiter"

  local temp_dir
  local harness
  local unit_script

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-stdio-invalid.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  harness="$temp_dir/harness.sh"

  sed -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=\"$TEST_ROOT\"#" \
    -e '/^cmd="${1:-}"/,$d' \
    "$AGENTCTL_IMPL" >"$harness"

  unit_script="$temp_dir/no-delimiter.sh"
  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$harness"
require_container() { return 0; }
container_running() { [ "\$1" = "unit-test-container" ]; }
exec_cmd --name unit-test-container --stdio sh -lc true
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "exec --stdio requires an explicit command after --"

  unit_script="$temp_dir/no-command.sh"
  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$harness"
require_container() { return 0; }
container_running() { [ "\$1" = "unit-test-container" ]; }
exec_cmd --name unit-test-container --stdio --
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "Missing command after --"
}

test_exec_cmd_stdio_requires_running_container() {
  begin_test "exec --stdio requires running container"

  local temp_dir
  local harness
  local unit_script

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-stdio-stopped.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  harness="$temp_dir/harness.sh"

  sed -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=\"$TEST_ROOT\"#" \
    -e '/^cmd="${1:-}"/,$d' \
    "$AGENTCTL_IMPL" >"$harness"

  unit_script="$temp_dir/stopped.sh"
  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$harness"
require_container() { return 0; }
container_running() { return 1; }
exec_cmd --name stopped-container --stdio -- cat
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "Container not running: stopped-container"
}

test_run_cmd_stdio_uses_interactive_without_tty() {
  begin_test "run --stdio uses interactive exec without tty flags"

  load_agentctl_functions

  local exec_log=""
  local old_container_cmd="$CONTAINER_CMD"
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { [ "$1" = "unit-test-container" ]; }
  validate_mount_mode() { :; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      exec)
        shift
        exec_log="$(printf '%s\n' "$*")"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture run_cmd --name unit-test-container --workdir "$workdir" --stdio --cmd sh -lc 'printf ok'
  assert_status 0
  printf '%s\n' "$exec_log" | grep -Fq -- '--interactive' || fail "Expected --interactive for run --stdio, got: $exec_log"
  if printf '%s\n' "$exec_log" | grep -Eq -- '(^|[[:space:]])(-it|-t|--tty)([[:space:]]|$)'; then
    fail "Did not expect tty flags for run --stdio, got: $exec_log"
  fi
  printf '%s\n' "$exec_log" | grep -Fq -- 'unit-test-container' || fail "Expected exec target container, got: $exec_log"
  printf '%s\n' "$exec_log" | grep -Fq -- 'sh' || fail "Expected explicit command, got: $exec_log"
  printf '%s\n' "$exec_log" | grep -Fq -- 'printf ok' || fail "Expected command arguments to be preserved, got: $exec_log"
  CONTAINER_CMD="$old_container_cmd"
}

test_run_cmd_stdio_suppresses_lifecycle_stdout() {
  begin_test "run --stdio suppresses lifecycle command stdout"

  load_agentctl_functions

  local old_container_cmd="$CONTAINER_CMD"
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  container_exists() { return 1; }
  container_running() { return 1; }
  persist_container_system_manifest_baseline_from_image() { :; }
  validate_mount_mode() { :; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      create)
        printf 'container-create-stdout\n'
        ;;
      start)
        printf 'container-start-stdout\n'
        ;;
      exec)
        printf 'protocol-stdout\n'
        ;;
      stop)
        :
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture run_cmd --name unit-test-container --workdir "$workdir" --stdio --cmd cat
  assert_status 0
  assert_contains "protocol-stdout"
  if printf '%s\n' "$RUN_OUTPUT" | grep -Fq -- 'container-create-stdout'; then
    fail "Did not expect create stdout in run --stdio output: $RUN_OUTPUT"
  fi
  if printf '%s\n' "$RUN_OUTPUT" | grep -Fq -- 'container-start-stdout'; then
    fail "Did not expect start stdout in run --stdio output: $RUN_OUTPUT"
  fi
  CONTAINER_CMD="$old_container_cmd"
}

test_run_container_stdio_detaches_pre_exec_stdin() {
  begin_test "run --stdio keeps protocol stdin away from pre-exec"

  local temp_dir
  local unit_script

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-run-stdio-preexec.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$AGENTCTL_IMPL"
require_container() { return 0; }
container_exists() { [ "\$1" = "unit-test-container" ]; }
container_running() { [ "\$1" = "unit-test-container" ]; }
validate_mount_mode() { :; }
configure_container_host_alias() { :; }
pre_reads_stdin() {
  local line=""
  if IFS= read -r line; then
    printf 'pre:%s\n' "\$line"
  fi
}
CONTAINER_CMD=container
container() {
  case "\$1" in
    exec)
      local line=""
      if IFS= read -r line; then
        printf 'exec:%s\n' "\$line"
      fi
      ;;
    *)
      printf 'unexpected:%s\n' "\$*" >&2
      return 1
      ;;
  esac
}
printf 'protocol-input\n' | run_container unit-test-container agent-python 0 0 "" "" 0 "$TEST_ROOT" "" pre_reads_stdin "" 0 1 cat
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 0
  assert_contains "exec:protocol-input"
  if printf '%s\n' "$RUN_OUTPUT" | grep -Fq -- 'pre:protocol-input'; then
    fail "pre-exec consumed protocol stdin: $RUN_OUTPUT"
  fi
}

test_run_cmd_stdio_requires_cmd() {
  begin_test "run --stdio requires --cmd"

  local temp_dir
  local unit_script

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-run-stdio-invalid.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$AGENTCTL_IMPL"
require_container() { return 0; }
run_cmd --stdio
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "--stdio requires --cmd"
}

test_run_cmd_stdio_rejects_shell() {
  begin_test "run --stdio rejects --shell"

  local temp_dir
  local unit_script

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-run-stdio-shell.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  unit_script="$temp_dir/check.sh"

  cat >"$unit_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$AGENTCTL_IMPL"
require_container() { return 0; }
run_cmd --stdio --shell --cmd true
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "Cannot combine --shell with --cmd"
}

test_run_pre_exec_updates_codex_via_runtime_helper() {
  begin_test "run_pre_exec updates codex via the runtime user helper"

  load_agentctl_functions

  local helper_log=""
  local helper_log_file=""
  local temp_dir=""
  RUN_SELECTED_RUNTIME=""
  RUN_INSTALL_RUNTIME=0
  RUN_SYNC_RUNTIME_AUTH=0
  RUN_SYNC_POST_RUNTIME_AUTH=0
  RUN_FORCE_RUNTIME_AUTH=0
  RUN_LOCAL_MODEL_PREFLIGHT=0
  RUN_UPDATE_CODEX=1
  RUN_REQUESTED_IMAGE="agent-plain"

  run_agent_sh_in_container() {
    helper_log="${helper_log}user:$1:$2:$3:$4"$'\n'
  }

  run_capture run_pre_exec unit-test-container
  assert_status 0
  printf '%s' "$helper_log" | grep -Fq $'user:unit-test-container:runtime:update:codex' || fail "Expected runtime update user helper call, got: $helper_log"
}

test_run_pre_exec_updates_legacy_npm_codex_via_root_helper() {
  begin_test "run_pre_exec updates legacy npm-global codex via the runtime root helper"

  load_agentctl_functions

  local helper_log=""
  RUN_SELECTED_RUNTIME=""
  RUN_INSTALL_RUNTIME=0
  RUN_SYNC_RUNTIME_AUTH=0
  RUN_SYNC_POST_RUNTIME_AUTH=0
  RUN_FORCE_RUNTIME_AUTH=0
  RUN_LOCAL_MODEL_PREFLIGHT=0
  RUN_UPDATE_CODEX=1
  RUN_REQUESTED_IMAGE="agent-plain"
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-legacy-update.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  helper_log_file="$temp_dir/helper.log"
  : >"$helper_log_file"

  run_agent_sh_in_container() {
    printf 'user:%s:%s:%s:%s\n' "$1" "$2" "$3" "${4:-}" >>"$helper_log_file"
    if [ "$2" = "runtime" ] && [ "$3" = "info" ] && [ "${4:-}" = "codex" ]; then
      printf '{"runtime":"codex","install_method":"npm-global"}\n'
    fi
  }
  run_agent_sh_in_container_root() {
    printf 'root:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" >>"$helper_log_file"
  }

  run_capture run_pre_exec unit-test-container
  helper_log="$(cat "$helper_log_file")"
  assert_status 0
  assert_contains "Using root Codex update for legacy npm-global install in unit-test-container"
  printf '%s' "$helper_log" | grep -Fq $'user:unit-test-container:runtime:info:codex' || fail "Expected runtime info probe, got: $helper_log"
  printf '%s' "$helper_log" | grep -Fq $'root:unit-test-container:runtime:update:codex' || fail "Expected legacy runtime update root helper call, got: $helper_log"
  if printf '%s' "$helper_log" | grep -Fq $'user:unit-test-container:runtime:update:codex'; then
    fail "Did not expect user update for legacy npm-global codex, got: $helper_log"
  fi
}

test_run_container_reset_config_uses_runtime_helper() {
  begin_test "run_container reset-config uses the runtime reset helper"

  load_agentctl_functions

  local helper_log=""

  RUN_SELECTED_RUNTIME=""
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
  run_agent_sh_in_container() {
    if [ "$2" = "preferred" ] && [ "$3" = "get" ]; then
      printf '%s\n' codex
      return 0
    fi
    if [ "$2" = "preferred" ] && [ "$3" = "set" ] && [ "$4" = "codex" ]; then
      helper_log="${helper_log}$1:preferred-set:$4"$'\n'
      return 0
    fi
    fail "Unexpected agent.sh invocation: $*"
  }

  run_capture run_container unit-test-container agent-plain 0 0 "" "" 0 "$TEST_ROOT" "" "" "" 1 0 true
  assert_status 0
  printf '%s' "$helper_log" | grep -Fq $'unit-test-container:codex' || fail "Expected runtime reset-config helper call, got: $helper_log"
  printf '%s' "$helper_log" | grep -Fq $'unit-test-container:preferred-set:codex' || fail "Expected preferred runtime to be preserved, got: $helper_log"
}

test_run_container_reset_config_uses_selected_runtime() {
  begin_test "run_container reset-config uses the selected runtime when provided"

  load_agentctl_functions

  local helper_log=""

  RUN_SELECTED_RUNTIME="opencode"
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
  run_agent_sh_in_container() {
    if [ "$2" = "preferred" ] && [ "$3" = "set" ] && [ "$4" = "opencode" ]; then
      helper_log="${helper_log}$1:preferred-set:$4"$'\n'
      return 0
    fi
    fail "Did not expect preferred runtime lookup when selected runtime is set: $*"
  }

  run_capture run_container unit-test-container agent-plain 0 0 "" "" 0 "$TEST_ROOT" "" "" "" 1 0 true
  assert_status 0
  printf '%s' "$helper_log" | grep -Fq $'unit-test-container:opencode' || fail "Expected selected runtime reset-config helper call, got: $helper_log"
  printf '%s' "$helper_log" | grep -Fq $'unit-test-container:preferred-set:opencode' || fail "Expected selected runtime to be preserved, got: $helper_log"
}

test_run_container_reset_config_preserves_preferred_runtime() {
  begin_test "run_container reset-config preserves the resolved preferred runtime"

  load_agentctl_functions

  local helper_log=""

  RUN_SELECTED_RUNTIME=""
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
    helper_log="${helper_log}$1:reset:$2"$'\n'
  }
  run_agent_sh_in_container() {
    if [ "$2" = "preferred" ] && [ "$3" = "get" ]; then
      printf '%s\n' opencode
      return 0
    fi
    if [ "$2" = "preferred" ] && [ "$3" = "set" ] && [ "$4" = "opencode" ]; then
      helper_log="${helper_log}$1:preferred-set:$4"$'\n'
      return 0
    fi
    fail "Unexpected agent.sh invocation: $*"
  }

  run_capture run_container unit-test-container agent-plain 0 0 "" "" 0 "$TEST_ROOT" "" "" "" 1 0 true
  assert_status 0
  printf '%s' "$helper_log" | grep -Fq $'unit-test-container:reset:opencode' || fail "Expected preferred runtime reset-config helper call, got: $helper_log"
  printf '%s' "$helper_log" | grep -Fq $'unit-test-container:preferred-set:opencode' || fail "Expected preferred runtime to be restored after reset, got: $helper_log"
}

test_run_pre_exec_syncs_auth_for_preferred_runtime_when_unspecified() {
  begin_test "run_pre_exec syncs auth for the preferred runtime when online mode is enabled"

  load_agentctl_functions

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

  load_agentctl_functions

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

  load_agentctl_functions

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

  load_agentctl_functions

  local captured_pre_exec=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  run_container() {
    captured_pre_exec="${10}"
  }

  run_cmd --name unit-test-container --workdir "$workdir"

  [ -z "$captured_pre_exec" ] || fail "Did not expect host-side run_pre_exec for local preflight, got: $captured_pre_exec"
  [ "$RUN_SYNC_RUNTIME_AUTH" -eq 0 ] || fail "Did not expect online auth sync for local default run"
  [ "$RUN_LOCAL_MODEL_PREFLIGHT" -eq 0 ] || fail "Expected local-model preflight to be handled by agent.sh"
}

test_sync_runtime_auth_to_container_if_available_skips_missing_keychain() {
  begin_test "sync_runtime_auth_to_container_if_available skips runtimes without keychain auth"

  load_agentctl_functions

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

  load_agentctl_functions

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

  load_agentctl_functions

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

test_runtime_cmd_install_uses_user_helper() {
  begin_test "runtime_cmd install uses the user helper path"

  load_agentctl_functions

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
  printf '%s' "$helper_log" | grep -Fq $'user:unit-runtime-container:runtime:install:codex' || fail "Expected user runtime helper call, got: $helper_log"
}

test_runtime_cmd_install_claude_warns_on_undersized_container() {
  begin_test "runtime_cmd install claude warns on an undersized existing container"

  load_agentctl_functions

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
  run_agent_sh_in_container() {
    helper_log="${helper_log}user:$1:$2:$3:$4"$'\n'
  }

  run_capture runtime_cmd --name unit-runtime-container install claude
  assert_status 0
  assert_contains "Container unit-runtime-container is limited to 1G."
  assert_contains "Claude install may be killed by memory pressure"
  assert_contains "upgrade --name unit-runtime-container --mem 4G"
  printf '%s' "$helper_log" | grep -Fq $'user:unit-runtime-container:runtime:install:claude' || fail "Expected user runtime helper call, got: $helper_log"
}

test_runtime_cmd_install_claude_reports_memory_guidance_on_failure() {
  begin_test "runtime_cmd install claude reports memory guidance after an undersized failure"

  local harness
  local script

  harness="$(mktemp "${TMPDIR:-/tmp}/agentctl-unit.XXXXXX")"
  register_dir_cleanup "$harness"
  sed -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=\"$TEST_ROOT\"#" \
    -e '/^cmd="${1:-}"/,$d' \
    "$AGENTCTL_IMPL" >"$harness"

  script="$(mktemp "${TMPDIR:-/tmp}/agentctl-unit-script.XXXXXX")"
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
run_agent_sh_in_container() {
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

test_runtime_cmd_update_uses_user_helper() {
  begin_test "runtime_cmd update uses the user helper path"

  load_agentctl_functions

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
  printf '%s' "$helper_log" | grep -Fq $'user:unit-runtime-container:runtime:update:codex' || fail "Expected user runtime helper call, got: $helper_log"
}

test_bootstrap_cmd_bootstraps_alpine_container_and_restores_stopped_state() {
  begin_test "bootstrap_cmd bootstraps an Alpine container and restores stopped state"

  load_agentctl_functions

  local start_calls=0
  local stop_calls=0
  local running=0
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
        running=1
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        running=0
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
  printf '%s\n' "$exec_log" | grep -Fq "apk add --no-cache bash zsh file curl git ripgrep jq util-linux bubblewrap nodejs npm" || fail "Expected root bootstrap install commands"
  printf '%s\n' "$exec_log" | grep -Fq "file:/usr/local/bin/agent.sh" || fail "Expected bootstrap to install agent.sh"
  printf '%s\n' "$exec_log" | grep -Fq "tree:/etc/agentctl/runtimes.d" || fail "Expected bootstrap to install runtime manifests"
  printf '%s\n' "$exec_log" | grep -Fq "tree:/etc/agentctl/features.d" || fail "Expected bootstrap to install feature manifests"
  printf '%s\n' "$exec_log" | grep -Fq "file:/etc/agentctl/image.md" || fail "Expected bootstrap to install image metadata"
}

test_bootstrap_cmd_creates_and_bootstraps_new_alpine_container() {
  begin_test "bootstrap_cmd can create and bootstrap a new Alpine container"

  load_agentctl_functions

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

  load_agentctl_functions

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
  printf '%s\n' "$exec_log" | grep -Fq "apt-get install -y --no-install-recommends bash zsh file curl git ripgrep jq util-linux bubblewrap nodejs npm ca-certificates" || fail "Expected apt bootstrap install commands"
  printf '%s\n' "$exec_log" | grep -Fq "file:/usr/local/bin/agent.sh" || fail "Expected bootstrap to install agent.sh"
  printf '%s\n' "$exec_log" | grep -Fq "tree:/etc/agentctl/runtimes.d" || fail "Expected bootstrap to install runtime manifests"
  printf '%s\n' "$exec_log" | grep -Fq "tree:/etc/agentctl/features.d" || fail "Expected bootstrap to install feature manifests"
}

test_bootstrap_cmd_rejects_unsupported_base() {
  begin_test "bootstrap_cmd rejects unsupported container bases"

  load_agentctl_functions

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

test_host_test_filter_normalizes_hyphens_spaces_and_underscores() {
  begin_test "host test filter normalizes hyphens, spaces, and underscores"

  local original_filter="$TEST_FILTER"
  local original_start_from="$TEST_START_FROM"
  local original_start_active="$TEST_START_ACTIVE"

  TEST_FILTER="tagged-apk"
  test_matches_filter \
    test_upgrade_repeats_tagged_apk_reinstall_instructions \
    "upgrade repeats complete tagged APK reinstall instructions" \
    || fail "Expected a hyphenated filter to match underscore and space separators"

  TEST_START_FROM="tagged-apk"
  TEST_START_ACTIVE=0
  test_matches_start_from \
    test_upgrade_repeats_tagged_apk_reinstall_instructions \
    "upgrade repeats complete tagged APK reinstall instructions" \
    || fail "Expected a hyphenated --from value to match underscore and space separators"
  [ "$TEST_START_ACTIVE" -eq 1 ] \
    || fail "Expected a matching --from value to activate subsequent tests"

  TEST_FILTER="$original_filter"
  TEST_START_FROM="$original_start_from"
  TEST_START_ACTIVE="$original_start_active"
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

test_images_help_reports_subcommand_options() {
  begin_test "images help reports subcommand option sections"

  run_capture "$AGENTCTL" images --help
  assert_status 0
  assert_contains "Usage: agentctl images [options]"
  assert_contains "Options for images:"
  assert_contains "Options for images prune:"
  assert_contains "Options for images rm:"
  assert_not_contains "command not found"
  assert_not_contains "Options for :"
}

test_images_print_sorted_keeps_compact_output() {
  begin_test "raw images listing keeps compact output"

  load_agentctl_functions

  run_capture images_print_sorted $'agent-python:20260718-180539\nagent-plain:20260718-180539\nagent-project-backup-20260718174529\nagent-python\nagent-plain' 0 "" 0

  assert_status 0
  [ "$RUN_OUTPUT" = $'agent-plain\nagent-plain:20260718-180539\nagent-python\nagent-python:20260718-180539\nagent-project-backup-20260718174529' ] \
    || fail "Expected compact image output, got: $RUN_OUTPUT"
}

test_images_print_metadata_uses_runtime_image_details() {
  begin_test "images metadata uses runtime creation, size, platform, and digest details"

  load_agentctl_functions

  run_capture images_print_metadata $'agent-plain\nagent-plain:20260718-180539\nlocalhost:5000/team/image' '[
    {"configuration":{"name":"agent-plain:latest","creationDate":"2026-07-18T18:05:54Z","descriptor":{"digest":"sha256:7726e80cafd612345678","size":374}},"variants":[{"platform":{"os":"linux","architecture":"arm64"},"size":179522222}]},
    {"configuration":{"name":"docker.io/library/agent-plain:20260718-180539","creationDate":"2026-07-18T18:05:54Z","descriptor":{"digest":"sha256:7726e80cafd612345678","size":374}},"variants":[{"platform":{"os":"linux","architecture":"arm64"},"size":179522222}]},
    {"configuration":{"name":"localhost:5000/team/image:latest","creationDate":"2026-07-18T19:00:00Z","descriptor":{"digest":"sha256:abcdef1234567890"}},"variants":[{"platform":{"os":"linux","architecture":"arm64"}}]}
  ]'

  assert_status 0
  assert_contains "IMAGE"
  assert_contains "CREATED"
  assert_contains "SIZE"
  assert_contains "PLATFORM"
  assert_contains "IMAGE ID"
  assert_contains "agent-plain"
  assert_contains "2026-07-18 18:05:54Z"
  assert_contains "171.2 MiB"
  assert_contains "linux/arm64"
  assert_contains "7726e80cafd6"
  assert_contains "localhost:5000/team/image"
  assert_contains "2026-07-18 19:00:00Z"
  printf '%s\n' "$RUN_OUTPUT" | grep -E '^localhost:5000/team/image +2026-07-18 19:00:00Z +unknown +linux/arm64 +abcdef123456$' >/dev/null \
    || fail "Expected registry-port image metadata with unknown size, got: $RUN_OUTPUT"
}

test_images_list_defaults_to_metadata_and_supports_raw_output() {
  begin_test "images list defaults to metadata and supports raw output"

  load_agentctl_functions

  require_container() { :; }
  parse_image_list() {
    printf '%s\n' agent-plain agent-plain:20260718-180539 agent-project-backup-20260718174529
  }
  image_list_json() {
    printf '%s\n' '[
      {"configuration":{"name":"agent-plain:latest","creationDate":"2026-07-18T18:05:54Z","descriptor":{"digest":"sha256:7726e80cafd612345678"}},"variants":[{"platform":{"os":"linux","architecture":"arm64"},"size":179522222}]},
      {"configuration":{"name":"agent-plain:20260718-180539","creationDate":"2026-07-18T18:05:54Z","descriptor":{"digest":"sha256:7726e80cafd612345678"}},"variants":[{"platform":{"os":"linux","architecture":"arm64"},"size":179522222}]},
      {"configuration":{"name":"agent-project-backup-20260718174529:latest","creationDate":"2026-07-18T17:47:51Z","descriptor":{"digest":"sha256:77ac1f1455a712345678"}},"variants":[{"platform":{"os":"linux","architecture":"arm64"},"size":3139973763}]}
    ]'
  }

  run_capture images_list_cmd
  assert_status 0
  assert_contains "CREATED"
  assert_contains "171.2 MiB"
  assert_contains "2.9 GiB"

  image_list_json() { fail "raw image listing should not request JSON metadata"; }
  run_capture images_list_cmd --raw
  assert_status 0
  assert_not_contains "CREATED"
  assert_contains $'agent-plain\nagent-plain:20260718-180539\nagent-project-backup-20260718174529'
}

test_images_list_falls_back_to_refs_when_metadata_is_unavailable() {
  begin_test "images list falls back to refs when metadata is unavailable"

  load_agentctl_functions

  require_container() { :; }
  parse_image_list() { printf '%s\n' agent-plain agent-python; }
  image_list_json() { printf '%s\n' 'not-json'; }

  run_capture images_list_cmd
  assert_status 0
  assert_contains "Warning: Image metadata is unavailable; showing image refs only"
  assert_contains $'agent-plain\nagent-python'
  assert_not_contains "0 B"
  assert_not_contains "CREATED"
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
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and .install_method == "standalone-installer" and .default_config_dir == "/etc/agentctl/codex" and (.auth_formats | index("json_refresh_token") != null) and .launch_configs.profile.type == "string" and .launch_configs.profile.default == "gpt-oss"' >/dev/null || fail "Expected runtime info JSON for codex, got: $RUN_OUTPUT"
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
  grep -Fq " npm " "$install_log" || fail "Expected office feature to install npm package"
  grep -Fq " py3-pypdf py3-pdfminer " "$install_log" || fail "Expected office feature to install available PDF apk packages"
  if grep -Fq "py3-mupdf" "$install_log"; then
    fail "Did not expect unavailable py3-mupdf package in office feature install"
  fi
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

test_agent_sh_runtime_list_ignores_dangling_runtime_launcher() {
  begin_test "agent.sh runtime list ignores a dangling runtime launcher"

  local temp_home
  local fake_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  mkdir -p "$fake_bin"
  ln -s "$temp_home/missing/codex" "$fake_bin/codex"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$temp_home/tools" \
    -- runtime list
  assert_status 0
  assert_not_contains "codex"
  assert_not_contains "claude"
}

test_agent_sh_runtime_info_prefers_tool_bin_over_user_path() {
  begin_test "agent.sh runtime info prefers tool bin over user-local launcher"

  local temp_home
  local tools_home
  local user_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  tools_home="$temp_home/tools"
  user_bin="$temp_home/home/.local/bin"
  mkdir -p "$tools_home/bin" "$user_bin"

  printf '#!/bin/sh\nexit 0\n' >"$tools_home/bin/codex"
  printf '#!/bin/sh\nexit 0\n' >"$user_bin/codex"
  chmod +x "$tools_home/bin/codex" "$user_bin/codex"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$user_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- runtime info codex
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er --arg path "$tools_home/bin/codex" --arg tools "$tools_home" '.installed == true and .command_path == $path and .tools_home == $tools and .tools_bin_dir == ($tools + "/bin") and .runtime_tool_home == ($tools + "/codex")' >/dev/null || fail "Expected runtime info to prefer tool bin, got: $RUN_OUTPUT"
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
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "claude" and .installed == false and .install_method == "native-installer" and .default_config_dir == "/etc/agentctl/claude" and .capabilities.install == true and .capabilities.update == true and .capabilities.reset_config == true and .capabilities.auth_login == true and .capabilities.auth_read == true and .capabilities.auth_write == true and .capabilities.local_mode == true and .capabilities.online_mode == true and (.auth_formats | index("claude_ai_oauth_json") != null) and (.commands | index("runtime install claude") != null) and (.commands | index("auth login claude") != null)' >/dev/null || fail "Expected runtime info JSON for claude runtime, got: $RUN_OUTPUT"
}

test_agent_sh_opencode_runtime_info_reports_local_only_metadata() {
  begin_test "agent.sh runtime info reports opencode local-only metadata"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" runtime info opencode
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "opencode" and .installed == false and .install_method == "npm-prefix" and .default_config_dir == "/etc/agentctl/opencode" and .auth_formats == [] and .capabilities.install == true and .capabilities.update == true and .capabilities.reset_config == true and .capabilities.auth_login == false and .capabilities.auth_read == false and .capabilities.auth_write == false and .capabilities.local_mode == true and .capabilities.online_mode == false and (.commands | index("runtime install opencode") != null)' >/dev/null || fail "Expected runtime info JSON for opencode runtime, got: $RUN_OUTPUT"
}

test_agent_sh_qwen_runtime_info_reports_local_only_metadata() {
  begin_test "agent.sh runtime info reports qwen local-only metadata"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" runtime info qwen
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "qwen" and .installed == false and .install_method == "npm-prefix" and .default_config_dir == "/etc/agentctl/qwen" and .auth_formats == [] and .capabilities.install == true and .capabilities.update == true and .capabilities.reset_config == true and .capabilities.auth_login == false and .capabilities.auth_read == false and .capabilities.auth_write == false and .capabilities.local_mode == true and .capabilities.online_mode == false and (.commands | index("runtime install qwen") != null)' >/dev/null || fail "Expected runtime info JSON for qwen runtime, got: $RUN_OUTPUT"
}

test_agent_sh_pi_runtime_info_reports_local_only_metadata() {
  begin_test "agent.sh runtime info reports pi local-only metadata"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" runtime info pi
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "pi" and .installed == false and .install_method == "npm-prefix" and .default_config_dir == "/etc/agentctl/pi" and .auth_formats == [] and .capabilities.install == true and .capabilities.update == true and .capabilities.reset_config == true and .capabilities.auth_login == false and .capabilities.auth_read == false and .capabilities.auth_write == false and .capabilities.local_mode == true and .capabilities.online_mode == false and (.commands | index("runtime install pi") != null)' >/dev/null || fail "Expected runtime info JSON for pi runtime, got: $RUN_OUTPUT"
}

test_agent_sh_system_manifest_includes_runtime_feature_and_preference_state() {
  begin_test "agent.sh system manifest includes installed runtimes, features, and preferred runtime state"

  local temp_home
  local fake_bin
  local tools_home
  local state_dir
  local image_version_file
  local tooling_version_file
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  tools_home="$temp_home/tools"
  fake_bin="$(make_fake_runtime_bin "$temp_home" codex)"
  make_fake_runtime_bin "$temp_home" claude >/dev/null
  state_dir="$temp_home/state"
  image_version_file="$temp_home/image-version"
  tooling_version_file="$temp_home/tooling-version"
  mkdir -p "$state_dir/office" "$temp_home/config/agentctl"
  printf '%s\n' installed >"$state_dir/office/install-complete"
  printf '%s\n' claude >"$temp_home/config/agentctl/preferred-runtime"
  printf '%s\n' 0.2.0 >"$image_version_file"
  printf '%s\n' 0.2.1 >"$tooling_version_file"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    AGENTCTL_FEATURE_STATE_DIR="$state_dir" \
    AGENTCTL_IMAGE_VERSION_FILE="$image_version_file" \
    AGENTCTL_TOOLING_VERSION_FILE="$tooling_version_file" \
    -- system manifest
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er --arg tools "$tools_home" '.installed_runtimes == ["claude","codex"] and .installed_features == ["office"] and .default_runtime == "codex" and .preferred_runtime == "claude" and .tools_home == $tools and .tools_bin_dir == ($tools + "/bin") and .image_version == "0.2.0" and .tooling_version == "0.2.1"' >/dev/null || fail "Expected richer system manifest JSON, got: $RUN_OUTPUT"
}

test_agent_sh_system_manifest_reports_unknown_version_markers() {
  begin_test "agent.sh system manifest reports unknown missing version markers"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture_env "$temp_home" \
    AGENTCTL_IMAGE_VERSION_FILE="$temp_home/missing-image-version" \
    AGENTCTL_TOOLING_VERSION_FILE="$temp_home/missing-tooling-version" \
    -- system manifest
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.image_version == "unknown" and .tooling_version == "unknown"' >/dev/null \
    || fail "Expected unknown version markers, got: $RUN_OUTPUT"
}

test_agent_sh_system_manifest_reports_apk_requested_packages() {
  begin_test "agent.sh system manifest reports apk requested packages"

  local temp_home
  local fake_bin
  local apk_world_file
  local apk_repositories_file
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  apk_world_file="$temp_home/world"
  apk_repositories_file="$temp_home/repositories"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/apk" <<'EOF'
#!/bin/sh
if [ "$1" = "info" ] && [ "$2" = "-q" ]; then
  printf '%s\n' bash git libc-utils
fi
EOF
  chmod +x "$fake_bin/apk"
  printf '%s\n' git bash >"$apk_world_file"
  printf '%s\n' \
    'https://dl-cdn.alpinelinux.org/alpine/v3.22/main' \
    '@edgecommunity https://dl-cdn.alpinelinux.org/alpine/edge/community' \
    >"$apk_repositories_file"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_APK_WORLD_FILE="$apk_world_file" \
    AGENTCTL_APK_REPOSITORIES_FILE="$apk_repositories_file" \
    -- system manifest
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.package_manager == "apk" and .packages == ["bash","git","libc-utils"] and .requested_packages == ["bash","git"] and (.apk_repositories | index("@edgecommunity https://dl-cdn.alpinelinux.org/alpine/edge/community"))' >/dev/null || fail "Expected apk requested packages and repositories in system manifest, got: $RUN_OUTPUT"
}

test_agent_sh_system_manifest_reports_dpkg_requested_packages() {
  begin_test "agent.sh system manifest reports dpkg requested packages"

  local temp_home
  local fake_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/dpkg-query" <<'EOF'
#!/bin/sh
printf '%s\n' bash libc6 tree
EOF
  cat >"$fake_bin/apt-mark" <<'EOF'
#!/bin/sh
if [ "$1" = "showmanual" ]; then
  printf '%s\n' bash tree
fi
EOF
  chmod +x "$fake_bin/dpkg-query" "$fake_bin/apt-mark"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    -- system manifest
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.package_manager == "dpkg" and .packages == ["bash","libc6","tree"] and .requested_packages == ["bash","tree"]' >/dev/null || fail "Expected dpkg requested packages in system manifest, got: $RUN_OUTPUT"
}

test_agent_sh_claude_runtime_install_runs_native_installer() {
  begin_test "agent.sh claude runtime install runs the native installer"

  local temp_home
  local fake_bin
  local tools_home
  local install_log
  local expected_owner
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  tools_home="$temp_home/tools"
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
printf 'installer-bash HOME=%s PATH=%s\n' "\$HOME" "\$PATH" >>"$install_log"
mkdir -p "\$HOME/.local/bin"
cat >"\$HOME/.local/bin/claude" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x "\$HOME/.local/bin/claude"
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
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- runtime install claude
  assert_status 0
  [ -L "$tools_home/bin/claude" ] || fail "Expected Claude launcher symlink in tool bin"
  [ "$(readlink "$tools_home/bin/claude")" = "$tools_home/claude/.local/bin/claude" ] || fail "Expected Claude launcher to point at tool home"
  grep -Fq 'info -e libgcc' "$install_log" || fail "Expected Alpine dependency verification for libgcc"
  grep -Fq 'info -e libstdc++' "$install_log" || fail "Expected Alpine dependency verification for libstdc++"
  grep -Fq 'info -e ripgrep' "$install_log" || fail "Expected Alpine dependency verification for ripgrep"
  grep -Fq "installer-bash HOME=$tools_home/claude" "$install_log" || fail "Expected native installer to run with Claude tool home"
  grep -Fq "chown -R $expected_owner $temp_home/home/.claude" "$install_log" || fail "Expected Claude install to hand .claude ownership back to the container user"
  jq -er '.env.USE_BUILTIN_RIPGREP == "0"' "$temp_home/home/.claude/settings.json" >/dev/null || fail "Expected Claude settings.json to disable builtin ripgrep"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- preferred get
  assert_status 0
  assert_contains "claude"
}

test_agent_sh_claude_runtime_update_calls_claude_update() {
  begin_test "agent.sh claude runtime update calls claude update"

  local temp_home
  local fake_bin
  local tools_home
  local update_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  tools_home="$temp_home/tools"
  update_log="$temp_home/update.log"
  mkdir -p "$fake_bin" "$tools_home/bin"

  cat >"$tools_home/bin/claude" <<EOF
#!/bin/sh
printf 'HOME=%s\nPATH=%s\nARGS=%s\n' "\$HOME" "\$PATH" "\$*" >"$update_log"
exit 0
EOF
  chmod +x "$tools_home/bin/claude"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- runtime update claude
  assert_status 0
  grep -Fxq "HOME=$tools_home/claude" "$update_log" || fail "Expected claude update to run with tool home"
  grep -Fxq 'ARGS=update' "$update_log" || fail "Expected claude update to be invoked"
  run_agent_sh_capture_env "$temp_home" \
    PATH="$temp_home/home/.local/bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- runtime info claude
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er --arg path "$tools_home/bin/claude" '.installed == true and .command_path == $path' >/dev/null || fail "Expected Claude to remain resolved from tool bin after update, got: $RUN_OUTPUT"
}

test_agent_sh_codex_runtime_install_runs_standalone_installer() {
  begin_test "agent.sh codex runtime install runs the standalone installer"

  local temp_home
  local fake_bin
  local tools_home
  local install_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  tools_home="$temp_home/tools"
  install_log="$temp_home/install.log"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$install_log"
cat <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
EOF
  chmod +x "$fake_bin/curl"

  cat >"$fake_bin/sh" <<EOF
#!/bin/sh
cat >/dev/null
printf 'sh CODEX_HOME=%s\nCODEX_INSTALL_DIR=%s\nCODEX_NON_INTERACTIVE=%s\nPATH=%s\n' "\${CODEX_HOME:-}" "\${CODEX_INSTALL_DIR:-}" "\${CODEX_NON_INTERACTIVE:-}" "\$PATH" >>"$install_log"
mkdir -p "\$CODEX_INSTALL_DIR"
cat >"\$CODEX_INSTALL_DIR/codex" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x "\$CODEX_INSTALL_DIR/codex"
EOF
  chmod +x "$fake_bin/sh"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- runtime install codex
  assert_status 0
  grep -Fq 'https://chatgpt.com/codex/install.sh' "$install_log" || fail "Expected Codex standalone installer URL"
  grep -Fxq "sh CODEX_HOME=$tools_home/codex" "$install_log" || fail "Expected Codex installer to use tool CODEX_HOME"
  grep -Fxq "CODEX_INSTALL_DIR=$tools_home/bin" "$install_log" || fail "Expected Codex installer to use tool bin install dir"
  grep -Fxq 'CODEX_NON_INTERACTIVE=1' "$install_log" || fail "Expected non-interinteractive Codex installer"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- preferred get
  assert_status 0
  assert_contains "codex"
}

test_agent_sh_codex_runtime_install_falls_back_to_direct_package() {
  begin_test "agent.sh codex runtime install falls back to direct package assets"

  local temp_home
  local fake_bin
  local tools_home
  local install_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  tools_home="$temp_home/tools"
  install_log="$temp_home/install.log"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/curl" <<EOF
#!/bin/sh
printf 'curl %s\n' "\$*" >>"$install_log"
case "\$*" in
  *"https://chatgpt.com/codex/install.sh"*)
    cat <<'SCRIPT'
#!/bin/sh
printf '%s\n' 'Could not find Codex package or platform npm release assets for Codex 0.139.0.' >&2
exit 1
SCRIPT
    ;;
  *"https://api.github.com/repos/openai/codex/releases/latest"*)
    printf '{"tag_name":"rust-v0.139.0"}\n'
    ;;
  *"codex-package_SHA256SUMS"*)
    output=""
    while [ "\$#" -gt 0 ]; do
      if [ "\$1" = "-o" ]; then
        output="\$2"
        shift 2
        continue
      fi
      shift
    done
    printf '%s  codex-package-aarch64-unknown-linux-musl.tar.gz\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"\$output"
    ;;
  *"codex-package-aarch64-unknown-linux-musl.tar.gz"*)
    output=""
    while [ "\$#" -gt 0 ]; do
      if [ "\$1" = "-o" ]; then
        output="\$2"
        shift 2
        continue
      fi
      shift
    done
    printf 'archive' >"\$output"
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "$fake_bin/curl"

  cat >"$fake_bin/uname" <<'EOF'
#!/bin/sh
case "$1" in
  -s) printf '%s\n' Linux ;;
  -m) printf '%s\n' aarch64 ;;
  *) /usr/bin/uname "$@" ;;
esac
EOF
  chmod +x "$fake_bin/uname"

  cat >"$fake_bin/sha256sum" <<'EOF'
#!/bin/sh
printf '%s  %s\n' "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$1"
EOF
  chmod +x "$fake_bin/sha256sum"

  cat >"$fake_bin/tar" <<'EOF'
#!/bin/sh
target=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-C" ]; then
    target="$2"
    shift 2
    continue
  fi
  shift
done
mkdir -p "$target/bin" "$target/codex-path" "$target/codex-resources"
printf '#!/bin/sh\nexit 0\n' >"$target/bin/codex"
printf '#!/bin/sh\nexit 0\n' >"$target/codex-path/rg"
printf '{}\n' >"$target/codex-package.json"
EOF
  chmod +x "$fake_bin/tar"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- runtime install codex
  assert_status 0
  [ -L "$tools_home/bin/codex" ] || fail "Expected fallback install to create tool-bin codex symlink"
  [ -x "$tools_home/codex/packages/standalone/releases/0.139.0-aarch64-unknown-linux-musl/bin/codex" ] || fail "Expected fallback install to extract Codex package under tool home"
  [ ! -e "$temp_home/home/.codex/packages" ] || fail "Did not expect fallback install to write package cache under user Codex state"
  assert_contains "Falling back to direct Codex standalone package install."
}

test_agent_sh_codex_runtime_update_calls_codex_update() {
  begin_test "agent.sh codex runtime update calls codex update"

  local temp_home
  local fake_bin
  local tools_home
  local update_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  tools_home="$temp_home/tools"
  update_log="$temp_home/update.log"
  mkdir -p "$fake_bin" "$tools_home/bin"

  cat >"$tools_home/bin/codex" <<EOF
#!/bin/sh
printf 'CODEX_HOME=%s\nCODEX_INSTALL_DIR=%s\nPATH=%s\nARGS=%s\n' "\$CODEX_HOME" "\$CODEX_INSTALL_DIR" "\$PATH" "\$*" >"$update_log"
exit 0
EOF
  chmod +x "$tools_home/bin/codex"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- runtime update codex
  assert_status 0
  grep -Fxq "CODEX_HOME=$tools_home/codex" "$update_log" || fail "Expected codex update to use tool CODEX_HOME"
  grep -Fxq "CODEX_INSTALL_DIR=$tools_home/bin" "$update_log" || fail "Expected codex update to use tool install dir"
  grep -Fxq 'ARGS=update' "$update_log" || fail "Expected codex update to be invoked"
}

test_agent_sh_opencode_runtime_install_uses_npm_prefix() {
  begin_test "agent.sh opencode runtime install uses npm prefix and links launcher"

  local temp_home
  local fake_bin
  local tools_home
  local install_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  tools_home="$temp_home/tools"
  install_log="$temp_home/install.log"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/npm" <<EOF
#!/bin/sh
printf 'npm %s\n' "\$*" >>"$install_log"
prefix=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "--prefix" ]; then
    prefix="\$2"
    shift 2
    continue
  fi
  shift
done
mkdir -p "\$prefix/node_modules/.bin"
cat >"\$prefix/node_modules/.bin/opencode" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x "\$prefix/node_modules/.bin/opencode"
EOF
  chmod +x "$fake_bin/npm"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- runtime install opencode
  assert_status 0
  grep -Fq "npm install --prefix $tools_home/opencode opencode-ai@latest" "$install_log" || fail "Expected OpenCode install to use npm prefix under tool home"
  [ -L "$tools_home/bin/opencode" ] || fail "Expected OpenCode launcher symlink in tool bin"
  [ "$(readlink "$tools_home/bin/opencode")" = "$tools_home/opencode/node_modules/.bin/opencode" ] || fail "Expected OpenCode launcher to point at tool home"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- preferred get
  assert_status 0
  assert_contains "opencode"
}

test_agent_sh_opencode_runtime_update_uses_npm_prefix() {
  begin_test "agent.sh opencode runtime update reinstalls with npm prefix"

  local temp_home
  local fake_bin
  local tools_home
  local install_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  tools_home="$temp_home/tools"
  install_log="$temp_home/install.log"
  mkdir -p "$fake_bin" "$tools_home/opencode/node_modules/.bin"
  printf '#!/bin/sh\nexit 0\n' >"$tools_home/opencode/node_modules/.bin/opencode"
  chmod +x "$tools_home/opencode/node_modules/.bin/opencode"
  ln -s "$tools_home/opencode/node_modules/.bin/opencode" "$tools_home/bin/opencode" 2>/dev/null || {
    mkdir -p "$tools_home/bin"
    ln -s "$tools_home/opencode/node_modules/.bin/opencode" "$tools_home/bin/opencode"
  }

  cat >"$fake_bin/npm" <<EOF
#!/bin/sh
printf 'npm %s\n' "\$*" >>"$install_log"
exit 0
EOF
  chmod +x "$fake_bin/npm"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- runtime update opencode
  assert_status 0
  grep -Fq "npm install --prefix $tools_home/opencode opencode-ai@latest" "$install_log" || fail "Expected OpenCode update to use npm prefix under tool home"
}

test_agent_sh_qwen_runtime_install_uses_npm_prefix() {
  begin_test "agent.sh qwen runtime install uses npm prefix and links launcher"

  local temp_home
  local fake_bin
  local tools_home
  local install_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  tools_home="$temp_home/tools"
  install_log="$temp_home/install.log"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/node" <<'EOF'
#!/bin/sh
case "$1" in
  -p) printf '%s\n' 24.16.0 ;;
  -e) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  cat >"$fake_bin/npm" <<EOF
#!/bin/sh
printf 'npm %s\n' "\$*" >>"$install_log"
prefix=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "--prefix" ]; then
    prefix="\$2"
    shift 2
    continue
  fi
  shift
done
mkdir -p "\$prefix/node_modules/.bin"
cat >"\$prefix/node_modules/.bin/qwen" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x "\$prefix/node_modules/.bin/qwen"
EOF
  chmod +x "$fake_bin/node" "$fake_bin/npm"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- runtime install qwen
  assert_status 0
  grep -Fq "npm install --prefix $tools_home/qwen @qwen-code/qwen-code@latest" "$install_log" || fail "Expected Qwen install to use npm prefix under tool home"
  [ -L "$tools_home/bin/qwen" ] || fail "Expected Qwen launcher symlink in tool bin"
  [ "$(readlink "$tools_home/bin/qwen")" = "$tools_home/qwen/node_modules/.bin/qwen" ] || fail "Expected Qwen launcher to point at tool home"
}

test_agent_sh_pi_runtime_install_uses_npm_prefix() {
  begin_test "agent.sh pi runtime install uses npm prefix and links launcher"

  local temp_home
  local fake_bin
  local tools_home
  local install_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  tools_home="$temp_home/tools"
  install_log="$temp_home/install.log"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/node" <<'EOF'
#!/bin/sh
case "$1" in
  -p) printf '%s\n' 24.16.0 ;;
  -e) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  cat >"$fake_bin/npm" <<EOF
#!/bin/sh
printf 'npm %s\n' "\$*" >>"$install_log"
prefix=""
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = "--prefix" ]; then
    prefix="\$2"
    shift 2
    continue
  fi
  shift
done
mkdir -p "\$prefix/node_modules/.bin"
cat >"\$prefix/node_modules/.bin/pi" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
chmod +x "\$prefix/node_modules/.bin/pi"
EOF
  chmod +x "$fake_bin/node" "$fake_bin/npm"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- runtime install pi
  assert_status 0
  grep -Fq "npm install --prefix $tools_home/pi @earendil-works/pi-coding-agent@latest" "$install_log" || fail "Expected Pi install to use npm prefix under tool home"
  [ -L "$tools_home/bin/pi" ] || fail "Expected Pi launcher symlink in tool bin"
  [ "$(readlink "$tools_home/bin/pi")" = "$tools_home/pi/node_modules/.bin/pi" ] || fail "Expected Pi launcher to point at tool home"
}

test_agent_sh_qwen_runtime_install_rejects_old_node() {
  begin_test "agent.sh qwen runtime install rejects old Node.js"

  local temp_home
  local fake_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/node" <<'EOF'
#!/bin/sh
case "$1" in
  -p) printf '%s\n' 21.9.0 ;;
  -e) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_bin/node"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    -- runtime install qwen
  assert_status 1
  assert_contains "Qwen Code requires Node.js >= 22.0.0; found 21.9.0"
}

test_agent_sh_pi_runtime_install_rejects_old_node() {
  begin_test "agent.sh pi runtime install rejects old Node.js"

  local temp_home
  local fake_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/node" <<'EOF'
#!/bin/sh
case "$1" in
  -p) printf '%s\n' 22.18.0 ;;
  -e) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_bin/node"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    -- runtime install pi
  assert_status 1
  assert_contains "Pi requires Node.js >= 22.19.0; found 22.18.0"
}

test_agent_sh_qwen_runtime_update_uses_npm_prefix() {
  begin_test "agent.sh qwen runtime update reinstalls with npm prefix"

  local temp_home
  local fake_bin
  local tools_home
  local install_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  tools_home="$temp_home/tools"
  install_log="$temp_home/install.log"
  mkdir -p "$fake_bin" "$tools_home/qwen/node_modules/.bin" "$tools_home/bin"
  printf '#!/bin/sh\nexit 0\n' >"$tools_home/qwen/node_modules/.bin/qwen"
  chmod +x "$tools_home/qwen/node_modules/.bin/qwen"
  ln -s "$tools_home/qwen/node_modules/.bin/qwen" "$tools_home/bin/qwen"

  cat >"$fake_bin/node" <<'EOF'
#!/bin/sh
case "$1" in
  -p) printf '%s\n' 24.16.0 ;;
  -e) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  cat >"$fake_bin/npm" <<EOF
#!/bin/sh
printf 'npm %s\n' "\$*" >>"$install_log"
exit 0
EOF
  chmod +x "$fake_bin/node" "$fake_bin/npm"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- runtime update qwen
  assert_status 0
  grep -Fq "npm install --prefix $tools_home/qwen @qwen-code/qwen-code@latest" "$install_log" || fail "Expected Qwen update to use npm prefix under tool home"
}

test_agent_sh_pi_runtime_update_uses_npm_prefix() {
  begin_test "agent.sh pi runtime update reinstalls with npm prefix"

  local temp_home
  local fake_bin
  local tools_home
  local install_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  tools_home="$temp_home/tools"
  install_log="$temp_home/install.log"
  mkdir -p "$fake_bin" "$tools_home/pi/node_modules/.bin" "$tools_home/bin"
  printf '#!/bin/sh\nexit 0\n' >"$tools_home/pi/node_modules/.bin/pi"
  chmod +x "$tools_home/pi/node_modules/.bin/pi"
  ln -s "$tools_home/pi/node_modules/.bin/pi" "$tools_home/bin/pi"

  cat >"$fake_bin/node" <<'EOF'
#!/bin/sh
case "$1" in
  -p) printf '%s\n' 24.16.0 ;;
  -e) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  cat >"$fake_bin/npm" <<EOF
#!/bin/sh
printf 'npm %s\n' "\$*" >>"$install_log"
exit 0
EOF
  chmod +x "$fake_bin/node" "$fake_bin/npm"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    -- runtime update pi
  assert_status 0
  grep -Fq "npm install --prefix $tools_home/pi @earendil-works/pi-coding-agent@latest" "$install_log" || fail "Expected Pi update to use npm prefix under tool home"
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

  cat >"$temp_home/home/.claude/settings.json" <<'EOF'
{
  "env": {
    "USE_BUILTIN_RIPGREP": "1"
  },
  "mcpServers": {
    "custom": {
      "command": "custom-mcp"
    }
  }
}
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    -- runtime reset-config claude
  assert_status 0
  assert_contains "Warning: resetting Claude configuration will replace ~/.claude/settings.json"
  assert_contains "MCP servers"
  assert_contains "Existing Claude MCP configuration that reset-config will replace:"
  assert_contains '"command": "custom-mcp"'
  grep -Fq "chown -R $expected_owner $temp_home/home/.claude" "$install_log" || fail "Expected reset-config to hand .claude ownership back to the container user"
  grep -Fq "chown $expected_owner $temp_home/home/.claude.json" "$install_log" || fail "Expected reset-config to hand .claude.json ownership back to the container user"
  jq -er '.env.USE_BUILTIN_RIPGREP == "0"' "$temp_home/home/.claude/settings.json" >/dev/null || fail "Expected Claude settings reset to default ripgrep behavior"
}

test_agent_sh_codex_runtime_reset_config_warns_about_lost_configuration() {
  begin_test "agent.sh codex runtime reset-config warns about lost configuration"

  local temp_home
  local fake_bin
  local registry_dir
  local config_dir
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  registry_dir="$temp_home/runtimes.d"
  config_dir="$temp_home/default-codex"
  mkdir -p "$fake_bin" "$registry_dir" "$config_dir" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/codex"

  jq --arg config_dir "$config_dir" '.default_config_dir = $config_dir' \
    "$TEST_ROOT/runtimes.d/codex.json" >"$registry_dir/codex.json"

  cat >"$config_dir/config.toml" <<'EOF'
[model_providers.myollama]
name = "Ollama"
base_url = "http://192.168.64.1:11434/v1"
EOF
  cat >"$config_dir/gpt-oss.config.toml" <<'EOF'
model_provider = "myollama"
model = "gpt-oss:20b"
EOF
  printf '{"models":[]}\n' >"$config_dir/local_models.json"
  printf '# image defaults\n' >"$config_dir/image.md"

  cat >"$temp_home/home/.codex/config.toml" <<'EOF'
[mcp_servers.custom]
command = "custom-mcp"
EOF
  printf '{"models":[{"slug":"custom"}]}\n' >"$temp_home/home/.codex/local_models.json"
  printf '# custom agents\n' >"$temp_home/home/.codex/AGENTS.md"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$registry_dir" \
    -- runtime reset-config codex
  assert_status 0
  assert_contains "Warning: resetting Codex configuration will replace ~/.codex/config.toml"
  assert_contains "custom profiles, MCP servers, providers, local model metadata, and runtime preference"
  assert_contains "Existing Codex MCP configuration that reset-config will replace:"
  assert_contains "[mcp_servers.custom]"
  assert_contains 'command = "custom-mcp"'
  grep -Fq '[model_providers.myollama]' "$temp_home/home/.codex/config.toml" || fail "Expected Codex config.toml to reset to image defaults"
  grep -Fq 'model = "gpt-oss:20b"' "$temp_home/home/.codex/gpt-oss.config.toml" || fail "Expected Codex profile config to reset to image defaults"
  jq -er '.models == []' "$temp_home/home/.codex/local_models.json" >/dev/null || fail "Expected Codex local_models.json to reset to image defaults"
  [ -L "$temp_home/home/.codex/AGENTS.md" ] || fail "Expected Codex AGENTS.md to reset to a symlink"
  [ "$(readlink "$temp_home/home/.codex/AGENTS.md")" = "/etc/agentctl/image.md" ] || fail "Expected Codex AGENTS.md to point at image defaults"
}

test_agent_sh_opencode_runtime_reset_config_writes_ollama_config() {
  begin_test "agent.sh opencode runtime reset-config writes Ollama provider config"

  local temp_home
  local fake_bin
  local config_file
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  config_file="$temp_home/home/.config/opencode/opencode.json"
  mkdir -p "$fake_bin" "$(dirname "$config_file")"
  printf '{"provider":{"custom":{}}}\n' >"$config_file"

  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- runtime reset-config opencode
  assert_status 0
  assert_contains "Warning: resetting OpenCode configuration will replace ~/.config/opencode/opencode.json"
  jq -er '.model == "ollama/gpt-oss:20b" and .provider.ollama.npm == "@ai-sdk/openai-compatible" and .provider.ollama.options.baseURL == "http://192.168.0.1:11434/v1" and .provider.ollama.options.apiKey == "ollama" and .provider.ollama.models["gpt-oss:20b"].name == "gpt-oss:20b (local)"' "$config_file" >/dev/null || fail "Expected OpenCode reset-config to write Ollama config"
}

test_agent_sh_qwen_runtime_reset_config_writes_ollama_config() {
  begin_test "agent.sh qwen runtime reset-config writes Ollama provider config"

  local temp_home
  local fake_bin
  local settings_file
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  settings_file="$temp_home/home/.qwen/settings.json"
  mkdir -p "$fake_bin" "$(dirname "$settings_file")"
  printf '{"model":{"name":"custom"}}\n' >"$settings_file"

  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- runtime reset-config qwen
  assert_status 0
  assert_contains "Warning: resetting Qwen Code configuration will replace ~/.qwen/settings.json"
  jq -er '.model.name == "gpt-oss:20b" and .security.auth.selectedType == "openai" and .env.OLLAMA_API_KEY == "ollama" and .modelProviders.openai.protocol == "openai" and .modelProviders.openai.models[0].id == "gpt-oss:20b" and .modelProviders.openai.models[0].baseUrl == "http://192.168.0.1:11434/v1" and .modelProviders.openai.models[0].envKey == "OLLAMA_API_KEY" and .telemetry.enabled == false and .privacy.usageStatisticsEnabled == false' "$settings_file" >/dev/null || fail "Expected Qwen reset-config to write Ollama config"
}

test_agent_sh_pi_runtime_reset_config_writes_ollama_config() {
  begin_test "agent.sh pi runtime reset-config writes Ollama provider config"

  local temp_home
  local fake_bin
  local models_file
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  models_file="$temp_home/home/.pi/agent/models.json"
  mkdir -p "$fake_bin" "$(dirname "$models_file")"
  printf '{"providers":{"custom":{}}}\n' >"$models_file"

  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- runtime reset-config pi
  assert_status 0
  assert_contains "Warning: resetting Pi configuration will replace ~/.pi/agent/models.json"
  jq -er '.providers.ollama.baseUrl == "http://192.168.0.1:11434/v1" and .providers.ollama.api == "openai-completions" and .providers.ollama.apiKey == "ollama" and .providers.ollama.compat.supportsDeveloperRole == false and .providers.ollama.models[0].id == "gpt-oss:20b" and .providers.ollama.models[0].name == "gpt-oss:20b (local Ollama)"' "$models_file" >/dev/null || fail "Expected Pi reset-config to write Ollama config"
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
printf 'CODEX_HOME=%s\nARGS=%s\n' "\$CODEX_HOME" "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/codex"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_RUN_MODE=online \
    -- run
  assert_status 0
  grep -Fxq "CODEX_HOME=$temp_home/home/.codex" "$run_log" || fail "Expected codex run to use user CODEX_HOME"
  grep -Fq -- 'ARGS=--cd /workdir' "$run_log" || fail "Expected codex run to include --cd /workdir"
}

test_agent_sh_codex_run_repairs_broken_bundled_rg() {
  begin_test "agent.sh codex run repairs broken bundled ripgrep"

  local temp_home
  local fake_bin
  local tools_home
  local run_log
  local bundled_rg
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  tools_home="$temp_home/tools"
  run_log="$temp_home/codex-run.log"
  bundled_rg="$tools_home/codex/packages/standalone/current/codex-path/rg"
  mkdir -p "$fake_bin" "$(dirname "$bundled_rg")"

  cat >"$fake_bin/codex" <<EOF
#!/bin/sh
printf 'CODEX_HOME=%s\nARGS=%s\n' "\$CODEX_HOME" "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/codex"

  cat >"$fake_bin/rg" <<'EOF'
#!/bin/sh
case "$1" in
  --version) printf '%s\n' 'ripgrep 15.1.0'; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$fake_bin/rg"

  cat >"$bundled_rg" <<'EOF'
#!/bin/sh
exit 127
EOF
  chmod +x "$bundled_rg"

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_TOOLS_HOME="$tools_home" \
    AGENTCTL_RUN_MODE=online \
    -- run
  assert_status 0
  [ -L "$bundled_rg" ] || fail "Expected broken bundled rg to be replaced with a symlink"
  case "$(readlink "$bundled_rg")" in
    "$tools_home"/*) fail "Expected bundled rg to point outside tool home" ;;
  esac
  "$bundled_rg" --version >/dev/null 2>&1 || fail "Expected repaired bundled rg to execute"
  grep -Fxq "CODEX_HOME=$temp_home/home/.codex" "$run_log" || fail "Expected codex run to continue after rg repair"
  assert_contains "Repaired Codex bundled ripgrep:"
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
      and .reasoning_summary_format == "none"
      and .default_reasoning_summary == "auto"
      and .default_reasoning_level == "medium"
      and (.supported_reasoning_levels | length) == 3)
  ' "$temp_home/home/.codex/local_models.json" >/dev/null || fail "Expected Codex model catalog metadata to be generated"
  grep -Fq -- '--profile gpt-oss --cd /workdir' "$run_log" || fail "Expected codex run to launch after local metadata update"
}

test_agent_sh_codex_local_run_uses_ollama_host_env() {
  begin_test "agent.sh codex local run uses OLLAMA_HOST for Ollama config"

  local temp_home
  local fake_bin
  local url_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  url_log="$temp_home/urls.log"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/codex"

  cat >"$fake_bin/curl" <<EOF
#!/bin/sh
last=
for arg in "\$@"; do
  last="\$arg"
done
printf '%s\n' "\$last" >>"$url_log"
case "\$last" in
  http://192.168.64.1:11439/api/version)
    printf '{"version":"0.0.0"}\n'
    exit 0
    ;;
  http://192.168.64.1:11439/api/show)
    cat >/dev/null
    printf '{"system":"","capabilities":[],"details":{"format":"safetensors"},"model_info":{"llama.context_length":4096}}\n'
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$fake_bin/curl"

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
    OLLAMA_HOST="http://192.168.64.1:11439/" \
    -- run
  assert_status 0
  grep -Fq 'http://192.168.64.1:11439/api/version' "$url_log" || fail "Expected explicit Ollama host version probe"
  grep -Fq 'http://192.168.64.1:11439/api/show' "$url_log" || fail "Expected explicit Ollama host model probe"
  grep -Fq 'base_url = "http://192.168.64.1:11439/v1"' "$temp_home/home/.codex/config.toml" || fail "Expected Codex myollama base_url to use explicit Ollama host"
}

test_agent_sh_codex_local_run_config_ollama_host_overrides_env() {
  begin_test "agent.sh codex local run runtime config ollama_host overrides OLLAMA_HOST"

  local temp_home
  local fake_bin
  local url_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  url_log="$temp_home/urls.log"
  mkdir -p "$fake_bin" "$temp_home/home/.codex"

  cat >"$fake_bin/codex" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$fake_bin/codex"

  cat >"$fake_bin/curl" <<EOF
#!/bin/sh
last=
for arg in "\$@"; do
  last="\$arg"
done
printf '%s\n' "\$last" >>"$url_log"
case "\$last" in
  http://192.168.64.1:11439/api/version)
    printf '{"version":"0.0.0"}\n'
    exit 0
    ;;
  http://192.168.64.1:11439/api/show)
    cat >/dev/null
    printf '{"system":"","capabilities":[],"details":{"format":"safetensors"},"model_info":{"llama.context_length":4096}}\n'
    exit 0
    ;;
  http://wrong-host:11434/*)
    exit 1
    ;;
esac
exit 1
EOF
  chmod +x "$fake_bin/curl"

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
    OLLAMA_HOST="http://wrong-host:11434" \
    AGENTCTL_RUNTIME_CONFIG_JSON='{"ollama_host":"http://192.168.64.1:11439/"}' \
    -- run
  assert_status 0
  grep -Fq 'http://192.168.64.1:11439/api/version' "$url_log" || fail "Expected runtime config Ollama host version probe"
  if grep -Fq 'http://wrong-host:11434' "$url_log"; then
    fail "Did not expect OLLAMA_HOST to be used when runtime config ollama_host is set"
  fi
  grep -Fq 'base_url = "http://192.168.64.1:11439/v1"' "$temp_home/home/.codex/config.toml" || fail "Expected Codex myollama base_url to use runtime config Ollama host"
}

test_agent_sh_codex_local_run_reports_unreachable_ollama_host() {
  begin_test "agent.sh codex local run reports unreachable explicit Ollama host"

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
exit 1
EOF
  chmod +x "$fake_bin/curl"

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
    OLLAMA_HOST="http://192.168.64.1:11439" \
    -- run
  assert_status 1
  assert_contains "Configured Ollama host: http://192.168.64.1:11439/api/version"
  assert_contains "Use a URL reachable from inside the container"
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
    "AGENTCTL_TOOLS_HOME=$temp_home/tools" \
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
EOF
  cat >"$temp_home/home/.codex/gemma.config.toml" <<'EOF'
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
      "apply_patch_tool_type": "function",
      "reasoning_summary_format": "none",
      "default_reasoning_summary": "auto",
      "default_reasoning_level": "medium",
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
    .models[0].apply_patch_tool_type == "freeform" and
    .models[0].custom == "keep" and
    .models[0].input_modalities == ["text"] and
    .models[0].supports_reasoning_summaries == false and
    (.models[0] | has("reasoning_summary_format") | not) and
    (.models[0] | has("default_reasoning_summary") | not) and
    (.models[0] | has("default_reasoning_level") | not)
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
        apply_patch_tool_type: "freeform",
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
  config_mtime_before="$(file_mtime "$temp_home/home/.codex/config.toml")"
  catalog_mtime_before="$(file_mtime "$temp_home/home/.codex/local_models.json")"
  sleep 1

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  assert_contains "model metadata unchanged: gpt-oss:20b"
  config_mtime_after="$(file_mtime "$temp_home/home/.codex/config.toml")"
  catalog_mtime_after="$(file_mtime "$temp_home/home/.codex/local_models.json")"
  [ "$config_mtime_after" = "$config_mtime_before" ] || fail "Expected unchanged Codex config timestamp to be preserved"
  [ "$catalog_mtime_after" = "$catalog_mtime_before" ] || fail "Expected unchanged Codex model catalog timestamp to be preserved"
}

test_agent_sh_codex_local_run_migrates_inactive_catalog_entries() {
  begin_test "agent.sh codex local run migrates inactive model catalog entries"

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
    printf '{"system":"","capabilities":[],"details":{"format":"safetensors"},"model_info":{"llama.context_length":4096},"parameters":""}\n'
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
model = "active:model"
EOF
  cat >"$temp_home/home/.codex/local_models.json" <<'EOF'
{
  "models": [
    {
      "slug": "active:model",
      "display_name": "active:model",
      "context_window": 4096,
      "apply_patch_tool_type": "freeform"
    },
    {
      "slug": "inactive:model",
      "display_name": "inactive:model",
      "context_window": 8192,
      "apply_patch_tool_type": "function"
    }
  ]
}
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  jq -er '
    (.models[] | select(.slug == "active:model").apply_patch_tool_type) == "freeform" and
    (.models[] | select(.slug == "inactive:model").apply_patch_tool_type) == "freeform"
  ' "$temp_home/home/.codex/local_models.json" >/dev/null || fail "Expected all catalog entries to use freeform patch type"
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
  assert_contains "Local Ollama model is not available: gpt-oss:20b"
  assert_contains "ollama pull gpt-oss:20b"
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
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
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
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
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
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
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
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
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

test_agent_sh_opencode_run_uses_local_ollama_defaults() {
  begin_test "agent.sh opencode run writes default Ollama config and model"

  local temp_home
  local fake_bin
  local run_log
  local config_file
  local registry_dir
  local default_dir
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/opencode-run.log"
  config_file="$temp_home/home/.config/opencode/opencode.json"
  registry_dir="$temp_home/runtimes.d"
  default_dir="$temp_home/default-opencode"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl" "$registry_dir" "$default_dir"
  printf '%s\n' opencode >"$temp_home/config/agentctl/preferred-runtime"
  jq --arg config_dir "$default_dir" '.default_config_dir = $config_dir' \
    "$TEST_ROOT/runtimes.d/opencode.json" >"$registry_dir/opencode.json"
  printf '%s\n' '{"seeded":true,"model":"ollama/gpt-oss:20b","provider":{"ollama":{}}}' >"$default_dir/opencode.json"

  cat >"$fake_bin/opencode" <<EOF
#!/bin/sh
printf 'ARGS=%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/opencode"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$registry_dir" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  grep -Fq 'ARGS=--model ollama/gpt-oss:20b' "$run_log" || fail "Expected OpenCode run to inject the default local model"
  jq -er '.seeded == true' "$config_file" >/dev/null || fail "Expected OpenCode run to seed image-owned defaults"
}

test_agent_sh_opencode_run_uses_model_override() {
  begin_test "agent.sh opencode run maps the generic model override to provider/model"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/opencode-run.log"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl"
  printf '%s\n' opencode >"$temp_home/config/agentctl/preferred-runtime"

  cat >"$fake_bin/opencode" <<EOF
#!/bin/sh
printf 'ARGS=%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/opencode"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
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
  grep -Fq 'ARGS=--model ollama/qwen3:14b' "$run_log" || fail "Expected OpenCode model override to use provider/model format"
}

test_agent_sh_opencode_run_respects_explicit_model() {
  begin_test "agent.sh opencode run keeps an explicit model argument"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/opencode-run.log"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl"
  printf '%s\n' opencode >"$temp_home/config/agentctl/preferred-runtime"

  cat >"$fake_bin/opencode" <<EOF
#!/bin/sh
printf 'ARGS=%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/opencode"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0   0  00000000    0   0      0
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_MODEL_OVERRIDE="qwen3:14b" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run --model custom/model run hello
  assert_status 0
  grep -Fq 'ARGS=--model custom/model run hello' "$run_log" || fail "Expected explicit OpenCode model to be preserved"
}

test_agent_sh_qwen_run_uses_local_ollama_defaults() {
  begin_test "agent.sh qwen run writes default Ollama config and model"

  local temp_home
  local fake_bin
  local run_log
  local settings_file
  local registry_dir
  local default_dir
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/qwen-run.log"
  settings_file="$temp_home/home/.qwen/settings.json"
  registry_dir="$temp_home/runtimes.d"
  default_dir="$temp_home/default-qwen"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl" "$registry_dir" "$default_dir"
  printf '%s\n' qwen >"$temp_home/config/agentctl/preferred-runtime"
  jq --arg config_dir "$default_dir" '.default_config_dir = $config_dir' \
    "$TEST_ROOT/runtimes.d/qwen.json" >"$registry_dir/qwen.json"
  printf '%s\n' '{"seeded":true}' >"$default_dir/settings.json"

  cat >"$fake_bin/qwen" <<EOF
#!/bin/sh
printf 'ARGS=%s\nOLLAMA_API_KEY=%s\nOPENAI_BASE_URL=%s\nOPENAI_MODEL=%s\n' "\$*" "\$OLLAMA_API_KEY" "\$OPENAI_BASE_URL" "\$OPENAI_MODEL" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/qwen"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$registry_dir" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  grep -Fq 'ARGS=--auth-type openai --model gpt-oss:20b' "$run_log" || fail "Expected Qwen run to inject OpenAI auth type and default local model"
  grep -Fq 'OLLAMA_API_KEY=ollama' "$run_log" || fail "Expected Qwen run to provide dummy Ollama API key"
  grep -Fq 'OPENAI_BASE_URL=http://192.168.0.1:11434/v1' "$run_log" || fail "Expected Qwen run to provide OpenAI-compatible Ollama base URL"
  grep -Fq 'OPENAI_MODEL=gpt-oss:20b' "$run_log" || fail "Expected Qwen run to provide OpenAI model env"
  jq -er '.seeded == true and .model.name == "gpt-oss:20b" and .modelProviders.openai.models[0].baseUrl == "http://192.168.0.1:11434/v1" and .privacy.usageStatisticsEnabled == false' "$settings_file" >/dev/null || fail "Expected Qwen run to seed defaults and merge Ollama config"
}

test_agent_sh_qwen_run_uses_model_override() {
  begin_test "agent.sh qwen run maps the generic model override"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/qwen-run.log"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl"
  printf '%s\n' qwen >"$temp_home/config/agentctl/preferred-runtime"

  cat >"$fake_bin/qwen" <<EOF
#!/bin/sh
printf 'ARGS=%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/qwen"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
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
  grep -Fq 'ARGS=--auth-type openai --model qwen3:14b' "$run_log" || fail "Expected Qwen model override to be passed through with OpenAI auth type"
}

test_agent_sh_qwen_run_respects_explicit_model() {
  begin_test "agent.sh qwen run keeps an explicit model argument"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/qwen-run.log"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl"
  printf '%s\n' qwen >"$temp_home/config/agentctl/preferred-runtime"

  cat >"$fake_bin/qwen" <<EOF
#!/bin/sh
printf 'ARGS=%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/qwen"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
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
    -- run --model custom-model hello
  assert_status 0
  grep -Fq 'ARGS=--auth-type openai --model custom-model hello' "$run_log" || fail "Expected explicit Qwen model to be preserved with OpenAI auth type"
}

test_agent_sh_qwen_run_merges_existing_settings() {
  begin_test "agent.sh qwen run merges Ollama config into existing settings"

  local temp_home
  local fake_bin
  local run_log
  local settings_file
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/qwen-run.log"
  settings_file="$temp_home/home/.qwen/settings.json"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl" "$(dirname "$settings_file")"
  printf '%s\n' qwen >"$temp_home/config/agentctl/preferred-runtime"
  cat >"$settings_file" <<'EOF'
{
  "modelProviders": {
    "anthropic": {
      "protocol": "anthropic",
      "models": [
        {
          "id": "claude",
          "envKey": "ANTHROPIC_API_KEY"
        }
      ]
    }
  },
  "security": {
    "auth": {
      "selectedType": "anthropic"
    }
  },
  "telemetry": {
    "enabled": true
  },
  "privacy": {
    "usageStatisticsEnabled": true
  }
}
EOF

  cat >"$fake_bin/qwen" <<EOF
#!/bin/sh
printf 'ARGS=%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/qwen"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_MODEL_OVERRIDE="qwen2.5-coder:7b" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  grep -Fq 'ARGS=--auth-type openai --model qwen2.5-coder:7b' "$run_log" || fail "Expected Qwen run to force OpenAI auth for local Ollama"
  jq -er '.modelProviders.anthropic.models[0].id == "claude" and any(.modelProviders.openai.models[]; .id == "qwen2.5-coder:7b" and .baseUrl == "http://192.168.0.1:11434/v1")' "$settings_file" >/dev/null || fail "Expected Qwen run to preserve existing providers and add Ollama model"
  jq -er '.security.auth.selectedType == "openai" and .model.name == "qwen2.5-coder:7b" and .telemetry.enabled == false and .privacy.usageStatisticsEnabled == false' "$settings_file" >/dev/null || fail "Expected Qwen run to force local OpenAI auth and privacy settings"
}

test_agent_sh_qwen_run_rejects_missing_ollama_model() {
  begin_test "agent.sh qwen run rejects a missing Ollama model before launch"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/qwen-run.log"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl"
  printf '%s\n' qwen >"$temp_home/config/agentctl/preferred-runtime"

  cat >"$fake_bin/qwen" <<EOF
#!/bin/sh
printf 'SHOULD_NOT_RUN\n' >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/qwen"
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

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_MODEL_OVERRIDE="qwen2.5-coder:7b" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 1
  assert_contains "Local Ollama model is not available: qwen2.5-coder:7b"
  assert_contains "ollama pull qwen2.5-coder:7b"
  [ ! -e "$run_log" ] || fail "Did not expect Qwen to launch when Ollama model is missing"
}

test_agent_sh_pi_run_uses_local_ollama_defaults() {
  begin_test "agent.sh pi run writes default Ollama config and model"

  local temp_home
  local fake_bin
  local run_log
  local models_file
  local registry_dir
  local default_dir
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/pi-run.log"
  models_file="$temp_home/home/.pi/agent/models.json"
  registry_dir="$temp_home/runtimes.d"
  default_dir="$temp_home/default-pi"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl" "$registry_dir" "$default_dir"
  printf '%s\n' pi >"$temp_home/config/agentctl/preferred-runtime"
  jq --arg config_dir "$default_dir" '.default_config_dir = $config_dir' \
    "$TEST_ROOT/runtimes.d/pi.json" >"$registry_dir/pi.json"
  printf '%s\n' '{"seeded":true}' >"$default_dir/models.json"

  cat >"$fake_bin/pi" <<EOF
#!/bin/sh
printf 'ARGS=%s\nPI_TELEMETRY=%s\nPI_OFFLINE=%s\nPI_SKIP_VERSION_CHECK=%s\n' "\$*" "\$PI_TELEMETRY" "\$PI_OFFLINE" "\$PI_SKIP_VERSION_CHECK" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/pi"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$registry_dir" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  grep -Fq 'ARGS=--model ollama/gpt-oss:20b' "$run_log" || fail "Expected Pi run to inject the default local model"
  grep -Fq 'PI_TELEMETRY=0' "$run_log" || fail "Expected Pi telemetry to be disabled"
  grep -Fq 'PI_OFFLINE=1' "$run_log" || fail "Expected Pi offline mode to disable startup network operations"
  grep -Fq 'PI_SKIP_VERSION_CHECK=1' "$run_log" || fail "Expected Pi version checks to be disabled"
  jq -er '.seeded == true and .providers.ollama.baseUrl == "http://192.168.0.1:11434/v1" and .providers.ollama.models[0].id == "gpt-oss:20b"' "$models_file" >/dev/null || fail "Expected Pi run to seed defaults and merge Ollama config"
}

test_agent_sh_pi_run_uses_model_override() {
  begin_test "agent.sh pi run maps the generic model override to provider/model"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/pi-run.log"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl"
  printf '%s\n' pi >"$temp_home/config/agentctl/preferred-runtime"

  cat >"$fake_bin/pi" <<EOF
#!/bin/sh
printf 'ARGS=%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/pi"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
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
  grep -Fq 'ARGS=--model ollama/qwen3:14b' "$run_log" || fail "Expected Pi model override to use provider/model format"
}

test_agent_sh_pi_run_respects_explicit_model() {
  begin_test "agent.sh pi run keeps an explicit model argument"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/pi-run.log"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl"
  printf '%s\n' pi >"$temp_home/config/agentctl/preferred-runtime"

  cat >"$fake_bin/pi" <<EOF
#!/bin/sh
printf 'ARGS=%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/pi"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
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
    -- run --model custom/model hello
  assert_status 0
  grep -Fq 'ARGS=--model custom/model hello' "$run_log" || fail "Expected explicit Pi model to be preserved"
}

test_agent_sh_pi_run_merges_existing_models_config() {
  begin_test "agent.sh pi run merges Ollama provider into existing models config"

  local temp_home
  local fake_bin
  local run_log
  local models_file
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/pi-run.log"
  models_file="$temp_home/home/.pi/agent/models.json"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl" "$(dirname "$models_file")"
  printf '%s\n' pi >"$temp_home/config/agentctl/preferred-runtime"
  cat >"$models_file" <<'EOF'
{
  "providers": {
    "custom": {
      "baseUrl": "https://example.test/v1",
      "api": "openai-completions",
      "apiKey": "custom",
      "models": [
        {
          "id": "custom-model"
        }
      ]
    }
  }
}
EOF

  cat >"$fake_bin/pi" <<EOF
#!/bin/sh
printf 'ARGS=%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/pi"
  cat >"$fake_bin/curl" <<'EOF'
#!/bin/sh
case "$*" in
  *'/api/show'*) cat >/dev/null; printf '{}\n'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fake_bin/curl"
  cat >"$temp_home/proc-net-route" <<'EOF'
Iface   Destination Gateway     Flags RefCnt Use Metric Mask        MTU Window IRTT
eth0    00000000    0100A8C0    0003  0      0   0      00000000    0   0      0
EOF

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_MODEL_OVERRIDE="qwen2.5-coder:7b" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 0
  grep -Fq 'ARGS=--model ollama/qwen2.5-coder:7b' "$run_log" || fail "Expected Pi run to use Ollama provider model"
  jq -er '.providers.custom.models[0].id == "custom-model" and .providers.ollama.baseUrl == "http://192.168.0.1:11434/v1" and any(.providers.ollama.models[]; .id == "qwen2.5-coder:7b")' "$models_file" >/dev/null || fail "Expected Pi run to preserve existing providers and add Ollama model"
}

test_agent_sh_pi_run_rejects_missing_ollama_model() {
  begin_test "agent.sh pi run rejects a missing Ollama model before launch"

  local temp_home
  local fake_bin
  local run_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  run_log="$temp_home/pi-run.log"
  mkdir -p "$fake_bin" "$temp_home/config/agentctl"
  printf '%s\n' pi >"$temp_home/config/agentctl/preferred-runtime"

  cat >"$fake_bin/pi" <<EOF
#!/bin/sh
printf 'SHOULD_NOT_RUN\n' >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/pi"
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

  run_agent_sh_capture_env "$temp_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    AGENTCTL_MODEL_OVERRIDE="qwen2.5-coder:7b" \
    AGENTCTL_OLLAMA_ROUTE_FILE="$temp_home/proc-net-route" \
    -- run
  assert_status 1
  assert_contains "Local Ollama model is not available: qwen2.5-coder:7b"
  assert_contains "ollama pull qwen2.5-coder:7b"
  [ ! -e "$run_log" ] || fail "Did not expect Pi to launch when Ollama model is missing"
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
    "$temp_home/home/.codex/packages/standalone/current/bin" \
    "$temp_home/home/.config/agentctl" \
    "$temp_home/home/.claude"
  printf '%s' 'codex-auth' >"$temp_home/home/.codex/auth.json"
  printf '%s' 'codex-binary' >"$temp_home/home/.codex/packages/standalone/current/bin/codex"
  printf '%s' 'claude' >"$temp_home/home/.config/agentctl/preferred-runtime"
  printf '%s' '{"claudeAiOauth":{"accessToken":"a","refreshToken":"b","expiresAt":1}}' >"$temp_home/home/.claude/.credentials.json"
  printf '%s' '{"hasCompletedOnboarding":true}' >"$temp_home/home/.claude.json"
  printf '%s' 'export PATH="$HOME/go/bin:$PATH"' >"$temp_home/home/.profile"
  printf '%s' 'alias ll="ls -la"' >"$temp_home/home/.bashrc"
  printf '%s' 'apk add --no-cache go' >"$temp_home/home/.bash_history"

  env -i \
    "HOME=$temp_home/home" \
    "XDG_CONFIG_HOME=$temp_home/home/.config" \
    "PATH=/usr/bin:/bin" \
    "AGENTCTL_TOOLS_HOME=$temp_home/tools" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state export >"$tar_file"

  tar -tf "$tar_file" | grep -Fx '.codex/auth.json' >/dev/null || fail "Expected .codex/auth.json in exported state"
  if tar -tf "$tar_file" | grep -Fqx '.codex/packages/standalone/current/bin/codex'; then
    fail "Did not expect Codex package artifacts in legacy exported state"
  fi
  tar -tf "$tar_file" | grep -Fx '.config/agentctl/preferred-runtime' >/dev/null || fail "Expected preferred runtime in exported state"
  tar -tf "$tar_file" | grep -Fx '.claude/.credentials.json' >/dev/null || fail "Expected Claude credentials in exported state"
  tar -tf "$tar_file" | grep -Fx '.claude.json' >/dev/null || fail "Expected Claude home state in exported state"
  tar -tf "$tar_file" | grep -Fx '.profile' >/dev/null || fail "Expected .profile in exported state"
  tar -tf "$tar_file" | grep -Fx '.bashrc' >/dev/null || fail "Expected .bashrc in exported state"
  tar -tf "$tar_file" | grep -Fx '.bash_history' >/dev/null || fail "Expected .bash_history in exported state"
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
    "$temp_home/home/.codex/packages/standalone/current/bin" \
    "$temp_home/home/.claude" \
    "$temp_home/home/.config/agentctl"
  printf '%s' 'codex-auth' >"$temp_home/home/.codex/auth.json"
  printf '%s' 'codex-binary' >"$temp_home/home/.codex/packages/standalone/current/bin/codex"
  printf '%s' '{"claudeAiOauth":{"accessToken":"a","refreshToken":"b","expiresAt":1}}' >"$temp_home/home/.claude/.credentials.json"
  printf '%s' '{"hasCompletedOnboarding":true}' >"$temp_home/home/.claude.json"
  printf '%s' 'codex' >"$temp_home/home/.config/agentctl/preferred-runtime"
  printf '%s' 'export PATH="$HOME/go/bin:$PATH"' >"$temp_home/home/.profile"

  env -i \
    "HOME=$temp_home/home" \
    "XDG_CONFIG_HOME=$temp_home/home/.config" \
    "PATH=$fake_bin:/usr/bin:/bin" \
    "AGENTCTL_TOOLS_HOME=$temp_home/tools" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state export >"$tar_file"

  tar -tf "$tar_file" | grep -Fx '.codex/auth.json' >/dev/null || fail "Expected installed Codex runtime state in exported state"
  if tar -tf "$tar_file" | grep -Fqx '.codex/packages/standalone/current/bin/codex'; then
    fail "Did not expect Codex package artifacts in exported state"
  fi
  tar -tf "$tar_file" | grep -Fx '.config/agentctl/preferred-runtime' >/dev/null || fail "Expected generic agentctl state in exported state"
  tar -tf "$tar_file" | grep -Fx '.profile' >/dev/null || fail "Expected shell state in exported state"
  if tar -tf "$tar_file" | grep -Fqx '.claude/.credentials.json'; then
    fail "Did not expect Claude legacy state to be exported when only Codex is installed"
  fi
  if tar -tf "$tar_file" | grep -Fqx '.claude.json'; then
    fail "Did not expect Claude home state to be exported when only Codex is installed"
  fi
}

test_agent_sh_opencode_state_export_uses_runtime_hooks() {
  begin_test "agent.sh state export includes installed OpenCode state"

  local temp_home
  local fake_bin
  local tar_file
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  tar_file="$temp_home/state.tar"
  fake_bin="$(make_fake_runtime_bin "$temp_home" opencode)"

  mkdir -p \
    "$temp_home/home/.config/opencode" \
    "$temp_home/home/.local/share/opencode" \
    "$temp_home/home/.config/agentctl" \
    "$temp_home/home/.codex"
  printf '%s' '{"provider":{}}' >"$temp_home/home/.config/opencode/opencode.json"
  printf '%s' 'session' >"$temp_home/home/.local/share/opencode/session.db"
  printf '%s' 'token' >"$temp_home/home/.codex/auth.json"
  printf '%s' 'opencode' >"$temp_home/home/.config/agentctl/preferred-runtime"

  env -i \
    "HOME=$temp_home/home" \
    "XDG_CONFIG_HOME=$temp_home/home/.config" \
    "PATH=$fake_bin:/usr/bin:/bin" \
    "AGENTCTL_TOOLS_HOME=$temp_home/tools" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state export >"$tar_file"

  tar -tf "$tar_file" | grep -Fx '.config/opencode/opencode.json' >/dev/null || fail "Expected OpenCode config in exported state"
  tar -tf "$tar_file" | grep -Fx '.local/share/opencode/session.db' >/dev/null || fail "Expected OpenCode share state in exported state"
  tar -tf "$tar_file" | grep -Fx '.config/agentctl/preferred-runtime' >/dev/null || fail "Expected agentctl state in exported state"
  if tar -tf "$tar_file" | grep -Fqx '.codex/auth.json'; then
    fail "Did not expect Codex legacy state to be exported when only OpenCode is installed"
  fi
}

test_agent_sh_qwen_state_export_uses_runtime_hooks() {
  begin_test "agent.sh state export includes installed Qwen state"

  local temp_home
  local fake_bin
  local tar_file
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  tar_file="$temp_home/state.tar"
  fake_bin="$(make_fake_runtime_bin "$temp_home" qwen)"

  mkdir -p \
    "$temp_home/home/.qwen" \
    "$temp_home/home/.config/agentctl" \
    "$temp_home/home/.codex"
  printf '%s' '{"model":{"name":"gpt-oss:20b"}}' >"$temp_home/home/.qwen/settings.json"
  printf '%s' 'session' >"$temp_home/home/.qwen/session.json"
  printf '%s' 'token' >"$temp_home/home/.codex/auth.json"
  printf '%s' 'qwen' >"$temp_home/home/.config/agentctl/preferred-runtime"

  env -i \
    "HOME=$temp_home/home" \
    "XDG_CONFIG_HOME=$temp_home/home/.config" \
    "PATH=$fake_bin:/usr/bin:/bin" \
    "AGENTCTL_TOOLS_HOME=$temp_home/tools" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state export >"$tar_file"

  tar -tf "$tar_file" | grep -Fx '.qwen/settings.json' >/dev/null || fail "Expected Qwen settings in exported state"
  tar -tf "$tar_file" | grep -Fx '.qwen/session.json' >/dev/null || fail "Expected Qwen runtime state in exported state"
  tar -tf "$tar_file" | grep -Fx '.config/agentctl/preferred-runtime' >/dev/null || fail "Expected agentctl state in exported state"
  if tar -tf "$tar_file" | grep -Fqx '.codex/auth.json'; then
    fail "Did not expect Codex legacy state to be exported when only Qwen is installed"
  fi
}

test_agent_sh_pi_state_export_uses_runtime_hooks() {
  begin_test "agent.sh state export includes installed Pi state"

  local temp_home
  local fake_bin
  local tar_file
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  tar_file="$temp_home/state.tar"
  fake_bin="$(make_fake_runtime_bin "$temp_home" pi)"

  mkdir -p \
    "$temp_home/home/.pi/agent/sessions" \
    "$temp_home/home/.config/agentctl" \
    "$temp_home/home/.codex"
  printf '%s' '{"providers":{"ollama":{}}}' >"$temp_home/home/.pi/agent/models.json"
  printf '%s' 'session' >"$temp_home/home/.pi/agent/sessions/session.jsonl"
  printf '%s' 'token' >"$temp_home/home/.codex/auth.json"
  printf '%s' 'pi' >"$temp_home/home/.config/agentctl/preferred-runtime"

  env -i \
    "HOME=$temp_home/home" \
    "XDG_CONFIG_HOME=$temp_home/home/.config" \
    "PATH=$fake_bin:/usr/bin:/bin" \
    "AGENTCTL_TOOLS_HOME=$temp_home/tools" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state export >"$tar_file"

  tar -tf "$tar_file" | grep -Fx '.pi/agent/models.json' >/dev/null || fail "Expected Pi models config in exported state"
  tar -tf "$tar_file" | grep -Fx '.pi/agent/sessions/session.jsonl' >/dev/null || fail "Expected Pi session state in exported state"
  tar -tf "$tar_file" | grep -Fx '.config/agentctl/preferred-runtime' >/dev/null || fail "Expected agentctl state in exported state"
  if tar -tf "$tar_file" | grep -Fqx '.codex/auth.json'; then
    fail "Did not expect Codex legacy state to be exported when only Pi is installed"
  fi
}

test_backup_codex_config_from_export_excludes_codex_packages() {
  begin_test "export fallback backup excludes Codex package cache"

  load_agentctl_functions

  local temp_dir
  local export_file
  local backup_file
  local extract_root
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-fallback-export.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  export_file="$temp_dir/rootfs.tar"
  backup_file="$temp_dir/state.tar"
  extract_root="$temp_dir/extracted"
  : >"$export_file"

  extract_export_root() {
    local extract_root="$2"
    mkdir -p \
      "$extract_root/home/coder/.codex/packages/standalone/current/bin" \
      "$extract_root/home/coder/.codex/sessions" \
      "$extract_root/home/coder/.config/agentctl" \
      "$extract_root/opt/agentctl/codex"
    printf '%s' 'token' >"$extract_root/home/coder/.codex/auth.json"
    printf '%s' 'session' >"$extract_root/home/coder/.codex/sessions/session.jsonl"
    printf '%s' 'binary-cache' >"$extract_root/home/coder/.codex/packages/standalone/current/bin/codex"
    printf '%s' 'codex' >"$extract_root/home/coder/.config/agentctl/preferred-runtime"
    printf '%s' 'tool-cache' >"$extract_root/opt/agentctl/codex/package"
  }

  run_capture backup_codex_config_from_export "$export_file" "$backup_file" "$extract_root"
  assert_status 0

  tar -tf "$backup_file" | grep -Fx '.codex/auth.json' >/dev/null || fail "Expected Codex auth in export fallback backup"
  tar -tf "$backup_file" | grep -Fx '.codex/sessions/session.jsonl' >/dev/null || fail "Expected Codex sessions in export fallback backup"
  tar -tf "$backup_file" | grep -Fx '.config/agentctl/preferred-runtime' >/dev/null || fail "Expected agentctl state in export fallback backup"
  if tar -tf "$backup_file" | grep -Eq '^\.codex/packages(/|$)|^opt/agentctl(/|$)'; then
    tar -tf "$backup_file" >&2
    fail "Did not expect Codex packages or tool home in export fallback backup"
  fi
}

test_backup_known_state_from_container_excludes_codex_packages() {
  begin_test "legacy container backup excludes Codex package cache"

  load_agentctl_functions

  local temp_dir
  local fake_home
  local fake_bin
  local backup_file
  local old_container_cmd
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-known-state.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  fake_home="$temp_dir/home/coder"
  fake_bin="$temp_dir/bin"
  backup_file="$temp_dir/state.tar"
  mkdir -p \
    "$fake_home/.codex/packages/standalone/current/bin" \
    "$fake_home/.codex/sessions" \
    "$fake_home/.config/agentctl" \
    "$temp_dir/opt/agentctl/codex" \
    "$fake_bin"
  printf '%s' 'token' >"$fake_home/.codex/auth.json"
  printf '%s' 'session' >"$fake_home/.codex/sessions/session.jsonl"
  printf '%s' 'binary-cache' >"$fake_home/.codex/packages/standalone/current/bin/codex"
  printf '%s' 'codex' >"$fake_home/.config/agentctl/preferred-runtime"
  printf '%s' 'tool-cache' >"$temp_dir/opt/agentctl/codex/package"

  cat >"$fake_bin/container" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" != "exec" ]; then
  printf 'unexpected container command: %s\n' "$*" >&2
  exit 2
fi
shift
while [ $# -gt 0 ]; do
  case "$1" in
    -i)
      shift
      ;;
    unit-test-container)
      shift
      ;;
    --inh-caps=*|--ambient-caps=*|--no-new-privs)
      shift
      ;;
    sh)
      shift
      [ "${1:-}" = "-lc" ] || exit 2
      shift
      script="${1:-}"
      script="${script//\/home\/coder/$FAKE_CONTAINER_HOME}"
      exec sh -lc "$script"
      ;;
    *)
      shift
      ;;
  esac
done
EOF
  chmod +x "$fake_bin/container"

  old_container_cmd="$CONTAINER_CMD"
  CONTAINER_CMD="$fake_bin/container"
  FAKE_CONTAINER_HOME="$fake_home"
  export FAKE_CONTAINER_HOME

  run_capture backup_known_state_from_container unit-test-container "$backup_file"
  assert_status 0
  CONTAINER_CMD="$old_container_cmd"

  tar -tf "$backup_file" | grep -Fx '.codex/auth.json' >/dev/null || fail "Expected Codex auth in legacy backup"
  tar -tf "$backup_file" | grep -Fx '.codex/sessions/session.jsonl' >/dev/null || fail "Expected Codex sessions in legacy backup"
  tar -tf "$backup_file" | grep -Fx '.config/agentctl/preferred-runtime' >/dev/null || fail "Expected agentctl state in legacy backup"
  if tar -tf "$backup_file" | grep -Eq '^\.codex/packages(/|$)|^opt/agentctl(/|$)'; then
    tar -tf "$backup_file" >&2
    fail "Did not expect Codex packages or tool home in legacy backup"
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
  printf '%s' 'export PATH="$HOME/go/bin:$PATH"' >"$source_home/home/.profile"
  printf '%s' 'alias ll="ls -la"' >"$source_home/home/.bashrc"
  printf '%s' 'apk add --no-cache go' >"$source_home/home/.bash_history"

  env -i \
    "HOME=$source_home/home" \
    "XDG_CONFIG_HOME=$source_home/home/.config" \
    "PATH=/usr/bin:/bin" \
    "AGENTCTL_TOOLS_HOME=$source_home/tools" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state export >"$tar_file"

  env -i \
    "HOME=$target_home/home" \
    "XDG_CONFIG_HOME=$target_home/home/.config" \
    "PATH=/usr/bin:/bin" \
    "AGENTCTL_TOOLS_HOME=$target_home/tools" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state import <"$tar_file"

  [ "$(cat "$target_home/home/.codex/auth.json")" = "codex-auth" ] || fail "Expected Codex auth to be restored"
  [ "$(cat "$target_home/home/.config/agentctl/preferred-runtime")" = "claude" ] || fail "Expected preferred runtime to be restored"
  jq -er '.claudeAiOauth.refreshToken == "b"' "$target_home/home/.claude/.credentials.json" >/dev/null || fail "Expected Claude credentials to be restored"
  jq -er '.hasCompletedOnboarding == true' "$target_home/home/.claude.json" >/dev/null || fail "Expected Claude home state to be restored"
  grep -Fq 'go/bin' "$target_home/home/.profile" || fail "Expected .profile to be restored"
  grep -Fq 'alias ll=' "$target_home/home/.bashrc" || fail "Expected .bashrc to be restored"
  grep -Fq 'apk add --no-cache go' "$target_home/home/.bash_history" || fail "Expected .bash_history to be restored"
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
  printf '%s' 'export PATH="$HOME/go/bin:$PATH"' >"$source_home/home/.profile"

  env -i \
    "HOME=$source_home/home" \
    "XDG_CONFIG_HOME=$source_home/home/.config" \
    "PATH=/usr/bin:/bin" \
    "AGENTCTL_TOOLS_HOME=$source_home/tools" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state export >"$tar_file"

  mkdir -p "$target_home/home/.codex/packages/standalone/current/bin" "$target_home/home/.claude"
  printf '%s' 'stale-codex' >"$target_home/home/.codex/auth.json"
  printf '%s' 'image-codex-binary' >"$target_home/home/.codex/packages/standalone/current/bin/codex"
  printf '%s' '{"claudeAiOauth":{"accessToken":"stale","refreshToken":"keep","expiresAt":1}}' >"$target_home/home/.claude/.credentials.json"

  env -i \
    "HOME=$target_home/home" \
    "XDG_CONFIG_HOME=$target_home/home/.config" \
    "PATH=$fake_bin:/usr/bin:/bin" \
    "AGENTCTL_TOOLS_HOME=$target_home/tools" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state import <"$tar_file"

  [ "$(cat "$target_home/home/.codex/auth.json")" = "codex-auth" ] || fail "Expected installed Codex runtime state to be restored"
  [ "$(cat "$target_home/home/.codex/packages/standalone/current/bin/codex")" = "image-codex-binary" ] || fail "Expected image-owned Codex package artifacts to survive state import"
  [ "$(cat "$target_home/home/.config/agentctl/preferred-runtime")" = "codex" ] || fail "Expected generic agentctl state to be restored"
  grep -Fq 'go/bin' "$target_home/home/.profile" || fail "Expected shell state to be restored"
  jq -er '.claudeAiOauth.refreshToken == "keep"' "$target_home/home/.claude/.credentials.json" >/dev/null || fail "Expected unrelated Claude legacy state to remain untouched when Claude is not installed"
}

test_agent_sh_state_import_preserves_image_owned_codex_packages() {
  begin_test "agent.sh state import preserves image-owned codex packages"

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
    "$source_home/home/.codex/packages/standalone/current/bin" \
    "$target_home/home/.codex/packages/standalone/current/bin"
  printf '%s' 'restored-auth' >"$source_home/home/.codex/auth.json"
  printf '%s' 'stale-codex-binary' >"$source_home/home/.codex/packages/standalone/current/bin/codex"
  printf '%s' 'image-codex-binary' >"$target_home/home/.codex/packages/standalone/current/bin/codex"
  tar -C "$source_home/home" -cf "$tar_file" .codex

  env -i \
    "HOME=$target_home/home" \
    "XDG_CONFIG_HOME=$target_home/home/.config" \
    "PATH=$fake_bin:/usr/bin:/bin" \
    "AGENTCTL_TOOLS_HOME=$target_home/tools" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state import <"$tar_file"

  [ "$(cat "$target_home/home/.codex/auth.json")" = "restored-auth" ] || fail "Expected Codex auth state to be restored"
  [ "$(cat "$target_home/home/.codex/packages/standalone/current/bin/codex")" = "image-codex-binary" ] || fail "Expected image-owned Codex packages to survive stale package state import"
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
    "AGENTCTL_TOOLS_HOME=$temp_home/tools" \
    "AGENTCTL_RUNTIME_REGISTRY_DIR=$TEST_ROOT/runtimes.d" \
    "AGENTCTL_RUNTIME_ADAPTER_DIR=$TEST_ROOT/runtimes" \
    "AGENTCTL_FEATURE_REGISTRY_DIR=$TEST_ROOT/features.d" \
    "AGENTCTL_FEATURE_ADAPTER_DIR=$TEST_ROOT/features" \
    /bin/bash "$TEST_ROOT/agent.sh" state import </dev/null

  [ "$(cat "$temp_home/home/.codex/auth.json")" = "keep-me" ] || fail "Expected existing state to survive empty state import"
}

test_verify_restored_codex_state_passes_when_counts_match() {
  begin_test "verify_restored_codex_state accepts restored Codex history and sessions"

  load_agentctl_functions

  local temp_dir
  local backup_file
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-state-verify.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  backup_file="$temp_dir/state.tar"

  mkdir -p "$temp_dir/home/.codex/sessions/2026" "$temp_dir/home/.codex/archived_sessions"
  printf 'one\nsecond\n' >"$temp_dir/home/.codex/history.jsonl"
  printf 'idx\n' >"$temp_dir/home/.codex/session_index.jsonl"
  printf 'session\n' >"$temp_dir/home/.codex/sessions/2026/session.jsonl"
  printf 'archived\n' >"$temp_dir/home/.codex/archived_sessions/old.jsonl"
  tar -C "$temp_dir/home" -cf "$backup_file" .codex

  codex_state_summary_from_container() {
    printf '2\t2\t1\n'
  }

  run_capture verify_restored_codex_state unit-test-container "$backup_file"
  assert_status 0
  assert_contains "Restored Codex state in unit-test-container: history lines 2/2, session files 2/2, session index lines 1/1"
}

test_verify_restored_codex_state_fails_when_counts_drop() {
  begin_test "verify_restored_codex_state rejects missing restored Codex sessions"

  load_agentctl_functions

  local temp_dir
  local backup_file
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-state-verify.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  backup_file="$temp_dir/state.tar"

  mkdir -p "$temp_dir/home/.codex/sessions/2026"
  printf 'one\nsecond\n' >"$temp_dir/home/.codex/history.jsonl"
  printf 'session\n' >"$temp_dir/home/.codex/sessions/2026/session.jsonl"
  tar -C "$temp_dir/home" -cf "$backup_file" .codex

  codex_state_summary_from_container() {
    printf '0\t0\t0\n'
  }

  run_capture verify_restored_codex_state unit-test-container "$backup_file"
  assert_status 1
  assert_contains "Codex history restore verification failed"
  assert_contains "Codex session restore verification failed"
  assert_contains "Restored Codex state verification failed"
}

test_verify_restored_claude_state_passes_when_counts_match() {
  begin_test "verify_restored_claude_state accepts restored Claude state"

  load_agentctl_functions

  local temp_dir
  local backup_file
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-state-verify.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  backup_file="$temp_dir/state.tar"

  mkdir -p "$temp_dir/home/.claude/projects/project-a"
  printf '{}\n' >"$temp_dir/home/.claude/.credentials.json"
  printf '{}\n' >"$temp_dir/home/.claude/settings.json"
  printf '{}\n' >"$temp_dir/home/.claude.json"
  printf 'session\n' >"$temp_dir/home/.claude/projects/project-a/session.jsonl"
  tar -C "$temp_dir/home" -cf "$backup_file" .claude .claude.json

  claude_state_summary_from_container() {
    printf '1\t1\t1\t1\n'
  }

  run_capture verify_restored_claude_state unit-test-container "$backup_file"
  assert_status 0
  assert_contains "Restored Claude state in unit-test-container: credentials files 1/1, settings files 1/1, home state files 1/1, project files 1/1"
}

test_verify_restored_claude_state_fails_when_counts_drop() {
  begin_test "verify_restored_claude_state rejects missing restored Claude state"

  load_agentctl_functions

  local temp_dir
  local backup_file
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-state-verify.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  backup_file="$temp_dir/state.tar"

  mkdir -p "$temp_dir/home/.claude/projects/project-a"
  printf '{}\n' >"$temp_dir/home/.claude/.credentials.json"
  printf '{}\n' >"$temp_dir/home/.claude/settings.json"
  printf '{}\n' >"$temp_dir/home/.claude.json"
  printf 'session\n' >"$temp_dir/home/.claude/projects/project-a/session.jsonl"
  tar -C "$temp_dir/home" -cf "$backup_file" .claude .claude.json

  claude_state_summary_from_container() {
    printf '0\t0\t0\t0\n'
  }

  run_capture verify_restored_claude_state unit-test-container "$backup_file"
  assert_status 1
  assert_contains "Claude credentials restore verification failed"
  assert_contains "Claude settings restore verification failed"
  assert_contains "Claude home state restore verification failed"
  assert_contains "Claude project restore verification failed"
  assert_contains "Restored Claude state verification failed"
}

test_container_auth_info_uses_agent_sh_auth_read() {
  begin_test "container_auth_info reads auth via agent.sh auth read"

  load_agentctl_functions

  local temp_dir
  local exec_log_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-auth-read.XXXXXX")"
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
          shift 5
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

  load_agentctl_functions

  local temp_dir
  local exec_log_file
  local payload_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-auth-write.XXXXXX")"
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
          shift 5
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

  load_agentctl_functions

  local temp_dir
  local exec_log_file
  local fallback_payload_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-auth-write.XXXXXX")"
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
          shift 5
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

  load_agentctl_functions

  local temp_dir
  local exec_log_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-auth-write.XXXXXX")"
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
          shift 5
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

  load_agentctl_functions

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

test_sync_runtime_auth_to_container_skips_matching_auth() {
  begin_test "sync_runtime_auth_to_container skips matching auth"

  load_agentctl_functions

  local writes=0

  ensure_keychain() { return 0; }
  keychain_auth_info() {
    printf 'unit-token\t2026-04-17T00:00:00Z\n'
  }
  container_auth_info() {
    printf 'unit-token\t2026-04-17T00:00:00Z\n'
  }
  write_auth_blob_to_container() {
    writes=$((writes + 1))
  }
  write_keychain_auth_blob() {
    writes=$((writes + 1))
  }

  run_capture sync_runtime_auth_to_container unit-test-container codex json_refresh_token "missing auth"
  assert_status 0
  [ "$writes" -eq 0 ] || fail "Did not expect matching auth to be written"
}

test_sync_runtime_auth_to_container_uses_newer_keychain_auth() {
  begin_test "sync_runtime_auth_to_container refreshes container from newer Keychain auth"

  load_agentctl_functions

  local written_payload=""
  local keychain_writes=0

  ensure_keychain() { return 0; }
  keychain_auth_info() {
    printf 'keychain-token\t2026-04-17T02:00:00Z\n'
  }
  keychain_auth_blob() {
    printf '{"refresh_token":"keychain-token","last_refresh":"2026-04-17T02:00:00Z"}'
  }
  container_auth_info() {
    printf 'container-token\t2026-04-17T01:00:00Z\n'
  }
  write_auth_blob_to_container() {
    local name="$1" payload="$2" runtime="$3" auth_format="$4"
    [ "$name" = "unit-test-container" ] || fail "Unexpected container name: $name"
    [ "$runtime" = "codex" ] || fail "Unexpected runtime: $runtime"
    [ "$auth_format" = "json_refresh_token" ] || fail "Unexpected auth format: $auth_format"
    written_payload="$payload"
  }
  write_keychain_auth_blob() {
    keychain_writes=$((keychain_writes + 1))
  }

  run_capture sync_runtime_auth_to_container unit-test-container codex json_refresh_token "missing auth"
  assert_status 0
  printf '%s' "$written_payload" | jq -er '.refresh_token == "keychain-token"' >/dev/null || fail "Expected newer Keychain auth to be written to container"
  [ "$keychain_writes" -eq 0 ] || fail "Did not expect Keychain to be written"
}

test_sync_runtime_auth_to_container_promotes_newer_container_auth() {
  begin_test "sync_runtime_auth_to_container promotes newer container auth to Keychain"

  load_agentctl_functions

  local container_writes=0
  local written_blob_file
  local temp_dir

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-auth-promote.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  written_blob_file="$temp_dir/written-auth.json"

  ensure_keychain() { return 0; }
  keychain_auth_info() {
    printf 'keychain-token\t2026-04-17T01:00:00Z\n'
  }
  container_auth_info() {
    printf 'container-token\t2026-04-17T02:00:00Z\n'
  }
  container_auth_blob() {
    local name="$1" runtime="$2" auth_format="$3"
    [ "$name" = "unit-test-container" ] || fail "Unexpected container name: $name"
    [ "$runtime" = "codex" ] || fail "Unexpected runtime: $runtime"
    [ "$auth_format" = "json_refresh_token" ] || fail "Unexpected auth format: $auth_format"
    printf '{"refresh_token":"container-token","last_refresh":"2026-04-17T02:00:00Z"}'
  }
  write_auth_blob_to_container() {
    container_writes=$((container_writes + 1))
  }
  write_keychain_auth_blob() {
    local runtime="$1" auth_format="$2"
    [ "$runtime" = "codex" ] || fail "Unexpected runtime: $runtime"
    [ "$auth_format" = "json_refresh_token" ] || fail "Unexpected auth format: $auth_format"
    cat >"$written_blob_file"
  }

  run_capture sync_runtime_auth_to_container unit-test-container codex json_refresh_token "missing auth"
  assert_status 0
  assert_contains "Updating Keychain auth from unit-test-container"
  [ "$container_writes" -eq 0 ] || fail "Did not expect container auth to be overwritten"
  jq -er '.refresh_token == "container-token"' "$written_blob_file" >/dev/null || fail "Expected newer container auth to be written to Keychain"
}

test_sync_runtime_auth_to_container_rejects_inconclusive_conflict() {
  begin_test "sync_runtime_auth_to_container rejects conflicting auth without freshness"

  load_agentctl_functions

  ensure_keychain() { return 0; }
  keychain_auth_info() {
    printf 'keychain-token\t\n'
  }
  container_auth_info() {
    printf 'container-token\t\n'
  }
  write_auth_blob_to_container() {
    fail "Did not expect conflicting auth to be written to container"
  }
  write_keychain_auth_blob() {
    fail "Did not expect conflicting auth to be written to Keychain"
  }
  run_conflicting_auth_sync() {
    ( sync_runtime_auth_to_container unit-test-container codex json_refresh_token "missing auth" )
  }

  run_capture run_conflicting_auth_sync
  assert_status 1
  assert_contains "Refusing to overwrite conflicting codex auth for unit-test-container"
}

test_sync_runtime_auth_from_container_uses_runtime_parameters() {
  begin_test "sync_runtime_auth_from_container uses runtime-specific auth parameters"

  load_agentctl_functions

  local temp_dir
  local observed_runtime=""
  local observed_format=""
  local written_blob_file=""

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-auth-sync-from.XXXXXX")"
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

  load_agentctl_functions
  RUN_OUTPUT="$(printf '%s' '{"claudeAiOauth":{"refreshToken":"claude-refresh","expiresAt":1776462236852}}' | auth_info_from_json)"
  RUN_STATUS=0
  [ "$RUN_OUTPUT" = $'claude-refresh\t1776462236852' ] || fail "Expected Claude auth info tuple, got: $RUN_OUTPUT"
}

test_auth_info_from_json_preserves_escaped_tokens_and_normalizes_timestamps() {
  begin_test "auth JSON parsing preserves escaped tokens and normalizes timestamp types"

  load_agentctl_functions
  [ "$(printf '%s' '{"tokens":{"refresh_token":"quote\" slash\\ tab\t"},"last_refresh":"stamp"}' | auth_info_from_json)" = $'quote" slash\\ tab\t\tstamp' ] \
    || fail "Expected escaped token characters to survive jq parsing"
  [ "$(printf '%s' '{"claudeAiOauth":{"refreshToken":"token","expiresAt":"123"}}' | auth_info_from_json)" = $'token\t0000000000123' ] \
    || fail "Expected string expiresAt normalization"
  [ "$(printf '%s' '{"claudeAiOauth":{"refreshToken":"token","expiresAt":123456789012345}}' | auth_info_from_json)" = $'token\t123456789012345' ] \
    || fail "Expected long numeric expiresAt values to remain intact"
  [ "$(printf '%s' '{"claudeAiOauth":{"refreshToken":"token","expiresAt":12345678901234567}}' | auth_info_from_json)" = $'token\t12345678901234567' ] \
    || fail "Expected numeric expiresAt values above jq integer precision to remain intact"
  [ "$(printf '%s' '{"claudeAiOauth":{"refreshToken":"token","expiresAt":"123456789012345"}}' | auth_info_from_json)" = $'token\t123456789012345' ] \
    || fail "Expected long string expiresAt values to remain intact"
  [ "$(printf '%s' '{"refresh_token":"token","last_refresh":123}' | auth_info_from_json)" = $'token\t123' ] \
    || fail "Expected top-level numeric last_refresh to remain unpadded"
  [ "$(printf '%s' '{"last_refresh":0,"claudeAiOauth":{"refreshToken":"token","expiresAt":123}}' | auth_info_from_json)" = $'token\t0000000000123' ] \
    || fail "Expected zero last_refresh to fall back to Claude expiresAt"
  [ "$(printf '%s' '{"last_refresh":false,"claudeAiOauth":{"refreshToken":"token","expiresAt":"456"}}' | auth_info_from_json)" = $'token\t0000000000456' ] \
    || fail "Expected false last_refresh to fall back to Claude expiresAt"
  [ "$(printf '%s' '{"metadata":{"expiresAt":999},"claudeAiOauth":{"refreshToken":"token","expiresAt":12345678901234567}}' | auth_info_from_json)" = $'token\t12345678901234567' ] \
    || fail "Expected unrelated expiresAt fields to be ignored"
  [ "$(printf '%s' '{"note":"misleading \\\"expiresAt\\\": 888","claudeAiOauth":{"refreshToken":"token","expiresAt":12345678901234567}}' | auth_info_from_json)" = $'token\t12345678901234567' ] \
    || fail "Expected expiresAt-like string content to be ignored"
  [ "$(printf '%s' '{"refresh_token":"__agentctl_json_number__:secret","last_refresh":"__agentctl_json_number__:stamp"}' | auth_info_from_json)" = $'__agentctl_json_number__:secret\t__agentctl_json_number__:stamp' ] \
    || fail "Expected number-marker-like strings to remain intact"
  [ "$(printf '%s' '{"claudeAiOauth":{"refreshToken":"token","expiresAt":"__agentctl_json_number__:123"}}' | auth_info_from_json)" = $'token\t__agentctl_json_number__:123' ] \
    || fail "Expected number-marker-like string expiresAt to remain intact"
  [ "$(printf '%s' '{"claudeAiOauth":{"refreshToken":"token","expiresAt":-1}}' | auth_info_from_json)" = $'token\t-000000000001' ] \
    || fail "Expected negative integer expiresAt formatting to match Python"
  [ "$(printf '%s' '{"claudeAiOauth":{"refreshToken":"token","expiresAt":1.5}}' | auth_info_from_json)" = $'token\t' ] \
    || fail "Expected non-integer numeric expiresAt to remain ignored"
  [ "$(printf '%s' '{"refresh_token":"","tokens":{"refresh_token":"fallback-token"}}' | auth_info_from_json)" = $'fallback-token\t' ] \
    || fail "Expected falsey top-level tokens to use the nested fallback"
  [ "$(printf '%s' '{"refresh_token":0,"tokens":{"refresh_token":false},"claudeAiOauth":{"refreshToken":"claude-token","expiresAt":true}}' | auth_info_from_json)" = $'claude-token\t0000000000001' ] \
    || fail "Expected Python-compatible falsey token fallback and boolean expiresAt handling"
  [ "$(printf '%s' '{"refresh_token":"legacy","last_refresh":"2026-01-01"' | auth_info_from_json)" = $'legacy\t2026-01-01' ] \
    || fail "Expected malformed legacy payload fallback"
  [ "$(printf '%s' '' | auth_info_from_json)" = $'\t' ] || fail "Expected empty auth tuple"
}

test_run_auth_flow_uses_agent_sh_auth_contract() {
  begin_test "run_auth_flow uses agent.sh auth login and auth read"

  load_agentctl_functions

  local temp_dir
  local fake_keychain
  local stored_blob_file
  local exec_log_file
  local read_count_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-auth.XXXXXX")"
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
          shift 5
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

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-auth-unchanged.XXXXXX")"
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
source "$AGENTCTL_IMPL"
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
        shift 5
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

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-auth-unsupported.XXXXXX")"
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
source "$AGENTCTL_IMPL"
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
        shift 5
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

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-auth-claude.XXXXXX")"
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
source "$AGENTCTL_IMPL"
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
        shift 5
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

  load_agentctl_functions

  local temp_dir
  local fake_keychain
  local env_log_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-keychain-codex.XXXXXX")"
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

  load_agentctl_functions

  local temp_dir
  local fake_keychain
  local env_log_file

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-keychain-runtime.XXXXXX")"
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

  load_agentctl_functions

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

test_rescue_runs_command_in_temporary_backup_container() {
  begin_test "rescue runs a command in a temporary backup container"

  load_agentctl_functions

  local create_log=""
  local exec_log=""
  local stop_calls=0
  local rm_calls=0

  require_container() { return 0; }
  image_exists() { [ "$1" = "agent-project-backup-20260516113757" ]; }
  container_exists() { return 1; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      create)
        create_log="$(printf '%s\n' "$*")"
        ;;
      start)
        [ "$2" = "unit-rescue" ] || fail "Unexpected rescue start target: $*"
        ;;
      exec)
        exec_log="$(printf '%s\n' "$*")"
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        [ "$2" = "unit-rescue" ] || fail "Unexpected rescue stop target: $*"
        ;;
      rm)
        rm_calls=$((rm_calls + 1))
        [ "$2" = "unit-rescue" ] || fail "Unexpected rescue rm target: $*"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture rescue_cmd --image agent-project-backup-20260516113757 --name unit-rescue --cmd /bin/sh -lc 'cat /etc/agentctl/smoke-marker'
  assert_status 0
  printf '%s\n' "$create_log" | grep -Fq -- "--name unit-rescue" || fail "Expected named rescue container create, got: $create_log"
  printf '%s\n' "$create_log" | grep -Fq -- "agent-project-backup-20260516113757" || fail "Expected backup image in create call, got: $create_log"
  printf '%s\n' "$create_log" | grep -Fq -- "/bin/sh" || fail "Expected sleep wrapper shell in create call, got: $create_log"
  printf '%s\n' "$exec_log" | grep -Fq -- "exec" || fail "Expected rescue exec call, got: $exec_log"
  if printf '%s\n' "$exec_log" | grep -Fq -- "-it"; then
    fail "Did not expect non-interactive rescue command to force -it: $exec_log"
  fi
  printf '%s\n' "$exec_log" | grep -Fq -- "cat /etc/agentctl/smoke-marker" || fail "Expected command in rescue exec, got: $exec_log"
  [ "$stop_calls" -eq 1 ] || fail "Expected temporary rescue stop, got $stop_calls"
  [ "$rm_calls" -eq 1 ] || fail "Expected temporary rescue rm, got $rm_calls"
  assert_contains "Creating rescue container: unit-rescue"
  assert_contains "Removing rescue container: unit-rescue"
}

test_rescue_keep_leaves_container_running() {
  begin_test "rescue --keep leaves the rescue container running"

  load_agentctl_functions

  local stop_calls=0
  local rm_calls=0

  require_container() { return 0; }
  image_exists() { [ "$1" = "agent-project-backup-20260516113757" ]; }
  container_exists() { return 1; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      create|start|exec) ;;
      stop) stop_calls=$((stop_calls + 1)) ;;
      rm) rm_calls=$((rm_calls + 1)) ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture rescue_cmd agent-project-backup-20260516113757 --name unit-rescue --keep --cmd true
  assert_status 0
  [ "$stop_calls" -eq 0 ] || fail "Did not expect kept rescue container to stop, got $stop_calls"
  [ "$rm_calls" -eq 0 ] || fail "Did not expect kept rescue container to be removed, got $rm_calls"
  assert_contains "Rescue container kept: unit-rescue"
}

test_image_ref_for_runtime_falls_back_to_legacy_when_present() {
  begin_test "image_ref_for_runtime prefers canonical names but falls back to legacy refs"

  load_agentctl_functions

  image_exists() {
    [ "$1" = "codex" ]
  }

  [ "$(image_ref_for_runtime codex)" = "codex" ] || fail "Expected fallback to legacy codex image"
}

test_ls_raw_filters_non_codex_containers() {
  begin_test "ls --raw hides non-Codex runtime containers"

  load_agentctl_functions

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

  run_capture ls_cmd --raw
  assert_status 0
  assert_contains "ID                               IMAGE"
  assert_contains "codex-python                     codex-python:latest"
  assert_contains "codex-local-codex-container      codex:latest"
  assert_contains "codex-custom                     my-team/codex-custom:latest"
  assert_not_contains "buildkit"
  assert_not_contains "converter"
}

test_ls_reports_matching_snapshot_ref_by_default() {
  begin_test "ls reports matching timestamp snapshot by image digest by default"

  load_agentctl_functions

  require_container() { return 0; }
  CONTAINER_CMD=container
  container() {
    case "$*" in
      "ls -a --quiet")
        printf '%s\n' agent-local-agent-container
        ;;
      "image ls --format json")
        cat <<'EOF'
[
  {"configuration":{"descriptor":{"digest":"sha256:4924ec2b2c5a647919c4d8b8c0846b169a5447b3d57722ec9b0094ed79fa7640"},"name":"agent-python:latest"},"variants":[]},
  {"configuration":{"descriptor":{"digest":"sha256:4924ec2b2c5a647919c4d8b8c0846b169a5447b3d57722ec9b0094ed79fa7640"},"name":"docker.io/library/agent-python:20260607-150156"},"variants":[]},
  {"configuration":{"descriptor":{"digest":"sha256:other"},"name":"agent-python:20260607-144649"},"variants":[]}
]
EOF
        ;;
      "inspect agent-local-agent-container")
        cat <<'EOF'
[{"configuration":{"mounts":[{"source":"/Users/philipp/Developer/local-agent-container","options":[],"destination":"/workdir","type":{"virtiofs":{}}}],"resources":{"memoryInBytes":4294967296,"cpus":4},"image":{"descriptor":{"annotations":{"org.opencontainers.image.created":"2026-06-07T15:02:18Z"},"digest":"sha256:4924ec2b2c5a647919c4d8b8c0846b169a5447b3d57722ec9b0094ed79fa7640"},"reference":"agent-python:latest"}},"status":{"state":"running","networks":[]}}]
EOF
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture ls_cmd
  assert_status 0
  assert_contains "NAME"
  assert_contains "SNAPSHOT"
  assert_contains "agent-local-agent-container"
  assert_contains "agent-python:20260607-150156"
  assert_contains "sha256:4924ec2b2c5a"
  assert_contains "/Users/philipp/Developer/local-agent-container"
  assert_contains "4G"
  assert_not_contains "converter"
}

test_ls_reports_unknown_snapshot_when_timestamp_missing() {
  begin_test "ls reports unknown snapshot when only latest matches digest"

  load_agentctl_functions

  require_container() { return 0; }
  CONTAINER_CMD=container
  container() {
    case "$*" in
      "ls -a --quiet")
        printf '%s\n' agent-local-agent-container
        ;;
      "image ls --format json")
        cat <<'EOF'
[
  {"descriptor":{"digest":"sha256:4924ec2b2c5a647919c4d8b8c0846b169a5447b3d57722ec9b0094ed79fa7640"},"reference":"agent-python:latest"}
]
EOF
        ;;
      "inspect agent-local-agent-container")
        cat <<'EOF'
[{"configuration":{"mounts":[],"resources":{},"image":{"descriptor":{"annotations":{},"digest":"sha256:4924ec2b2c5a647919c4d8b8c0846b169a5447b3d57722ec9b0094ed79fa7640"},"reference":"agent-python:latest"}},"status":"running"}]
EOF
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture ls_cmd
  assert_status 0
  assert_contains "agent-local-agent-container"
  assert_matches '^agent-local-agent-container[[:space:]]+running[[:space:]]+agent-python:latest[[:space:]]+unknown[[:space:]]+sha256:4924ec2b2c5a'
  assert_contains "unlimited"
}

test_ls_keeps_row_when_inspect_fails() {
  begin_test "ls keeps a managed container row when inspect output is unavailable"

  load_agentctl_functions

  require_container() { return 0; }
  CONTAINER_CMD=container
  container() {
    case "$*" in
      "ls -a --quiet")
        printf '%s\n' agent-local-agent-container
        ;;
      "image ls --format json")
        printf '[]\n'
        ;;
      "inspect agent-local-agent-container")
        printf 'not-json\n'
        return 1
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture ls_cmd
  assert_status 0
  assert_matches '^agent-local-agent-container[[:space:]]+unknown[[:space:]]+unknown[[:space:]]+unknown[[:space:]]+unknown[[:space:]]+unknown[[:space:]]+unknown[[:space:]]+unlimited[[:space:]]+unlimited[[:space:]]+unknown$'
}

test_ls_handles_malformed_image_list_json() {
  begin_test "ls handles malformed image-list JSON"

  load_agentctl_functions

  require_container() { return 0; }
  CONTAINER_CMD=container
  container() {
    case "$*" in
      "ls -a --quiet") printf '%s\n' agent-local-agent-container ;;
      "image ls --format json") printf '%s\n' not-json ;;
      "inspect agent-local-agent-container")
        printf '%s\n' '[{"configuration":{"mounts":[],"resources":{},"image":{"descriptor":{"digest":"sha256:abc"},"reference":"agent-plain:latest"}},"status":"running"}]'
        ;;
      *) fail "Unexpected container invocation: $*" ;;
    esac
  }

  run_capture ls_cmd
  assert_status 0
  assert_matches '^agent-local-agent-container[[:space:]]+running[[:space:]]+agent-plain:latest[[:space:]]+unknown[[:space:]]+sha256:abc'
  unset -f container
}

test_upgrade_backup_support_check() {
  begin_test "upgrade backup support check requires export support"

  load_agentctl_functions

  local fake_dir
  local fake_container
  local old_path

  fake_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-fake-container.XXXXXX")"
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

  fake_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-fake-container.XXXXXX")"
  register_dir_cleanup "$fake_dir"
  fake_container="$fake_dir/container"
  old_path="$PATH"

  cat >"$fake_container" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "$*" = "ls -a --quiet" ]; then
  printf '%s\n' unit-test-container
  exit 0
fi

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

  harness="$(mktemp "${TMPDIR:-/tmp}/agentctl-unit.XXXXXX")"
  register_dir_cleanup "$harness"
  sed -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=\"$TEST_ROOT\"#" \
    -e '/^cmd="${1:-}"/,$d' \
    "$AGENTCTL_IMPL" >"$harness"

  script="$(mktemp "${TMPDIR:-/tmp}/agentctl-unit-script.XXXXXX")"
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

  load_agentctl_functions

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
  ensure_started_container_is_running() { return 0; }
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
        :
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'codex\t%s\trw\t2\t4G\n' "$TEST_ROOT"
  }

  run_capture upgrade_cmd --name unit-test-container --cpu 6 --mem 12G
  assert_status 0
  assert_contains "Upgrade complete: unit-test-container (backup image: unit-test-container-backup-20260406120000)"
  assert_contains $'Starting container for state backup: unit-test-container\n\nBacking up user state from unit-test-container'
  assert_contains $'Stopping container: unit-test-container\n\nExporting container state to image: unit-test-container-backup-20260406120000'
  assert_contains $'Exporting container state to image: unit-test-container-backup-20260406120000\n\nRemoving container: unit-test-container'
  printf '%s\n' "$create_args" | grep -F -- "-c 6" >/dev/null || fail "Expected create args to include overridden cpu, got: $create_args"
  printf '%s\n' "$create_args" | grep -F -- "-m 12G" >/dev/null || fail "Expected create args to include overridden mem, got: $create_args"
  printf '%s\n' "$create_args" | grep -F -- "--name unit-test-container" >/dev/null || fail "Expected create args to include container name, got: $create_args"
  [ "$start_calls" -eq 2 ] || fail "Expected 2 start calls, got: $start_calls"
  [ "$stop_calls" -eq 2 ] || fail "Expected 2 stop calls, got: $stop_calls"
  [ "$rm_calls" -eq 1 ] || fail "Expected 1 rm call, got: $rm_calls"
}

test_upgrade_can_rename_container_during_recreation() {
  begin_test "upgrade can recreate the container under a new name"

  load_agentctl_functions

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
  ensure_started_container_is_running() { return 0; }
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

test_upgrade_export_failure_restarts_running_source() {
  begin_test "upgrade export failure restarts running source"

  load_agentctl_functions

  local start_log=""
  local stop_log=""
  local rm_log=""
  local create_calls=0

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  require_container_backup_support() { return 0; }
  warn_upgrade_package_loss() { :; }
  upgrade_added_runtimes_json() { printf '[]\n'; }
  upgrade_added_features_json() { printf '[]\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { [ "$1" = "unit-test-container" ]; }
  image_exists() { return 0; }
  codex_agents_state() { printf 'missing\n'; }
  backup_codex_config() { :; }
  collect_upgrade_container_preflight() {
    UPGRADE_PREFLIGHT_CONTAINER_MANIFEST='{"package_manager":"apk","packages":[]}'
    UPGRADE_PREFLIGHT_BASELINE_MANIFEST=''
    UPGRADE_PREFLIGHT_SOURCE_SUPPORTS_STATE_CONTRACT=1
  }
  image_system_manifest_json() { return 1; }
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
        echo 'unknown: "could not read block 3217034"' >&2
        return 1
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'agent-plain\t%s\trw\t2\t4G\n' "$TEST_ROOT"
  }
  upgrade_cmd_wrapper() {
    ( upgrade_cmd "$@" )
  }

  run_capture upgrade_cmd_wrapper --name unit-test-container
  assert_status 1
  assert_contains "Backing up user state from unit-test-container"
  assert_contains "Stopping container: unit-test-container"
  assert_contains "Exporting container state to image: unit-test-container-backup-20260406120000"
  assert_contains $'Stopping container: unit-test-container\n\nExporting container state to image: unit-test-container-backup-20260406120000'
  assert_contains "Restarting original container after failed export: unit-test-container"
  assert_contains "Failed to export container filesystem for backup image. The original container was not removed."
  assert_not_contains "Removing container: unit-test-container"
  assert_not_contains "Recreating container: unit-test-container"
}

test_upgrade_copy_keeps_running_source_container() {
  begin_test "upgrade copy keeps the source container and creates a new target"

  load_agentctl_functions

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

  harness="$(mktemp "${TMPDIR:-/tmp}/agentctl-unit.XXXXXX")"
  register_dir_cleanup "$harness"
  sed -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=\"$TEST_ROOT\"#" \
    -e '/^cmd="${1:-}"/,$d' \
    "$AGENTCTL_IMPL" >"$harness"

  script="$(mktemp "${TMPDIR:-/tmp}/agentctl-unit-script.XXXXXX")"
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

  load_agentctl_functions

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

  load_agentctl_functions

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

  load_agentctl_functions

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
  ensure_started_container_is_running() { return 0; }
  image_exists() {
    case "$1" in
      agent-plain|agent-swift) return 0 ;;
      *) return 1 ;;
    esac
  }
  codex_agents_state() { printf 'missing\n'; }
  backup_codex_config() { :; }
  restore_codex_config() { :; }
  persist_container_system_manifest_baseline() { :; }
  persist_container_system_manifest_baseline_from_image() { :; }
  collect_upgrade_container_preflight() {
    UPGRADE_PREFLIGHT_CONTAINER_MANIFEST='{"package_manager":"dpkg","packages":["bash","git","curl","tree"]}'
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
            printf '{"package_manager":"dpkg","packages":["bash","git","curl","tree"]}\n'
            ;;
          source-manifest)
            printf '{"package_manager":"dpkg","packages":["bash","git"]}\n'
            ;;
          target-manifest)
            printf '{"package_manager":"dpkg","packages":["bash","git","curl","python3"]}\n'
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

  run_capture upgrade_cmd --name unit-test-container --image agent-swift --no-backup
  assert_status 0
  assert_contains "Upgrade will remove 1 extra dpkg package(s) not present in agent-swift:"
  assert_contains "  - tree"
  assert_contains "To reinstall after upgrade:"
  assert_contains "su-exec --name unit-test-container apt-get update"
  assert_contains "su-exec --name unit-test-container apt-get install -y tree"
  assert_not_contains "  - curl"
  assert_not_contains "  - bash"
  assert_contains "Upgrade complete: unit-test-container (backup skipped)"
  assert_contains "Reminder: reinstall top-level packages removed by the upgrade if you still need them:"
  [ "$(printf '%s\n' "$RUN_OUTPUT" | grep -Fc "su-exec --name unit-test-container apt-get update")" -eq 2 ] \
    || fail "Expected apt-get update before and after upgrade"
  [ "$(printf '%s\n' "$RUN_OUTPUT" | grep -Fc "su-exec --name unit-test-container apt-get install -y tree")" -eq 2 ] \
    || fail "Expected apt-get install before and after upgrade"
  printf '%s\n' "$create_log" | grep -F -- "--name unit-test-container" >/dev/null || fail "Expected recreate call for unit-test-container, got: $create_log"
  [ "$start_calls" -eq 2 ] || fail "Expected 2 persisted start calls, got: $start_calls"
  [ "$stop_calls" -eq 2 ] || fail "Expected 2 persisted stop calls, got: $stop_calls"
  [ "$rm_calls" -eq 1 ] || fail "Expected 1 persisted rm call, got: $rm_calls"
}

test_upgrade_reinstall_command_prefers_requested_apk_packages() {
  begin_test "upgrade reinstall command prefers requested apk packages"

  load_agentctl_functions

  CLI_NAME=agentctl

  run_capture warn_upgrade_package_loss \
    unit-test-container \
    agent-plain \
    agent-python \
    '{"package_manager":"apk","packages":["bash","gcc","g++","gmp","musl-dev"],"requested_packages":["bash","g++"]}' \
    '{"package_manager":"apk","packages":["bash"],"requested_packages":["bash"]}' \
    '{"package_manager":"apk","packages":["bash"],"requested_packages":["bash"]}' \
    unit-test-container

  assert_status 0
  assert_contains "Upgrade will remove 4 extra apk package(s) not present in agent-python:"
  assert_contains "  - g++"
  assert_contains "  - gcc"
  assert_contains "  - gmp"
  assert_contains "  - musl-dev"
  assert_contains "To reinstall top-level packages after upgrade:"
  assert_contains "agentctl su-exec --name unit-test-container apk add --no-cache g++"
  assert_not_contains "apk add --no-cache gcc"
  assert_not_contains "apk add --no-cache gmp"
  assert_not_contains "apk add --no-cache musl-dev"
}

test_upgrade_reinstall_command_restores_missing_apk_repository_tags() {
  begin_test "upgrade reinstall command restores missing apk repository tags"

  load_agentctl_functions

  CLI_NAME=agentctl

  warn_with_final_package_reminder() {
    local upgrade_package_reinstall_commands=""

    warn_upgrade_package_loss "$@"
    printf 'Final reminder:\n%s\n' "$upgrade_package_reinstall_commands" >&2
  }

  run_capture warn_with_final_package_reminder \
    unit-test-container \
    agent-plain \
    agent-python \
    '{"package_manager":"apk","packages":["bash","go","golangci-lint","zstd"],"requested_packages":["bash","go@customrepo","golangci-lint@edgecommunity","zstd"],"apk_repositories":["https://dl-cdn.alpinelinux.org/alpine/v3.22/main","@customrepo https://packages.example.test/alpine/community"]}' \
    '{"package_manager":"apk","packages":["bash"],"requested_packages":["bash"],"apk_repositories":["https://dl-cdn.alpinelinux.org/alpine/v3.22/main"]}' \
    '{"package_manager":"apk","packages":["bash"],"requested_packages":["bash"],"apk_repositories":["https://dl-cdn.alpinelinux.org/alpine/v3.22/main"]}' \
    unit-test-container

  assert_status 0
  assert_contains "Upgrade will remove 3 extra apk package(s) not present in agent-python:"
  assert_contains "To reinstall top-level packages after upgrade:"
  assert_contains "Restore APK repository tag(s) before reinstalling tagged packages:"
  assert_contains "@customrepo https://packages.example.test/alpine/community"
  assert_contains "agentctl su-exec --name unit-test-container sh -lc 'grep -Fxq '\\''@edgecommunity https://dl-cdn.alpinelinux.org/alpine/edge/community'\\'' /etc/apk/repositories || printf \"%s\\\\n\" '\\''@edgecommunity https://dl-cdn.alpinelinux.org/alpine/edge/community'\\'' >> /etc/apk/repositories'"
  assert_contains "agentctl su-exec --name unit-test-container apk update"
  assert_contains "agentctl su-exec --name unit-test-container apk add --no-cache go@customrepo golangci-lint@edgecommunity zstd"
  assert_contains "Final reminder:"
  [ "$(printf '%s\n' "$RUN_OUTPUT" | grep -Fc "Restore APK repository tag(s) before reinstalling tagged packages:")" -eq 2 ] \
    || fail "Expected APK repository restore heading before and after upgrade"
  [ "$(printf '%s\n' "$RUN_OUTPUT" | grep -Fc "agentctl su-exec --name unit-test-container sh -lc")" -eq 4 ] \
    || fail "Expected both APK repository restore commands before and after upgrade"
  [ "$(printf '%s\n' "$RUN_OUTPUT" | grep -Fc "agentctl su-exec --name unit-test-container apk update")" -eq 2 ] \
    || fail "Expected apk update before and after upgrade"
  [ "$(printf '%s\n' "$RUN_OUTPUT" | grep -Fc "agentctl su-exec --name unit-test-container apk add --no-cache go@customrepo golangci-lint@edgecommunity zstd")" -eq 2 ] \
    || fail "Expected APK reinstall command before and after upgrade"
}

test_upgrade_reinstall_command_suggests_default_apk_edge_tags() {
  begin_test "upgrade reinstall command suggests default apk edge tags"

  load_agentctl_functions

  CLI_NAME=agentctl

  run_capture warn_upgrade_package_loss \
    unit-test-container \
    agent-plain \
    agent-python \
    '{"package_manager":"apk","packages":["bash","go","golangci-lint","zstd"],"requested_packages":["bash","go@edgecommunity","golangci-lint@edgecommunity","zstd"],"apk_repositories":[]}' \
    '{"package_manager":"apk","packages":["bash"],"requested_packages":["bash"],"apk_repositories":[]}' \
    '{"package_manager":"apk","packages":["bash"],"requested_packages":["bash"],"apk_repositories":[]}' \
    unit-test-container

  assert_status 0
  assert_contains "Restore APK repository tag(s) before reinstalling tagged packages:"
  assert_contains "agentctl su-exec --name unit-test-container sh -lc 'grep -Fxq '\\''@edgecommunity https://dl-cdn.alpinelinux.org/alpine/edge/community'\\'' /etc/apk/repositories || printf \"%s\\\\n\" '\\''@edgecommunity https://dl-cdn.alpinelinux.org/alpine/edge/community'\\'' >> /etc/apk/repositories'"
  assert_contains "agentctl su-exec --name unit-test-container apk update"
  assert_contains "agentctl su-exec --name unit-test-container apk add --no-cache go@edgecommunity golangci-lint@edgecommunity zstd"
  assert_not_contains "original repository URL was not available"
}

test_upgrade_warns_about_image_packages_removed_from_target() {
  begin_test "upgrade warns about image-provided packages removed from the target image"

  load_agentctl_functions

  CLI_NAME=agentctl

  run_capture warn_upgrade_package_loss \
    unit-test-container \
    agent-python \
    agent-python \
    '{"package_manager":"apk","packages":["bash","git","legacy-lib","legacy-tool"],"requested_packages":["bash","git","legacy-tool@edgecommunity"],"apk_repositories":["@edgecommunity https://dl-cdn.alpinelinux.org/alpine/edge/community"]}' \
    '{"package_manager":"apk","packages":["bash","git","legacy-lib","legacy-tool"],"requested_packages":["bash","git","legacy-tool@edgecommunity"],"apk_repositories":["@edgecommunity https://dl-cdn.alpinelinux.org/alpine/edge/community"]}' \
    '{"package_manager":"apk","packages":["bash","git"],"requested_packages":["bash","git"],"apk_repositories":[]}' \
    unit-test-container

  assert_status 0
  assert_contains "Upgrade will also remove 2 image-provided apk package(s) from agent-python that are no longer present in agent-python:"
  assert_contains "  - legacy-lib"
  assert_contains "  - legacy-tool"
  assert_contains "If you still need them, reinstall top-level packages after upgrade:"
  assert_contains "Restore APK repository tag(s) before reinstalling tagged packages:"
  assert_contains "@edgecommunity https://dl-cdn.alpinelinux.org/alpine/edge/community"
  assert_contains "agentctl su-exec --name unit-test-container apk update"
  assert_contains "agentctl su-exec --name unit-test-container apk add --no-cache legacy-tool@edgecommunity"
  assert_not_contains "Upgrade will remove 2 extra apk package(s)"
  assert_not_contains "apk add --no-cache legacy-lib"
}

test_upgrade_reinstall_command_prefers_requested_dpkg_packages() {
  begin_test "upgrade reinstall command prefers requested dpkg packages"

  load_agentctl_functions

  CLI_NAME=agentctl

  run_capture warn_upgrade_package_loss \
    unit-test-container \
    agent-swift \
    agent-swift \
    '{"package_manager":"dpkg","packages":["bash","libc6","tree"],"requested_packages":["bash","tree"]}' \
    '{"package_manager":"dpkg","packages":["bash","libc6"],"requested_packages":["bash"]}' \
    '{"package_manager":"dpkg","packages":["bash","libc6"],"requested_packages":["bash"]}' \
    unit-test-container

  assert_status 0
  assert_contains "Upgrade will remove 1 extra dpkg package(s) not present in agent-swift:"
  assert_contains "  - tree"
  assert_contains "To reinstall top-level packages after upgrade:"
  assert_contains "agentctl su-exec --name unit-test-container apt-get update"
  assert_contains "agentctl su-exec --name unit-test-container apt-get install -y tree"
}

test_upgrade_package_warning_excludes_reinstalled_feature_packages() {
  begin_test "upgrade package warning excludes packages owned by reinstalled features"

  load_agentctl_functions

  local feature_registry
  feature_registry="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-feature-registry.XXXXXX")"
  register_dir_cleanup "$feature_registry"
  printf '%s\n' '{
    "id":"office",
    "supported_image_families":["agent-python"],
    "system_packages":{"apk":["build-base","pandoc-cli"]}
  }' >"$feature_registry/office.json"
  AGENTCTL_HOST_FEATURE_REGISTRY_DIR="$feature_registry"
  CLI_NAME=agentctl

  run_capture warn_upgrade_package_loss \
    unit-test-container \
    agent-python \
    agent-python \
    '{"package_manager":"apk","packages":["bash","build-base","pandoc-cli","ripgrep"],"requested_packages":["bash","build-base","pandoc-cli","ripgrep"]}' \
    '{"package_manager":"apk","packages":["bash"],"requested_packages":["bash"]}' \
    '{"package_manager":"apk","packages":["bash"],"requested_packages":["bash"]}' \
    unit-test-container \
    '["office"]'

  assert_status 0
  assert_contains "agentctl su-exec --name unit-test-container apk add --no-cache ripgrep"
  assert_not_contains "apk add --no-cache build-base"
  assert_not_contains "apk add --no-cache pandoc-cli"

  run_capture warn_upgrade_package_loss \
    unit-test-container \
    agent-python \
    agent-python \
    '{"package_manager":"apk","packages":["bash","build-base","pandoc-cli"],"requested_packages":["bash","build-base","pandoc-cli"]}' \
    '{"package_manager":"apk","packages":["bash"],"requested_packages":["bash"]}' \
    '{"package_manager":"apk","packages":["bash"],"requested_packages":["bash"]}' \
    unit-test-container \
    '["office"]'

  assert_status 0
  [ -z "$RUN_OUTPUT" ] || fail "Expected feature-owned package warning to be suppressed, got: $RUN_OUTPUT"
}

test_upgrade_reinstalls_added_runtimes_and_features_in_target() {
  begin_test "upgrade reinstalls added runtimes and features in the target container"

  load_agentctl_functions

  local create_log=""
  local start_log=""
  local stop_log=""
  local rm_log=""
  local root_call_log=""
  local user_call_log=""

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  warn_upgrade_package_loss() { :; }
  upgrade_added_runtimes_json() { printf '["claude"]\n'; }
  upgrade_added_features_json() { printf '["office"]\n'; }
  container_supports_state_contract() { return 0; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  ensure_started_container_is_running() { return 0; }
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
    if [ "$2" = "runtime" ] && [ "$3" = "install" ] && [ "$4" = "claude" ]; then
      user_call_log="${user_call_log}$2 $3 $4"$'\n'
      return 0
    fi
    fail "Unexpected run_agent_sh_in_container call: $*"
  }
  run_agent_sh_in_container_env() {
    if [ "$2" = "AGENTCTL_SKIP_PREFERRED_SET=1" ] && [ "$3" = "--" ] && [ "$4" = "runtime" ] && [ "$5" = "install" ] && [ "$6" = "claude" ]; then
      user_call_log="${user_call_log}$4 $5 $6 skip-preferred"$'\n'
      return 0
    fi
    fail "Unexpected run_agent_sh_in_container_env call: $*"
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
  printf '%s\n' "$user_call_log" | grep -Fx -- "runtime install claude" >/dev/null || fail "Expected runtime reinstall call, got: $user_call_log"
  printf '%s\n' "$root_call_log" | grep -Fx -- "feature install office" >/dev/null || fail "Expected feature reinstall call, got: $root_call_log"
  assert_contains "Upgrade complete: unit-test-container (backup skipped)"
  printf '%s\n' "$create_log" | grep -F -- "--name unit-test-container" >/dev/null || fail "Expected recreate call for unit-test-container, got: $create_log"
  printf '%s\n' "$rm_log" | grep -Fx -- "unit-test-container" >/dev/null || fail "Expected removal of source container, got: $rm_log"
  printf '%s\n' "$start_log" | grep -Fx -- "unit-test-container" >/dev/null || fail "Expected source container start for backup, got: $start_log"
  printf '%s\n' "$start_log" | grep -Fx -- "unit-test-container" >/dev/null || fail "Expected target container start after recreation, got: $start_log"
  printf '%s\n' "$stop_log" | grep -Fx -- "unit-test-container" >/dev/null || fail "Expected source container stop after backup, got: $stop_log"
}

test_upgrade_reinstalls_missing_default_runtime_after_restore() {
  begin_test "upgrade reinstalls missing default runtime after restore"

  load_agentctl_functions

  local create_log=""
  local install_log=""

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  warn_upgrade_package_loss() { :; }
  upgrade_added_runtimes_json() { printf '[]\n'; }
  upgrade_added_features_json() { printf '[]\n'; }
  container_preferred_runtime() { printf '\n'; }
  target_default_runtime_for_upgrade() { printf 'codex\n'; }
  container_supports_state_contract() { return 0; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  ensure_started_container_is_running() { return 0; }
  image_exists() { return 0; }
  codex_agents_state() { printf 'missing\n'; }
  backup_codex_config() { :; }
  restore_codex_config() { :; }
  verify_restored_codex_state() { return 0; }
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
    if [ "$2" = "runtime" ] && [ "$3" = "info" ] && [ "$4" = "codex" ]; then
      printf '{"runtime":"codex","installed":false,"capabilities":{"install":true}}\n'
      return 0
    fi
    fail "Unexpected run_agent_sh_in_container call: $*"
  }
  run_agent_sh_in_container_env() {
    install_log="${install_log}$*"$'\n'
    return 0
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
      start|stop|rm)
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
    printf 'agent-python\t%s\trw\t2\t4G\n' "$TEST_ROOT"
  }

  run_capture upgrade_cmd --name unit-test-container --image agent-python --no-backup
  assert_status 0
  assert_contains "Reinstalling target default runtime in unit-test-container: codex"
  printf '%s\n' "$install_log" | grep -Fq -- "unit-test-container AGENTCTL_SKIP_PREFERRED_SET=1 -- runtime install codex" || fail "Expected default runtime reinstall without preferred-runtime side effect, got: $install_log"
  printf '%s\n' "$create_log" | grep -F -- "--name unit-test-container" >/dev/null || fail "Expected recreate call for unit-test-container, got: $create_log"
}

test_upgrade_warns_and_clears_missing_preferred_runtime() {
  begin_test "upgrade warns and clears a preferred runtime that is unavailable in the target"

  load_agentctl_functions

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
  ensure_started_container_is_running() { return 0; }
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
    if [ "$2" = "runtime" ] && [ "$3" = "info" ] && [ "$4" = "codex" ]; then
      printf '{"runtime":"codex","installed":true,"capabilities":{"install":true}}\n'
      return 0
    fi
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

  load_agentctl_functions

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
  ensure_started_container_is_running() { return 0; }
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
  assert_contains "su-exec --name unit-test-container apk add --no-cache ripgrep"
  assert_not_contains "Current image agent-plain is not available locally"
  assert_contains "Upgrade complete: unit-test-container (backup skipped)"
  printf '%s\n' "$create_log" | grep -F -- "--name unit-test-container" >/dev/null || fail "Expected recreate call for unit-test-container, got: $create_log"
  [ "$start_calls" -eq 2 ] || fail "Expected 2 start calls, got: $start_calls"
  [ "$stop_calls" -eq 2 ] || fail "Expected 2 stop calls, got: $stop_calls"
  [ "$rm_calls" -eq 1 ] || fail "Expected 1 rm call, got: $rm_calls"
}

test_upgrade_accepts_workdir_override_when_original_mount_is_missing() {
  begin_test "upgrade can replace a missing workdir mount source"

  load_agentctl_functions

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
    ln -sf /etc/agentctl/image.md "$extract_root/home/coder/.codex/AGENTS.md"
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

  load_agentctl_functions

  local create_args=""
  local export_calls=0
  local start_calls=0
  local stop_calls=0
  local rm_calls=0
  local export_root
  export_root="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-export-root.XXXXXX")"
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

  load_agentctl_functions

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
        if [ "$*" = "true" ]; then
          return 0
        fi
        if [ "${1:-}" = "setpriv" ]; then
          shift 5
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

test_image_system_manifest_removes_temp_container_after_success() {
  begin_test "image_system_manifest_json removes temporary container after success"

  load_agentctl_functions

  local create_calls=0
  local start_calls=0
  local stop_calls=0
  local rm_calls=0

  temporary_system_manifest_container_name() { printf 'unit-manifest-temp\n'; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      create)
        create_calls=$((create_calls + 1))
        [ "$4" = "unit-manifest-temp" ] || fail "Expected temp container name, got: $*"
        ;;
      start)
        start_calls=$((start_calls + 1))
        [ "$2" = "unit-manifest-temp" ] || fail "Expected temp start, got: $*"
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        [ "$2" = "unit-manifest-temp" ] || fail "Expected temp stop, got: $*"
        ;;
      rm)
        rm_calls=$((rm_calls + 1))
        [ "$2" = "unit-manifest-temp" ] || fail "Expected temp rm, got: $*"
        ;;
      exec)
        shift
        [ "$1" = "unit-manifest-temp" ] || fail "Unexpected exec target: $*"
        shift
        if [ "${1:-}" = "setpriv" ]; then
          shift 5
        fi
        [ "$*" = "bash /usr/local/bin/agent.sh system manifest" ] || fail "Unexpected exec command: $*"
        printf '{"package_manager":"none"}\n'
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture image_system_manifest_json agent-plain target
  assert_status 0
  assert_contains '"package_manager":"none"'
  [ "$create_calls" -eq 1 ] || fail "Expected 1 create call, got: $create_calls"
  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
  [ "$rm_calls" -eq 1 ] || fail "Expected 1 rm call, got: $rm_calls"
}

test_image_system_manifest_removes_temp_container_after_exec_failure() {
  begin_test "image_system_manifest_json removes temporary container after exec failure"

  load_agentctl_functions

  local stop_calls=0
  local rm_calls=0

  temporary_system_manifest_container_name() { printf 'unit-manifest-temp\n'; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      create)
        [ "$4" = "unit-manifest-temp" ] || fail "Expected temp container name, got: $*"
        ;;
      start)
        [ "$2" = "unit-manifest-temp" ] || fail "Expected temp start, got: $*"
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        [ "$2" = "unit-manifest-temp" ] || fail "Expected temp stop, got: $*"
        ;;
      rm)
        rm_calls=$((rm_calls + 1))
        [ "$2" = "unit-manifest-temp" ] || fail "Expected temp rm, got: $*"
        ;;
      exec)
        return 1
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture image_system_manifest_json agent-plain target
  assert_status 1
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
  [ "$rm_calls" -eq 1 ] || fail "Expected 1 rm call, got: $rm_calls"
}

test_collect_upgrade_container_preflight_starts_stopped_container_once() {
  begin_test "collect_upgrade_container_preflight reuses one start for manifest, baseline, and capability checks"

  load_agentctl_functions

  local start_calls=0
  local stop_calls=0
  local running=0
  local exec_log
  exec_log="$(mktemp "${TMPDIR:-/tmp}/agentctl-preflight-exec.XXXXXX")"
  register_dir_cleanup "$exec_log"

  CONTAINER_CMD=container
  container() {
    case "$1" in
      start)
        start_calls=$((start_calls + 1))
        running=1
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        running=0
        ;;
      exec)
        printf '%s\n' "$*" >>"$exec_log"
        shift
        if [ "${1:-}" = "unit-test-container" ]; then
          shift
        fi
        if [ "$*" = "true" ]; then
          return 0
        fi
        if [ "${1:-}" = "setpriv" ]; then
          shift 5
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
  container_running() { [ "$running" -eq 1 ]; }

  collect_upgrade_container_preflight unit-test-container

  [ "$start_calls" -eq 1 ] || fail "Expected 1 start call, got: $start_calls"
  [ "$stop_calls" -eq 1 ] || fail "Expected 1 stop call, got: $stop_calls"
  [ "$(wc -l <"$exec_log" | tr -d '[:space:]')" = "5" ] || fail "Expected 5 exec calls, got: $(cat "$exec_log")"
  [ "$UPGRADE_PREFLIGHT_SOURCE_SUPPORTS_STATE_CONTRACT" -eq 1 ] || fail "Expected state contract support to be detected"
  printf '%s' "$UPGRADE_PREFLIGHT_CONTAINER_MANIFEST" | jq -e '.packages == ["bash"]' >/dev/null 2>&1 || fail "Expected cached container manifest, got: $UPGRADE_PREFLIGHT_CONTAINER_MANIFEST"
  printf '%s' "$UPGRADE_PREFLIGHT_BASELINE_MANIFEST" | jq -e '.schema_version == 2' >/dev/null 2>&1 || fail "Expected cached baseline manifest, got: $UPGRADE_PREFLIGHT_BASELINE_MANIFEST"
}

test_refresh_updates_managed_files_without_recreate() {
  begin_test "refresh updates managed files and preserves stopped state"

  load_agentctl_functions

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
  printf '%s\n' "$exec_log" | grep -Fq "/etc/agentctl/codex/config.toml" || fail "Expected refresh to update /etc/agentctl/codex/config.toml"
  printf '%s\n' "$exec_log" | grep -Fq "/etc/agentctl/codex/gpt-oss.config.toml" || fail "Expected refresh to update /etc/agentctl/codex/gpt-oss.config.toml"
  printf '%s\n' "$exec_log" | grep -Fq "/etc/agentctl/tooling-version" || fail "Expected refresh to update the agentctl tooling version marker"
  printf '%s\n' "$exec_log" | grep -Fq "/etc/codexctl" || fail "Expected refresh to remove legacy Codex defaults"
  printf '%s\n' "$exec_log" | grep -Fq "/usr/local/bin/agent.sh" || fail "Expected refresh to update agent.sh"
  printf '%s\n' "$exec_log" | grep -Fq "/usr/local/lib/agentctl/runtimes" || fail "Expected refresh to update runtime adapters"
  printf '%s\n' "$exec_log" | grep -Fq "/etc/agentctl/runtimes.d" || fail "Expected refresh to update runtime registry"
  printf '%s\n' "$exec_log" | grep -Fq "/usr/local/lib/agentctl/features" || fail "Expected refresh to update feature adapters"
  printf '%s\n' "$exec_log" | grep -Fq "/etc/agentctl/features.d" || fail "Expected refresh to update feature registry"
}

test_doctor_reports_state_permission_problems() {
  begin_test "doctor reports user-state permission problems"

  load_agentctl_functions

  local running=0

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { [ "$running" -eq 1 ]; }
  doctor_state_permissions() {
    [ "$1" = "unit-test-container" ] || fail "Unexpected doctor target: $1"
    [ "$2" = "0" ] || fail "Did not expect fix mode: $2"
    printf '%s\n' '.codex/config.toml' '.codex/history.jsonl'
    return 1
  }
  doctor_runtime_health() { return 0; }
  doctor_runtime_state_summary() { return 0; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      start) running=1 ;;
      stop) running=0 ;;
      exec) [ "$2" = "unit-test-container" ] && [ "$3" = "true" ] ;;
      *) fail "Unexpected container invocation: $*" ;;
    esac
  }

  run_capture doctor_cmd --name unit-test-container
  assert_status 1
  assert_contains "Starting container for doctor: unit-test-container"
  assert_contains "Doctor found user-state ownership/readability problems in unit-test-container:"
  assert_contains "  - .codex/config.toml"
  assert_contains "doctor --name unit-test-container --fix"
  assert_contains "Stopping container: unit-test-container"
}

test_doctor_reports_container_startup_problem() {
  begin_test "doctor reports containers that do not stay running"

  load_agentctl_functions

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      start) : ;;
      logs) printf '%s\n' 'setpriv: apply bounding set: Operation not permitted' ;;
      *) fail "Unexpected container invocation: $*" ;;
    esac
  }

  run_capture doctor_cmd --name unit-test-container
  assert_status 1
  assert_contains "Warning: Container unit-test-container did not stay running after start during doctor."
  assert_contains "setpriv: apply bounding set: Operation not permitted"
  assert_contains "Doctor found a container startup problem in unit-test-container."
}

test_doctor_state_backup_readability_runs_real_export() {
  begin_test "doctor verifies state readability with the real export command"

  load_agentctl_functions

  container_supports_state_contract() { return 0; }
  CONTAINER_CMD=container
  container() {
    printf '%s\n' "tar: can't open '.codex/ollama-launch.config.toml': Permission denied" >&2
    return 1
  }

  run_capture doctor_state_backup_readable unit-test-container
  assert_status 1
  assert_contains "state export is not readable by coder"
  assert_contains ".codex/ollama-launch.config.toml"
}

test_doctor_state_permission_script_attaches_stdin() {
  begin_test "doctor attaches stdin when running the state permission script"

  load_agentctl_functions

  local exec_args_file
  local script_input_file

  exec_args_file="$(mktemp "${TMPDIR:-/tmp}/agentctl-exec-args.XXXXXX")"
  script_input_file="$(mktemp "${TMPDIR:-/tmp}/agentctl-script-input.XXXXXX")"
  register_dir_cleanup "$exec_args_file"
  register_dir_cleanup "$script_input_file"

  CONTAINER_CMD=container
  container() {
    printf '%s\n' "$*" >"$exec_args_file"
    cat >"$script_input_file"
  }

  run_capture doctor_state_permissions unit-test-container 1
  assert_status 0
  grep -Fq -- 'exec -i -u 0 unit-test-container sh -s 1' "$exec_args_file" \
    || fail "Expected doctor permission repair to attach stdin, got: $(cat "$exec_args_file")"
  grep -Fq 'home="/home/coder"' "$script_input_file" \
    || fail "Expected doctor permission repair script on stdin"
}

test_doctor_fix_repairs_state_permission_problems() {
  begin_test "doctor --fix repairs user-state permission problems"

  load_agentctl_functions

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 0; }
  doctor_state_permissions() {
    [ "$1" = "unit-test-container" ] || fail "Unexpected doctor target: $1"
    [ "$2" = "1" ] || fail "Expected fix mode, got: $2"
    printf '%s\n' '.codex/config.toml'
    return 1
  }
  doctor_runtime_health() { return 0; }
  doctor_runtime_state_summary() { return 0; }

  CONTAINER_CMD=container
  container() {
    fail "Did not expect container lifecycle changes for a running container: $*"
  }

  run_capture doctor_cmd --name unit-test-container --fix
  assert_status 0
  assert_contains "Doctor repaired user-state ownership/readability problems in unit-test-container:"
  assert_contains "  - .codex/config.toml"
}

test_doctor_reports_runtime_health_problems() {
  begin_test "doctor reports runtime health problems"

  load_agentctl_functions

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 0; }
  doctor_state_permissions() { return 0; }
  doctor_runtime_state_summary() { return 0; }
  doctor_runtime_health() {
    [ "$1" = "unit-test-container" ] || fail "Unexpected doctor target: $1"
    [ "$2" = "0" ] || fail "Did not expect fix mode: $2"
    printf '%s\n' 'preferred runtime not installed: codex'
    printf '%s\n' 'codex config missing model provider: myollama'
    printf '%s\n' 'codex AGENTS.md missing'
    return 1
  }

  CONTAINER_CMD=container
  container() {
    fail "Did not expect container lifecycle changes for a running container: $*"
  }

  run_capture doctor_cmd --name unit-test-container
  assert_status 1
  assert_contains "Doctor found no user-state ownership/readability problems in unit-test-container"
  assert_contains "Doctor found runtime health problems in unit-test-container:"
  assert_contains "  - preferred runtime not installed: codex"
  assert_contains "  - codex config missing model provider: myollama"
  assert_contains "  - codex AGENTS.md missing"
  assert_contains "doctor --name unit-test-container --fix"
}

test_doctor_fix_repairs_runtime_health_problems() {
  begin_test "doctor --fix repairs runtime health problems"

  load_agentctl_functions

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 0; }
  doctor_state_permissions() { return 0; }
  doctor_runtime_state_summary() { return 0; }
  doctor_runtime_health() {
    [ "$1" = "unit-test-container" ] || fail "Unexpected doctor target: $1"
    [ "$2" = "1" ] || fail "Expected fix mode, got: $2"
    printf '%s\n' 'codex config missing model provider: myollama'
    printf '%s\n' 'codex AGENTS.md missing'
    return 1
  }

  CONTAINER_CMD=container
  container() {
    fail "Did not expect container lifecycle changes for a running container: $*"
  }

  run_capture doctor_cmd --name unit-test-container --fix
  assert_status 0
  assert_contains "Doctor found no user-state ownership/readability problems in unit-test-container"
  assert_contains "Doctor repaired runtime health problems in unit-test-container:"
  assert_contains "  - codex config missing model provider: myollama"
  assert_contains "  - codex AGENTS.md missing"
}

test_doctor_runtime_health_detects_codex_config_and_agents_problems() {
  begin_test "doctor runtime health detects Codex config and AGENTS problems"

  load_agentctl_functions

  run_agent_sh_in_container() {
    case "$2 $3" in
      "runtime list") printf '%s\n' codex ;;
      "preferred get") printf '%s\n' codex ;;
      "runtime info")
        [ "$4" = "codex" ] || fail "Unexpected runtime info target: $4"
        printf '%s\n' '{"id":"codex","command":"codex","installed":true,"capabilities":{"install":true}}'
        ;;
      *) fail "Unexpected agent.sh invocation: $*" ;;
    esac
  }
  doctor_runtime_command_available() { return 0; }
  doctor_codex_config_has_myollama() { return 1; }
  codex_agents_state() { printf '%s\n' missing; }

  run_capture doctor_runtime_health unit-test-container 0
  assert_status 1
  assert_contains "codex config missing model provider: myollama"
  assert_contains "codex AGENTS.md missing"
}

test_doctor_runtime_health_fix_reinstalls_runtime_and_restores_agents() {
  begin_test "doctor runtime health --fix reinstalls missing runtime and restores AGENTS"

  load_agentctl_functions

  local installed_runtime=""
  local reset_runtime=""
  local fixed_agents=0

  run_agent_sh_in_container() {
    case "$2 $3" in
      "runtime list") printf '%s\n' codex ;;
      "preferred get") printf '%s\n' codex ;;
      "runtime info")
        [ "$4" = "codex" ] || fail "Unexpected runtime info target: $4"
        printf '%s\n' '{"id":"codex","command":"codex","installed":false,"capabilities":{"install":true}}'
        ;;
      *) fail "Unexpected agent.sh invocation: $*" ;;
    esac
  }
  doctor_runtime_command_available() { return 1; }
  doctor_codex_config_has_myollama() { return 1; }
  codex_agents_state() { printf '%s\n' missing; }
  install_runtime_in_container() {
    installed_runtime="$2:$3"
    return 0
  }
  reset_runtime_config_in_container() {
    reset_runtime="$2"
    return 0
  }
  doctor_fix_missing_codex_agents() {
    fixed_agents=1
    return 0
  }

  run_capture doctor_runtime_health unit-test-container 1
  assert_status 1
  assert_contains "preferred runtime not installed: codex"
  assert_contains "runtime command unavailable: codex (codex)"
  assert_contains "codex config missing model provider: myollama"
  assert_contains "codex AGENTS.md missing"
  [ "$installed_runtime" = "codex:1" ] || fail "Expected Codex reinstall with skip preferred, got: $installed_runtime"
  [ "$reset_runtime" = "codex" ] || fail "Expected Codex reset-config, got: $reset_runtime"
  [ "$fixed_agents" -eq 1 ] || fail "Expected missing AGENTS.md to be restored"
}

test_doctor_reports_runtime_state_summary() {
  begin_test "doctor reports runtime state summary"

  load_agentctl_functions

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 0; }
  doctor_state_permissions() { return 0; }
  doctor_runtime_health() { return 0; }
  doctor_runtime_state_summary() {
    printf '%s\n' 'Codex state: history lines 12, session files 3, session index lines 2'
    printf '%s\n' 'Claude state: credentials files 1, settings files 1, home state files 1, project files 4'
  }

  CONTAINER_CMD=container
  container() {
    fail "Did not expect container lifecycle changes for a running container: $*"
  }

  run_capture doctor_cmd --name unit-test-container
  assert_status 0
  assert_contains "Doctor runtime state summary in unit-test-container:"
  assert_contains "  - Codex state: history lines 12, session files 3, session index lines 2"
  assert_contains "  - Claude state: credentials files 1, settings files 1, home state files 1, project files 4"
}

test_container_state_permission_script_repairs_unreadable_state() {
  begin_test "container state permission script repairs unreadable user state"

  load_agentctl_functions

  local temp_home
  local script_file

  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-doctor-home.XXXXXX")"
  register_dir_cleanup "$temp_home"
  script_file="$temp_home/doctor.sh"
  mkdir -p "$temp_home/.codex"
  printf 'config\n' >"$temp_home/.codex/config.toml"
  chmod 000 "$temp_home/.codex/config.toml"

  container_state_permission_script | sed "s#home=\"/home/coder\"#home=\"$temp_home\"#" >"$script_file"

  run_capture sh "$script_file" 0
  assert_status 0
  assert_contains ".codex/config.toml"
  [ ! -r "$temp_home/.codex/config.toml" ] || fail "Expected config.toml to remain unreadable without --fix"

  run_capture sh "$script_file" 1
  assert_status 0
  assert_contains ".codex/config.toml"
  [ -r "$temp_home/.codex/config.toml" ] || fail "Expected config.toml to become readable after fix"
}

test_refresh_container_file_streams_source_via_stdin() {
  begin_test "refresh_container_file uses interactive exec for stdin streaming"

  load_agentctl_functions

  local source_file
  local exec_log=""

  source_file="$(mktemp "${TMPDIR:-/tmp}/agentctl-refresh-file.XXXXXX")"
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

test_refresh_container_tree_suppresses_host_xattrs() {
  begin_test "refresh_container_tree suppresses host extended attributes"

  load_agentctl_functions

  local temp_dir
  local source_dir
  local tar_log
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-refresh-tree.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  source_dir="$temp_dir/source"
  tar_log="$temp_dir/tar.log"
  mkdir -p "$source_dir"
  printf 'data\n' >"$source_dir/file.txt"

  CONTAINER_CMD=container
  container() {
    case "$1" in
      exec)
        return 0
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  tar() {
    printf 'COPYFILE_DISABLE=%s args=%s\n' "${COPYFILE_DISABLE:-}" "$*" >>"$tar_log"
    case "$*" in
      "--no-xattrs -cf /dev/null -T /dev/null")
        return 0
        ;;
      "--no-xattrs -C $source_dir -cf - .")
        printf 'tar-stream'
        return 0
        ;;
      *)
        fail "Unexpected tar invocation: $*"
        ;;
    esac
  }

  run_capture refresh_container_tree unit-test-container "$source_dir" /etc/agentctl/runtimes root:root 644 755
  unset -f tar
  assert_status 0
  grep -Fq 'COPYFILE_DISABLE=1 args=--no-xattrs -C '"$source_dir"' -cf - .' "$tar_log" || fail "Expected refresh tar stream to disable xattrs, got: $(cat "$tar_log")"
}

test_system_manifest_starts_stopped_container_and_restores_state() {
  begin_test "system-manifest starts a stopped container and restores stopped state"

  load_agentctl_functions

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

  load_agentctl_functions

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

  load_agentctl_functions

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

  load_agentctl_functions

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

  load_agentctl_functions

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

  load_agentctl_functions

  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-cleanup.XXXXXX")"
  register_dir_cleanup "$temp_dir"

  mkdir -p "$temp_dir/rootfs/pkg"
  : >"$temp_dir/rootfs/pkg/file.txt"
  chmod 500 "$temp_dir/rootfs" "$temp_dir/rootfs/pkg"
  chmod 400 "$temp_dir/rootfs/pkg/file.txt"

  cleanup_temp_dir "$temp_dir"

  [ ! -e "$temp_dir" ] || fail "Expected cleanup_temp_dir to remove $temp_dir"
}

test_extract_container_export_rootfs_respects_oci_layer_order() {
  begin_test "extract_container_export_rootfs applies OCI layers in manifest order"

  load_agentctl_functions

  local temp_dir
  local export_file
  local rootfs_dir
  local layout_dir
  local layer_one_src
  local layer_two_src
  local layer_one_tar
  local layer_two_tar
  local layer_one_digest
  local layer_two_digest
  local manifest_file
  local manifest_digest
  local nonce=0

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-oci-export.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  export_file="$temp_dir/container-export.tar"
  rootfs_dir="$temp_dir/rootfs"
  layout_dir="$temp_dir/layout"
  layer_one_src="$temp_dir/layer-one"
  layer_two_src="$temp_dir/layer-two"
  layer_one_tar="$temp_dir/layer-one.tar"
  layer_two_tar="$temp_dir/layer-two.tar"

  mkdir -p "$layer_one_src/home/coder" "$layer_one_src/bin"
  printf '%s\n' old >"$layer_one_src/home/coder/state"
  printf '%s\n' '#!/bin/sh' >"$layer_one_src/bin/sh"
  tar -C "$layer_one_src" -cf "$layer_one_tar" .
  layer_one_digest="$(sha256sum "$layer_one_tar" | awk '{print $1}')"

  while :; do
    rm -rf "$layer_two_src"
    mkdir -p "$layer_two_src/home/coder"
    printf 'new-%s\n' "$nonce" >"$layer_two_src/home/coder/state"
    tar -C "$layer_two_src" -cf "$layer_two_tar" .
    layer_two_digest="$(sha256sum "$layer_two_tar" | awk '{print $1}')"
    if [[ "$layer_two_digest" < "$layer_one_digest" ]]; then
      break
    fi
    nonce=$((nonce + 1))
    [ "$nonce" -lt 200 ] || fail "Could not construct OCI layer digests for ordering regression"
  done

  mkdir -p "$layout_dir/blobs/sha256"
  printf '{"imageLayoutVersion":"1.0.0"}\n' >"$layout_dir/oci-layout"
  cp "$layer_one_tar" "$layout_dir/blobs/sha256/$layer_one_digest"
  cp "$layer_two_tar" "$layout_dir/blobs/sha256/$layer_two_digest"
  manifest_file="$temp_dir/manifest.json"
  printf '{"schemaVersion":2,"layers":[{"digest":"sha256:%s"},{"digest":"sha256:%s"}]}\n' \
    "$layer_one_digest" "$layer_two_digest" >"$manifest_file"
  manifest_digest="$(sha256sum "$manifest_file" | awk '{print $1}')"
  cp "$manifest_file" "$layout_dir/blobs/sha256/$manifest_digest"
  printf '{"schemaVersion":2,"manifests":[{"digest":"sha256:%s"}]}\n' "$manifest_digest" >"$layout_dir/index.json"
  tar -C "$layout_dir" -cf "$export_file" .

  extract_container_export_rootfs "$export_file" "$rootfs_dir"

  [ "$(cat "$rootfs_dir/home/coder/state")" = "new-$nonce" ] || fail "Expected later OCI layer to win"
  [ -e "$rootfs_dir/bin/sh" ] || fail "Expected earlier OCI layer contents to be preserved"
}

test_validate_backup_rootfs_accepts_shell_symlink() {
  begin_test "validate_backup_rootfs accepts shell symlinks"

  load_agentctl_functions

  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-backup-rootfs.XXXXXX")"
  register_dir_cleanup "$temp_dir"

  mkdir -p "$temp_dir/rootfs/home/coder" "$temp_dir/rootfs/bin"
  ln -s /bin/busybox "$temp_dir/rootfs/bin/sh"

  validate_backup_rootfs "$temp_dir/rootfs" agent-test-backup
}

test_build_backup_image_uses_clean_context_for_exported_rootfs() {
  begin_test "build_backup_image_from_export uses a tarred rootfs build context"

  load_agentctl_functions

  local temp_dir
  local export_root
  local export_file
  local backup_root
  local backup_dockerfile
  local build_context=""
  local build_dockerfile=""
  local validated_image=""
  local buildkit_stopped=0

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-backup-build.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  export_root="$temp_dir/export-root"
  export_file="$temp_dir/export.tar"
  backup_root="$temp_dir/rootfs"
  backup_dockerfile="$temp_dir/Dockerfile.backup"

  mkdir -p "$export_root/home/coder" "$export_root/bin"
  printf '*\n' >"$export_root/.dockerignore"
  printf '%s\n' state >"$export_root/home/coder/state"
  ln -s /bin/busybox "$export_root/bin/sh"
  tar -C "$export_root" -cf "$export_file" .

  CONTAINER_CMD=container
  container() {
    case "$1" in
      build)
        build_dockerfile="$5"
        build_context="$6"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  stop_buildkit_container() { buildkit_stopped=1; }
  validate_backup_image() { validated_image="$1"; }

  build_backup_image_from_export agent-test-backup unit-test-container "$export_file" "$backup_root" "$backup_dockerfile"

  [ "$build_context" = "$backup_root.context" ] || fail "Expected clean wrapper build context, got: $build_context"
  [ "$build_dockerfile" = "$backup_root.context/Dockerfile" ] || fail "Expected in-context backup Dockerfile, got: $build_dockerfile"
  cmp "$build_dockerfile" "$backup_dockerfile" >/dev/null || fail "Expected external backup Dockerfile copy to match in-context Dockerfile"
  [ ! -e "$build_context/.dockerignore" ] || fail "Did not expect exported .dockerignore at build context root"
  [ -e "$build_context/rootfs/.dockerignore" ] || fail "Expected exported .dockerignore to be preserved under rootfs"
  tar -tf "$build_context/rootfs.tar" | grep -Fx './.dockerignore' >/dev/null || fail "Expected rootfs tar to preserve exported .dockerignore"
  tar -tf "$build_context/rootfs.tar" | grep -Fx './home/coder/state' >/dev/null || fail "Expected rootfs tar to include home state"
  grep -Fq 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' "$backup_dockerfile" || fail "Expected backup Dockerfile to set PATH"
  grep -Fq 'ADD rootfs.tar /' "$backup_dockerfile" || fail "Expected backup Dockerfile to add tarred rootfs"
  [ "$validated_image" = "agent-test-backup" ] || fail "Expected backup image validation, got: $validated_image"
  [ "$buildkit_stopped" -eq 1 ] || fail "Expected backup build to stop BuildKit"
}

test_build_backup_image_preserves_flat_export_tar() {
  begin_test "build_backup_image_from_export preserves flat export tar as build input"

  load_agentctl_functions

  local temp_dir
  local export_root
  local export_file
  local backup_root
  local backup_dockerfile
  local rootfs_tar

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-backup-flat.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  export_root="$temp_dir/export-root"
  export_file="$temp_dir/export.tar"
  backup_root="$temp_dir/rootfs"
  backup_dockerfile="$temp_dir/Dockerfile.backup"
  rootfs_tar="$backup_root.context/rootfs.tar"

  mkdir -p "$export_root/home/coder" "$export_root/bin"
  printf '%s\n' state >"$export_root/home/coder/state"
  ln -s /bin/busybox "$export_root/bin/sh"
  tar -C "$export_root" -cf "$export_file" .

  CONTAINER_CMD=container
  container() {
    case "$1" in
      build) ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  stop_buildkit_container() { :; }
  validate_backup_image() { :; }

  build_backup_image_from_export agent-test-backup unit-test-container "$export_file" "$backup_root" "$backup_dockerfile"

  cmp "$export_file" "$rootfs_tar" >/dev/null || fail "Expected flat export tar to be reused as rootfs.tar"
}

test_validate_backup_image_rejects_unbootable_backup() {
  begin_test "validate_backup_image rejects backup images that cannot start /bin/sh"

  load_agentctl_functions

  sanitize_image_name() { printf '%s\n' "$1"; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      rm)
        ;;
      create)
        return 0
        ;;
      start)
        return 1
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  validate_backup_image_wrapper() {
    ( validate_backup_image "$@" )
  }

  run_capture validate_backup_image_wrapper agent-test-backup
  assert_status 1
  assert_contains "Backup image agent-test-backup was built but cannot start /bin/sh"
}

test_validate_backup_image_stops_validation_container_before_remove() {
  begin_test "validate_backup_image stops validation container before remove"

  load_agentctl_functions

  local call_log=""

  sanitize_image_name() { printf '%s\n' "$1"; }
  date() { printf '20260406120000\n'; }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      rm)
        call_log="${call_log}rm $2"$'\n'
        ;;
      create)
        call_log="${call_log}create $5"$'\n'
        return 0
        ;;
      start)
        call_log="${call_log}start $2"$'\n'
        return 0
        ;;
      stop)
        call_log="${call_log}stop $2"$'\n'
        return 0
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  validate_backup_image agent-test-backup

  printf '%s\n' "$call_log" | grep -Fq "stop agentctl-backup-validate-20260406120000-$$" || fail "Expected validation container stop before removal, got: $call_log"
}

main() {
  log "Using agentctl at $AGENTCTL"
  log "Using agentctl implementation at $AGENTCTL_IMPL"
  if [ -n "$TEST_FILTER" ]; then
    log "Filtering unit tests by: $TEST_FILTER"
  fi
  if [ -n "$TEST_START_FROM" ]; then
    log "Running unit tests from: $TEST_START_FROM"
  fi

  run_selected_test test_run_config_wires_runtime_config_json "test_run_config_wires_runtime_config_json"
  run_selected_test test_run_cmd_wires_ollama_host_to_custom_command "test_run_cmd_wires_ollama_host_to_custom_command"
  run_selected_test test_run_help_reports_generic_runtime_config "test_run_help_reports_generic_runtime_config"
  run_selected_test test_run_help_reports_runtime_options "test_run_help_reports_runtime_options"
  run_selected_test test_exec_help_reports_stdio_option "test_exec_help_reports_stdio_option"
  run_selected_test test_run_cmd_wires_home_mount "test_run_cmd_wires_home_mount"
  run_selected_test test_doctor_help_reports_fix_option "test_doctor_help_reports_fix_option"
  run_selected_test test_agentctl_version_matches_version_file "test_agentctl_version_matches_version_file"
  run_selected_test test_doctor_host_reports_runtime_and_capabilities "test_doctor_host_reports_runtime_and_capabilities"
  run_selected_test test_jq_dependency_version_checks "test_jq_dependency_version_checks"
  run_selected_test test_host_address_reads_container_1_1_gateway "test_host_address_reads_container_1_1_gateway"
  run_selected_test test_host_address_supports_custom_network_subnet_fallback "test_host_address_supports_custom_network_subnet_fallback"
  run_selected_test test_host_address_handles_non_24_and_rejects_malformed_networks "test_host_address_handles_non_24_and_rejects_malformed_networks"
  run_selected_test test_inspect_json_helpers_handle_schema_shapes_and_invalid_input "test_inspect_json_helpers_handle_schema_shapes_and_invalid_input"
  run_selected_test test_configure_container_host_alias_replaces_stale_entry "test_configure_container_host_alias_replaces_stale_entry"
  run_selected_test test_migrate_legacy_runtime_config_files "test_migrate_legacy_runtime_config_files"
  run_selected_test test_migrate_legacy_runtime_config_files_preserves_source_on_copy_failure "test_migrate_legacy_runtime_config_files_preserves_source_on_copy_failure"
  run_selected_test test_runtime_default_files_apply_local_overrides "test_runtime_default_files_apply_local_overrides"
  run_selected_test test_run_container_refreshes_host_alias_before_exec "test_run_container_refreshes_host_alias_before_exec"
  run_selected_test test_container_agentctl_version_warning_distinguishes_image_and_tooling "test_container_agentctl_version_warning_distinguishes_image_and_tooling"
  run_selected_test test_new_container_launch_checks_agentctl_versions "test_new_container_launch_checks_agentctl_versions"
  run_selected_test test_start_and_restart_refresh_host_alias "test_start_and_restart_refresh_host_alias"
  run_selected_test test_rescue_help_reports_backup_image_options "test_rescue_help_reports_backup_image_options"
  run_selected_test test_run_model_wires_selected_model "test_run_model_wires_selected_model"
  run_selected_test test_build_help_reports_primary_base_images "test_build_help_reports_primary_base_images"
  run_selected_test test_build_cmd_passes_runtime_list_build_args "test_build_cmd_passes_runtime_list_build_args"
  run_selected_test test_build_cmd_expands_all_registered_runtimes "test_build_cmd_expands_all_registered_runtimes"
  run_selected_test test_build_cmd_all_rejects_manifest_filename_id_mismatch "test_build_cmd_all_rejects_manifest_filename_id_mismatch"
  run_selected_test test_build_cmd_uses_first_runtime_as_default_when_unspecified "test_build_cmd_uses_first_runtime_as_default_when_unspecified"
  run_selected_test test_build_cmd_default_runtime_alone_installs_only_that_runtime "test_build_cmd_default_runtime_alone_installs_only_that_runtime"
  run_selected_test test_build_cmd_rebuilds_existing_image_when_runtime_selection_is_overridden "test_build_cmd_rebuilds_existing_image_when_runtime_selection_is_overridden"
  run_selected_test test_build_cmd_rebuilds_and_snapshots_local_dependencies "test_build_cmd_rebuilds_and_snapshots_local_dependencies"
  run_selected_test test_build_cmd_snapshots_existing_image_when_timestamp_missing "test_build_cmd_snapshots_existing_image_when_timestamp_missing"
  run_selected_test test_build_cmd_skips_existing_image_when_timestamp_matches "test_build_cmd_skips_existing_image_when_timestamp_matches"
  run_selected_test test_build_cmd_recognizes_container_1_image_snapshot_schema "test_build_cmd_recognizes_container_1_image_snapshot_schema"
  run_selected_test test_container_lookup_uses_quiet_exact_ids "test_container_lookup_uses_quiet_exact_ids"
  run_selected_test test_run_cmd_runtime_selection_does_not_auto_install_for_new_container "test_run_cmd_runtime_selection_does_not_auto_install_for_new_container"
  run_selected_test test_run_cmd_runtime_selection_does_not_auto_install_for_existing_container "test_run_cmd_runtime_selection_does_not_auto_install_for_existing_container"
  run_selected_test test_build_cmd_warns_for_legacy_office_image "test_build_cmd_warns_for_legacy_office_image"
  run_selected_test test_build_cmd_rejects_runtime_override_snapshot_combo "test_build_cmd_rejects_runtime_override_snapshot_combo"
  run_selected_test test_build_cmd_rejects_default_runtime_outside_runtime_list "test_build_cmd_rejects_default_runtime_outside_runtime_list"
  run_selected_test test_run_cmd_rejects_invalid_runtime_config "test_run_cmd_rejects_invalid_runtime_config"
  run_selected_test test_run_cmd_rejects_install_runtime_without_runtime "test_run_cmd_rejects_install_runtime_without_runtime"
  run_selected_test test_run_cmd_rejects_auth_without_online "test_run_cmd_rejects_auth_without_online"
  run_selected_test test_run_pre_exec_syncs_selected_runtime_auth_when_available "test_run_pre_exec_syncs_selected_runtime_auth_when_available"
  run_selected_test test_run_pre_exec_updates_codex_via_runtime_helper "test_run_pre_exec_updates_codex_via_runtime_helper"
  run_selected_test test_run_pre_exec_updates_legacy_npm_codex_via_root_helper "test_run_pre_exec_updates_legacy_npm_codex_via_root_helper"
  run_selected_test test_run_container_reset_config_uses_runtime_helper "test_run_container_reset_config_uses_runtime_helper"
  run_selected_test test_run_container_reset_config_uses_selected_runtime "test_run_container_reset_config_uses_selected_runtime"
  run_selected_test test_run_container_reset_config_preserves_preferred_runtime "test_run_container_reset_config_preserves_preferred_runtime"
  run_selected_test test_run_pre_exec_syncs_auth_for_preferred_runtime_when_unspecified "test_run_pre_exec_syncs_auth_for_preferred_runtime_when_unspecified"
  run_selected_test test_run_pre_exec_runs_local_model_preflight_for_preferred_claude "test_run_pre_exec_runs_local_model_preflight_for_preferred_claude"
  run_selected_test test_run_pre_exec_runs_local_model_preflight_for_preferred_codex "test_run_pre_exec_runs_local_model_preflight_for_preferred_codex"
  run_selected_test test_run_cmd_default_entrypoint_enables_local_runtime_preflight "test_run_cmd_default_entrypoint_enables_local_runtime_preflight"
  run_selected_test test_sync_runtime_auth_to_container_if_available_skips_missing_keychain "test_sync_runtime_auth_to_container_if_available_skips_missing_keychain"
  run_selected_test test_exec_cmd_no_tty_omits_interactive_flags "test_exec_cmd_no_tty_omits_interactive_flags"
  run_selected_test test_exec_cmd_stdio_uses_interactive_without_tty "test_exec_cmd_stdio_uses_interactive_without_tty"
  run_selected_test test_exec_cmd_stdio_requires_delimiter_and_command "test_exec_cmd_stdio_requires_delimiter_and_command"
  run_selected_test test_exec_cmd_stdio_requires_running_container "test_exec_cmd_stdio_requires_running_container"
  run_selected_test test_run_cmd_stdio_uses_interactive_without_tty "test_run_cmd_stdio_uses_interactive_without_tty"
  run_selected_test test_run_cmd_stdio_suppresses_lifecycle_stdout "test_run_cmd_stdio_suppresses_lifecycle_stdout"
  run_selected_test test_run_container_stdio_detaches_pre_exec_stdin "test_run_container_stdio_detaches_pre_exec_stdin"
  run_selected_test test_run_cmd_stdio_requires_cmd "test_run_cmd_stdio_requires_cmd"
  run_selected_test test_run_cmd_stdio_rejects_shell "test_run_cmd_stdio_rejects_shell"
  run_selected_test test_auth_cmd_warns_for_legacy_office_image "test_auth_cmd_warns_for_legacy_office_image"
  run_selected_test test_feature_cmd_installs_via_root_helper "test_feature_cmd_installs_via_root_helper"
  run_selected_test test_runtime_cmd_install_uses_user_helper "test_runtime_cmd_install_uses_user_helper"
  run_selected_test test_runtime_cmd_install_claude_warns_on_undersized_container "test_runtime_cmd_install_claude_warns_on_undersized_container"
  run_selected_test test_runtime_cmd_install_claude_reports_memory_guidance_on_failure "test_runtime_cmd_install_claude_reports_memory_guidance_on_failure"
  run_selected_test test_runtime_cmd_update_uses_user_helper "test_runtime_cmd_update_uses_user_helper"
  run_selected_test test_bootstrap_cmd_bootstraps_alpine_container_and_restores_stopped_state "test_bootstrap_cmd_bootstraps_alpine_container_and_restores_stopped_state"
  run_selected_test test_bootstrap_cmd_creates_and_bootstraps_new_alpine_container "test_bootstrap_cmd_creates_and_bootstraps_new_alpine_container"
  run_selected_test test_bootstrap_cmd_bootstraps_apt_container "test_bootstrap_cmd_bootstraps_apt_container"
  run_selected_test test_bootstrap_cmd_rejects_unsupported_base "test_bootstrap_cmd_rejects_unsupported_base"
  run_selected_test test_agentctl_wrapper_usage_banner "test_agentctl_wrapper_usage_banner"
  run_selected_test test_host_test_filter_normalizes_hyphens_spaces_and_underscores "test_host_test_filter_normalizes_hyphens_spaces_and_underscores"
  run_selected_test test_refresh_help_reports_new_command "test_refresh_help_reports_new_command"
  run_selected_test test_bootstrap_help_reports_new_command "test_bootstrap_help_reports_new_command"
  run_selected_test test_system_manifest_help_reports_new_command "test_system_manifest_help_reports_new_command"
  run_selected_test test_runtime_help_reports_new_command "test_runtime_help_reports_new_command"
  run_selected_test test_feature_help_reports_new_command "test_feature_help_reports_new_command"
  run_selected_test test_use_help_reports_new_command "test_use_help_reports_new_command"
  run_selected_test test_images_help_reports_subcommand_options "test_images_help_reports_subcommand_options"
  run_selected_test test_images_print_sorted_keeps_compact_output "test_images_print_sorted_keeps_compact_output"
  run_selected_test test_images_print_metadata_uses_runtime_image_details "test_images_print_metadata_uses_runtime_image_details"
  run_selected_test test_images_list_defaults_to_metadata_and_supports_raw_output "test_images_list_defaults_to_metadata_and_supports_raw_output"
  run_selected_test test_images_list_falls_back_to_refs_when_metadata_is_unavailable "test_images_list_falls_back_to_refs_when_metadata_is_unavailable"
  run_selected_test test_rm_help_reports_force_option "test_rm_help_reports_force_option"
  run_selected_test test_agent_sh_runtime_info_reports_registry_metadata "test_agent_sh_runtime_info_reports_registry_metadata"
  run_selected_test test_agent_sh_feature_list_reports_declared_features "test_agent_sh_feature_list_reports_declared_features"
  run_selected_test test_agent_sh_feature_info_reports_manifest_metadata "test_agent_sh_feature_info_reports_manifest_metadata"
  run_selected_test test_agent_sh_feature_install_office_creates_feature_state "test_agent_sh_feature_install_office_creates_feature_state"
  run_selected_test test_agent_sh_feature_info_reports_installed_after_office_install "test_agent_sh_feature_info_reports_installed_after_office_install"
  run_selected_test test_agent_sh_runtime_list_reports_installed_runtimes_only "test_agent_sh_runtime_list_reports_installed_runtimes_only"
  run_selected_test test_agent_sh_runtime_list_ignores_dangling_runtime_launcher "test_agent_sh_runtime_list_ignores_dangling_runtime_launcher"
  run_selected_test test_agent_sh_runtime_info_prefers_tool_bin_over_user_path "test_agent_sh_runtime_info_prefers_tool_bin_over_user_path"
  run_selected_test test_agent_sh_runtime_capabilities_reports_manifest_commands "test_agent_sh_runtime_capabilities_reports_manifest_commands"
  run_selected_test test_agent_sh_claude_runtime_info_reports_skeleton_metadata "test_agent_sh_claude_runtime_info_reports_skeleton_metadata"
  run_selected_test test_agent_sh_opencode_runtime_info_reports_local_only_metadata "test_agent_sh_opencode_runtime_info_reports_local_only_metadata"
  run_selected_test test_agent_sh_qwen_runtime_info_reports_local_only_metadata "test_agent_sh_qwen_runtime_info_reports_local_only_metadata"
  run_selected_test test_agent_sh_pi_runtime_info_reports_local_only_metadata "test_agent_sh_pi_runtime_info_reports_local_only_metadata"
  run_selected_test test_agent_sh_system_manifest_includes_runtime_feature_and_preference_state "test_agent_sh_system_manifest_includes_runtime_feature_and_preference_state"
  run_selected_test test_agent_sh_system_manifest_reports_unknown_version_markers "test_agent_sh_system_manifest_reports_unknown_version_markers"
  run_selected_test test_agent_sh_system_manifest_reports_apk_requested_packages "test_agent_sh_system_manifest_reports_apk_requested_packages"
  run_selected_test test_agent_sh_system_manifest_reports_dpkg_requested_packages "test_agent_sh_system_manifest_reports_dpkg_requested_packages"
  run_selected_test test_agent_sh_claude_runtime_install_runs_native_installer "test_agent_sh_claude_runtime_install_runs_native_installer"
  run_selected_test test_agent_sh_claude_runtime_update_calls_claude_update "test_agent_sh_claude_runtime_update_calls_claude_update"
  run_selected_test test_agent_sh_codex_runtime_install_runs_standalone_installer "test_agent_sh_codex_runtime_install_runs_standalone_installer"
  run_selected_test test_agent_sh_codex_runtime_install_falls_back_to_direct_package "test_agent_sh_codex_runtime_install_falls_back_to_direct_package"
  run_selected_test test_agent_sh_codex_runtime_update_calls_codex_update "test_agent_sh_codex_runtime_update_calls_codex_update"
  run_selected_test test_agent_sh_opencode_runtime_install_uses_npm_prefix "test_agent_sh_opencode_runtime_install_uses_npm_prefix"
  run_selected_test test_agent_sh_opencode_runtime_update_uses_npm_prefix "test_agent_sh_opencode_runtime_update_uses_npm_prefix"
  run_selected_test test_agent_sh_qwen_runtime_install_uses_npm_prefix "test_agent_sh_qwen_runtime_install_uses_npm_prefix"
  run_selected_test test_agent_sh_pi_runtime_install_uses_npm_prefix "test_agent_sh_pi_runtime_install_uses_npm_prefix"
  run_selected_test test_agent_sh_qwen_runtime_install_rejects_old_node "test_agent_sh_qwen_runtime_install_rejects_old_node"
  run_selected_test test_agent_sh_pi_runtime_install_rejects_old_node "test_agent_sh_pi_runtime_install_rejects_old_node"
  run_selected_test test_agent_sh_qwen_runtime_update_uses_npm_prefix "test_agent_sh_qwen_runtime_update_uses_npm_prefix"
  run_selected_test test_agent_sh_pi_runtime_update_uses_npm_prefix "test_agent_sh_pi_runtime_update_uses_npm_prefix"
  run_selected_test test_agent_sh_claude_runtime_reset_config_restores_settings "test_agent_sh_claude_runtime_reset_config_restores_settings"
  run_selected_test test_agent_sh_codex_runtime_reset_config_warns_about_lost_configuration "test_agent_sh_codex_runtime_reset_config_warns_about_lost_configuration"
  run_selected_test test_agent_sh_opencode_runtime_reset_config_writes_ollama_config "test_agent_sh_opencode_runtime_reset_config_writes_ollama_config"
  run_selected_test test_agent_sh_qwen_runtime_reset_config_writes_ollama_config "test_agent_sh_qwen_runtime_reset_config_writes_ollama_config"
  run_selected_test test_agent_sh_pi_runtime_reset_config_writes_ollama_config "test_agent_sh_pi_runtime_reset_config_writes_ollama_config"
  run_selected_test test_agent_sh_codex_run_defaults_to_workdir_cd "test_agent_sh_codex_run_defaults_to_workdir_cd"
  run_selected_test test_agent_sh_codex_run_repairs_broken_bundled_rg "test_agent_sh_codex_run_repairs_broken_bundled_rg"
  run_selected_test test_agent_sh_codex_run_uses_runtime_profile_config "test_agent_sh_codex_run_uses_runtime_profile_config"
  run_selected_test test_agent_sh_accepts_explicit_empty_runtime_config_json "test_agent_sh_accepts_explicit_empty_runtime_config_json"
  run_selected_test test_agent_sh_codex_run_uses_model_override "test_agent_sh_codex_run_uses_model_override"
  run_selected_test test_agent_sh_codex_online_run_skips_catalog_update "test_agent_sh_codex_online_run_skips_catalog_update"
  run_selected_test test_agent_sh_codex_local_run_updates_config_and_catalog "test_agent_sh_codex_local_run_updates_config_and_catalog"
  run_selected_test test_agent_sh_codex_local_run_uses_ollama_host_env "test_agent_sh_codex_local_run_uses_ollama_host_env"
  run_selected_test test_agent_sh_codex_local_run_config_ollama_host_overrides_env "test_agent_sh_codex_local_run_config_ollama_host_overrides_env"
  run_selected_test test_agent_sh_codex_local_run_reports_unreachable_ollama_host "test_agent_sh_codex_local_run_reports_unreachable_ollama_host"
  run_selected_test test_agent_sh_codex_local_metadata_status_uses_stderr "test_agent_sh_codex_local_metadata_status_uses_stderr"
  run_selected_test test_agent_sh_codex_local_run_with_explicit_profile_updates_catalog "test_agent_sh_codex_local_run_with_explicit_profile_updates_catalog"
  run_selected_test test_agent_sh_codex_local_run_updates_stale_catalog_entry "test_agent_sh_codex_local_run_updates_stale_catalog_entry"
  run_selected_test test_agent_sh_codex_local_run_reports_unchanged_catalog_entry "test_agent_sh_codex_local_run_reports_unchanged_catalog_entry"
  run_selected_test test_agent_sh_codex_local_run_migrates_inactive_catalog_entries "test_agent_sh_codex_local_run_migrates_inactive_catalog_entries"
  run_selected_test test_agent_sh_codex_local_run_uses_model_override_for_catalog "test_agent_sh_codex_local_run_uses_model_override_for_catalog"
  run_selected_test test_agent_sh_codex_local_run_uses_explicit_model_arg_for_catalog "test_agent_sh_codex_local_run_uses_explicit_model_arg_for_catalog"
  run_selected_test test_agent_sh_codex_local_run_creates_missing_catalog "test_agent_sh_codex_local_run_creates_missing_catalog"
  run_selected_test test_agent_sh_codex_local_run_rejects_invalid_catalog_without_overwrite "test_agent_sh_codex_local_run_rejects_invalid_catalog_without_overwrite"
  run_selected_test test_agent_sh_codex_local_run_rejects_missing_myollama_provider "test_agent_sh_codex_local_run_rejects_missing_myollama_provider"
  run_selected_test test_agent_sh_codex_local_run_api_show_failure_preserves_catalog "test_agent_sh_codex_local_run_api_show_failure_preserves_catalog"
  run_selected_test test_agent_sh_claude_run_uses_local_ollama_defaults "test_agent_sh_claude_run_uses_local_ollama_defaults"
  run_selected_test test_agent_sh_claude_run_respects_explicit_model "test_agent_sh_claude_run_respects_explicit_model"
  run_selected_test test_agent_sh_claude_run_uses_model_override "test_agent_sh_claude_run_uses_model_override"
  run_selected_test test_agent_sh_claude_run_uses_runtime_flag_config "test_agent_sh_claude_run_uses_runtime_flag_config"
  run_selected_test test_agent_sh_opencode_run_uses_local_ollama_defaults "test_agent_sh_opencode_run_uses_local_ollama_defaults"
  run_selected_test test_agent_sh_opencode_run_uses_model_override "test_agent_sh_opencode_run_uses_model_override"
  run_selected_test test_agent_sh_opencode_run_respects_explicit_model "test_agent_sh_opencode_run_respects_explicit_model"
  run_selected_test test_agent_sh_qwen_run_uses_local_ollama_defaults "test_agent_sh_qwen_run_uses_local_ollama_defaults"
  run_selected_test test_agent_sh_qwen_run_uses_model_override "test_agent_sh_qwen_run_uses_model_override"
  run_selected_test test_agent_sh_qwen_run_respects_explicit_model "test_agent_sh_qwen_run_respects_explicit_model"
  run_selected_test test_agent_sh_qwen_run_merges_existing_settings "test_agent_sh_qwen_run_merges_existing_settings"
  run_selected_test test_agent_sh_qwen_run_rejects_missing_ollama_model "test_agent_sh_qwen_run_rejects_missing_ollama_model"
  run_selected_test test_agent_sh_pi_run_uses_local_ollama_defaults "test_agent_sh_pi_run_uses_local_ollama_defaults"
  run_selected_test test_agent_sh_pi_run_uses_model_override "test_agent_sh_pi_run_uses_model_override"
  run_selected_test test_agent_sh_pi_run_respects_explicit_model "test_agent_sh_pi_run_respects_explicit_model"
  run_selected_test test_agent_sh_pi_run_merges_existing_models_config "test_agent_sh_pi_run_merges_existing_models_config"
  run_selected_test test_agent_sh_pi_run_rejects_missing_ollama_model "test_agent_sh_pi_run_rejects_missing_ollama_model"
  run_selected_test test_agent_sh_rejects_unknown_runtime "test_agent_sh_rejects_unknown_runtime"
  run_selected_test test_agent_sh_preferred_round_trip "test_agent_sh_preferred_round_trip"
  run_selected_test test_agent_sh_preferred_set_as_root_repairs_ownership "test_agent_sh_preferred_set_as_root_repairs_ownership"
  run_selected_test test_agent_sh_preferred_set_rejects_uninstalled_runtime "test_agent_sh_preferred_set_rejects_uninstalled_runtime"
  run_selected_test test_agent_sh_auth_read_rejects_invalid_codex_auth "test_agent_sh_auth_read_rejects_invalid_codex_auth"
  run_selected_test test_agent_sh_auth_write_rejects_invalid_codex_auth "test_agent_sh_auth_write_rejects_invalid_codex_auth"
  run_selected_test test_agent_sh_auth_write_codex_does_not_require_user_config_dir "test_agent_sh_auth_write_codex_does_not_require_user_config_dir"
  run_selected_test test_agent_sh_claude_auth_read_includes_optional_home_state "test_agent_sh_claude_auth_read_includes_optional_home_state"
  run_selected_test test_agent_sh_claude_auth_read_rejects_invalid_credentials "test_agent_sh_claude_auth_read_rejects_invalid_credentials"
  run_selected_test test_agent_sh_claude_auth_write_restores_credentials_and_home_state "test_agent_sh_claude_auth_write_restores_credentials_and_home_state"
  run_selected_test test_agent_sh_claude_auth_write_rejects_invalid_payload "test_agent_sh_claude_auth_write_rejects_invalid_payload"
  run_selected_test test_agent_sh_state_export_includes_known_user_state "test_agent_sh_state_export_includes_known_user_state"
  run_selected_test test_agent_sh_state_export_uses_installed_runtime_hooks "test_agent_sh_state_export_uses_installed_runtime_hooks"
  run_selected_test test_agent_sh_opencode_state_export_uses_runtime_hooks "test_agent_sh_opencode_state_export_uses_runtime_hooks"
  run_selected_test test_agent_sh_qwen_state_export_uses_runtime_hooks "test_agent_sh_qwen_state_export_uses_runtime_hooks"
  run_selected_test test_agent_sh_pi_state_export_uses_runtime_hooks "test_agent_sh_pi_state_export_uses_runtime_hooks"
  run_selected_test test_backup_codex_config_from_export_excludes_codex_packages "test_backup_codex_config_from_export_excludes_codex_packages"
  run_selected_test test_backup_known_state_from_container_excludes_codex_packages "test_backup_known_state_from_container_excludes_codex_packages"
  run_selected_test test_agent_sh_state_import_restores_known_user_state "test_agent_sh_state_import_restores_known_user_state"
  run_selected_test test_agent_sh_state_import_uses_installed_runtime_hooks "test_agent_sh_state_import_uses_installed_runtime_hooks"
  run_selected_test test_agent_sh_state_import_preserves_image_owned_codex_packages "test_agent_sh_state_import_preserves_image_owned_codex_packages"
  run_selected_test test_agent_sh_state_import_with_empty_stdin_preserves_existing_state "test_agent_sh_state_import_with_empty_stdin_preserves_existing_state"
  run_selected_test test_verify_restored_codex_state_passes_when_counts_match "test_verify_restored_codex_state_passes_when_counts_match"
  run_selected_test test_verify_restored_codex_state_fails_when_counts_drop "test_verify_restored_codex_state_fails_when_counts_drop"
  run_selected_test test_verify_restored_claude_state_passes_when_counts_match "test_verify_restored_claude_state_passes_when_counts_match"
  run_selected_test test_verify_restored_claude_state_fails_when_counts_drop "test_verify_restored_claude_state_fails_when_counts_drop"
  run_selected_test test_container_auth_info_uses_agent_sh_auth_read "test_container_auth_info_uses_agent_sh_auth_read"
  run_selected_test test_write_auth_blob_to_container_uses_agent_sh_auth_write "test_write_auth_blob_to_container_uses_agent_sh_auth_write"
  run_selected_test test_write_auth_blob_to_container_falls_back_for_legacy_codex "test_write_auth_blob_to_container_falls_back_for_legacy_codex"
  run_selected_test test_write_auth_blob_to_container_does_not_fallback_on_non_legacy_error "test_write_auth_blob_to_container_does_not_fallback_on_non_legacy_error"
  run_selected_test test_sync_runtime_auth_to_container_uses_runtime_parameters "test_sync_runtime_auth_to_container_uses_runtime_parameters"
  run_selected_test test_sync_runtime_auth_to_container_skips_matching_auth "test_sync_runtime_auth_to_container_skips_matching_auth"
  run_selected_test test_sync_runtime_auth_to_container_uses_newer_keychain_auth "test_sync_runtime_auth_to_container_uses_newer_keychain_auth"
  run_selected_test test_sync_runtime_auth_to_container_promotes_newer_container_auth "test_sync_runtime_auth_to_container_promotes_newer_container_auth"
  run_selected_test test_sync_runtime_auth_to_container_rejects_inconclusive_conflict "test_sync_runtime_auth_to_container_rejects_inconclusive_conflict"
  run_selected_test test_sync_runtime_auth_from_container_uses_runtime_parameters "test_sync_runtime_auth_from_container_uses_runtime_parameters"
  run_selected_test test_auth_info_from_json_parses_claude_oauth_payload "test_auth_info_from_json_parses_claude_oauth_payload"
  run_selected_test test_auth_info_from_json_preserves_escaped_tokens_and_normalizes_timestamps "test_auth_info_from_json_preserves_escaped_tokens_and_normalizes_timestamps"
  run_selected_test test_run_auth_flow_uses_agent_sh_auth_contract "test_run_auth_flow_uses_agent_sh_auth_contract"
  run_selected_test test_run_auth_flow_skips_keychain_write_when_auth_unchanged "test_run_auth_flow_skips_keychain_write_when_auth_unchanged"
  run_selected_test test_run_auth_flow_rejects_runtime_without_host_auth_support "test_run_auth_flow_rejects_runtime_without_host_auth_support"
  run_selected_test test_run_auth_flow_installs_runtime_before_claude_auth "test_run_auth_flow_installs_runtime_before_claude_auth"
  run_selected_test test_run_keychain_for_runtime_uses_runtime_specific_codex_slot "test_run_keychain_for_runtime_uses_runtime_specific_codex_slot"
  run_selected_test test_run_keychain_for_runtime_uses_runtime_specific_slot "test_run_keychain_for_runtime_uses_runtime_specific_slot"
  run_selected_test test_rm_force_stops_running_container_before_remove "test_rm_force_stops_running_container_before_remove"
  run_selected_test test_rescue_runs_command_in_temporary_backup_container "test_rescue_runs_command_in_temporary_backup_container"
  run_selected_test test_rescue_keep_leaves_container_running "test_rescue_keep_leaves_container_running"
  run_selected_test test_image_ref_for_runtime_falls_back_to_legacy_when_present "test_image_ref_for_runtime_falls_back_to_legacy_when_present"
  run_selected_test test_ls_raw_filters_non_codex_containers "test_ls_raw_filters_non_codex_containers"
  run_selected_test test_ls_reports_matching_snapshot_ref_by_default "test_ls_reports_matching_snapshot_ref_by_default"
  run_selected_test test_ls_reports_unknown_snapshot_when_timestamp_missing "test_ls_reports_unknown_snapshot_when_timestamp_missing"
  run_selected_test test_ls_keeps_row_when_inspect_fails "test_ls_keeps_row_when_inspect_fails"
  run_selected_test test_ls_handles_malformed_image_list_json "test_ls_handles_malformed_image_list_json"
  run_selected_test test_upgrade_backup_support_check "test_upgrade_backup_support_check"
  run_selected_test test_run_rejects_resource_flags_for_existing_container "test_run_rejects_resource_flags_for_existing_container"
  run_selected_test test_upgrade_rejects_no_backup_for_legacy_source "test_upgrade_rejects_no_backup_for_legacy_source"
  run_selected_test test_upgrade_uses_explicit_resource_overrides "test_upgrade_uses_explicit_resource_overrides"
  run_selected_test test_upgrade_can_rename_container_during_recreation "test_upgrade_can_rename_container_during_recreation"
  run_selected_test test_upgrade_export_failure_restarts_running_source "test_upgrade_export_failure_restarts_running_source"
  run_selected_test test_upgrade_copy_keeps_running_source_container "test_upgrade_copy_keeps_running_source_container"
  run_selected_test test_upgrade_copy_requires_new_name "test_upgrade_copy_requires_new_name"
  run_selected_test test_upgrade_dry_run_reports_plan_without_recreating_container "test_upgrade_dry_run_reports_plan_without_recreating_container"
  run_selected_test test_upgrade_copy_dry_run_reports_copy_plan "test_upgrade_copy_dry_run_reports_copy_plan"
  run_selected_test test_upgrade_warns_about_added_packages_missing_from_target_image "test_upgrade_warns_about_added_packages_missing_from_target_image"
  run_selected_test test_upgrade_reinstall_command_prefers_requested_apk_packages "test_upgrade_reinstall_command_prefers_requested_apk_packages"
  run_selected_test test_upgrade_reinstall_command_restores_missing_apk_repository_tags "test_upgrade_reinstall_command_restores_missing_apk_repository_tags"
  run_selected_test test_upgrade_reinstall_command_suggests_default_apk_edge_tags "test_upgrade_reinstall_command_suggests_default_apk_edge_tags"
  run_selected_test test_upgrade_warns_about_image_packages_removed_from_target "test_upgrade_warns_about_image_packages_removed_from_target"
  run_selected_test test_upgrade_reinstall_command_prefers_requested_dpkg_packages "test_upgrade_reinstall_command_prefers_requested_dpkg_packages"
  run_selected_test test_upgrade_package_warning_excludes_reinstalled_feature_packages "test_upgrade_package_warning_excludes_reinstalled_feature_packages"
  run_selected_test test_upgrade_reinstalls_added_runtimes_and_features_in_target "test_upgrade_reinstalls_added_runtimes_and_features_in_target"
  run_selected_test test_upgrade_reinstalls_missing_default_runtime_after_restore "test_upgrade_reinstalls_missing_default_runtime_after_restore"
  run_selected_test test_upgrade_warns_and_clears_missing_preferred_runtime "test_upgrade_warns_and_clears_missing_preferred_runtime"
  run_selected_test test_upgrade_uses_stored_baseline_when_current_image_is_missing "test_upgrade_uses_stored_baseline_when_current_image_is_missing"
  run_selected_test test_upgrade_accepts_workdir_override_when_original_mount_is_missing "test_upgrade_accepts_workdir_override_when_original_mount_is_missing"
  run_selected_test test_upgrade_allows_no_backup_for_modern_export_source "test_upgrade_allows_no_backup_for_modern_export_source"
  run_selected_test test_container_baseline_manifest_starts_stopped_container_and_restores_state "test_container_baseline_manifest_starts_stopped_container_and_restores_state"
  run_selected_test test_image_system_manifest_removes_temp_container_after_success "test_image_system_manifest_removes_temp_container_after_success"
  run_selected_test test_image_system_manifest_removes_temp_container_after_exec_failure "test_image_system_manifest_removes_temp_container_after_exec_failure"
  run_selected_test test_collect_upgrade_container_preflight_starts_stopped_container_once "test_collect_upgrade_container_preflight_starts_stopped_container_once"
  run_selected_test test_refresh_updates_managed_files_without_recreate "test_refresh_updates_managed_files_without_recreate"
  run_selected_test test_doctor_reports_state_permission_problems "test_doctor_reports_state_permission_problems"
  run_selected_test test_doctor_reports_container_startup_problem "test_doctor_reports_container_startup_problem"
  run_selected_test test_doctor_state_backup_readability_runs_real_export "test_doctor_state_backup_readability_runs_real_export"
  run_selected_test test_doctor_state_permission_script_attaches_stdin "test_doctor_state_permission_script_attaches_stdin"
  run_selected_test test_doctor_fix_repairs_state_permission_problems "test_doctor_fix_repairs_state_permission_problems"
  run_selected_test test_doctor_reports_runtime_health_problems "test_doctor_reports_runtime_health_problems"
  run_selected_test test_doctor_fix_repairs_runtime_health_problems "test_doctor_fix_repairs_runtime_health_problems"
  run_selected_test test_doctor_runtime_health_detects_codex_config_and_agents_problems "test_doctor_runtime_health_detects_codex_config_and_agents_problems"
  run_selected_test test_doctor_runtime_health_fix_reinstalls_runtime_and_restores_agents "test_doctor_runtime_health_fix_reinstalls_runtime_and_restores_agents"
  run_selected_test test_doctor_reports_runtime_state_summary "test_doctor_reports_runtime_state_summary"
  run_selected_test test_container_state_permission_script_repairs_unreadable_state "test_container_state_permission_script_repairs_unreadable_state"
  run_selected_test test_refresh_container_file_streams_source_via_stdin "test_refresh_container_file_streams_source_via_stdin"
  run_selected_test test_refresh_container_tree_suppresses_host_xattrs "test_refresh_container_tree_suppresses_host_xattrs"
  run_selected_test test_system_manifest_starts_stopped_container_and_restores_state "test_system_manifest_starts_stopped_container_and_restores_state"
  run_selected_test test_runtime_cmd_starts_stopped_container_and_restores_state "test_runtime_cmd_starts_stopped_container_and_restores_state"
  run_selected_test test_runtime_cmd_propagates_exec_failures "test_runtime_cmd_propagates_exec_failures"
  run_selected_test test_use_cmd_sets_preferred_runtime_in_stopped_container "test_use_cmd_sets_preferred_runtime_in_stopped_container"
  run_selected_test test_runtime_use_cmd_sets_preferred_runtime_in_stopped_container "test_runtime_use_cmd_sets_preferred_runtime_in_stopped_container"
  run_selected_test test_cleanup_temp_dir_handles_read_only_trees "test_cleanup_temp_dir_handles_read_only_trees"
  run_selected_test test_extract_container_export_rootfs_respects_oci_layer_order "test_extract_container_export_rootfs_respects_oci_layer_order"
  run_selected_test test_validate_backup_rootfs_accepts_shell_symlink "test_validate_backup_rootfs_accepts_shell_symlink"
  run_selected_test test_build_backup_image_uses_clean_context_for_exported_rootfs "test_build_backup_image_uses_clean_context_for_exported_rootfs"
  run_selected_test test_build_backup_image_preserves_flat_export_tar "test_build_backup_image_preserves_flat_export_tar"
  run_selected_test test_validate_backup_image_rejects_unbootable_backup "test_validate_backup_image_rejects_unbootable_backup"
  run_selected_test test_validate_backup_image_stops_validation_container_before_remove "test_validate_backup_image_stops_validation_container_before_remove"
  assert_selected_tests_ran

  log "PASS: all shell unit tests completed"
}

main "$@"
