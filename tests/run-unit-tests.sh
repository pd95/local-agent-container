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

  sed '/^cmd="${1:-}"/,$d' "$CODEXCTL" >"$harness"
  # shellcheck source=/dev/null
  . "$harness"
}

test_run_profile_wires_selected_profile() {
  begin_test "run_cmd wires --profile into the launched codex command"

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
  printf '%s\n' "$captured_cmd" | grep -Fxq 'codex --profile gemma --cd /workdir' || fail "Expected codex command to include --profile gemma, got: $captured_cmd"
}

test_run_help_reports_profile_default() {
  begin_test "run help reports the actual default profile"

  run_capture "$CODEXCTL" run --help
  assert_status 0
  assert_contains "--profile NAME  Codex profile to use (default: gpt-oss)"
}

main() {
  log "Using codexctl at $CODEXCTL"

  test_run_profile_wires_selected_profile
  test_run_help_reports_profile_default

  log "PASS: all shell unit tests completed"
}

main "$@"
