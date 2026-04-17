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

  [ "$captured_pre_exec" = "run_pre_exec" ] || fail "Expected run_pre_exec, got: $captured_pre_exec"
  printf '%s\n' "$captured_cmd" | grep -Fq 'AGENTCTL_RUN_MODE=' || fail "Expected agent.sh launch wrapper, got: $captured_cmd"
  printf '%s\n' "$captured_cmd" | grep -Fq 'AGENTCTL_DEFAULT_PROFILE=' || fail "Expected profile to be passed to agent.sh, got: $captured_cmd"
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
}

test_run_cmd_runtime_selection_prepares_runtime_before_launch() {
  begin_test "run_cmd can select and install a runtime before launch"

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

  run_cmd --name unit-test-container --workdir "$workdir" --runtime claude --install-runtime --shell

  [ "$captured_pre_exec" = "run_pre_exec" ] || fail "Expected run_pre_exec, got: $captured_pre_exec"
  [ "$RUN_SELECTED_RUNTIME" = "claude" ] || fail "Expected runtime claude, got: $RUN_SELECTED_RUNTIME"
  [ "$RUN_INSTALL_RUNTIME" -eq 1 ] || fail "Expected install-runtime to be enabled"
  [ "$RUN_SYNC_SELECTED_RUNTIME_AUTH" -eq 1 ] || fail "Expected runtime auth sync to be enabled"
  [ "$RUN_LOCAL_MODEL_PREFLIGHT" -eq 0 ] || fail "Did not expect local-model preflight for Claude shell launch"
  [ "$captured_mem" = "4G" ] || fail "Expected Claude bootstrap run to request 4G, got: $captured_mem"
}

test_run_cmd_rejects_non_codex_profile() {
  begin_test "run_cmd rejects --profile for non-codex runtimes"

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
run_cmd --runtime claude --profile gemma
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "--profile only applies to the codex runtime"
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

test_run_cmd_rejects_openai_for_non_codex_runtime() {
  begin_test "run_cmd rejects --openai for non-codex runtimes"

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
run_cmd --runtime claude --openai
EOF
  chmod +x "$unit_script"

  run_capture bash "$unit_script"
  assert_status 1
  assert_contains "--openai currently requires --runtime codex"
}

test_run_pre_exec_syncs_selected_runtime_auth_when_available() {
  begin_test "run_pre_exec syncs selected runtime auth when available"

  load_codexctl_functions

  local call_log=""
  RUN_SELECTED_RUNTIME="claude"
  RUN_INSTALL_RUNTIME=1
  RUN_SYNC_SELECTED_RUNTIME_AUTH=1
  RUN_SYNC_OPENAI=0
  RUN_LOCAL_MODEL_PREFLIGHT=0
  RUN_UPDATE_CODEX=0

  run_agent_sh_in_container() {
    call_log="${call_log}$1:$2:$3"$'\n'
  }
  sync_runtime_auth_to_container_if_available() {
    call_log="${call_log}sync:$1:$2"$'\n'
  }

  run_capture run_pre_exec unit-test-container
  assert_status 0
  printf '%s' "$call_log" | grep -Fq $'unit-test-container:runtime:install' || fail "Expected runtime install call, got: $call_log"
  printf '%s' "$call_log" | grep -Fq $'unit-test-container:preferred:set' || fail "Expected preferred set call, got: $call_log"
  printf '%s' "$call_log" | grep -Fq $'sync:unit-test-container:claude' || fail "Expected runtime auth sync call, got: $call_log"
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
  local fake_bin
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$(make_fake_runtime_bin "$temp_home" codex)"

  run_capture env \
    HOME="$temp_home/home" \
    XDG_CONFIG_HOME="$temp_home/config" \
    PATH="$fake_bin:$PATH" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$TEST_ROOT/runtimes.d" \
    AGENTCTL_RUNTIME_ADAPTER_DIR="$TEST_ROOT/runtimes" \
    "$TEST_ROOT/agent.sh" runtime list
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
  begin_test "agent.sh runtime info reports claude runtime metadata"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_agent_sh_capture "$temp_home" runtime info claude
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "claude" and .installed == false and .install_method == "native-installer" and .capabilities.install == true and .capabilities.update == true and .capabilities.reset_config == true and .capabilities.auth_login == true and .capabilities.auth_read == true and .capabilities.auth_write == true and (.auth_formats | index("claude_ai_oauth_json") != null) and (.commands | index("runtime install claude") != null) and (.commands | index("auth login claude") != null)' >/dev/null || fail "Expected runtime info JSON for claude runtime, got: $RUN_OUTPUT"
}

test_agent_sh_claude_runtime_install_runs_native_installer() {
  begin_test "agent.sh claude runtime install runs the native installer"

  local temp_home
  local fake_bin
  local install_log
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  fake_bin="$temp_home/bin"
  install_log="$temp_home/install.log"
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

  run_capture env \
    HOME="$temp_home/home" \
    XDG_CONFIG_HOME="$temp_home/config" \
    PATH="$fake_bin:$PATH" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$TEST_ROOT/runtimes.d" \
    AGENTCTL_RUNTIME_ADAPTER_DIR="$TEST_ROOT/runtimes" \
    /bin/bash "$TEST_ROOT/agent.sh" runtime install claude
  assert_status 0
  [ -x "$fake_bin/claude" ] || fail "Expected fake claude launcher to be created by installer"
  grep -Fq 'info -e libgcc' "$install_log" || fail "Expected Alpine dependency verification for libgcc"
  grep -Fq 'info -e libstdc++' "$install_log" || fail "Expected Alpine dependency verification for libstdc++"
  grep -Fq 'info -e ripgrep' "$install_log" || fail "Expected Alpine dependency verification for ripgrep"
  grep -Fq 'installer-bash' "$install_log" || fail "Expected native installer script to be piped into bash"
  jq -er '.env.USE_BUILTIN_RIPGREP == "0"' "$temp_home/home/.claude/settings.json" >/dev/null || fail "Expected Claude settings.json to disable builtin ripgrep"

  run_capture env \
    HOME="$temp_home/home" \
    XDG_CONFIG_HOME="$temp_home/config" \
    PATH="$fake_bin:$PATH" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$TEST_ROOT/runtimes.d" \
    AGENTCTL_RUNTIME_ADAPTER_DIR="$TEST_ROOT/runtimes" \
    /bin/bash "$TEST_ROOT/agent.sh" preferred get
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

  run_capture env \
    HOME="$temp_home/home" \
    XDG_CONFIG_HOME="$temp_home/config" \
    PATH="$fake_bin:$PATH" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$TEST_ROOT/runtimes.d" \
    AGENTCTL_RUNTIME_ADAPTER_DIR="$TEST_ROOT/runtimes" \
    /bin/bash "$TEST_ROOT/agent.sh" runtime update claude
  assert_status 0
  grep -Fxq 'update' "$update_log" || fail "Expected claude update to be invoked"
}

test_agent_sh_claude_runtime_reset_config_restores_settings() {
  begin_test "agent.sh claude runtime reset-config restores settings"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  mkdir -p "$temp_home/home/.claude"
  printf '%s' '{"env":{"USE_BUILTIN_RIPGREP":"1"}}' >"$temp_home/home/.claude/settings.json"

  run_capture env \
    HOME="$temp_home/home" \
    XDG_CONFIG_HOME="$temp_home/config" \
    PATH="$PATH" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$TEST_ROOT/runtimes.d" \
    AGENTCTL_RUNTIME_ADAPTER_DIR="$TEST_ROOT/runtimes" \
    /bin/bash "$TEST_ROOT/agent.sh" runtime reset-config claude
  assert_status 0
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

  run_capture env \
    HOME="$temp_home/home" \
    XDG_CONFIG_HOME="$temp_home/config" \
    PATH="$fake_bin:$PATH" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$TEST_ROOT/runtimes.d" \
    AGENTCTL_RUNTIME_ADAPTER_DIR="$TEST_ROOT/runtimes" \
    /bin/bash "$TEST_ROOT/agent.sh" run
  assert_status 0
  grep -Fq -- '--cd /workdir' "$run_log" || fail "Expected codex run to include --cd /workdir"
}

test_agent_sh_claude_run_avoids_codex_specific_cd_flag() {
  begin_test "agent.sh claude run does not inject Codex-specific cd flag"

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
printf '%s\n' "\$*" >"$run_log"
exit 0
EOF
  chmod +x "$fake_bin/claude"

  run_capture env \
    HOME="$temp_home/home" \
    XDG_CONFIG_HOME="$temp_home/config" \
    PATH="$fake_bin:$PATH" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$TEST_ROOT/runtimes.d" \
    AGENTCTL_RUNTIME_ADAPTER_DIR="$TEST_ROOT/runtimes" \
    /bin/bash "$TEST_ROOT/agent.sh" run
  assert_status 0
  if grep -Fq -- '--cd /workdir' "$run_log"; then
    fail "Did not expect Claude run to receive --cd /workdir"
  fi
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

  run_capture env \
    HOME="$temp_home/home" \
    XDG_CONFIG_HOME="$temp_home/config" \
    PATH="$fake_bin:$PATH" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$TEST_ROOT/runtimes.d" \
    AGENTCTL_RUNTIME_ADAPTER_DIR="$TEST_ROOT/runtimes" \
    "$TEST_ROOT/agent.sh" preferred set codex
  assert_status 0

  run_capture env \
    HOME="$temp_home/home" \
    XDG_CONFIG_HOME="$temp_home/config" \
    PATH="$fake_bin:$PATH" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$TEST_ROOT/runtimes.d" \
    AGENTCTL_RUNTIME_ADAPTER_DIR="$TEST_ROOT/runtimes" \
    "$TEST_ROOT/agent.sh" preferred get
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

  run_capture env \
    HOME="$temp_home/home" \
    XDG_CONFIG_HOME="$temp_home/config" \
    PATH="$PATH" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$TEST_ROOT/runtimes.d" \
    AGENTCTL_RUNTIME_ADAPTER_DIR="$TEST_ROOT/runtimes" \
    "$TEST_ROOT/agent.sh" auth write codex json_refresh_token '{}'
  assert_status 1
  assert_contains "invalid auth payload for codex"
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
  local payload
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"
  payload='{"claudeAiOauth":{"accessToken":"access-token","refreshToken":"refresh-token","expiresAt":1776462236852},"claudeCodeState":{"oauthAccount":{"emailAddress":"user@example.com"},"hasCompletedOnboarding":true}}'

  run_capture env \
    HOME="$temp_home/home" \
    XDG_CONFIG_HOME="$temp_home/config" \
    PATH="$PATH" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$TEST_ROOT/runtimes.d" \
    AGENTCTL_RUNTIME_ADAPTER_DIR="$TEST_ROOT/runtimes" \
    "$TEST_ROOT/agent.sh" auth write claude claude_ai_oauth_json "$payload"
  assert_status 0
  jq -er '(.claudeAiOauth.refreshToken == "refresh-token") and (has("claudeCodeState") | not)' "$temp_home/home/.claude/.credentials.json" >/dev/null || fail "Expected Claude credentials file to contain only auth payload"
  jq -er '.oauthAccount.emailAddress == "user@example.com" and .hasCompletedOnboarding == true and (has("installMethod") | not) and (has("userID") | not)' "$temp_home/home/.claude.json" >/dev/null || fail "Expected Claude home state file to be restored minimally"
}

test_agent_sh_claude_auth_write_rejects_invalid_payload() {
  begin_test "agent.sh auth write rejects invalid claude auth data"

  local temp_home
  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/agent-sh-unit.XXXXXX")"
  register_dir_cleanup "$temp_home"

  run_capture env \
    HOME="$temp_home/home" \
    XDG_CONFIG_HOME="$temp_home/config" \
    PATH="$PATH" \
    AGENTCTL_RUNTIME_REGISTRY_DIR="$TEST_ROOT/runtimes.d" \
    AGENTCTL_RUNTIME_ADAPTER_DIR="$TEST_ROOT/runtimes" \
    "$TEST_ROOT/agent.sh" auth write claude claude_ai_oauth_json '{}'
  assert_status 1
  assert_contains "invalid auth payload for claude"
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

test_run_keychain_for_runtime_uses_legacy_codex_slot() {
  begin_test "run_keychain_for_runtime preserves the legacy codex keychain slot"

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
  grep -Fq 'service=codex-OpenAI-auth' "$env_log_file" || fail "Expected legacy codex keychain service name"
  grep -Fq 'account=device-auth-openAI' "$env_log_file" || fail "Expected legacy codex keychain account name"
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
  test_run_help_reports_runtime_options
  test_run_cmd_runtime_selection_prepares_runtime_before_launch
  test_run_cmd_rejects_non_codex_profile
  test_run_cmd_rejects_install_runtime_without_runtime
  test_run_cmd_rejects_openai_for_non_codex_runtime
  test_run_pre_exec_syncs_selected_runtime_auth_when_available
  test_sync_runtime_auth_to_container_if_available_skips_missing_keychain
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
  test_agent_sh_claude_runtime_install_runs_native_installer
  test_agent_sh_claude_runtime_update_calls_claude_update
  test_agent_sh_claude_runtime_reset_config_restores_settings
  test_agent_sh_codex_run_defaults_to_workdir_cd
  test_agent_sh_claude_run_avoids_codex_specific_cd_flag
  test_agent_sh_rejects_unknown_runtime
  test_agent_sh_preferred_round_trip
  test_agent_sh_preferred_set_rejects_uninstalled_runtime
  test_agent_sh_auth_read_rejects_invalid_codex_auth
  test_agent_sh_auth_write_rejects_invalid_codex_auth
  test_agent_sh_claude_auth_read_includes_optional_home_state
  test_agent_sh_claude_auth_read_rejects_invalid_credentials
  test_agent_sh_claude_auth_write_restores_credentials_and_home_state
  test_agent_sh_claude_auth_write_rejects_invalid_payload
  test_container_auth_info_uses_agent_sh_auth_read
  test_write_auth_blob_to_container_uses_agent_sh_auth_write
  test_sync_runtime_auth_to_container_uses_runtime_parameters
  test_sync_runtime_auth_from_container_uses_runtime_parameters
  test_auth_info_from_json_parses_claude_oauth_payload
  test_run_auth_flow_uses_agent_sh_auth_contract
  test_run_auth_flow_skips_keychain_write_when_auth_unchanged
  test_run_auth_flow_rejects_runtime_without_host_auth_support
  test_run_auth_flow_installs_runtime_before_claude_auth
  test_run_keychain_for_runtime_uses_legacy_codex_slot
  test_run_keychain_for_runtime_uses_runtime_specific_slot
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
