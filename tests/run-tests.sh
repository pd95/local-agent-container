#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=tests/testlib.sh
. "$SCRIPT_DIR/testlib.sh"

trap cleanup_and_report EXIT

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

ensure_agent_plain_image() {
  if image_exists agent-plain; then
    return 0
  fi

  run_capture "$AGENTCTL" build --image agent-plain
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

test_tool_home_smoke_codex_external_home() {
  begin_test "tool-home smoke keeps Codex tools outside mounted home"

  local name
  local temp_root
  local home_mount
  local work_mount
  name="$(unique_name tool-home-smoke)"
  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/agentctl tool home.XXXXXX")"
  register_dir_cleanup "$temp_root"
  home_mount="$temp_root/home"
  work_mount="$temp_root/workdir"
  mkdir -p "$home_mount" "$work_mount"
  printf 'host-marker\n' >"$home_mount/.agentctl-host-home-marker"
  register_container_cleanup "$name"

  ensure_agent_plain_image

  run_capture "$AGENTCTL" run \
    --name "$name" \
    --image agent-plain \
    --workdir "$work_mount" \
    --home "$home_mount" \
    --cmd true
  assert_status 0

  run_capture "$AGENTCTL" start --name "$name"
  assert_status 0

  run_capture "$AGENTCTL" exec --name "$name" --no-tty -- bash -lc '
set -euo pipefail

dump_diagnostics() {
  status=$?
  printf "\n--- tool-home diagnostics (exit %s) ---\n" "$status" >&2
  printf "PATH=%s\n" "$PATH" >&2 || true
  command -v codex >&2 || true
  command -v claude >&2 || true
  agent.sh runtime info codex >&2 || true
  agent.sh runtime info claude >&2 || true
  agent.sh system manifest >&2 || true
  find /home/coder -maxdepth 3 -print >&2 || true
  find /opt/agentctl -maxdepth 4 -print >&2 || true
  exit "$status"
}
trap dump_diagnostics ERR

test -f /home/coder/.agentctl-host-home-marker
grep -Fxq "host-marker" /home/coder/.agentctl-host-home-marker
printf "container-marker\n" >/home/coder/.agentctl-container-home-marker

assert_not_under_home() {
  case "$1" in
    /home/coder/*)
      printf "launcher resolved under mounted home: %s\n" "$1" >&2
      exit 1
      ;;
  esac
}

path_index() {
  needle="$1"
  printf "%s" "$PATH" | awk -v RS=: -v needle="$needle" '\''$0 == needle { print NR; found = 1; exit } END { if (!found) exit 1 }'\''
}

tools_idx="$(path_index /opt/agentctl/bin)"
local_idx="$(path_index /home/coder/.local/bin || true)"
if [ -n "$local_idx" ] && [ "$tools_idx" -ge "$local_idx" ]; then
  printf "/opt/agentctl/bin must precede /home/coder/.local/bin in PATH\n" >&2
  exit 1
fi

codex_info="$(agent.sh runtime info codex)"
printf "%s" "$codex_info" | jq -e \
  ".installed == true
  and (.command_path | startswith(\"/opt/agentctl/bin/\"))
  and ((.command_path | startswith(\"/home/coder/\")) | not)
  and .tools_home == \"/opt/agentctl\"
  and .tools_bin_dir == \"/opt/agentctl/bin\"
  and .runtime_tool_home == \"/opt/agentctl/codex\"" >/dev/null

codex_path="$(command -v codex)"
[ "$codex_path" = "/opt/agentctl/bin/codex" ] || {
  printf "expected codex at /opt/agentctl/bin/codex, got %s\n" "$codex_path" >&2
  exit 1
}
assert_not_under_home "$codex_path"

codex --version
CODEX_HOME=/home/coder/.codex codex app-server --help >/tmp/codex-app-server-help.txt
agent.sh runtime update codex
codex_after_update="$(command -v codex)"
assert_not_under_home "$codex_after_update"
[ "$codex_after_update" = "/opt/agentctl/bin/codex" ]

test ! -e /home/coder/.codex/packages

manifest="$(agent.sh system manifest)"
printf "%s" "$manifest" | jq -e \
  ".tools_home == \"/opt/agentctl\"
  and .tools_bin_dir == \"/opt/agentctl/bin\"
  and (.installed_runtimes | index(\"codex\") != null)" >/dev/null

state_tar=/tmp/agentctl-state.tar
mkdir -p /home/coder/.codex/packages/standalone/current/bin
printf "stale-package\n" >/home/coder/.codex/packages/standalone/current/bin/codex
printf "{\"refresh_token\":\"dummy\"}\n" >/home/coder/.codex/auth.json
bash /usr/local/bin/agent.sh state export >"$state_tar"
if tar -tf "$state_tar" | grep -Eq "^\\.codex/packages(/|$)|^opt/agentctl(/|$)"; then
  tar -tf "$state_tar" >&2
  exit 1
fi
  '
  assert_status 0
  if ! grep -Fxq "container-marker" "$home_mount/.agentctl-container-home-marker"; then
    printf '%s\n' "$RUN_OUTPUT" >&2
    fail "Expected /home/coder marker written in container to appear in host home mount"
  fi

  run_capture "$AGENTCTL" rm --name "$name" --force
  assert_status 0
}

test_tool_home_smoke_claude_external_home_when_installed() {
  begin_test "tool-home smoke keeps Claude tools outside mounted home when installed"

  local name
  local temp_root
  local home_mount
  local work_mount
  name="$(unique_name tool-home-claude)"
  temp_root="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-tool-home-claude.XXXXXX")"
  register_dir_cleanup "$temp_root"
  home_mount="$temp_root/home"
  work_mount="$temp_root/workdir"
  mkdir -p "$home_mount" "$work_mount"
  register_container_cleanup "$name"

  ensure_agent_plain_image

  run_capture "$AGENTCTL" run \
    --name "$name" \
    --image agent-plain \
    --workdir "$work_mount" \
    --home "$home_mount" \
    --cmd true
  assert_status 0

  run_capture "$AGENTCTL" start --name "$name"
  assert_status 0

  run_capture "$AGENTCTL" exec --name "$name" --no-tty -- bash -lc '
set -euo pipefail

dump_diagnostics() {
  status=$?
  printf "\n--- tool-home Claude diagnostics (exit %s) ---\n" "$status" >&2
  printf "PATH=%s\n" "$PATH" >&2 || true
  command -v claude >&2 || true
  agent.sh runtime info claude >&2 || true
  agent.sh system manifest >&2 || true
  find /home/coder -maxdepth 3 -print >&2 || true
  find /opt/agentctl -maxdepth 4 -print >&2 || true
  exit "$status"
}
trap dump_diagnostics ERR

assert_not_under_home() {
  case "$1" in
    /home/coder/*)
      printf "launcher resolved under mounted home: %s\n" "$1" >&2
      exit 1
      ;;
  esac
}

claude_info="$(agent.sh runtime info claude)"
if ! printf "%s" "$claude_info" | jq -e ".installed == true" >/dev/null; then
  printf "Skipping Claude tool-home smoke because claude is not installed in this image.\n"
  exit 0
fi

printf "%s" "$claude_info" | jq -e \
  ".installed == true
  and (.command_path | startswith(\"/opt/agentctl/bin/\"))
  and ((.command_path | startswith(\"/home/coder/\")) | not)
  and .runtime_tool_home == \"/opt/agentctl/claude\"" >/dev/null

claude_path="$(command -v claude)"
assert_not_under_home "$claude_path"
case "$claude_path" in
  /opt/agentctl/bin/claude) ;;
  *) printf "expected claude at /opt/agentctl/bin/claude, got %s\n" "$claude_path" >&2; exit 1 ;;
esac

claude --version
agent.sh runtime update claude
claude_after_update="$(command -v claude)"
assert_not_under_home "$claude_after_update"
[ "$claude_after_update" = "/opt/agentctl/bin/claude" ]

agent.sh system manifest | jq -e ".installed_runtimes | index(\"claude\") != null" >/dev/null
'
  assert_status 0

  run_capture "$AGENTCTL" rm --name "$name" --force
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
  local versioned_image

  run_capture "$AGENTCTL" build --image agent-plain --rebuild
  assert_status 0
  assert_contains "Building image tags: agent-plain,"
  versioned_image="$(printf '%s\n' "$RUN_OUTPUT" | sed -n 's/^Building image tags: agent-plain, \(agent-plain:[^[:space:]]*\)$/\1/p' | tail -n 1)"
  [ -n "$versioned_image" ] || fail "Could not parse versioned build image from output: $RUN_OUTPUT"
  register_image_cleanup "$versioned_image"

  if ! "$CONTAINER_CMD" ls -a 2>/dev/null | grep -q -E '^buildkit[[:space:]]+.*[[:space:]]stopped([[:space:]]|$)'; then
    printf '%s\n' "$RUN_OUTPUT" >&2
    fail "Expected buildkit to be stopped after agentctl build"
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

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd bash -lc '
    mkdir -p /home/coder/.codex /home/coder/.claude /home/coder/.config/agentctl
    echo upgrade-ok >/home/coder/.codex/upgrade-smoke.txt
    printf "{\"refresh_token\":\"codex-token\"}\n" >/home/coder/.codex/auth.json
    printf "codex\n" >/home/coder/.config/agentctl/preferred-runtime
    printf "{\"claudeAiOauth\":{\"accessToken\":\"a\",\"refreshToken\":\"should-not-survive\",\"expiresAt\":1}}\n" >/home/coder/.claude/.credentials.json
    printf "{\"hasCompletedOnboarding\":true}\n" >/home/coder/.claude.json
  '
  assert_status 0

  run_capture "$AGENTCTL" upgrade --name "$name" --no-backup
  assert_status 0
  assert_contains "Skipping backup image export for $name"
  assert_contains "Upgrade complete: $name (backup skipped)"

  if [ -n "$(list_backup_images "$backup_base")" ]; then
    printf '%s\n' "$(list_backup_images "$backup_base")" >&2
    fail "Backup images were created unexpectedly for $name"
  fi

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd bash -lc '
    cat /home/coder/.codex/upgrade-smoke.txt
    jq -er '"'"'.refresh_token == "codex-token"'"'"' /home/coder/.codex/auth.json >/dev/null
    test "$(cat /home/coder/.config/agentctl/preferred-runtime)" = "codex"
    test ! -e /home/coder/.claude/.credentials.json
    test ! -e /home/coder/.claude.json
    echo runtime-state-ok
  '
  assert_status 0
  assert_contains "upgrade-ok"
  assert_contains "runtime-state-ok"
}

test_upgrade_repeats_tagged_apk_reinstall_instructions() {
  begin_test "upgrade repeats complete tagged APK reinstall instructions"
  local name
  local workdir
  local reinstall_command
  local main_repository
  local community_repository
  local main_restore_fragment
  local community_restore_fragment
  local preflight_output
  local reminder_output

  name="$(unique_name upgrade-tagged-apk)"
  workdir="$(new_workdir)"
  register_container_cleanup "$name"
  reinstall_command="agentctl su-exec --name $name apk add --no-cache nano@agentctlmain tree@agentctlcommunity"

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd true
  assert_status 0

  run_capture "$AGENTCTL" start --name "$name"
  assert_status 0

  # Give packages from main and community one distinct repository tag each.
  run_capture "$CONTAINER_CMD" exec -u 0 "$name" sh -lc '
set -e
main_repository="$(sed -n "/\/main$/ { p; q; }" /etc/apk/repositories)"
community_repository="$(sed -n "/\/community$/ { p; q; }" /etc/apk/repositories)"
[ -n "$main_repository" ] || {
  printf "agent-plain has no APK main repository\n" >&2
  exit 1
}
[ -n "$community_repository" ] || {
  printf "agent-plain has no APK community repository\n" >&2
  exit 1
}
! apk info -e nano || {
  printf "nano is already part of agent-plain; choose another main package fixture\n" >&2
  exit 1
}
! apk info -e tree || {
  printf "tree is already part of agent-plain; choose another community package fixture\n" >&2
  exit 1
}
printf "@agentctlmain %s\n" "$main_repository" >>/etc/apk/repositories
printf "@agentctlcommunity %s\n" "$community_repository" >>/etc/apk/repositories
apk update
apk add --no-cache nano@agentctlmain tree@agentctlcommunity
apk info -e nano
apk info -e tree
printf "AGENTCTL_MAIN_REPOSITORY=%s\n" "$main_repository"
printf "AGENTCTL_COMMUNITY_REPOSITORY=%s\n" "$community_repository"
'
  assert_status 0
  main_repository="$(printf '%s\n' "$RUN_OUTPUT" | sed -n 's/^AGENTCTL_MAIN_REPOSITORY=//p' | tail -n 1)"
  community_repository="$(printf '%s\n' "$RUN_OUTPUT" | sed -n 's/^AGENTCTL_COMMUNITY_REPOSITORY=//p' | tail -n 1)"
  [ -n "$main_repository" ] || fail "Could not capture the tagged APK main repository"
  [ -n "$community_repository" ] || fail "Could not capture the tagged APK community repository"
  main_restore_fragment="grep -Fxq '\\''@agentctlmain $main_repository'\\'' /etc/apk/repositories"
  community_restore_fragment="grep -Fxq '\\''@agentctlcommunity $community_repository'\\'' /etc/apk/repositories"

  run_capture "$AGENTCTL" upgrade --name "$name" --image agent-plain --no-backup
  assert_status 0
  assert_contains "Upgrade complete: $name (backup skipped)"
  assert_contains "Reminder: reinstall top-level packages removed by the upgrade if you still need them:"

  preflight_output="$(printf '%s\n' "$RUN_OUTPUT" | sed '/^Reminder: reinstall top-level packages removed by the upgrade if you still need them:$/,$d')"
  reminder_output="$(printf '%s\n' "$RUN_OUTPUT" | sed -n '/^Reminder: reinstall top-level packages removed by the upgrade if you still need them:$/,$p')"

  printf '%s\n' "$preflight_output" | grep -Fq "Restore APK repository tag(s) before reinstalling tagged packages:" \
    || fail "Expected tagged APK repository instructions during upgrade preflight"
  printf '%s\n' "$reminder_output" | grep -Fq "Restore APK repository tag(s) before reinstalling tagged packages:" \
    || fail "Expected tagged APK repository instructions in the final reminder"
  printf '%s\n' "$preflight_output" | grep -Fq "$main_restore_fragment" \
    || fail "Expected the exact APK main repository restore command during upgrade preflight"
  printf '%s\n' "$preflight_output" | grep -Fq "$community_restore_fragment" \
    || fail "Expected the exact APK community repository restore command during upgrade preflight"
  printf '%s\n' "$reminder_output" | grep -Fq "$main_restore_fragment" \
    || fail "Expected the exact APK main repository restore command in the final reminder"
  printf '%s\n' "$reminder_output" | grep -Fq "$community_restore_fragment" \
    || fail "Expected the exact APK community repository restore command in the final reminder"
  printf '%s\n' "$preflight_output" | grep -Fq "agentctl su-exec --name $name apk update" \
    || fail "Expected apk update during upgrade preflight"
  printf '%s\n' "$reminder_output" | grep -Fq "agentctl su-exec --name $name apk update" \
    || fail "Expected apk update in the final reminder"
  printf '%s\n' "$preflight_output" | grep -Fq "$reinstall_command" \
    || fail "Expected the tagged APK reinstall command during upgrade preflight"
  printf '%s\n' "$reminder_output" | grep -Fq "$reinstall_command" \
    || fail "Expected the tagged APK reinstall command in the final reminder"

  run_capture "$CONTAINER_CMD" exec "$name" sh -lc '! apk info -e nano && ! apk info -e tree'
  assert_status 0
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

test_upgrade_backup_restores_home_and_boots_rescue_image() {
  begin_test "upgrade backup restores home state and creates a bootable full-rootfs rescue image"
  local name
  local workdir
  local backup_image
  local rescue

  name="$(unique_name upgrade-state-backup)"
  workdir="$(new_workdir)"
  backup_image="$(printf '%s\n' "${name}-backup-smoke" | tr '[:upper:]' '[:lower:]')"
  rescue="$(printf '%s\n' "${name}-rescue" | tr '[:upper:]' '[:lower:]')"
  register_container_cleanup "$name"
  register_raw_container_cleanup "$rescue"
  register_backup_cleanup "$backup_image"

  run_capture "$AGENTCTL" run --name "$name" --image agent-python --mem 4G --workdir "$workdir" --cmd true
  assert_status 0

  run_capture "$AGENTCTL" start --name "$name"
  assert_status 0

  run_capture "$CONTAINER_CMD" exec "$name" setpriv --inh-caps=-all --ambient-caps=-all --no-new-privs -- sh -lc '
set -e
mkdir -p /home/coder/.codex /home/coder/.config/agentctl /home/coder/.claude
printf "{\"refresh_token\":\"dummy-codex-token\"}\n" >/home/coder/.codex/auth.json
printf "codex\n" >/home/coder/.config/agentctl/preferred-runtime
printf "{\"claudeAiOauth\":{\"accessToken\":\"a\",\"refreshToken\":\"dummy-claude-token\",\"expiresAt\":1}}\n" >/home/coder/.claude/.credentials.json
printf "{\"hasCompletedOnboarding\":true}\n" >/home/coder/.claude.json
'
  assert_status 0

  run_capture "$CONTAINER_CMD" exec -u 0 "$name" sh -lc '
set -e
mkdir -p /etc/agentctl
printf "etc-marker-before-upgrade\n" >/etc/agentctl/smoke-marker
chown -R coder:coder /home/coder
'
  assert_status 0

  run_capture "$AGENTCTL" upgrade --name "$name" --image agent-python --mem 4G --backup-image "$backup_image"
  assert_status 0
  assert_contains "Upgrade complete: $name (backup image: $backup_image)"

  if ! container_running "$name"; then
    run_capture "$AGENTCTL" start --name "$name"
    assert_status 0
  fi

  run_capture "$CONTAINER_CMD" exec "$name" setpriv --inh-caps=-all --ambient-caps=-all --no-new-privs -- sh -lc '
set -e
grep -q dummy-codex-token /home/coder/.codex/auth.json
test "$(cat /home/coder/.config/agentctl/preferred-runtime)" = codex
test "$(stat -c "%U:%G" /home/coder/.config)" = coder:coder
echo home-state-restored
'
  assert_status 0
  assert_contains "home-state-restored"

  run_capture "$AGENTCTL" rescue --image "$backup_image" --name "$rescue" --cmd sh -lc '
set -e
grep -q dummy-codex-token /home/coder/.codex/auth.json
test "$(cat /home/coder/.config/agentctl/preferred-runtime)" = codex
test "$(cat /etc/agentctl/smoke-marker)" = etc-marker-before-upgrade
test -x /bin/sh -o -x /usr/bin/sh
test "$(stat -c "%U:%G" /home/coder/.config)" = coder:coder
echo backup-image-rootfs-valid
'
  assert_status 0
  assert_contains "backup-image-rootfs-valid"
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

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --reset-config --yes --cmd bash -lc 'if diff -q /etc/agentctl/codex/config.toml /home/coder/.codex/config.toml && diff -q /etc/agentctl/codex/gpt-oss.config.toml /home/coder/.codex/gpt-oss.config.toml && diff -q /etc/agentctl/codex/local_models.json /home/coder/.codex/local_models.json && test -L /home/coder/.codex/AGENTS.md && [ "$(readlink /home/coder/.codex/AGENTS.md)" = "/etc/agentctl/image.md" ]; then echo reset-config-ok; else exit 1; fi'
  assert_status 0
  assert_contains "reset-config-ok"
}

test_refresh_reset_config_restores_defaults_and_stopped_state() {
  begin_test "refresh --reset-config restores defaults and preserves stopped state"
  local name
  local workdir

  name="$(unique_name refresh-reset-config)"
  workdir="$(new_workdir)"
  register_container_cleanup "$name"

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd bash -lc 'mkdir -p /home/coder/.codex && printf "# legacy-config\\n" >/home/coder/.codex/config.toml && rm -f /home/coder/.codex/AGENTS.md && printf "legacy-agents\\n" >/home/coder/.codex/AGENTS.md'
  assert_status 0
  run_capture "$AGENTCTL" stop --name "$name"
  assert_status 0

  run_capture "$AGENTCTL" refresh --name "$name" --reset-config --yes
  assert_status 0
  assert_contains "Active Codex configuration reset from refreshed defaults."
  run_capture "$CONTAINER_CMD" ls --quiet
  assert_status 0
  if printf '%s\n' "$RUN_OUTPUT" | grep -Fqx -- "$name"; then fail "refresh --reset-config did not restore stopped state"; fi

  run_capture "$CONTAINER_CMD" start "$name"
  assert_status 0
  run_capture "$CONTAINER_CMD" exec "$name" sh -lc 'diff -q /etc/agentctl/codex/config.toml /home/coder/.codex/config.toml && test -L /home/coder/.codex/AGENTS.md && test "$(readlink /home/coder/.codex/AGENTS.md)" = /etc/agentctl/image.md'
  assert_status 0
  run_capture "$AGENTCTL" stop --name "$name"
  assert_status 0
}

test_image_contains_runtime_defaults_and_version_markers() {
  begin_test "image contains normalized defaults and separate version markers"
  local workdir

  workdir="$(new_workdir)"
  run_capture "$AGENTCTL" run --image agent-plain --temp --workdir "$workdir" --cmd sh -lc '
    test -f /etc/agentctl/codex/config.toml
    test -f /etc/agentctl/claude/settings.json
    test -f /etc/agentctl/image-version
    test -f /etc/agentctl/tooling-version
    test "$(cat /etc/agentctl/image-version)" = "$(cat /etc/agentctl/tooling-version)"
    ! find /etc/agentctl /home/coder/.codex -name .gitkeep -print | grep -q .
    echo runtime-defaults-and-versions-ok
  '
  assert_status 0
  assert_contains "runtime-defaults-and-versions-ok"
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
  assert_contains "Overwriting config.toml, default profiles, local_models.json in ~/.codex/ and recreating ~/.codex/AGENTS.md in $name"
  assert_contains "Upgrade complete: $name (backup skipped)"

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd bash -lc 'if diff -q /etc/agentctl/codex/config.toml /home/coder/.codex/config.toml && diff -q /etc/agentctl/codex/gpt-oss.config.toml /home/coder/.codex/gpt-oss.config.toml && diff -q /etc/agentctl/codex/local_models.json /home/coder/.codex/local_models.json && test -L /home/coder/.codex/AGENTS.md && [ "$(readlink /home/coder/.codex/AGENTS.md)" = "/etc/agentctl/image.md" ]; then echo overwrite-config-ok; else exit 1; fi'
  assert_status 0
  assert_contains "overwrite-config-ok"
}

test_system_manifest_requested_packages_on_agent_plain_apk() {
  begin_test "system manifest reports requested apk packages on agent-plain"
  local name
  local workdir

  name="$(unique_name manifest-apk)"
  workdir="$(new_workdir)"
  register_container_cleanup "$name"

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --cmd true
  assert_status 0

  run_capture "$AGENTCTL" refresh --name "$name"
  assert_status 0

  run_capture "$AGENTCTL" system-manifest --name "$name"
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '
    .package_manager == "apk"
    and (.packages | index("bash"))
    and (.requested_packages | index("bash"))
    and (.requested_packages | index("git"))
  ' >/dev/null || fail "Expected requested apk packages in system manifest, got: $RUN_OUTPUT"
}

test_system_manifest_requested_packages_on_agent_swift_dpkg() {
  begin_test "system manifest reports requested dpkg packages on agent-swift"
  local name
  local workdir

  name="$(unique_name manifest-dpkg)"
  workdir="$(new_workdir)"
  register_container_cleanup "$name"

  run_capture "$AGENTCTL" run --name "$name" --image agent-swift --workdir "$workdir" --cmd true
  assert_status 0

  run_capture "$AGENTCTL" refresh --name "$name"
  assert_status 0

  run_capture "$AGENTCTL" system-manifest --name "$name"
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '
    .package_manager == "dpkg"
    and (.packages | index("zsh"))
    and (.requested_packages | index("zsh"))
    and (.requested_packages | index("make"))
  ' >/dev/null || fail "Expected requested dpkg packages in system manifest, got: $RUN_OUTPUT"
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
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and .install_method == "standalone-installer" and .preferred_runtime == "codex"' >/dev/null || fail "Expected runtime info JSON for codex, got: $RUN_OUTPUT"

  run_capture "$AGENTCTL" runtime --name "$name" capabilities codex
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and (.commands | index("runtime capabilities codex") != null) and (.commands | index("runtime install codex") != null)' >/dev/null || fail "Expected runtime capabilities JSON for codex, got: $RUN_OUTPUT"

  run_capture "$AGENTCTL" use --name "$name" codex
  assert_status 0
  assert_contains "Preferred runtime set to codex in $name"

  run_capture "$CONTAINER_CMD" exec "$name" setpriv --inh-caps=-all --ambient-caps=-all --no-new-privs -- cat /home/coder/.config/agentctl/preferred-runtime
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

  run_capture "$CONTAINER_CMD" exec "$name" setpriv --inh-caps=-all --ambient-caps=-all --no-new-privs -- bash -lc '
    bash /usr/local/bin/agent.sh runtime info codex \
      | jq -e '"'"'.runtime == "codex" and .install_method == "standalone-installer"'"'"' >/dev/null
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

test_ssh_feature_build_and_forwarding_lifecycle() {
  begin_test "SSH forwarding feature preinstall survives upgrade and can be disabled"
  local name workdir versioned_image

  [ -n "${SSH_AUTH_SOCK:-}" ] || fail "SSH forwarding test requires SSH_AUTH_SOCK"
  [ -S "$SSH_AUTH_SOCK" ] || fail "SSH forwarding test requires an existing SSH_AUTH_SOCK socket: $SSH_AUTH_SOCK"
  name="$(unique_name ssh-forwarding)"
  workdir="$(new_workdir)"
  register_container_cleanup "$name"

  run_capture "$AGENTCTL" build --image agent-plain --features ssh --rebuild
  assert_status 0
  versioned_image="$(printf '%s\n' "$RUN_OUTPUT" | sed -n 's/^Building image tags: agent-plain, \(agent-plain:[^[:space:]]*\)$/\1/p' | tail -n 1)"
  [ -n "$versioned_image" ] || fail "Could not parse versioned SSH build image from output: $RUN_OUTPUT"
  register_image_cleanup "$versioned_image"

  run_capture "$AGENTCTL" run --name "$name" --image agent-plain --workdir "$workdir" --ssh --cmd true
  assert_status 0
  assert_not_contains "Installing requested feature"

  run_capture "$CONTAINER_CMD" inspect "$name"
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -e '(if type == "array" then .[0] else . end) | .configuration.ssh == true' >/dev/null \
    || fail "Expected SSH forwarding in container inspect"

  run_capture "$AGENTCTL" start --name "$name"
  assert_status 0
  run_capture "$AGENTCTL" exec --name "$name" --no-tty -- sh -lc '
set -u
command -v ssh >/dev/null
command -v ssh-add >/dev/null
test -S "${SSH_AUTH_SOCK:-/var/host-services/ssh-auth.sock}"
output="$(ssh-add -l 2>&1)"
status=$?
[ "$status" -le 1 ]
case "$output" in *"Could not open a connection"*) exit 1 ;; esac
  '
  assert_status 0

  # Rebuild the target without preinstalled SSH to verify that preserved SSH
  # forwarding ensures its required client feature is available.
  run_capture "$AGENTCTL" build --image agent-plain --rebuild
  assert_status 0
  versioned_image="$(printf '%s\n' "$RUN_OUTPUT" | sed -n 's/^Building image tags: agent-plain, \(agent-plain:[^[:space:]]*\)$/\1/p' | tail -n 1)"
  [ -n "$versioned_image" ] || fail "Could not parse versioned plain build image from output: $RUN_OUTPUT"
  register_image_cleanup "$versioned_image"

  run_capture "$AGENTCTL" upgrade --name "$name" --no-backup
  assert_status 0
  run_capture "$CONTAINER_CMD" inspect "$name"
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -e '(if type == "array" then .[0] else . end) | .configuration.ssh == true' >/dev/null \
    || fail "Expected upgrade to preserve SSH forwarding"
  run_capture "$AGENTCTL" feature --name "$name" info ssh
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -e '.installed == true' >/dev/null \
    || fail "Expected preserved SSH forwarding to ensure the SSH client feature"

  # --no-ssh changes forwarding only. Explicit recovery keeps the independent
  # SSH client feature installed while that forwarding mount is removed.
  run_capture "$AGENTCTL" upgrade --name "$name" --no-backup --no-ssh --restore
  assert_status 0
  run_capture "$CONTAINER_CMD" inspect "$name"
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -e '(if type == "array" then .[0] else . end) | (.configuration.ssh // false) == false' >/dev/null \
    || fail "Expected --no-ssh to disable forwarding"
  run_capture "$AGENTCTL" feature --name "$name" info ssh
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -e '.installed == true' >/dev/null || fail "Expected SSH client feature to remain installed"
}

test_host_socket_mount_lifecycle() {
  begin_test "host Unix socket mount survives restart, upgrade, replacement, copy, and removal"
  local name copy_name workdir socket_dir socket_one socket_two guest_socket server_script

  command -v python3 >/dev/null 2>&1 || fail "socket-mount integration test requires host python3"
  name="$(unique_name socket-mount)"
  copy_name="${name}-copy"
  workdir="$(new_workdir)"
  socket_dir="$(mktemp -d /tmp/agentctl-sock.XXXXXX)"
  register_dir_cleanup "$socket_dir"
  socket_one="$socket_dir/one.sock"
  socket_two="$socket_dir/two.sock"
  guest_socket="/tmp/agentctl-test.sock"
  server_script="$socket_dir/server.py"
  register_container_cleanup "$name"
  register_container_cleanup "$copy_name"

  cat >"$server_script" <<'PY'
import os
import socket
import sys

path, response = sys.argv[1:]
server = socket.socket(socket.AF_UNIX)
server.bind(path)
os.chmod(path, 0o666)
server.listen()
while True:
    connection, _ = server.accept()
    with connection:
        request = connection.recv(1024)
        connection.sendall(response.encode() + b":" + request)
PY
  python3 "$server_script" "$socket_one" one &
  register_pid_cleanup "$!"
  python3 "$server_script" "$socket_two" two &
  register_pid_cleanup "$!"
  for _ in 1 2 3 4 5; do
    [ -S "$socket_one" ] && [ -S "$socket_two" ] && break
    sleep 1
  done
  [ -S "$socket_one" ] && [ -S "$socket_two" ] || fail "host socket servers did not start"

  if ! image_exists agent-python; then
    run_capture "$AGENTCTL" build --image agent-python
    assert_status 0
  fi

  assert_guest_socket_response() {
    local target_name="$1"
    local expected="$2"
    run_capture "$AGENTCTL" exec --name "$target_name" --no-tty -- python3 -c \
      'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"ping"); print(s.recv(1024).decode())' \
      "$guest_socket"
    assert_status 0
    assert_contains "$expected:ping"
  }

  run_capture "$AGENTCTL" run --name "$name" --image agent-python --workdir "$workdir" \
    --mount-socket "$socket_one:$guest_socket" --cmd python3 -c \
    'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"ping"); print(s.recv(1024).decode())' \
    "$guest_socket"
  assert_status 0
  assert_contains "one:ping"

  run_capture "$AGENTCTL" start --name "$name"
  assert_status 0
  assert_guest_socket_response "$name" one
  run_capture "$AGENTCTL" restart --name "$name"
  assert_status 0
  assert_guest_socket_response "$name" one
  run_capture "$AGENTCTL" stop --name "$name"
  assert_status 0

  run_capture "$AGENTCTL" upgrade --name "$name" --no-backup
  assert_status 0
  run_capture "$AGENTCTL" start --name "$name"
  assert_status 0
  assert_guest_socket_response "$name" one
  run_capture "$AGENTCTL" stop --name "$name"
  assert_status 0

  run_capture "$AGENTCTL" upgrade --name "$name" --no-backup --mount-socket "$socket_two:$guest_socket"
  assert_status 0
  run_capture "$AGENTCTL" start --name "$name"
  assert_status 0
  assert_guest_socket_response "$name" two
  run_capture "$AGENTCTL" stop --name "$name"
  assert_status 0

  run_capture "$AGENTCTL" upgrade --name "$name" --new-name "$copy_name" --copy
  assert_status 0
  run_capture "$AGENTCTL" start --name "$copy_name"
  assert_status 0
  assert_guest_socket_response "$copy_name" two
  run_capture "$AGENTCTL" stop --name "$copy_name"
  assert_status 0

  run_capture "$AGENTCTL" upgrade --name "$name" --no-backup --unmount-socket "$guest_socket"
  assert_status 0
  run_capture "$CONTAINER_CMD" inspect "$name"
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -e --arg destination "$guest_socket" '
    (if type == "array" then .[0] else . end)
    | [(.configuration.mounts // .mounts // [])[]
       | (.destination // .dst // .target // .containerPath // "")]
    | index($destination) == null
  ' >/dev/null || fail "Expected socket mapping removal in inspect: $RUN_OUTPUT"
}

test_managed_mcp_bridge_lifecycle() {
  begin_test "managed MCP bridge exchanges traffic and survives start, restart, upgrade, and disable"
  local name workdir marker node_path definition registry port debug_dir http_pid http_port_file http_port credential token rotated_token expected_auth_file

  command -v node >/dev/null 2>&1 || fail "managed MCP integration test requires host Node.js"
  name="$(unique_name managed-mcp)"
  workdir="$(new_workdir)"
  marker="$workdir/mcp-started"
  node_path="$(command -v node)"
  registry="$HOME/Library/Application Support/agentctl/mcp/$name.json"
  port=47123
  debug_dir="$TEST_ROOT/tmp/mcp/$name"
  mkdir -p "$debug_dir"
  chmod 700 "$TEST_ROOT/tmp" "$debug_dir" 2>/dev/null || true
  export AGENTCTL_MCP_LOG_DIR="$debug_dir"
  register_container_cleanup "$name"
  credential="${name}-http-token"
  token="phase4-test-token-${name}"
  rotated_token="${token}-rotated"
  register_mcp_credential_cleanup "$credential"
  printf '%s' "$token" | "$AGENTCTL" mcp credential set "$credential" --stdin >/dev/null
  http_port_file="$debug_dir/http-port"
  expected_auth_file="$debug_dir/expected-authorization.sha256"; printf 'Bearer %s' "$token" | shasum -a 256 | awk '{print $1}' >"$expected_auth_file"
  AGENTCTL_FAKE_HTTP_ABORTED="$debug_dir/http-aborted" AGENTCTL_FAKE_HTTP_EXPECTED_AUTH_HASH_FILE="$expected_auth_file" node "$TEST_ROOT/tests/fixtures/fake-http-mcp-server.mjs" >"$http_port_file" 2>"$debug_dir/http-upstream.log" &
  http_pid=$!; register_pid_cleanup "$http_pid"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$http_port_file" ] && break; sleep 0.1; done
  [ -s "$http_port_file" ] || fail "fake HTTP MCP upstream did not report its port"
  http_port="$(sed -n '1p' "$http_port_file")"

  # Reuse the current image on iterative runs. Set AGENTCTL_MCP_TEST_REBUILD=1
  # when validating image assembly itself or after changing feature assets.
  if ! image_exists agent-python || [ "${AGENTCTL_MCP_TEST_REBUILD:-0}" = 1 ]; then
    run_capture "$AGENTCTL" build --image agent-python --features mcp-bridge --rebuild
    assert_status 0
  fi

  definition="$(jq -cn \
    --arg command "$node_path" \
    --arg server "$TEST_ROOT/tests/fixtures/fake-mcp-server.mjs" \
    --arg marker "$marker" \
    --arg url "http://127.0.0.1:${http_port}/mcp?fixed=1" \
    --arg credential "$credential" \
    '[{name:"fake",command:$command,args:[$server],env:{AGENTCTL_FAKE_MCP_STARTED:$marker},shared:true},{name:"http-fake",type:"http",url:$url,bearer_token_keychain:$credential}]')"

  log "managed-mcp: creating bridge and checking lazy child startup"
  run_capture "$AGENTCTL" run --name "$name" --image agent-python --workdir "$workdir" \
    --mcp "$definition" --cmd sh -lc '
set -eu
test ! -e /workdir/mcp-started
codex mcp get fake --json | jq -e ".transport.type == \"streamable_http\" and .transport.url == \"http://127.0.0.1:47123/mcp/fake\"" >/dev/null
codex mcp get http-fake --json | jq -e ".transport.type == \"streamable_http\" and .transport.url == \"http://127.0.0.1:47123/mcp/http-fake\"" >/dev/null
if curl -fsS --max-time 1 "http://host.container.internal:'"$http_port"'/mcp?fixed=1" >/dev/null 2>&1; then
  echo "loopback-only host MCP unexpectedly reachable through the VM gateway" >&2
  exit 1
fi
http_response="$(curl -fsS -X POST -H "content-type: application/json" \
  --data "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"tools/list\"}" \
  http://127.0.0.1:47123/mcp/http-fake)"
printf "%s" "$http_response" | jq -e ".authorization_matches == true and .url == \"/mcp?fixed=1\"" >/dev/null
response=""
curl_error=/tmp/agentctl-mcp-curl-error
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  response="$(curl -fsS -X POST -H "content-type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}" \
    http://127.0.0.1:47123/mcp/fake 2>"$curl_error")" && break
  sleep 1
done
if [ -s "$curl_error" ]; then cat "$curl_error" >&2; fi
printf "MCP response: %s\n" "$response" >&2
printf "%s" "$response" | jq -e ".result.serverInfo.name == \"fake\"" >/dev/null
second="$(curl -fsS -X POST -H "content-type: application/json" \
  --data "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{}}" \
  http://127.0.0.1:47123/mcp/fake)"
printf "%s" "$second" | jq -e ".result.serverInfo.name == \"fake\"" >/dev/null
test -s /workdir/mcp-started
test "$(wc -l </workdir/mcp-started | tr -d " ")" = 1
  '
  if [ "$RUN_STATUS" -ne 0 ]; then
    printf '%s\n' '--- managed MCP run output ---' >&2
    printf '%s\n' "$RUN_OUTPUT" >&2
    printf '%s\n' '--- host MCP relay logs ---' >&2
    find "$debug_dir" -maxdepth 1 -name 'mcp-*.log' -type f -print -exec sed -n '1,200p' {} \; >&2 || true
    printf '%s\n' '--- guest MCP proxy logs ---' >&2
    find "$debug_dir" -maxdepth 1 -name 'guest-*.log' -type f -print -exec sed -n '1,200p' {} \; >&2 || true
  fi
  assert_status 0
  if [ ! -s "$marker" ]; then
    printf '%s\n' "$RUN_OUTPUT" >&2
    ls -la "$workdir" >&2 || true
    fail "Expected fake MCP child to start on the first request"
  fi
  [ "$(wc -l <"$marker" | tr -d ' ')" = 1 ] || fail "Expected repeated sessionless requests to reuse one MCP child"
  [ -f "$registry" ] || fail "Expected private MCP registry: $registry"
  [ "$(stat -f '%Lp' "$registry")" = 600 ] || fail "Expected MCP registry mode 0600"
  if grep -Fq -- "$marker" "$registry"; then
    fail "Literal MCP environment value was persisted in the registry"
  fi
  jq -e --arg credential "$credential" '.schema_version==2 and any(.servers[]; .name=="http-fake" and .bearer_token_keychain==$credential and (has("resolved_headers")|not))' "$registry" >/dev/null \
    || fail "Expected safe HTTP credential reference in registry"
  grep -Fq -- "$token" "$registry" && fail "HTTP MCP Keychain value was persisted in the registry"
  if lsof -nP -iTCP:47123 -sTCP:LISTEN 2>/dev/null | grep -q agentctl; then fail "agentctl unexpectedly opened a host TCP listener on the guest MCP port"; fi

  log "managed-mcp: reusing the same named container through run --mcp"
  run_capture "$AGENTCTL" run --name "$name" --image agent-python --workdir "$workdir" \
    --mcp "$definition" --cmd true
  assert_status 0

  assert_mcp_initialize() {
    run_capture "$AGENTCTL" exec --name "$name" --no-tty -- sh -lc '
curl -fsS -X POST -H "content-type: application/json" \
  --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}" \
  http://127.0.0.1:'"$port"'/mcp/fake | jq -e ".result.serverInfo.name == \"fake\"" >/dev/null
    '
    assert_status 0
  }

  log "managed-mcp: checking start and restart supervision"
  run_capture "$AGENTCTL" start --name "$name"
  assert_status 0
  assert_mcp_initialize

  log "managed-mcp: rotating and removing Keychain-backed HTTP credentials"
  printf '%s' "$rotated_token" | "$AGENTCTL" mcp credential set "$credential" --stdin >/dev/null
  printf 'Bearer %s' "$rotated_token" | shasum -a 256 | awk '{print $1}' >"$expected_auth_file"
  run_capture "$AGENTCTL" exec --name "$name" --no-tty -- sh -lc 'curl -fsS -X POST --data "{}" http://127.0.0.1:'"$port"'/mcp/http-fake | jq -e ".authorization_matches == false" >/dev/null'
  assert_status 0
  run_capture "$AGENTCTL" restart --name "$name"; assert_status 0
  run_capture "$AGENTCTL" exec --name "$name" --no-tty -- sh -lc 'curl -fsS -X POST --data "{}" http://127.0.0.1:'"$port"'/mcp/http-fake | jq -e ".authorization_matches == true" >/dev/null'
  assert_status 0
  "$AGENTCTL" mcp credential delete "$credential" >/dev/null
  run_capture "$AGENTCTL" restart --name "$name"; assert_status 0
  run_capture "$AGENTCTL" exec --name "$name" --no-tty -- sh -lc 'test "$(curl -sS -o /tmp/mcp-missing.json -w "%{http_code}" -X POST --data "{}" http://127.0.0.1:'"$port"'/mcp/http-fake)" = 503'
  assert_status 0
  run_capture "$AGENTCTL" doctor --name "$name"
  assert_status 1; assert_contains "missing MCP Keychain credentials: $credential"
  printf '%s' "$rotated_token" | "$AGENTCTL" mcp credential set "$credential" --stdin >/dev/null
  run_capture "$AGENTCTL" restart --name "$name"; assert_status 0
  run_capture "$AGENTCTL" restart --name "$name"
  assert_status 0
  assert_mcp_initialize

  run_capture "$AGENTCTL" doctor --name "$name"
  assert_status 0
  assert_contains "Doctor managed MCP bridge"
  assert_contains "definitions: fake"
  assert_contains "guest-to-host MCP route healthy"

  run_capture "$AGENTCTL" doctor --host
  assert_contains "Managed MCP relays"
  assert_contains "Container $name"
  assert_contains "container-scoped relays normally have parent PID 1"
  assert_contains "process agentctl-mcp-relay:$name"

  log "managed-mcp: checking stopped-container doctor supervision"
  local starts_before_doctor
  starts_before_doctor="$(wc -l <"$marker" | tr -d ' ')"
  run_capture "$AGENTCTL" stop --name "$name"
  assert_status 0
  run_capture "$AGENTCTL" doctor --name "$name"
  assert_status 0
  assert_contains "host relay inactive because the container is stopped"
  assert_contains "Doctor confirmed managed MCP health after temporarily starting $name"
  assert_not_contains "host source unavailable or not a Unix socket"
  assert_not_contains "stopped-container published-socket problem"
  [ "$(wc -l <"$marker" | tr -d ' ')" = "$starts_before_doctor" ] || fail "Doctor health checks unexpectedly started the MCP child"
  run_capture "$CONTAINER_CMD" ls --quiet
  if printf '%s\n' "$RUN_OUTPUT" | grep -Fqx -- "$name"; then fail "Doctor did not restore the stopped container state"; fi
  run_capture "$AGENTCTL" doctor --host
  assert_contains "Container $name"
  assert_contains "host relay inactive because the container is stopped"
  log "managed-mcp: checking stopped-container upgrade preservation"
  starts_before_doctor="$(wc -l <"$marker" | tr -d ' ')"
  run_capture "$AGENTCTL" upgrade --name "$name" --no-backup
  assert_status 0
  [ "$(wc -l <"$marker" | tr -d ' ')" = "$starts_before_doctor" ] || fail "Stopped MCP upgrade preflight unexpectedly started the MCP child"
  run_capture "$AGENTCTL" start --name "$name"
  assert_status 0
  assert_mcp_initialize

  log "managed-mcp: disabling bridge"
  run_capture "$AGENTCTL" upgrade --name "$name" --no-backup --disable-mcp
  assert_status 0
  [ ! -e "$registry" ] || fail "Expected --disable-mcp to remove the registry"
  run_capture "$CONTAINER_CMD" inspect "$name"
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -e '
    (if type == "array" then .[0] else . end)
    | [(.configuration.mounts // [])[] | (.destination // .dst // "")]
    | index("/run/agentctl/mcp-host.sock") == null
  ' >/dev/null || fail "Expected --disable-mcp to remove managed socket wiring"
}

test_published_socket_lifecycle() {
  begin_test "container Unix socket publishing survives lifecycle and upgrade changes"
  local name copy_name running_copy_name collision_name workdir socket_dir host_one host_two guest_socket

  name="$(unique_name published-socket)"
  copy_name="${name}-copy"
  running_copy_name="${name}-running-copy"
  collision_name="${name}-collision"
  workdir="$(new_workdir)"
  socket_dir="$(mktemp -d /tmp/agentctl-published.XXXXXX)"
  socket_dir="$(CDPATH= cd -- "$socket_dir" && pwd -P)"
  chmod 700 "$socket_dir"
  register_dir_cleanup "$socket_dir"
  host_one="$socket_dir/one.sock"
  host_two="$socket_dir/two.sock"
  guest_socket="/tmp/agentctl-published-test.sock"
  register_container_cleanup "$name"
  register_container_cleanup "$copy_name"
  register_container_cleanup "$running_copy_name"
  register_container_cleanup "$collision_name"

  if ! image_exists agent-python; then
    run_capture "$AGENTCTL" build --image agent-python
    assert_status 0
  fi

  chmod 750 "$socket_dir"
  run_capture "$AGENTCTL" run --name "$collision_name" --image agent-python --workdir "$workdir" \
    --publish-socket "$host_one:$guest_socket" --cmd true
  assert_status 1
  assert_contains "inaccessible to group and other users"
  chmod 700 "$socket_dir"

  assert_collision_refused() {
    local collision_path="$1"
    run_capture "$AGENTCTL" run --name "$collision_name" --image agent-python --workdir "$workdir" \
      --publish-socket "$collision_path:$guest_socket" --cmd true
    assert_status 1
    assert_contains "already exists"
    [ -e "$collision_path" ] || [ -L "$collision_path" ] \
      || fail "agentctl removed the colliding host entry: $collision_path"
  }

  : >"$host_one"
  assert_collision_refused "$host_one"
  rm -f "$host_one"
  mkdir "$host_one"
  assert_collision_refused "$host_one"
  rmdir "$host_one"
  ln -s "$host_two" "$host_one"
  assert_collision_refused "$host_one"
  rm -f "$host_one"
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$host_one"
  assert_collision_refused "$host_one"
  rm -f "$host_one"

  host_exchange() {
    local host_path="$1"
    log "published-socket: exchanging data through $host_path"
    run_capture python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(b"ping"); print(s.recv(1024).decode())' "$host_path"
    assert_status 0
    assert_contains "container:ping"
  }

  start_guest_server() {
    log "published-socket: starting non-root guest server in $1"
    run_capture "$AGENTCTL" exec --name "$1" --no-tty -- python3 -c \
      'import os,socket,sys; p=sys.argv[1]; os.path.exists(p) and os.unlink(p); s=socket.socket(socket.AF_UNIX); s.bind(p); s.listen(); c,_=s.accept(); c.sendall(b"container:"+c.recv(1024)); c.close()' \
      "$guest_socket" &
    register_pid_cleanup "$!"
    sleep 1
  }

  log "published-socket: creating $name"
  run_capture "$AGENTCTL" run --name "$name" --image agent-python --workdir "$workdir" \
    --publish-socket "$host_one:$guest_socket" --cmd true
  assert_status 0
  [ ! -e "$host_one" ] || fail "Published listener remained after run stopped the container"

  log "published-socket: starting $name"
  run_capture "$AGENTCTL" start --name "$name"
  assert_status 0
  [ -S "$host_one" ] || fail "Published listener was not created on start"
  start_guest_server "$name"
  host_exchange "$host_one"
  log "published-socket: restarting $name"
  run_capture "$AGENTCTL" restart --name "$name"
  assert_status 0
  [ -S "$host_one" ] || fail "Published listener was not recreated on restart"
  log "published-socket: stopping $name"
  run_capture "$AGENTCTL" stop --name "$name"
  assert_status 0
  [ ! -e "$host_one" ] || fail "Published listener remained after stop"
  : >"$host_one"
  run_capture "$AGENTCTL" doctor --name "$name"
  assert_status 1
  assert_contains "stopped container left a published host entry behind"
  [ -f "$host_one" ] || fail "Doctor deleted a stopped-container host collision"
  rm -f "$host_one"

  log "published-socket: upgrading $name with an additional listener"
  run_capture "$AGENTCTL" upgrade --name "$name" --no-backup --publish-socket "$host_two:$guest_socket"
  assert_status 0
  [ ! -e "$host_one" ] && [ ! -e "$host_two" ] \
    || fail "Stopped-container upgrade left published listeners behind"
  run_capture "$CONTAINER_CMD" inspect "$name"
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -e --arg one "$host_one" --arg two "$host_two" '
    (if type == "array" then .[0] else . end)
    | [(.configuration.publishedSockets // [])[] | .hostPath]
    | index($one) != null and index($two) != null
  ' >/dev/null || fail "Upgrade did not preserve and add published mappings: $RUN_OUTPUT"
  run_capture "$AGENTCTL" start --name "$name"
  assert_status 0
  [ -S "$host_one" ] && [ -S "$host_two" ] \
    || fail "Starting the upgraded container did not create both published listeners"
  run_capture "$AGENTCTL" upgrade --name "$name" --new-name "$running_copy_name" --copy
  assert_status 1
  assert_contains "Cannot copy running container"
  container_exists "$name" || fail "Running-copy refusal removed the source container"
  [ -S "$host_one" ] && [ -S "$host_two" ] \
    || fail "Running-copy refusal disrupted source listeners"
  run_capture "$AGENTCTL" stop --name "$name"
  assert_status 0

  log "published-socket: copying stopped $name to $copy_name"
  run_capture "$AGENTCTL" upgrade --name "$name" --new-name "$copy_name" --copy
  assert_status 0
  [ ! -e "$host_one" ] && [ ! -e "$host_two" ] \
    || fail "Stopped-source copy left published listeners behind"
  run_capture "$CONTAINER_CMD" inspect "$copy_name"
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -e --arg one "$host_one" --arg two "$host_two" '
    (if type == "array" then .[0] else . end)
    | [(.configuration.publishedSockets // [])[] | .hostPath]
    | index($one) != null and index($two) != null
  ' >/dev/null || fail "Stopped-source copy did not preserve published mappings: $RUN_OUTPUT"
  run_capture "$AGENTCTL" start --name "$copy_name"
  assert_status 0
  [ -S "$host_one" ] && [ -S "$host_two" ] \
    || fail "Starting the stopped-source copy did not create both published listeners"
  run_capture "$AGENTCTL" stop --name "$copy_name"
  assert_status 0

  log "published-socket: removing one listener from $name"
  run_capture "$AGENTCTL" upgrade --name "$name" --no-backup --unpublish-socket "$host_one"
  assert_status 0
  run_capture "$CONTAINER_CMD" inspect "$name"
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -e --arg removed "$host_one" --arg kept "$host_two" '
    (if type == "array" then .[0] else . end)
    | [(.configuration.publishedSockets // [])[] | .hostPath]
    | index($removed) == null and index($kept) != null
  ' >/dev/null || fail "Expected targeted published socket removal in inspect: $RUN_OUTPUT"

  run_capture "$AGENTCTL" upgrade --name "$name" --no-backup \
    --publish-socket "$host_two:/tmp/agentctl-published-replacement.sock"
  assert_status 0
  run_capture "$CONTAINER_CMD" inspect "$name"
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -e --arg host "$host_two" '
    (if type == "array" then .[0] else . end)
    | [(.configuration.publishedSockets // [])[]
       | select(.hostPath == $host and .containerPath == "/tmp/agentctl-published-replacement.sock")]
    | length == 1
  ' >/dev/null || fail "Expected host-path replacement in inspect: $RUN_OUTPUT"
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
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and .install_method == "standalone-installer"' >/dev/null || fail "Expected runtime info JSON for codex after bootstrap, got: $RUN_OUTPUT"

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
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and .install_method == "standalone-installer"' >/dev/null || fail "Expected runtime info JSON for codex after create+bootstrap, got: $RUN_OUTPUT"

  run_capture "$AGENTCTL" feature --name "$name" info office
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.feature == "office" and .capabilities.install == true' >/dev/null || fail "Expected feature info JSON for office after create+bootstrap, got: $RUN_OUTPUT"
}

test_bootstrap_works_on_existing_debian_container() {
  begin_test "bootstrap works on an existing Debian container"
  local name

  name="$(unique_name bootstrap-debian)"
  register_raw_container_cleanup "$name"

  run_capture "$CONTAINER_CMD" create --name "$name" docker.io/library/debian:stable-slim sleep infinity
  assert_status 0

  run_capture "$CONTAINER_CMD" start "$name"
  assert_status 0

  run_capture "$AGENTCTL" bootstrap --name "$name"
  assert_status 0
  assert_contains "Bootstrap complete: $name"

  run_capture "$AGENTCTL" runtime --name "$name" info codex
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.runtime == "codex" and .install_method == "standalone-installer"' >/dev/null || fail "Expected runtime info JSON for codex after Debian bootstrap, got: $RUN_OUTPUT"

  run_capture "$AGENTCTL" feature --name "$name" info office
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -er '.feature == "office" and .capabilities.install == true and .installed == false' >/dev/null || fail "Expected feature info JSON for office after Debian bootstrap, got: $RUN_OUTPUT"

  run_capture "$AGENTCTL" refresh --name "$name"
  assert_status 0
  assert_contains "Refresh complete: $name"

  run_capture "$CONTAINER_CMD" exec "$name" sh -lc 'test -f /etc/agentctl/bootstrap.json && test -x /usr/local/bin/agent.sh && test -f /etc/agentctl/runtimes.d/codex.json && test -f /etc/agentctl/features.d/office.json'
  assert_status 0
}

test_host_only_network_lifecycle_isolation_and_upgrade() {
  begin_test "host-only networks isolate external and cross-network traffic and survive upgrade"

  local network
  local other_network
  local server
  local peer
  local outsider
  local workdir
  local gateway
  local server_address
  local host_server_dir
  local host_server_log
  local host_server_pid
  local host_server_port
  local host_server_port_file
  local host_server_script
  network="$(unique_name internal-net)"
  other_network="$(unique_name other-net)"
  server="$(unique_name internal-server)"
  peer="$(unique_name internal-peer)"
  outsider="$(unique_name internal-outsider)"
  workdir="$(new_workdir)"
  register_network_cleanup "$network"
  register_network_cleanup "$other_network"
  register_container_cleanup "$server"
  register_container_cleanup "$peer"
  register_container_cleanup "$outsider"

  ensure_agent_plain_image

  run_capture "$AGENTCTL" network create --internal "$network"
  assert_status 0
  run_capture "$AGENTCTL" network create --internal "$other_network"
  assert_status 0
  run_capture "$AGENTCTL" network list
  assert_status 0
  assert_contains "$network"
  assert_contains "yes"

  run_capture "$AGENTCTL" run --name "$server" --image agent-plain --workdir "$workdir" --network "$network" --cmd true
  assert_status 0
  run_capture "$AGENTCTL" start --name "$server"
  assert_status 0
  log "host-only: checking same-network connectivity"
  run_capture "$AGENTCTL" exec --name "$server" --no-tty -- sh -lc 'nohup node -e '\''require("http").createServer((_request, response) => response.end("ok")).listen(18080, "0.0.0.0")'\'' >/tmp/agentctl-network-server.log 2>&1 &'
  assert_status 0
  run_capture "$CONTAINER_CMD" inspect "$server"
  assert_status 0
  if ! server_address="$(printf '%s' "$RUN_OUTPUT" | jq -er --arg network "$network" '
    (if type == "array" then .[0] else . end)
    | first(
        (.networks // .status.networks // [])[]
        | select((.network // .name // .id) == $network)
        | (.address // .ipv4Address // empty)
        | split("/")[0]
      )
  ')"; then
    fail "Unable to parse server address on network $network from container inspect: $RUN_OUTPUT"
  fi
  [ -n "$server_address" ] || fail "Unable to determine server address on network $network"
  sleep 1
  run_capture "$AGENTCTL" exec --name "$server" --no-tty -- curl -fsS --connect-timeout 3 --max-time 5 http://127.0.0.1:18080
  if [ "$RUN_STATUS" -ne 0 ]; then
    printf '%s\n' "$RUN_OUTPUT" >&2
    "$AGENTCTL" exec --name "$server" --no-tty -- sh -lc 'ps -ef; cat /tmp/agentctl-network-server.log 2>/dev/null || true' >&2 || true
    fail "Expected the network test server to answer inside its own container"
  fi

  # Apple container's own host-only test attaches the client after the server
  # and network are running. Preserve that ordering because vmnet attachment
  # initialization can otherwise race peer reachability.
  run_capture "$AGENTCTL" run --name "$peer" --image agent-plain --workdir "$workdir" --network "$network" --cmd true
  assert_status 0
  run_capture "$AGENTCTL" run --name "$outsider" --image agent-plain --workdir "$workdir" --network "$other_network" --cmd true
  assert_status 0
  run_capture "$AGENTCTL" start --name "$peer"
  assert_status 0
  run_capture "$AGENTCTL" start --name "$outsider"
  assert_status 0
  run_capture "$AGENTCTL" exec --name "$peer" --no-tty -- curl -fsS --retry 10 --retry-connrefused --retry-delay 1 --connect-timeout 3 --max-time 20 "http://$server_address:18080"
  if [ "$RUN_STATUS" -ne 0 ]; then
    printf '%s\n' "$RUN_OUTPUT" >&2
    "$AGENTCTL" exec --name "$server" --no-tty -- sh -lc 'ps -ef; printf "\n--- server log ---\n"; cat /tmp/agentctl-network-server.log 2>/dev/null || true' >&2 || true
    "$CONTAINER_CMD" inspect "$server" "$peer" >&2 || true
    fail "Expected same-network connection to $server_address:18080 to succeed"
  fi

  log "host-only: checking cross-network and external isolation"
  run_capture "$AGENTCTL" exec --name "$outsider" --no-tty -- curl -fsS --connect-timeout 3 --max-time 5 "http://$server_address:18080"
  [ "$RUN_STATUS" -ne 0 ] || fail "Expected distinct host-only networks to be isolated"
  run_capture "$AGENTCTL" exec --name "$peer" --no-tty -- curl -fsS --connect-timeout 3 --max-time 5 https://example.com/
  [ "$RUN_STATUS" -ne 0 ] || fail "Expected a host-only network to have no external route"
  log "host-only: checking online-mode rejection and host alias"
  run_capture "$AGENTCTL" run --name "$peer" --online --cmd true
  assert_status 1
  assert_contains "Online mode cannot use a host-only network"

  run_capture "$AGENTCTL" host-address --network "$network"
  assert_status 0
  gateway="$RUN_OUTPUT"
  [ -n "$gateway" ] || fail "Expected a host gateway for network $network"
  run_capture "$AGENTCTL" exec --name "$peer" --no-tty -- awk -v gateway="$gateway" '$1 == gateway && $2 == "host.container.internal" { found=1 } END { exit !found }' /etc/hosts
  assert_status 0

  log "host-only: checking connectivity to a host service"
  command -v python3 >/dev/null 2>&1 || fail "The host-only host-service test requires python3 on the macOS host"
  host_server_dir="$(new_workdir)"
  host_server_script="$host_server_dir/server.py"
  host_server_port_file="$host_server_dir/port"
  host_server_log="$host_server_dir/server.log"
  printf 'host-only gateway reached\n' >"$host_server_dir/index.html"
  cat >"$host_server_script" <<'PY'
import http.server
import pathlib
import sys

address, port_file, directory = sys.argv[1:]
handler = lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(
    *args, directory=directory, **kwargs
)
server = http.server.ThreadingHTTPServer((address, 0), handler)
pathlib.Path(port_file).write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
  python3 "$host_server_script" "$gateway" "$host_server_port_file" "$host_server_dir" >"$host_server_log" 2>&1 &
  host_server_pid=$!
  register_pid_cleanup "$host_server_pid"
  for _ in 1 2 3 4 5; do
    [ -s "$host_server_port_file" ] && break
    kill -0 "$host_server_pid" >/dev/null 2>&1 || break
    sleep 1
  done
  if [ ! -s "$host_server_port_file" ]; then
    cat "$host_server_log" >&2 || true
    fail "Unable to start a host HTTP server on host-only gateway $gateway"
  fi
  host_server_port="$(cat "$host_server_port_file")"
  run_capture "$AGENTCTL" exec --name "$peer" --no-tty -- curl -fsS --connect-timeout 3 --max-time 10 "http://host.container.internal:$host_server_port/"
  if [ "$RUN_STATUS" -ne 0 ]; then
    printf '%s\n' "$RUN_OUTPUT" >&2
    cat "$host_server_log" >&2 || true
    fail "Expected host-only container to reach the host service at $gateway:$host_server_port"
  fi
  assert_contains "host-only gateway reached"

  log "host-only: checking upgrade preservation and deletion safety"
  run_capture "$AGENTCTL" upgrade --name "$peer" --image agent-plain --no-backup
  assert_status 0
  run_capture "$CONTAINER_CMD" inspect "$peer"
  assert_status 0
  printf '%s' "$RUN_OUTPUT" | jq -e --arg network "$network" '
    (if type == "array" then .[0] else . end)
    | ((.configuration.networks // .status.networks // .networks // []) | tostring)
    | contains($network)
  ' >/dev/null || fail "Expected upgrade to preserve network $network"

  run_capture "$AGENTCTL" network rm "$network"
  [ "$RUN_STATUS" -ne 0 ] || fail "Expected deletion of an attached network to fail"
}

main() {
  require_host_prereqs

  log "Using agentctl at $AGENTCTL"
  log "Using agentctl implementation at $AGENTCTL_IMPL"
  log "Using container runtime command $CONTAINER_CMD"
  log "Running host test tier: $TEST_TIER"
  if [ -n "$TEST_FILTER" ]; then
    log "Filtering host tests by: $TEST_FILTER"
  fi
  if [ -n "$TEST_START_FROM" ]; then
    log "Running host tests from: $TEST_START_FROM"
  fi
  start_leak_tracking

  run_selected_test test_temp_run_removes_container "run --temp removes the named container" smoke
  run_selected_test test_named_run_persists_until_rm "named run persists until explicit removal" smoke
  run_selected_test test_build_rebuild_stops_buildkit "build --rebuild stops buildkit after a successful build" full
  run_selected_test test_upgrade_no_backup_preserves_state "upgrade --no-backup preserves state without creating backup images" full
  run_selected_test test_upgrade_repeats_tagged_apk_reinstall_instructions "upgrade repeats complete tagged APK reinstall instructions" full
  run_selected_test test_upgrade_with_backup_creates_recovery_image "upgrade creates a backup image by default" full
  run_selected_test test_upgrade_backup_restores_home_and_boots_rescue_image "upgrade backup restores home state and creates a bootable full-rootfs rescue image" full
  run_selected_test test_upgrade_preflight_failure_keeps_container "upgrade preflight failure leaves the original container intact" full
  run_selected_test test_run_reset_config_restores_image_defaults "run --reset-config restores config, models, and AGENTS symlink" smoke
  run_selected_test test_refresh_reset_config_restores_defaults_and_stopped_state "refresh --reset-config restores defaults and preserves stopped state" smoke
  run_selected_test test_image_contains_runtime_defaults_and_version_markers "image contains normalized defaults and separate version markers" smoke
  run_selected_test test_upgrade_overwrite_config_restores_image_defaults "upgrade --overwrite-config restores config, models, and AGENTS symlink" full
  run_selected_test test_system_manifest_requested_packages_on_agent_plain_apk "system manifest reports requested apk packages on agent-plain" full
  run_selected_test test_system_manifest_requested_packages_on_agent_swift_dpkg "system manifest reports requested dpkg packages on agent-swift" full
  run_selected_test test_runtime_management_commands_work_for_existing_container "runtime list, info, capabilities, and use work for an existing container" smoke
  run_selected_test test_refresh_pushes_runtime_registry_into_existing_container "refresh updates the runtime registry in an existing container" smoke
  run_selected_test test_runtime_info_claude_works_after_refresh_on_stopped_container "runtime info claude works after refresh when the container is stopped" smoke
  run_selected_test test_tool_home_smoke_codex_external_home "tool-home smoke keeps Codex tools outside mounted home" smoke
  run_selected_test test_tool_home_smoke_claude_external_home_when_installed "tool-home smoke keeps Claude tools outside mounted home when installed" smoke
  run_selected_test test_feature_office_install_works_on_agent_python "feature install office works on agent-python" full
  run_selected_test test_ssh_feature_build_and_forwarding_lifecycle "SSH forwarding feature preinstall survives upgrade and can be disabled" full
  run_selected_test test_host_socket_mount_lifecycle "host Unix socket mount survives restart, upgrade, replacement, copy, and removal" full
  run_selected_test test_managed_mcp_bridge_lifecycle "managed MCP bridge exchanges traffic and survives start, restart, upgrade, and disable" full
  run_selected_test test_published_socket_lifecycle "container Unix socket publishing survives lifecycle and upgrade changes" full
  run_selected_test test_bootstrap_works_on_existing_alpine_container "bootstrap works on an existing Alpine container" full
  run_selected_test test_bootstrap_can_create_and_bootstrap_new_alpine_container "bootstrap can create and bootstrap a new Alpine container" full
  run_selected_test test_bootstrap_works_on_existing_debian_container "bootstrap works on an existing Debian container" full
  run_selected_test test_host_only_network_lifecycle_isolation_and_upgrade "host-only networks isolate external and cross-network traffic and survive upgrade" full
  assert_selected_tests_ran

  log "PASS: all host integration tests completed"
}

main "$@"
