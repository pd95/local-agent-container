#!/usr/bin/env bash
# Harness checks only: ordinary child processes and local files, no container mock.
set -euo pipefail
SCRIPT_DIRECTORY="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIRECTORY/testlib.sh"
trap cleanup EXIT
COMPAT_SHELL="${COMPAT_TEST_BASH:-$BASH}"
. "$SCRIPT_DIRECTORY/container-compat/lib.sh"
. "$SCRIPT_DIRECTORY/container-compat/processes.sh"

new_case() {
  COMPAT_OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-compat-unit.XXXXXXXX")"
  register_dir_cleanup "$COMPAT_OUTPUT_DIR"
  COMPAT_TEST_DIR="$COMPAT_OUTPUT_DIR/test"
  COMPAT_JOURNAL="$COMPAT_OUTPUT_DIR/resources"
  COMPAT_TEST_ID=local-harness
  COMPAT_RUN_ID="$(date -u +%Y%m%d%H%M%S)-$$"
  COMPAT_KILL_GRACE=1
  mkdir -p "$COMPAT_TEST_DIR" "$COMPAT_JOURNAL"
  export COMPAT_OUTPUT_DIR COMPAT_TEST_DIR COMPAT_TEST_ID COMPAT_JOURNAL COMPAT_RUN_ID COMPAT_KILL_GRACE
}

operation_record() {
  local records=("$COMPAT_OUTPUT_DIR"/operations/*/record.json)
  [ "${#records[@]}" -eq 1 ] || fail 'Expected one operation record'
  printf '%s\n' "${records[0]}"
}

test_compat_capture() {
  begin_test 'compatibility supervisor preserves argument arrays, separate streams, and exit codes'
  new_case
  local status=0 record
  "$COMPAT_SHELL" "$COMPAT_DIR/supervise.sh" 5 "$COMPAT_SHELL" -c \
    'printf "%s\n" "$@"; printf "stderr-only\n" >&2; exit 23' sh '' 'a b' '$literal;*' 'line
break' >"$COMPAT_TEST_DIR/out" 2>"$COMPAT_TEST_DIR/err" || status=$?
  [ "$status" -eq 23 ] || fail 'Supervisor lost exit code'
  printf '%s\n' '' 'a b' '$literal;*' 'line
break' >"$COMPAT_TEST_DIR/expected"
  cmp "$COMPAT_TEST_DIR/out" "$COMPAT_TEST_DIR/expected" || fail 'Supervisor changed stdout'
  printf 'stderr-only\n' >"$COMPAT_TEST_DIR/expected"
  cmp "$COMPAT_TEST_DIR/err" "$COMPAT_TEST_DIR/expected" || fail 'Supervisor changed stderr'
  record="$(operation_record)"
  jq -e '.exit_code==23 and .elapsed_seconds>=0 and .timed_out==false
    and .arguments[-4:]==["","a b","$literal;*","line\nbreak"] and .status=="complete"' "$record" >/dev/null || fail 'Invalid operation metadata'
}

test_compat_process_selection() {
  begin_test 'process selection includes only actual descendants, never ancestors or unrelated PIDs'
  new_case
  local parent child unrelated selected pid
  "$COMPAT_SHELL" -c 'sleep 90 & printf "%s\n" "$!" >"$1"; wait' sh "$COMPAT_TEST_DIR/child" &
  parent=$!
  register_pid_cleanup "$parent"
  sleep 90 &
  unrelated=$!
  register_pid_cleanup "$unrelated"
  wait_file "$COMPAT_TEST_DIR/child"
  child="$(cat "$COMPAT_TEST_DIR/child")"
  register_pid_cleanup "$child"
  selected="$(compat_descendants "$parent")"
  [ "$selected" = "$child" ] || fail "Unsafe process selection for $parent: $selected (expected $child)"
  selected="$(compat_descendants "$child")"
  [ -z "$selected" ] || fail "Leaf process acquired unrelated descendants: $selected"
  kill "$child" 2>/dev/null || true
  wait "$parent" 2>/dev/null || true
  kill "$unrelated" 2>/dev/null || true
  wait "$unrelated" 2>/dev/null || true
}

test_compat_binary_stdin() {
  begin_test 'compatibility supervisor forwards binary stdin and EOF losslessly'
  new_case
  local record
  node -e 'const b=Buffer.alloc(1024*1024); for(let i=0;i<b.length;i++) b[i]=i%256; process.stdout.write(b)' >"$COMPAT_TEST_DIR/input"
  "$COMPAT_SHELL" "$COMPAT_DIR/supervise.sh" 5 cat <"$COMPAT_TEST_DIR/input" >"$COMPAT_TEST_DIR/out" 2>"$COMPAT_TEST_DIR/err"
  cmp "$COMPAT_TEST_DIR/input" "$COMPAT_TEST_DIR/out" || fail 'Binary stdin/stdout differs'
  [ ! -s "$COMPAT_TEST_DIR/err" ] || fail 'Successful supervision contaminated stderr'
  record="$(operation_record)"
  cmp "$COMPAT_TEST_DIR/input" "$(dirname "$record")/stdout" || fail 'Captured bytes differ'
}

wait_file() {
  local path="$1" tries=0
  while [ ! -s "$path" ]; do
    tries=$((tries+1)); [ "$tries" -lt 50 ] || fail "Fixture did not start: $path"
    sleep 0.1
  done
}

assert_dead() {
  local pid="$1" state
  if [ "$(uname -s)" = Darwin ]; then state="$(ps -p "$pid" -o stat= 2>/dev/null || true)"
  else state="$(ps -o pid=,stat= | awk -v pid="$pid" '$1==pid { print $2 }')"; fi
  case "$state" in ''|Z*) return 0 ;; *) fail "Supervised child still alive: $pid ($state)" ;; esac
}

test_compat_live_streams() {
  begin_test 'compatibility capture delivers protocol replies before stdin closes'
  new_case
  node "$COMPAT_DIR/protocol-client.mjs" "$COMPAT_SHELL" "$COMPAT_DIR/supervise.sh" 10 \
    "$COMPAT_SHELL" -c 'while IFS= read -r line; do printf "%s\n" "$line"; done' \
    >"$COMPAT_TEST_DIR/out" 2>"$COMPAT_TEST_DIR/err"
  [ ! -s "$COMPAT_TEST_DIR/err" ] || fail 'Live stream capture added stderr'
  [ "$(wc -l <"$COMPAT_TEST_DIR/out" | tr -d ' ')" = 2 ] || fail 'Missing live protocol replies'
}

test_compat_timeout() {
  begin_test 'compatibility deadlines terminate a TERM-resistant workload and its descendant'
  new_case
  local status=0 record child parent
  "$COMPAT_SHELL" "$COMPAT_DIR/supervise.sh" 2 "$COMPAT_SHELL" -c \
    'trap "" TERM; printf "%s\n" "$$" >"$1/parent"; sleep 90 & printf "%s\n" "$!" >"$1/child"; wait' sh "$COMPAT_TEST_DIR" \
    >"$COMPAT_TEST_DIR/out" 2>"$COMPAT_TEST_DIR/err" || status=$?
  [ "$status" -eq 124 ] || fail 'Timeout did not return 124'
  parent="$(cat "$COMPAT_TEST_DIR/parent")"; child="$(cat "$COMPAT_TEST_DIR/child")"
  assert_dead "$parent"; assert_dead "$child"
  record="$(operation_record)"
  jq -e '.exit_code==124 and .timed_out and .elapsed_seconds>=2 and .elapsed_seconds<10' "$record" >/dev/null || fail 'Timeout report incorrect'
}

test_compat_interrupt() {
  begin_test 'compatibility interruption terminates descendants and finalizes diagnostics'
  new_case
  local supervisor status=0 record
  "$COMPAT_SHELL" "$COMPAT_DIR/supervise.sh" 90 "$COMPAT_SHELL" -c \
    'trap "wait; exit 0" TERM; printf "%s\n" "$$" >"$1/parent"; sleep 90 & printf "%s\n" "$!" >"$1/child"; wait' sh "$COMPAT_TEST_DIR" \
    < /dev/null >"$COMPAT_TEST_DIR/out" 2>"$COMPAT_TEST_DIR/err" &
  supervisor=$!
  register_pid_cleanup "$supervisor"
  wait_file "$COMPAT_TEST_DIR/child"
  kill -TERM "$supervisor"
  wait "$supervisor" || status=$?
  [ "$status" -eq 130 ] || fail 'Interrupted supervisor did not return 130'
  assert_dead "$(cat "$COMPAT_TEST_DIR/parent")"; assert_dead "$(cat "$COMPAT_TEST_DIR/child")"
  record="$(operation_record)"
  jq -e '.interrupted and .timed_out==false and .exit_code==130' "$record" >/dev/null || fail 'Interruption report incorrect'
}

test_compat_nested_supervision() {
  begin_test 'outer compatibility deadline reaches independently supervised process groups'
  new_case
  local status=0 records record
  "$COMPAT_SHELL" "$COMPAT_DIR/supervise.sh" 2 "$COMPAT_SHELL" "$COMPAT_DIR/supervise.sh" 90 \
    "$COMPAT_SHELL" -c 'trap "" TERM; printf "%s\n" "$$" >"$1/parent"; sleep 90 & printf "%s\n" "$!" >"$1/child"; wait' sh "$COMPAT_TEST_DIR" \
    >"$COMPAT_TEST_DIR/out" 2>"$COMPAT_TEST_DIR/err" || status=$?
  [ "$status" -eq 124 ] || fail 'Outer deadline did not expire'
  assert_dead "$(cat "$COMPAT_TEST_DIR/parent")"; assert_dead "$(cat "$COMPAT_TEST_DIR/child")"
  records=("$COMPAT_OUTPUT_DIR"/operations/*/record.json)
  [ "${#records[@]}" -eq 2 ] || fail 'Nested commands were not both recorded'
  for record in "${records[@]}"; do jq -e '.status=="complete"' "$record" >/dev/null || fail 'Nested record unfinished'; done
}

test_compat_journal() {
  begin_test 'compatibility cleanup removes owned paths and refuses malformed or foreign entries'
  new_case
  local directory foreign entry
  directory="$(compat_tmpdir owned)"
  cleanup_journal "$COMPAT_JOURNAL" || fail 'Owned directory cleanup failed'
  [ ! -d "$directory" ] || fail 'Owned directory leaked'
  foreign="$COMPAT_TEST_DIR/foreign"
  mkdir -p "$foreign"
  compat_register directory "$foreign"
  if cleanup_journal "$COMPAT_JOURNAL"; then fail 'Foreign path accepted'; fi
  [ -d "$foreign" ] || fail 'Foreign path removed'
  rm -f "$COMPAT_JOURNAL"/resource.*
  entry="$COMPAT_JOURNAL/resource.invalid"
  printf '{broken' >"$entry"
  if cleanup_journal "$COMPAT_JOURNAL"; then fail 'Malformed journal accepted'; fi
  rm -f "$entry"
  compat_register directory "/tmp/agentctl-compat-$COMPAT_RUN_ID-escape/../../foreign"
  if cleanup_journal "$COMPAT_JOURNAL"; then fail 'Traversal path accepted'; fi
}

test_compat_summary() {
  begin_test 'partial, blocked, interrupted, preparation, and cleanup failures cannot certify compatibility'
  new_case
  local status test
  printf '[]\n' >"$COMPAT_OUTPUT_DIR/tests.json"
  for test in $COMPAT_CASES; do
    [ "$test" != retained_upgrade ] || continue
    jq --arg name "$test" '. + [{name:$name,status:"passed"}]' "$COMPAT_OUTPUT_DIR/tests.json" >"$COMPAT_OUTPUT_DIR/tests.tmp"
    mv "$COMPAT_OUTPUT_DIR/tests.tmp" "$COMPAT_OUTPUT_DIR/tests.json"
  done
  compat_write_summary compatible run 0 1 0
  jq -e '.compatible' "$COMPAT_OUTPUT_DIR/summary.json" >/dev/null || fail 'Complete passing run was not certified'
  compat_write_summary compatible run 0 1 1
  jq -e '.compatible==false' "$COMPAT_OUTPUT_DIR/summary.json" >/dev/null || fail 'Filtered run certified'
  compat_write_summary compatible run 0 0 0
  jq -e '.compatible==false' "$COMPAT_OUTPUT_DIR/summary.json" >/dev/null || fail 'Cleanup failure certified'
  for status in partial runtime-unresponsive interrupted prepared upgrade-prepared setup-failure incompatible; do
    compat_write_summary "$status" run 0 1 0
    jq -e '.compatible==false' "$COMPAT_OUTPUT_DIR/summary.json" >/dev/null || fail "Status certified: $status"
  done
  printf '[{"name":"health","status":"blocked"}]\n' >"$COMPAT_OUTPUT_DIR/tests.json"
  compat_write_summary compatible run 0 1 0
  jq -e '.compatible==false' "$COMPAT_OUTPUT_DIR/summary.json" >/dev/null || fail 'Blocked test certified'
  printf '[{"name":"health","status":"passed"}]\n' >"$COMPAT_OUTPUT_DIR/tests.json"
  compat_write_summary compatible run 0 1 0
  jq -e '.compatible==false' "$COMPAT_OUTPUT_DIR/summary.json" >/dev/null || fail 'Missing contracts certified'
}

test_compat_resource_names() {
  begin_test 'case names isolate resources and keep container hostnames bounded'
  new_case
  local first second name test
  COMPAT_TEST_ID=named_network
  first="$(compat_name network-server)"
  COMPAT_TEST_ID=internal_network
  second="$(compat_name network-server)"
  [ "$first" != "$second" ] || fail 'Independent cases reused a resource name'
  for test in $COMPAT_CASES; do
    COMPAT_TEST_ID="$test"
    name="$(compat_name longest-component-we-use)"
    [ "${#name}" -le 63 ] || fail "Container name too long: $name"
  done
}

test_compat_socket_helper() {
  begin_test 'host-controlled socket fixtures exchange exact bytes'
  new_case
  local directory port
  directory="$(compat_tmpdir socket-unit)"
  compat_host_server server "$directory/test.sock"
  node "$COMPAT_DIR/socket-helper.mjs" client "$directory/test.sock"
  compat_host_server tcp-server 127.0.0.1 0
  port="$(jq -er '.port' "$COMPAT_TEST_DIR/server.address")"
  node "$COMPAT_DIR/socket-helper.mjs" tcp-client 127.0.0.1 "$port"
  compat_worker_cleanup
  COMPAT_HELPER_PIDS=""
  cleanup_journal "$COMPAT_JOURNAL" || fail 'Local socket fixture leaked'
}

test_compat_list_parsing() {
  begin_test 'cleanup uses the same normalized image references and network identifiers as agentctl'
  new_case
  local output
  output="$(printf '%s' '[{"configuration":{"reference":"docker.io/library/example:latest"}},{"reference":"other:latest"}]' | compat_image_names)"
  [ "$output" = $'example:latest\nother:latest' ] || fail 'Image names not normalized'
  [ -z "$(printf '[]' | compat_image_names)" ] || fail 'Empty image list invalid'
  if printf '[{}]' | compat_image_names; then fail 'Missing image name accepted'; fi
  if printf '{}' | compat_network_names; then fail 'Invalid network list accepted'; fi
}

test_compat_early_pipe_close() {
  begin_test 'early pipeline consumers do not fail capability probes or truncate diagnostics'
  new_case
  "$COMPAT_SHELL" "$COMPAT_DIR/supervise.sh" 10 "$COMPAT_SHELL" -c \
    'printf "needle\n"; head -c 1048576 /dev/zero; printf "tail-marker\n"' | grep -Fq needle
  local record
  record="$(operation_record)"
  jq -e '.exit_code==0 and .timed_out==false' "$record" >/dev/null || fail 'Closed pipe changed successful command status'
  [ "$(wc -c <"${record%/*}/stdout" | tr -d ' ')" = 1048595 ] || fail 'Closed consumer truncated the captured stream'
}

test_compat_server_version() {
  begin_test 'runtime status reads the API server version from the observed nested schema'
  local output
  output="$(printf '%s' '{"client":{"version":"1.5.0"},"server":{"appName":"container-apiserver","version":"1.4.1"},"status":"running"}' | compat_server_version)"
  [ "$output" = 1.4.1 ] || fail 'Server version confused with CLI version'
  output="$(printf '%s' '{"server":{"version":"v1.3.1"},"status":"running"}' | compat_server_version)"
  [ "$output" = 1.3.1 ] || fail 'Server version prefix not normalized'
  output="$(printf '%s' '{"apiServerAppName":"container-apiserver","apiServerVersion":"container-apiserver version 1.3.1 (build: release, commit: unspeci)","status":"running"}' | compat_server_version)"
  [ "$output" = 1.3.1 ] || fail 'Baseline API version schema not parsed'
  if printf '%s' '{"apiServerVersion":"unknown","status":"running"}' | compat_server_version; then fail 'Unknown server version accepted'; fi
  if printf '%s' '{"status":"running"}' | compat_server_version; then fail 'Missing server version accepted'; fi
  if printf '%s' '{"server":{"version":"1.4.1"},"status":"stopped"}' | compat_server_version; then fail 'Stopped server accepted'; fi
}

test_compat_failure_preview() {
  begin_test 'failed binary operations keep full bytes but print bounded terminal diagnostics'
  new_case
  local status=0 record
  (
    compat_capture 0 node -e 'process.stdout.write(Buffer.alloc(2*1024*1024, 0)); process.stderr.write("real-error\n"); process.exitCode=23'
  ) >"$COMPAT_TEST_DIR/failure.out" 2>"$COMPAT_TEST_DIR/failure.err" || status=$?
  [ "$status" -eq 1 ] || fail 'Failed operation was accepted'
  record="$(operation_record)"
  [ "$(wc -c <"${record%/*}/stdout" | tr -d ' ')" = 2097152 ] || fail 'Binary failure capture was truncated'
  [ "$(wc -c <"$COMPAT_TEST_DIR/failure.err" | tr -d ' ')" -lt 4096 ] || fail 'Binary diagnostic flooded the terminal'
  grep -F '2097152 bytes' "$COMPAT_TEST_DIR/failure.err" >/dev/null || fail 'Binary byte count missing'
  grep -F 'binary preview' "$COMPAT_TEST_DIR/failure.err" >/dev/null || fail 'Binary bytes were not escaped'
  grep -F 'real-error' "$COMPAT_TEST_DIR/failure.err" >/dev/null || fail 'Original stderr omitted'
}

test_compat_assertion_failures() {
  begin_test 'guest assertions reject missing files, stale files, and incorrect exec environment or cwd'
  new_case
  python3 - "$COMPAT_DIR/cases.sh" "$COMPAT_TEST_DIR" <<'PYTHON'
import os, pathlib, shlex, subprocess, sys
source = pathlib.Path(sys.argv[1]).read_text()
root = pathlib.Path(sys.argv[2])
scripts = []
for line in source.splitlines():
    if ' sh -' not in line or line.rstrip().endswith('\\'):
        continue
    words = shlex.split(line)
    for index, word in enumerate(words[:-2]):
        if word == 'sh' and words[index+1].startswith('-'):
            assert 'e' in words[index+1], f'Guest shell can hide failed assertions: {line}'
            scripts.append(words[index+2])
def rejects(script, *args, env=None, cwd=None):
    result = subprocess.run(['sh', '-ec', script, 'sh', *map(str, args)], env=env, cwd=cwd,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode != 0, f'Invalid fixture passed: {script}'
transfer = next(script for script in scripts if 'printf stale' in script)
empty = root / 'empty'
empty.mkdir()
rejects(transfer, empty)
assert not (empty / 'stale').exists(), 'Failed transfer assertion continued into mutation'
replacement = next(script for script in scripts if 'test ! -e "$1/stale"' in script)
(empty / 'link').write_text('replacement\n')
(empty / 'stale').write_text('stale\n')
rejects(replacement, empty, empty)
(empty / 'stale').unlink()
(empty / 'link').write_text('wrong\n')
rejects(replacement, empty, empty)
execution = next(script for script in scripts if 'COMPAT_VALUE' in script)
rejects(execution, env={**os.environ, 'COMPAT_VALUE': 'wrong'})
rejects(execution, env={**os.environ, 'COMPAT_VALUE': 'a b;$literal'}, cwd=empty)
PYTHON
}

test_compat_probe_failures() {
  begin_test 'capability errors fail instead of silently skipping advertised features'
  new_case
  local scenario status
  for scenario in create-error missing-subcommand missing-top-level advertised-error timeout absent-option; do
    status=0
    (
      compat_capture() {
        COMPAT_STATUS=0
        COMPAT_STDOUT='SUBCOMMANDS:
  df  Display storage usage'
        case "$scenario:$*" in
          create-error:*) COMPAT_STATUS=1; COMPAT_STDOUT='' ;;
          missing-subcommand:*df*|advertised-error:*df*) COMPAT_STATUS=64; COMPAT_STDOUT='' ;;
          missing-subcommand:*) COMPAT_STDOUT='SUBCOMMANDS:
  status  Display runtime status' ;;
          missing-top-level:*network*) COMPAT_STATUS=64; COMPAT_STDOUT='' ;;
          missing-top-level:*) COMPAT_STDOUT='SUBCOMMANDS:
  create  Create a container' ;;
          timeout:*) COMPAT_STATUS=124; COMPAT_STDOUT='' ;;
          absent-option:*) COMPAT_STDOUT='USAGE: container create [options]' ;;
        esac
      }
      case "$scenario" in
        create-error|absent-option) compat_feature ssh --ssh create ;;
        missing-top-level) compat_feature named-network create network ;;
        *) compat_feature storage --format system df ;;
      esac
    ) >"$COMPAT_TEST_DIR/$scenario.out" 2>"$COMPAT_TEST_DIR/$scenario.err" || status=$?
    [ "$status" -ne 0 ] || fail 'Probe fixture unexpectedly advertised support'
    case "$scenario" in
      missing-subcommand|missing-top-level|absent-option) grep -F 'Unsupported optional feature:' "$COMPAT_TEST_DIR/$scenario.out" >/dev/null || fail 'Genuinely absent capability was rejected' ;;
      *) grep -F '[compat] FAIL:' "$COMPAT_TEST_DIR/$scenario.err" >/dev/null || fail 'Probe error was silently skipped' ;;
    esac
  done
}

test_compat_protocol_failure_cleanup() {
  begin_test 'missing and malformed protocol replies reap TERM-resistant command trees'
  new_case
  local mode status
  cat >"$COMPAT_TEST_DIR/target.mjs" <<'JAVASCRIPT'
import {spawn} from 'node:child_process';
import {writeFileSync} from 'node:fs';
const [directory, mode] = process.argv.slice(2);
process.on('SIGTERM', () => {});
writeFileSync(`${directory}/parent`, String(process.pid));
const child = spawn(process.execPath, ['-e', `process.on('SIGTERM',()=>{}); require('fs').writeFileSync(${JSON.stringify(`${directory}/child`)},String(process.pid)); process.stdout.write('ready'); setInterval(()=>{},1000)`], {stdio: ['ignore', 'pipe', 'inherit']});
child.stdout.once('data', () => { if (mode === 'malformed') process.stdout.write('xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'); });
child.on('close', () => process.exit(0));
JAVASCRIPT
  for mode in missing malformed; do
    rm -f "$COMPAT_TEST_DIR/parent" "$COMPAT_TEST_DIR/child"
    status=0
    COMPAT_PROTOCOL_TIMEOUT_MS=1000 COMPAT_PROTOCOL_KILL_GRACE_MS=500 \
      node "$COMPAT_DIR/protocol-client.mjs" node "$COMPAT_TEST_DIR/target.mjs" "$COMPAT_TEST_DIR" "$mode" \
      >"$COMPAT_TEST_DIR/$mode.out" 2>"$COMPAT_TEST_DIR/$mode.err" || status=$?
    [ "$status" -eq 1 ] || fail 'Protocol failure did not exit 1'
    assert_dead "$(cat "$COMPAT_TEST_DIR/parent")"
    assert_dead "$(cat "$COMPAT_TEST_DIR/child")"
    [ ! -s "$COMPAT_TEST_DIR/$mode.out" ] || fail 'Protocol failure emitted success bytes'
    grep -E 'No protocol reply|First protocol reply differs' "$COMPAT_TEST_DIR/$mode.err" >/dev/null || fail 'Protocol failure lacks a diagnostic'
  done
}

test_compat_protocol_parent_exit_cleanup() {
  begin_test 'protocol ownership reaches nested adapters after their command parent exits'
  new_case
  local status=0
  cat >"$COMPAT_TEST_DIR/early-exit.sh" <<'SHELL'
#!/usr/bin/env bash
set -euo pipefail
# The inner adapter must inherit protocol ownership instead of creating another
# group that becomes unreachable once this launcher exits.
bash "$COMPAT_DIR/supervise.sh" 90 bash -c \
  'trap "" TERM; printf "%s\n" "$$" >"$1/child"; sleep 90 & printf "%s\n" "$!" >"$1/grandchild"; wait' sh "$COMPAT_TEST_DIR" \
  </dev/null >/dev/null 2>&1 &
printf '%s\n' "$!" >"$COMPAT_TEST_DIR/adapter"
while [ ! -s "$COMPAT_TEST_DIR/grandchild" ]; do sleep 0.1; done
exit 1
SHELL
  COMPAT_DIR="$COMPAT_DIR" COMPAT_PROTOCOL_TIMEOUT_MS=1000 COMPAT_PROTOCOL_KILL_GRACE_MS=6000 \
    node "$COMPAT_DIR/protocol-client.mjs" "$COMPAT_SHELL" "$COMPAT_TEST_DIR/early-exit.sh" \
    >"$COMPAT_TEST_DIR/out" 2>"$COMPAT_TEST_DIR/err" || status=$?
  [ "$status" -eq 1 ] || fail 'Premature protocol parent did not fail'
  assert_dead "$(cat "$COMPAT_TEST_DIR/adapter")"
  assert_dead "$(cat "$COMPAT_TEST_DIR/child")"
  assert_dead "$(cat "$COMPAT_TEST_DIR/grandchild")"
  jq -e '.status=="complete" and .interrupted' "$(operation_record)" >/dev/null || fail 'Orphaned adapter did not finish its diagnostics'
}

test_compat_startup_interrupt() {
  begin_test 'cancellation before watchdog creation stays interrupted and does not wait for the deadline'
  new_case
  local directory supervisor status=0 record
  directory="$COMPAT_TEST_DIR/delayed-supervisor"
  mkdir -p "$directory"
  cp "$COMPAT_DIR/processes.sh" "$COMPAT_DIR/relay.mjs" "$directory/"
  python3 - "$COMPAT_DIR/supervise.sh" "$directory/supervise.sh" <<'PYTHON'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
needle = '(\n    timer=""'
assert source.count(needle) == 1
source = source.replace(needle, 'printf ready >"$COMPAT_TEST_DIR/startup.ready"\nsleep 1\n' + needle)
pathlib.Path(sys.argv[2]).write_text(source)
PYTHON
  "$COMPAT_SHELL" "$directory/supervise.sh" 20 "$COMPAT_SHELL" -c 'sleep 90' \
    </dev/null >"$COMPAT_TEST_DIR/out" 2>"$COMPAT_TEST_DIR/err" &
  supervisor=$!
  register_pid_cleanup "$supervisor"
  wait_file "$COMPAT_TEST_DIR/startup.ready"
  kill -TERM "$supervisor"
  wait "$supervisor" || status=$?
  [ "$status" -eq 130 ] || fail 'Startup cancellation lost interruption status'
  record="$(operation_record)"
  jq -e '.interrupted and .timed_out==false and .elapsed_seconds<8' "$record" >/dev/null || fail 'Startup cancellation waited for the full deadline'
}

test_compat_registry_helper() {
  begin_test 'local registry serves valid OCI manifests and exact fixture layer bytes'
  new_case
  mkdir -p "$COMPAT_TEST_DIR/root"
  printf fixture >"$COMPAT_TEST_DIR/root/marker"
  tar -C "$COMPAT_TEST_DIR/root" -cf "$COMPAT_TEST_DIR/layer.tar" marker
  compat_start_helper node "$COMPAT_DIR/registry-helper.mjs" "$COMPAT_TEST_DIR/layer.tar" arm64 fixture "$COMPAT_TEST_DIR/requests"
  node --input-type=module - "$COMPAT_TEST_DIR" <<'JAVASCRIPT'
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const directory = process.argv[2];
const address = JSON.parse(readFileSync(`${directory}/server.address`));
const root = `http://127.0.0.1:${address.port}`;
const response = await fetch(`${root}/v2/fixture/manifests/latest`);
assert.equal(response.status, 200);
const body = Buffer.from(await response.arrayBuffer());
assert.equal(`sha256:${createHash('sha256').update(body).digest('hex')}`, address.index_digest);
const index = JSON.parse(body);
const manifestReply = await fetch(`${root}/v2/fixture/manifests/${index.manifests[0].digest}`);
const manifestBytes = Buffer.from(await manifestReply.arrayBuffer());
assert.equal(`sha256:${createHash('sha256').update(manifestBytes).digest('hex')}`, address.manifest_digest);
const manifest = JSON.parse(manifestBytes);
assert.equal(manifest.schemaVersion, 2);
for (const descriptor of [manifest.config, ...manifest.layers]) {
  const reply = await fetch(`${root}/v2/fixture/blobs/${descriptor.digest}`);
  assert.equal(reply.status, 200);
  const bytes = Buffer.from(await reply.arrayBuffer());
  assert.equal(bytes.length, descriptor.size);
  assert.equal(`sha256:${createHash('sha256').update(bytes).digest('hex')}`, descriptor.digest);
  if (descriptor.digest === address.layer_digest) assert.deepEqual(bytes, readFileSync(`${directory}/layer.tar`));
}
assert.equal((await fetch(`${root}/v2/unknown/manifests/latest`)).status, 404);
JAVASCRIPT
  compat_worker_cleanup
  COMPAT_HELPER_PIDS=""
  compat_registry_reference_owned "127.0.0.1:12345/agentctl-compat-$COMPAT_RUN_ID-images-pull:latest" "$COMPAT_RUN_ID" || fail 'Owned local registry reference rejected'
  local reference
  for reference in "127.0.0.1:99999/agentctl-compat-$COMPAT_RUN_ID-images-pull:latest" \
    "127.0.0.1:12345/foreign:latest" "other-host:12345/agentctl-compat-$COMPAT_RUN_ID-images-pull:latest" \
    "127.0.0.1:12345/agentctl-compat-20000101000000-1-images-pull:latest"; do
    if compat_registry_reference_owned "$reference" "$COMPAT_RUN_ID"; then fail 'Foreign registry reference accepted'; fi
  done
}

main() {
  test_compat_failure_preview
  test_compat_assertion_failures
  test_compat_probe_failures
  test_compat_protocol_failure_cleanup
  test_compat_protocol_parent_exit_cleanup
  test_compat_startup_interrupt
  test_compat_registry_helper
  test_compat_server_version
  test_compat_early_pipe_close
  test_compat_process_selection
  test_compat_capture
  test_compat_binary_stdin
  test_compat_live_streams
  test_compat_timeout
  test_compat_interrupt
  test_compat_nested_supervision
  test_compat_journal
  test_compat_summary
  test_compat_resource_names
  test_compat_socket_helper
  test_compat_list_parsing
  log 'Compatibility harness checks passed'
}
main "$@"
