#!/usr/bin/env bash
set -euo pipefail

COMPAT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPAT_ROOT="$(CDPATH= cd -- "$COMPAT_DIR/../.." && pwd)"
CONTAINER_CMD="$COMPAT_DIR/container.sh"
export CONTAINER_CMD
COMPAT_CASES='retained_upgrade health lifecycle images exec streams agentctl_run transfers recovery mounts resources default_network named_network internal_network mounted_socket published_socket ssh storage'
COMPAT_OPTIONAL_CASES='named_network internal_network published_socket ssh storage'

compat_log() { printf '[compat] %s\n' "$*"; }
compat_fail() { printf '[compat] FAIL: %s\n' "$*" >&2; exit 1; }

compat_capture() {
  local expected="$1" status=0
  shift
  if [ "${1:-}" = "$COMPAT_ROOT/agentctl" ] || [ "${1:-}" = node ]; then
    bash "$COMPAT_DIR/supervise.sh" "${COMPAT_TEST_TIMEOUT:-900}" "$@" \
      >"$COMPAT_TEST_DIR/capture.stdout" 2>"$COMPAT_TEST_DIR/capture.stderr" || status=$?
  else
    "$@" >"$COMPAT_TEST_DIR/capture.stdout" 2>"$COMPAT_TEST_DIR/capture.stderr" || status=$?
  fi
  COMPAT_STATUS="$status"
  # Text conveniences only; assertions for binary streams use the original files.
  COMPAT_STDOUT="$(LC_ALL=C tr -d '\000' <"$COMPAT_TEST_DIR/capture.stdout")"
  COMPAT_STDERR="$(LC_ALL=C tr -d '\000' <"$COMPAT_TEST_DIR/capture.stderr")"
  case "$expected" in
    any) return 0 ;;
    failure) [ "$status" -ne 0 ] && [ "$status" -ne 124 ] && return 0 ;;
    *) [ "$status" -eq "$expected" ] && return 0 ;;
  esac
  printf 'Command:' >&2; printf ' %q' "$@" >&2; printf '\nexit=%s; expected=%s\nstdout:\n' "$status" "$expected" >&2
  node "$COMPAT_DIR/preview.mjs" "$COMPAT_TEST_DIR/capture.stdout" >&2
  printf '\nstderr:\n' >&2; node "$COMPAT_DIR/preview.mjs" "$COMPAT_TEST_DIR/capture.stderr" >&2
  compat_fail "Operation failed; see $COMPAT_OUTPUT_DIR/operations"
}

compat_load_agentctl() {
  local harness="$COMPAT_TEST_DIR/agentctl-functions.sh"
  # Use the existing unit harness's production-function loading convention.
  sed -e 's/^SCRIPT_DIR=.*/SCRIPT_DIR="$COMPAT_ROOT"/' \
    -e '/^cmd="${1:-}"/,$d' "$COMPAT_ROOT/agentctl" >"$harness"
  . "$harness"
  CONTAINER_CMD="$COMPAT_DIR/container.sh"
  export CONTAINER_CMD
}

compat_name() {
  # Include the test identity so failures cannot make later cases collide.
  # Bounded components keep generated container hostnames within 63 bytes.
  printf 'agentctl-compat-%s-%s-%s' "$COMPAT_RUN_ID" "${COMPAT_TEST_ID:0:8}" "${1:0:16}"
}

compat_tmpdir() {
  local directory
  directory="$(mktemp -d "/tmp/agentctl-compat-$COMPAT_RUN_ID-$1.XXXXXXXX")"
  chmod 700 "$directory"
  compat_register directory "$directory"
  printf '%s\n' "$directory"
}

compat_register() {
  local type="$1" name="$2" file
  mkdir -p "$COMPAT_JOURNAL"
  file="$(mktemp "$COMPAT_JOURNAL/.pending.XXXXXXXX")"
  jq -n --arg type "$type" --arg name "$name" --arg owner "$COMPAT_TEST_ID" \
    --arg run "$COMPAT_RUN_ID" '{type:$type,name:$name,test:$owner,run:$run}' >"$file"
  mv "$file" "$COMPAT_JOURNAL/resource.${file##*.pending.}"
}

compat_create() {
  local name="$1"
  shift
  compat_register container "$name"
  compat_capture 0 "$CONTAINER_CMD" create -t --name "$name" "$@" "$COMPAT_IMAGE" sh -ec 'sleep infinity'
  compat_capture 0 "$CONTAINER_CMD" start "$name"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" true
}

compat_assert_absent() {
  local name="$1"
  compat_capture 0 "$CONTAINER_CMD" ls -a --quiet
  if printf '%s\n' "$COMPAT_STDOUT" | grep -Fx -- "$name" >/dev/null; then compat_fail "Container still exists: $name"; fi
  compat_capture failure "$CONTAINER_CMD" inspect "$name"
}

compat_assert_running() {
  local name="$1" expected="$2" found=0
  compat_capture 0 "$CONTAINER_CMD" ls --quiet
  if printf '%s\n' "$COMPAT_STDOUT" | grep -Fx -- "$name" >/dev/null; then found=1; fi
  [ "$found" -eq "$expected" ] || compat_fail "Unexpected running state for $name"
}

compat_feature() {
  local name="$1" pattern="$2" subcommand="" parent=""
  shift 2
  compat_capture any "$CONTAINER_CMD" "$@" --help
  if [ "$COMPAT_STATUS" -ne 0 ]; then
    [ "$COMPAT_STATUS" -lt 128 ] && [ "$COMPAT_STATUS" -ne 124 ] || compat_fail "Capability probe terminated: $name"
    # Existing mandatory commands must answer help. For optional subcommands,
    # confirm absence through a successful parent help instead of guessing from
    # an arbitrary error message or exit code.
    if [ "$#" -gt 1 ]; then
      subcommand="$2"; parent="$1"
    elif [ "$1" = network ]; then
      subcommand="$1"
    fi
    if [ -n "$subcommand" ]; then
      if [ -n "$parent" ]; then compat_capture 0 "$CONTAINER_CMD" "$parent" --help
      else compat_capture 0 "$CONTAINER_CMD" --help; fi
      if ! printf '%s\n' "$COMPAT_STDOUT" | awk -v command="$subcommand" '$1==command {found=1} END {exit !found}'; then
        jq -n --arg feature "$name" '{feature:$feature,status:"unsupported"}' >"$COMPAT_TEST_DIR/unsupported.json"
        compat_log "Unsupported optional feature: $name"
        return 1
      fi
    fi
    compat_fail "Capability probe failed: $name (see operations)"
  fi
  if [ "$COMPAT_STATUS" -eq 0 ] && printf '%s' "$COMPAT_STDOUT" | grep -F -- "$pattern" >/dev/null; then
    return 0
  fi
  jq -n --arg feature "$name" '{feature:$feature,status:"unsupported"}' >"$COMPAT_TEST_DIR/unsupported.json"
  compat_log "Unsupported optional feature: $name"
  return 1
}

compat_fixture_context() {
  local destination="$1"
  mkdir -p "$destination"
  cp "$COMPAT_ASSETS/rootfs.tar" "$destination/rootfs.tar"
  cp "$COMPAT_ROOT/tests/fixtures/container-compat/Dockerfile" "$destination/Dockerfile"
  cp "$COMPAT_ROOT/agent.sh" "$COMPAT_ROOT/agentctl-path.sh" "$COMPAT_ROOT/VERSION" "$destination/"
  cp "$COMPAT_DIR/socket-helper.mjs" "$destination/socket-helper.mjs"
  cp -R "$COMPAT_ROOT/defaults" "$COMPAT_ROOT/runtimes" "$COMPAT_ROOT/runtimes.d" \
    "$COMPAT_ROOT/features" "$COMPAT_ROOT/features.d" "$destination/"
}

compat_build() {
  local image="$1" context="$2"
  compat_register image "$image"
  compat_capture 0 "$CONTAINER_CMD" build -t "$image" -f "$context/Dockerfile" \
    --build-arg AGENT_RUNTIMES= --build-arg AGENT_DEFAULT_RUNTIME=codex \
    --build-arg AGENT_FEATURES= --build-arg BUILD_TIME=compatibility --no-cache "$context"
}

compat_server_version() {
  jq -er 'select(.status == "running") | (.server.version // .apiServerVersion) | strings
    | capture("(?<version>[0-9]+\\.[0-9]+\\.[0-9]+(?:-[a-zA-Z0-9.-]+)?(?:\\+[a-zA-Z0-9.-]+)?)").version'
}

compat_health() {
  local server_version
  compat_capture 0 "$CONTAINER_CMD" system status --format json
  server_version="$(printf '%s' "$COMPAT_STDOUT" | compat_server_version)" \
    || compat_fail 'API server is not running or has no version'
  if [ -n "${COMPAT_EXPECTED_VERSION:-}" ]; then
    [ "$server_version" = "$COMPAT_EXPECTED_VERSION" ] || compat_fail 'API server version changed during the run'
  fi
  compat_capture 0 "$CONTAINER_CMD" ls
}

compat_host_server() {
  compat_start_helper node "$COMPAT_DIR/socket-helper.mjs" "$1" "$2" "${3:-}"
}

compat_start_helper() {
  local pid attempts=0
  : >"$COMPAT_TEST_DIR/server.address"
  "$@" \
    >"$COMPAT_TEST_DIR/server.address" 2>"$COMPAT_TEST_DIR/server.stderr" &
  pid=$!
  # Owned helpers remain children of a supervised test process; PID cleanup
  # is never replayed from an old journal where the PID could have been reused.
  COMPAT_HELPER_PIDS="${COMPAT_HELPER_PIDS:-} $pid"
  while [ ! -s "$COMPAT_TEST_DIR/server.address" ]; do
    kill -0 "$pid" 2>/dev/null || compat_fail 'Host fixture server exited'
    attempts=$((attempts + 1)); [ "$attempts" -lt 10 ] || compat_fail 'Host fixture server did not become ready'
    sleep 1
  done
}

compat_worker_cleanup() {
  local pid
  for pid in ${COMPAT_HELPER_PIDS:-}; do kill "$pid" 2>/dev/null || true; done
  [ -z "${COMPAT_HELPER_PIDS:-}" ] || sleep 1
  for pid in ${COMPAT_HELPER_PIDS:-}; do kill -KILL "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
}

compat_image_names() {
  jq -r '
    if type != "array" then error("invalid image list") else . end
    | .[] | (.reference // .configuration.name // .configuration.reference // "")
    | if type != "string" or length == 0 then error("missing image reference") else sub("^docker\\.io/library/"; "") end'
}

compat_network_names() {
  jq -r 'if type!="array" then error("invalid network list") else . end
    | .[] | (.id // .name // .configuration.name // .configuration.id // "")
    | if type!="string" or length==0 then error("missing network name") else . end'
}

compat_write_summary() {
  local status="$1" mode="$2" code="$3" cleaned="$4" partial="$5"
  local expected="" test
  for test in $COMPAT_CASES; do
    [ "$test" != retained_upgrade ] || [ "$mode" = verify-upgrade ] || continue
    expected="${expected}${expected:+ }$test"
  done
  jq -n --arg status "$status" --arg mode "$mode" --argjson code "$code" \
    --arg expected "$expected" --arg optional "$COMPAT_OPTIONAL_CASES" \
    --argjson cleaned "$cleaned" --argjson partial "$partial" --slurpfile tests "$COMPAT_OUTPUT_DIR/tests.json" \
    '($expected|split(" ")|sort) as $expected_names | ($optional|split(" ")) as $optional_names
    | {status:$status,mode:$mode,exit_code:$code,cleanup_passed:($cleaned==1),
      compatible:($status=="compatible" and $code==0 and $cleaned==1 and $partial==0
        and ($mode=="run" or $mode=="verify-upgrade") and ($tests[0]|length)>0
        and ($tests[0]|map(.name)|sort)==$expected_names
        and ($tests[0]|all(. as $test | .status=="passed" or (.status=="unsupported" and ($optional_names|index($test.name))!=null)))),tests:$tests[0]}' \
    >"$COMPAT_OUTPUT_DIR/summary.json"
}

compat_guest_server() {
  local name="$1" mode="$2" target="$3" port="${4:-}"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec \
    'rm -f /tmp/compat-server.address /tmp/compat-server.stderr; if test "$1" = server; then rm -f "$2"; fi; nohup node /usr/local/lib/agentctl/compat-socket.mjs "$1" "$2" "$3" >/tmp/compat-server.address 2>/tmp/compat-server.stderr </dev/null &' sh "$mode" "$target" "$port"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec \
    'i=0; until test -s /tmp/compat-server.address; do i=$((i+1)); test "$i" -lt 10 || { cat /tmp/compat-server.stderr >&2; exit 1; }; sleep 1; done'
}

resource_capture() {
  local status=0
  "$@" >"$COMPAT_OUTPUT_DIR/cleanup.stdout" 2>"$COMPAT_OUTPUT_DIR/cleanup.stderr" || status=$?
  return "$status"
}

compat_remove_image() {
  resource_capture "$CONTAINER_CMD" image rm "$1" || resource_capture "$CONTAINER_CMD" image delete "$1"
}

compat_registry_reference_owned() {
  local reference="$1" run="$2" port
  case "$reference" in 127.0.0.1:*/agentctl-compat-"$run"-*:latest) ;; *) return 1 ;; esac
  printf '%s\n' "$reference" | grep -E '^127\.0\.0\.1:[1-9][0-9]{0,4}/agentctl-compat-[a-z0-9-]+:latest$' >/dev/null || return 1
  port="${reference#127.0.0.1:}"; port="${port%%/*}"
  [ "$port" -le 65535 ]
}

compat_runtime_network_list() {
  "$CONTAINER_CMD" network list --format json || "$CONTAINER_CMD" network ls --format json
}

cleanup_journal() {
  local journal="$1" owner="${2:-}" entry type name run test status failed=0
  [ -d "$journal" ] || return 0
  for entry in "$journal"/resource.*; do
    [ -f "$entry" ] || continue
    if ! jq -e '(.type | IN("container","builder","network","image","directory"))
      and (.name | type=="string" and length>0) and (.test | type=="string")
      and (.run | type=="string" and test("^[0-9]{14}-[0-9]+$"))' "$entry" >/dev/null; then
      compat_log "Invalid resource journal entry: $entry"
      return 1
    fi
  done
  # Dependency order: containers (including builder) before networks and images.
  for type in container builder network image directory; do
    for entry in "$journal"/resource.*; do
      [ -f "$entry" ] || continue
      jq -e --arg type "$type" '.type==$type' "$entry" >/dev/null || continue
      name="$(jq -er '.name | strings' "$entry")" || { failed=1; continue; }
      run="$(jq -er '.run | strings' "$entry")" || { failed=1; continue; }
      test="$(jq -er '.test | strings' "$entry")" || { failed=1; continue; }
      [ -z "$owner" ] || [ "$test" = "$owner" ] || continue
      case "$run" in ''|*[!0-9-]*) compat_log "Invalid journal run: $entry"; failed=1; continue ;; esac
      case "$name" in
        127.0.0.1:*/agentctl-compat-"$run"-*)
          [ "$type" = image ] && compat_registry_reference_owned "$name" "$run" || { failed=1; continue; } ;;
        agentctl-compat-"$run"-*)
          if [ "$type" = directory ] || [ "$type" = builder ]; then failed=1; continue; fi
          case "$name" in *[!a-zA-Z0-9_.:-]*) failed=1; continue ;; esac ;;
        /tmp/agentctl-compat-"$run"-*|/private/tmp/agentctl-compat-"$run"-*)
          if [ "$type" != directory ] || ! printf '%s\n' "${name##*/}" | grep -E '^agentctl-compat-[0-9]{14}-[0-9]+-[a-zA-Z0-9_.-]+$' >/dev/null; then failed=1; continue; fi
          case "${name%/*}" in /tmp|/private/tmp) ;; *) failed=1; continue ;; esac ;;
        agentctl-backup-validate-*|agentctl-system-manifest-*)
          [ "$type" = container ] || { failed=1; continue; }
          jq -e '(.generated_by=="validate_backup_image" and (.name | test("^agentctl-backup-validate-[0-9]{14}-[0-9]+$")))
            or (.generated_by=="image_system_manifest_json" and (.name | test("^agentctl-system-manifest-[a-zA-Z0-9_-]+-[0-9]+-[0-9]+$")))' "$entry" >/dev/null || { failed=1; continue; } ;;
        buildkit) [ "$type" = builder ] || { failed=1; continue; } ;;
        *) compat_log "Refusing foreign resource in journal: $name"; failed=1; continue ;;
      esac
      status=0
      compat_log "Cleanup: $type $name"
      case "$type" in
        directory) rm -rf -- "$name" || status=$? ;;
        container|builder)
          if resource_capture "$CONTAINER_CMD" ls -a --quiet; then
            if grep -Fx -- "$name" "$COMPAT_OUTPUT_DIR/cleanup.stdout" >/dev/null; then
              if resource_capture "$CONTAINER_CMD" ls --quiet; then
                if grep -Fx -- "$name" "$COMPAT_OUTPUT_DIR/cleanup.stdout" >/dev/null; then
                  resource_capture "$CONTAINER_CMD" stop "$name" || true
                fi
              else
                status=1
              fi
              resource_capture "$CONTAINER_CMD" rm "$name" || status=$?
            fi
          else status=1; fi
          if [ "$status" -eq 0 ]; then
            resource_capture "$CONTAINER_CMD" ls -a --quiet || status=$?
            if grep -Fx -- "$name" "$COMPAT_OUTPUT_DIR/cleanup.stdout" >/dev/null; then status=1; fi
          fi ;;
        network)
          if resource_capture compat_runtime_network_list; then
            compat_network_names <"$COMPAT_OUTPUT_DIR/cleanup.stdout" >"$COMPAT_OUTPUT_DIR/cleanup.names" || status=1
            if [ "$status" -eq 0 ] && grep -Fx -- "$name" "$COMPAT_OUTPUT_DIR/cleanup.names" >/dev/null; then
              resource_capture "$CONTAINER_CMD" network delete "$name" || status=$?
            fi
          else status=1; fi
          if [ "$status" -eq 0 ]; then
            resource_capture compat_runtime_network_list || status=$?
            compat_network_names <"$COMPAT_OUTPUT_DIR/cleanup.stdout" >"$COMPAT_OUTPUT_DIR/cleanup.names" || status=1
            if grep -Fx -- "$name" "$COMPAT_OUTPUT_DIR/cleanup.names" >/dev/null; then status=1; fi
          fi ;;
        image)
          if resource_capture "$CONTAINER_CMD" image ls --format json; then
            compat_image_names <"$COMPAT_OUTPUT_DIR/cleanup.stdout" >"$COMPAT_OUTPUT_DIR/cleanup.names" || status=1
            if [ "$status" -eq 0 ] && grep -Fx -- "$name" "$COMPAT_OUTPUT_DIR/cleanup.names" >/dev/null; then
              compat_remove_image "$name" || status=$?
            fi
          else status=1; fi
          if [ "$status" -eq 0 ]; then
            resource_capture "$CONTAINER_CMD" image ls --format json || status=$?
            compat_image_names <"$COMPAT_OUTPUT_DIR/cleanup.stdout" >"$COMPAT_OUTPUT_DIR/cleanup.names" || status=1
            if grep -Fx -- "$name" "$COMPAT_OUTPUT_DIR/cleanup.names" >/dev/null; then status=1; fi
          fi ;;
      esac
      if [ "$status" -eq 0 ]; then rm -f "$entry"
      else
        failed=1
        compat_log "Cleanup failed: $type $name (see operations)"
        printf 'Recover with: CONTAINER_CMD=%q bash %q --cleanup --state-dir %q\n' \
          "$COMPAT_REAL_CONTAINER" "$COMPAT_ROOT/tests/run-container-compat-tests.sh" "$(dirname "$journal")" >&2
      fi
    done
  done
  return "$failed"
}
