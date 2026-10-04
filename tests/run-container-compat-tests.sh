#!/usr/bin/env bash
# Real Apple container contract tests. Run on the macOS host, never in a guest.
set -euo pipefail

original_container="${CONTAINER_CMD:-container}"
SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIRECTORY/container-compat/lib.sh"

usage() {
  cat <<'EOF'
Usage: bash tests/run-container-compat-tests.sh [OPTIONS]
  --prepare                    Download and prepare reusable offline fixture assets
  --prepare-upgrade            Preserve running/stopped fixtures across a host upgrade
  --verify-upgrade             Check retained fixtures and run the complete fresh suite
  --cleanup                    Remove resources recorded in --state-dir
  --state-dir PATH             Required for upgrade phases and explicit cleanup
  --assets-dir PATH            Prepared assets (default: ~/.cache/agentctl-container-compat/assets)
  --output-dir PATH            Persistent diagnostics (default: state-root/runs/unique-id)
  --filter TEXT                Run matching fresh tests only; cannot certify compatibility
  --from TEXT                  Resume fresh tests at a matching name; cannot certify compatibility
  --help                       Show this help

CONTAINER_CMD selects a real CLI executable, including an absolute Homebrew path.
COMPAT_QUERY_TIMEOUT=30, COMPAT_LIFECYCLE_TIMEOUT=120, COMPAT_IMAGE_TIMEOUT=600,
COMPAT_TEST_TIMEOUT=900, and COMPAT_KILL_GRACE=5 override deadlines in seconds.
The suite never switches versions, starts the API server, or prunes global state.
EOF
}

mode=run
state_dir=""
filter=""
start_from=""
output_dir=""
COMPAT_STATE_ROOT="${COMPAT_STATE_ROOT:-$HOME/.cache/agentctl-container-compat}"
COMPAT_ASSETS="$COMPAT_STATE_ROOT/assets"
mode_set=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prepare|--prepare-upgrade|--verify-upgrade|--cleanup)
      [ "$mode_set" -eq 0 ] || compat_fail 'Choose only one phase'
      mode="${1#--}"; mode_set=1; shift ;;
    --state-dir|--assets-dir|--output-dir|--filter|--from)
      [ "$#" -ge 2 ] && [ -n "$2" ] || compat_fail "Missing value for $1"
      case "$1" in
        --state-dir) state_dir="$2" ;;
        --assets-dir) COMPAT_ASSETS="$2" ;;
        --output-dir) output_dir="$2" ;;
        --filter) filter="$2" ;;
        --from) start_from="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) compat_fail "Unknown argument: $1" ;;
  esac
done
case "$mode" in
  prepare-upgrade|verify-upgrade|cleanup) [ -n "$state_dir" ] || compat_fail '--state-dir is required for this phase' ;;
esac
if [ "$mode" != run ] && { [ -n "$filter" ] || [ -n "$start_from" ]; }; then compat_fail 'Filters are only available for fresh runs'; fi
[ "$(uname -s)" = Darwin ] || compat_fail 'Run this suite on the macOS host with Apple container'
for tool in bash jq node tar shasum ssh-agent ssh-add ssh-keygen script sw_vers ps awk tee mkfifo; do
  command -v "$tool" >/dev/null 2>&1 || compat_fail "Missing host tool: $tool"
done
COMPAT_REAL_CONTAINER="$(command -v "$original_container")" || compat_fail "Missing container executable: $original_container"
case "$COMPAT_REAL_CONTAINER" in /*) ;; *) COMPAT_REAL_CONTAINER="$(pwd)/$COMPAT_REAL_CONTAINER" ;; esac
for value in "${COMPAT_QUERY_TIMEOUT:-30}" "${COMPAT_LIFECYCLE_TIMEOUT:-120}" "${COMPAT_IMAGE_TIMEOUT:-600}" "${COMPAT_TEST_TIMEOUT:-900}" "${COMPAT_KILL_GRACE:-5}"; do
  case "$value" in ''|0|*[!0-9]*) compat_fail 'Deadlines must be positive integer seconds' ;; esac
done
mkdir -p "$COMPAT_STATE_ROOT/runs"
COMPAT_STATE_ROOT="$(CDPATH= cd -- "$COMPAT_STATE_ROOT" && pwd)"
lock="$COMPAT_STATE_ROOT/lock"
if ! mkdir "$lock" 2>/dev/null; then
  lock_pid="$(cat "$lock/pid" 2>/dev/null || true)"
  case "$lock_pid" in ''|*[!0-9]*) ;; *)
    if kill -0 "$lock_pid" 2>/dev/null; then compat_fail "Suite lock is held by PID $lock_pid: $lock"; fi ;;
  esac
  if [ "$mode" != cleanup ]; then compat_fail "Abandoned suite lock: run --cleanup --state-dir '$lock', then clean any reported run journals"; fi
  rm -f "$lock/pid"
  rmdir "$lock" || compat_fail "Cannot remove abandoned lock: $lock"
  compat_log 'Removed abandoned lock'
  if [ "$state_dir" = "$lock" ]; then exit 0; fi
  mkdir "$lock" || compat_fail 'Another suite acquired the lock; retry cleanup'
fi
printf '%s\n' "$$" >"$lock/pid"
trap 'rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true' EXIT
COMPAT_RUN_ID="$(date -u +%Y%m%d%H%M%S)-$$"
COMPAT_OUTPUT_DIR="${output_dir:-$COMPAT_STATE_ROOT/runs/$COMPAT_RUN_ID}"
mkdir -p "$COMPAT_OUTPUT_DIR"
chmod 700 "$COMPAT_OUTPUT_DIR"
COMPAT_OUTPUT_DIR="$(CDPATH= cd -- "$COMPAT_OUTPUT_DIR" && pwd)"
if [ -e "$COMPAT_OUTPUT_DIR/metadata.json" ] || [ -e "$COMPAT_OUTPUT_DIR/summary.json" ]; then
  rm -f "$lock/pid"; rmdir "$lock"
  compat_fail 'Choose a new output directory; previous reports must not be overwritten'
fi
mkdir -p "$COMPAT_STATE_ROOT/runs/$COMPAT_RUN_ID"
printf '%s\n' "$COMPAT_OUTPUT_DIR" >"$COMPAT_STATE_ROOT/runs/$COMPAT_RUN_ID/report-path"
COMPAT_TEST_ID=startup
COMPAT_TEST_DIR="$COMPAT_OUTPUT_DIR/startup"
COMPAT_JOURNAL="$COMPAT_OUTPUT_DIR/resources"
mkdir -p "$COMPAT_TEST_DIR" "$COMPAT_JOURNAL" "$COMPAT_OUTPUT_DIR/results"
mkdir -p "$(dirname "$COMPAT_ASSETS")"
COMPAT_ASSETS="$(CDPATH= cd -- "$(dirname "$COMPAT_ASSETS")" && pwd)/$(basename "$COMPAT_ASSETS")"
export COMPAT_REAL_CONTAINER COMPAT_OUTPUT_DIR COMPAT_RUN_ID COMPAT_TEST_ID COMPAT_TEST_DIR COMPAT_JOURNAL COMPAT_ASSETS
suite_status=setup-failure
preserve_upgrade=0
upgrade_state_created=0
cleanup_failed=0
upgrade_started=0
builder_was_running=0
active_supervisor=""
selection_partial=0
if [ -n "$filter" ] || [ -n "$start_from" ]; then selection_partial=1; fi


finish() {
  local exit_status=$? result_files
  trap - EXIT
  # A handler absorbs repeated interrupts without exporting SIG_IGN to children.
  # The operation watchdog must still be able to terminate its timer.
  trap ':' INT TERM HUP
  compat_worker_cleanup
  COMPAT_TEST_ID=cleanup; export COMPAT_TEST_ID
  compat_log 'Cleaning up owned resources (each runtime operation has a deadline)'
  cleanup_journal "$COMPAT_OUTPUT_DIR/resources" || cleanup_failed=1
  if [ "$preserve_upgrade" -eq 0 ] && [ "$upgrade_state_created" -eq 1 ]; then
    cleanup_journal "$state_dir/resources" || cleanup_failed=1
  fi
  if [ "$mode" = verify-upgrade ] && [ "$upgrade_started" -eq 1 ]; then
    cleanup_journal "$state_dir/resources" || cleanup_failed=1
  fi
  if [ "$builder_was_running" -eq 1 ]; then
    resource_capture "$CONTAINER_CMD" ls --quiet || cleanup_failed=1
    if ! grep -Fx buildkit "$COMPAT_OUTPUT_DIR/cleanup.stdout" >/dev/null; then
      resource_capture "$CONTAINER_CMD" start buildkit || cleanup_failed=1
    fi
  fi
  [ "$cleanup_failed" -eq 0 ] || { suite_status=cleanup-failure; exit_status=1; }
  result_files=("$COMPAT_OUTPUT_DIR"/results/*.json)
  if [ -f "${result_files[0]}" ]; then jq -s '.' "${result_files[@]}" >"$COMPAT_OUTPUT_DIR/tests.json"
  else printf '[]\n' >"$COMPAT_OUTPUT_DIR/tests.json"; fi
  if ! compat_write_summary "$suite_status" "$mode" "$exit_status" "$((1-cleanup_failed))" "$selection_partial"; then exit_status=1; fi
  if [ "$suite_status" = compatible ] && ! jq -e '.compatible' "$COMPAT_OUTPUT_DIR/summary.json" >/dev/null; then
    suite_status=incomplete
    exit_status=1
    compat_write_summary "$suite_status" "$mode" "$exit_status" "$((1-cleanup_failed))" "$selection_partial" || true
  fi
  compat_log "Result: $suite_status; report: $COMPAT_OUTPUT_DIR"
  rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true
  exit "$exit_status"
}
trap finish EXIT
interrupt_suite() {
  trap ':' INT TERM HUP
  suite_status=interrupted
  if [ -n "$active_supervisor" ]; then kill -TERM "$active_supervisor" 2>/dev/null || true; wait "$active_supervisor" 2>/dev/null || true; fi
  exit 130
}
trap interrupt_suite INT TERM HUP

compat_log "Report: $COMPAT_OUTPUT_DIR"
jq -n --arg executable "$COMPAT_REAL_CONTAINER" --arg os "$(sw_vers)" --arg architecture "$(uname -m)" \
  --arg version "$(cat "$COMPAT_ROOT/VERSION")" --arg commit "$(git -C "$COMPAT_ROOT" rev-parse HEAD 2>/dev/null || true)" \
  --arg dirty "$(git -C "$COMPAT_ROOT" status --porcelain 2>/dev/null || true)" --arg run "$COMPAT_RUN_ID" \
  '{run:$run,cli_version:null,api_server_version:null,container_executable:$executable,macos:$os,architecture:$architecture,agentctl_version:$version,git_commit:$commit,git_dirty:($dirty!="")}' >"$COMPAT_OUTPUT_DIR/metadata.json"
compat_capture 0 "$CONTAINER_CMD" --version
printf '%s\n' "$COMPAT_STDOUT" >"$COMPAT_OUTPUT_DIR/cli-version.txt"
cli_version="$(printf '%s\n' "$COMPAT_STDOUT" | jq -Rsr 'capture("(?<version>[0-9]+\\.[0-9]+\\.[0-9]+(?:-[a-zA-Z0-9.-]+)?(?:\\+[a-zA-Z0-9.-]+)?)").version')"
[ -n "$cli_version" ] || compat_fail 'Cannot determine CLI semantic version'
jq --arg cli "$cli_version" '.cli_version=$cli' "$COMPAT_OUTPUT_DIR/metadata.json" >"$COMPAT_OUTPUT_DIR/metadata.tmp"
mv "$COMPAT_OUTPUT_DIR/metadata.tmp" "$COMPAT_OUTPUT_DIR/metadata.json"
compat_capture 0 "$CONTAINER_CMD" system status --format json
printf '%s\n' "$COMPAT_STDOUT" >"$COMPAT_OUTPUT_DIR/system-status.json"
printf '%s' "$COMPAT_STDOUT" | jq -e '.status == "running"' >/dev/null || compat_fail 'API server is not running'
server_version="$(printf '%s' "$COMPAT_STDOUT" | compat_server_version)" || compat_fail 'API server is not running or has no version in system status'
compat_capture 0 "$CONTAINER_CMD" system version --format json
printf '%s\n' "$COMPAT_STDOUT" >"$COMPAT_OUTPUT_DIR/system-version.json"
jq --arg server "$server_version" '.api_server_version=$server' "$COMPAT_OUTPUT_DIR/metadata.json" >"$COMPAT_OUTPUT_DIR/metadata.tmp"
mv "$COMPAT_OUTPUT_DIR/metadata.tmp" "$COMPAT_OUTPUT_DIR/metadata.json"
if [ "$mode" != cleanup ]; then
  [ "$cli_version" = "$server_version" ] || compat_fail "CLI $cli_version and API server $server_version differ; switch both and rerun"
  COMPAT_EXPECTED_VERSION="$server_version"; export COMPAT_EXPECTED_VERSION
fi
compat_health

if [ "$mode" = cleanup ]; then
  [ -d "$state_dir/resources" ] || compat_fail 'State directory has no resource journal'
  cleanup_journal "$state_dir/resources" || { cleanup_failed=1; exit 1; }
  suite_status=cleaned
  exit 0
fi

# No automatic deletion of older runs: an upgrade preparation deliberately owns
# retained resources. Report ordinary abandoned journals before creating work.
for previous in "$COMPAT_STATE_ROOT"/runs/*; do
  if [ -f "$previous/report-path" ]; then previous="$(cat "$previous/report-path")"; fi
  [ "$previous" != "$COMPAT_OUTPUT_DIR" ] || continue
  [ -d "$previous/resources" ] || continue
  if [ -n "$(find "$previous/resources" -name 'resource.*' -type f -print)" ]; then
    compat_fail "Stale resource journal: run --cleanup --state-dir '$previous'"
  fi
done

# Preserve a pre-existing builder. Registration is before any build invocation.
compat_capture 0 "$CONTAINER_CMD" ls -a --quiet
if ! printf '%s\n' "$COMPAT_STDOUT" | grep -Fx buildkit >/dev/null; then compat_register builder buildkit; fi
compat_capture 0 "$CONTAINER_CMD" ls --quiet
if printf '%s\n' "$COMPAT_STDOUT" | grep -Fx buildkit >/dev/null; then builder_was_running=1; fi
compat_load_agentctl
COMPAT_WORK_DIR="$(compat_tmpdir setup)"; export COMPAT_WORK_DIR

if [ "$mode" = prepare ]; then
  [ ! -e "$COMPAT_ASSETS/manifest.json" ] || compat_fail 'Prepared assets already exist; choose a new --assets-dir to replace them'
  mkdir -p "$COMPAT_ASSETS"
  base='docker.io/library/alpine@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1'
  # The immutable pulled base is an explicitly retained preparation asset.
  compat_capture 0 "$CONTAINER_CMD" image pull "$base"
  prepared_image="$(compat_name prepared):latest"
  prepared_container="$(compat_name prepared)"
  compat_register image "$prepared_image"
  compat_capture 0 "$CONTAINER_CMD" build -t "$prepared_image" -f "$COMPAT_ROOT/tests/fixtures/container-compat/Dockerfile.prepare" "$COMPAT_ROOT/tests/fixtures/container-compat"
  compat_register container "$prepared_container"
  compat_capture 0 "$CONTAINER_CMD" create --name "$prepared_container" "$prepared_image" sh -ec 'sleep infinity'
  # Apple container materializes the writable root filesystem on first start.
  compat_capture 0 "$CONTAINER_CMD" start "$prepared_container"
  compat_capture 0 "$CONTAINER_CMD" exec "$prepared_container" true
  compat_capture 0 "$CONTAINER_CMD" stop "$prepared_container"
  compat_capture 0 "$CONTAINER_CMD" export "$prepared_container" --output "$COMPAT_WORK_DIR/export.tar"
  extract_container_export_rootfs "$COMPAT_WORK_DIR/export.tar" "$COMPAT_WORK_DIR/rootfs"
  tar -C "$COMPAT_WORK_DIR/rootfs" -cf "$COMPAT_ASSETS/rootfs.tar" .
  checksum="$(shasum -a 256 "$COMPAT_ASSETS/rootfs.tar" | awk '{print $1}')"
  jq -n --arg checksum "$checksum" --arg base "$base" --arg architecture "$(uname -m)" \
    --arg definition "$(shasum -a 256 "$COMPAT_ROOT/tests/fixtures/container-compat/Dockerfile.prepare" | awk '{print $1}')" \
    --arg version "$cli_version" '{schema_version:1,rootfs_sha256:$checksum,base_image:$base,architecture:$architecture,prepared_with:$version,fixture_definition_sha256:$definition}' >"$COMPAT_ASSETS/manifest.json"
  suite_status=prepared
  compat_log "Prepared local assets: $COMPAT_ASSETS"
  exit 0
fi

[ -f "$COMPAT_ASSETS/rootfs.tar" ] && [ -f "$COMPAT_ASSETS/manifest.json" ] || compat_fail 'Run --prepare first'
[ "$(jq -r '.architecture' "$COMPAT_ASSETS/manifest.json")" = "$(uname -m)" ] || compat_fail 'Fixture architecture does not match host'
checksum="$(shasum -a 256 "$COMPAT_ASSETS/rootfs.tar" | awk '{print $1}')"
[ "$checksum" = "$(jq -r '.rootfs_sha256' "$COMPAT_ASSETS/manifest.json")" ] || compat_fail 'Prepared fixture checksum mismatch'
[ "$(shasum -a 256 "$COMPAT_ROOT/tests/fixtures/container-compat/Dockerfile.prepare" | awk '{print $1}')" = "$(jq -r '.fixture_definition_sha256' "$COMPAT_ASSETS/manifest.json")" ] || compat_fail 'Fixture definition changed; prepare a new --assets-dir'
jq --slurpfile fixture "$COMPAT_ASSETS/manifest.json" '.fixture=$fixture[0]' "$COMPAT_OUTPUT_DIR/metadata.json" >"$COMPAT_OUTPUT_DIR/metadata.tmp"
mv "$COMPAT_OUTPUT_DIR/metadata.tmp" "$COMPAT_OUTPUT_DIR/metadata.json"
compat_fixture_context "$COMPAT_WORK_DIR/context"
COMPAT_IMAGE="$(compat_name fixture):latest"
export COMPAT_IMAGE
compat_build "$COMPAT_IMAGE" "$COMPAT_WORK_DIR/context"
fixture_check="$(compat_name fixture-check)"
compat_create "$fixture_check"
compat_capture 0 "$CONTAINER_CMD" exec "$fixture_check" sh -ec \
  'test "$(id -un)" = coder; for file in /etc/agentctl/image-version /etc/agentctl/tooling-version /usr/local/lib/agentctl/compat-socket.mjs; do test -r "$file" || { echo "Unreadable fixture file: $file" >&2; exit 1; }; done; for directory in /tmp /var/tmp /home/coder /workdir; do file=$(mktemp "$directory/compat-check.XXXXXXXX"); rm "$file"; done'
compat_capture 0 "$CONTAINER_CMD" stop "$fixture_check"
compat_capture 0 "$CONTAINER_CMD" rm "$fixture_check"

if [ "$mode" = prepare-upgrade ]; then
  [ ! -e "$state_dir" ] || compat_fail 'Upgrade state directory must be new'
  mkdir -p "$state_dir/resources" "$state_dir/work running" "$state_dir/work stopped"
  upgrade_state_created=1
  state_dir="$(CDPATH= cd -- "$state_dir" && pwd)"
  COMPAT_JOURNAL="$state_dir/resources"; export COMPAT_JOURNAL
  compat_register image "$COMPAT_IMAGE"
  # Move ownership of the image to the retained state journal.
  for entry in "$COMPAT_OUTPUT_DIR"/resources/resource.*; do
    [ -f "$entry" ] || continue
    if jq -e --arg image "$COMPAT_IMAGE" '.type=="image" and .name==$image' "$entry" >/dev/null; then rm -f "$entry"; fi
  done
  running="$(compat_name retained-running)"; stopped="$(compat_name retained-stopped)"
  published_supported=0
  if compat_feature published-socket --publish-socket create; then published_supported=1; fi
  for variant in running stopped; do
    name="$(compat_name "retained-$variant")"
    socket_dir="$(compat_tmpdir "retained-$variant")"
    compat_host_server server "$socket_dir/host.sock"
    printf '%s\n' "baseline-$variant" >"$state_dir/work $variant/host-marker"
    # Keep guest socket paths short; forwarding may prefix the container root.
    if [ "$published_supported" -eq 1 ]; then
      compat_create "$name" --mount "type=bind,src=$state_dir/work $variant,dst=/workdir" \
        --volume "$socket_dir/host.sock:/tmp/host.sock" --publish-socket "$socket_dir/guest.sock:/tmp/guest.sock"
      compat_guest_server "$name" server /tmp/guest.sock
      compat_capture 0 node "$COMPAT_DIR/socket-helper.mjs" client "$socket_dir/guest.sock"
    else
      compat_create "$name" --mount "type=bind,src=$state_dir/work $variant,dst=/workdir" --volume "$socket_dir/host.sock:/tmp/host.sock"
    fi
    compat_capture 0 "$CONTAINER_CMD" exec "$name" node /usr/local/lib/agentctl/compat-socket.mjs client /tmp/host.sock
    printf '%s\n' "$socket_dir" >"$state_dir/$variant.socket-dir"
    compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec 'printf "%s\n" "$1" > /home/coder/.codex/compat-retained' sh "baseline-$variant"
    compat_capture 0 "$CONTAINER_CMD" inspect "$name"
    printf '%s\n' "$COMPAT_STDOUT" >"$state_dir/$variant.inspect.json"
    [ "$variant" != stopped ] || compat_capture 0 "$CONTAINER_CMD" stop "$name"
  done
  jq -n --arg version "$cli_version" --arg image "$COMPAT_IMAGE" --arg run "$COMPAT_RUN_ID" \
    --arg running "$running" --arg stopped "$stopped" --arg commit "$(git -C "$COMPAT_ROOT" rev-parse HEAD)" \
    --argjson published "$published_supported" \
    '{schema_version:1,baseline_version:$version,image:$image,run:$run,running:$running,stopped:$stopped,git_commit:$commit,published_socket:($published==1)}' >"$state_dir/upgrade.json"
  preserve_upgrade=1
  suite_status=upgrade-prepared
  compat_log "Switch both CLI and API server on the host, then run --verify-upgrade --state-dir '$state_dir'"
  exit 0
fi

if [ "$mode" = verify-upgrade ]; then
  [ -f "$state_dir/upgrade.json" ] || compat_fail 'Missing prepared upgrade manifest'
  state_dir="$(CDPATH= cd -- "$state_dir" && pwd)"
  [ "$cli_version" != "$(jq -r '.baseline_version' "$state_dir/upgrade.json")" ] || compat_fail 'Upgrade verification requires a different runtime version'
  export COMPAT_UPGRADE_STATE="$state_dir"
  upgrade_started=1
fi

COMPAT_JOURNAL="$COMPAT_OUTPUT_DIR/resources"; export COMPAT_JOURNAL
. "$COMPAT_DIR/cases.sh"
suite_status=compatible
active=0
[ -n "$start_from" ] || active=1
if [ -n "$filter" ] || [ -n "$start_from" ]; then suite_status=partial; fi
selected=0
for test in $COMPAT_CASES; do
  [ "$test" != retained_upgrade ] || [ "$mode" = verify-upgrade ] || continue
  case "$test" in *"$start_from"*) active=1 ;; esac
  [ "$active" -eq 1 ] || continue
  case "$test" in *"$filter"*) ;; *) continue ;; esac
  selected=$((selected+1))
  COMPAT_TEST_ID="$test"; COMPAT_TEST_DIR="$COMPAT_OUTPUT_DIR/tests/$test"
  mkdir -p "$COMPAT_TEST_DIR"
  export COMPAT_TEST_ID COMPAT_TEST_DIR
  compat_log "Running: $test"
  status=0
  bash "$COMPAT_DIR/supervise.sh" "${COMPAT_TEST_TIMEOUT:-900}" bash "$COMPAT_DIR/worker.sh" "$test" <&0 &
  active_supervisor=$!
  wait "$active_supervisor" || status=$?
  active_supervisor=""
  cleanup_status=0
  cleanup_journal "$COMPAT_JOURNAL" "$test" || cleanup_status=$?
  result=passed
  if [ "$status" -ne 0 ] || [ "$cleanup_status" -ne 0 ]; then result=failed; suite_status=incompatible; fi
  if [ -f "$COMPAT_TEST_DIR/unsupported.json" ] && [ "$result" = passed ] && [ "$test" != resources ]; then result=unsupported; fi
  details=("$COMPAT_TEST_DIR"/copy*.json "$COMPAT_TEST_DIR"/bulk-echo-diagnostic.json "$COMPAT_TEST_DIR"/unsupported.json)
  printf '[]\n' >"$COMPAT_TEST_DIR/details.json"
  for detail in "${details[@]}"; do
    [ -f "$detail" ] || continue
    jq --slurpfile detail "$detail" '. + $detail' "$COMPAT_TEST_DIR/details.json" >"$COMPAT_TEST_DIR/details.tmp"
    mv "$COMPAT_TEST_DIR/details.tmp" "$COMPAT_TEST_DIR/details.json"
  done
  jq -n --arg name "$test" --arg status "$result" --argjson code "$status" --argjson cleanup "$cleanup_status" \
    --slurpfile details "$COMPAT_TEST_DIR/details.json" \
    '{name:$name,status:$status,exit_code:$code,cleanup_exit_code:$cleanup,details:$details[0]}' >"$COMPAT_OUTPUT_DIR/results/$(printf '%03d' "$selected")-$test.json"
  compat_log "$test: $result"
  if ! (
    COMPAT_TEST_ID="health-after-$test"
    COMPAT_TEST_DIR="$COMPAT_OUTPUT_DIR/tests/$test/health"
    mkdir -p "$COMPAT_TEST_DIR"
    export COMPAT_TEST_ID COMPAT_TEST_DIR
    compat_health
  ); then
    suite_status=runtime-unresponsive
    blocked=0
    for pending in $COMPAT_CASES; do
      [ "$pending" != retained_upgrade ] || [ "$mode" = verify-upgrade ] || continue
      if [ "$blocked" -eq 1 ]; then
        jq -n --arg name "$pending" '{name:$name,status:"blocked",reason:"runtime health probe failed"}' >"$COMPAT_OUTPUT_DIR/results/blocked-$pending.json"
      fi
      [ "$pending" != "$test" ] || blocked=1
    done
    break
  fi
done
[ "$selected" -gt 0 ] || { suite_status=setup-failure; compat_fail 'No tests matched'; }
case "$suite_status" in compatible|partial) exit 0 ;; *) exit 1 ;; esac
