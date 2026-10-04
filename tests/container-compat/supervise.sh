#!/usr/bin/env bash
# Run a real command with bounded execution and lossless stream capture.
set -euo pipefail
. "$(dirname "$0")/processes.sh"

: "${COMPAT_OUTPUT_DIR:?Missing report directory}"
limit="$1"
shift
case "$limit" in ''|*[!0-9]*|0) echo 'Invalid deadline' >&2; exit 2 ;; esac
[ "$#" -gt 0 ] || exit 2
mkdir -p "$COMPAT_OUTPUT_DIR/operations"
operation="$(mktemp -d "$COMPAT_OUTPUT_DIR/operations/op.XXXXXXXX")"
printf '%s\n' "$$" >"$operation/supervisor.active"
started="$(date +%s)"
jq -n --argjson deadline "$limit" --argjson started "$started" \
  --arg test "${COMPAT_TEST_ID:-startup}" --args \
  '{test:$test,command:$ARGS.positional[0],arguments:$ARGS.positional[1:],started_at:$started,deadline_seconds:$deadline,status:"running"}' \
  -- "$@" >"$operation/record.json"

command_pid=""
watchdog_pid=""
stdout_pid=""
stderr_pid=""
was_interrupted=0

# Snapshot descendants before terminating parents. Nested operation supervisors
# create their own process groups, so killing only the outer group is insufficient.
is_supervisor() {
  local marker
  for marker in "$COMPAT_OUTPUT_DIR"/operations/*/supervisor.active; do
    [ -f "$marker" ] || continue
    [ "$(cat "$marker")" != "$1" ] || return 0
  done
  return 1
}

terminate_command() {
  local targets="" pid
  [ -n "$command_pid" ] || return 0
  if is_supervisor "$command_pid"; then
    # Let nested supervisors own their timers and reap their workload.
    kill -TERM "$command_pid" 2>/dev/null || true
    sleep "$(( ${COMPAT_KILL_GRACE:-5} + 3 ))"
    kill -KILL -- "-$command_pid" 2>/dev/null || true
    kill -KILL "$command_pid" 2>/dev/null || true
    return 0
  fi
  targets="$(compat_descendants "$command_pid")"
  for pid in $targets; do kill -STOP "$pid" 2>/dev/null || true; done
  kill -STOP "$command_pid" 2>/dev/null || true
  for pid in $targets; do kill -TERM "$pid" 2>/dev/null || true; kill -CONT "$pid" 2>/dev/null || true; done
  # Give parents time to reap children before sending the parent its signal.
  kill -CONT "$command_pid" 2>/dev/null || true
  sleep 0.1
  kill -TERM -- "-$command_pid" 2>/dev/null || true
  kill -TERM "$command_pid" 2>/dev/null || true
  kill -CONT "$command_pid" 2>/dev/null || true
  sleep "${COMPAT_KILL_GRACE:-5}"
  for pid in $(printf '%s\n' $targets | sort -rn); do
    # Nested supervisors need to reap their workload and write its exit status.
    if ! is_supervisor "$pid"; then kill -KILL "$pid" 2>/dev/null || true; sleep 0.1; fi
  done
  # Let a supervising parent reap its killed workload and finalize its report.
  if [ "${1:-timeout}" = timeout ]; then sleep 1; fi
  kill -KILL -- "-$command_pid" 2>/dev/null || true
  kill -KILL "$command_pid" 2>/dev/null || true
}

interrupted() {
  trap ':' INT TERM HUP
  was_interrupted=1
  : >"$operation/interrupted"
  printf '%s\n' interrupted >"$operation/termination"
  if [ -n "$watchdog_pid" ]; then kill "$watchdog_pid" 2>/dev/null || true; fi
  terminate_command interrupt
}
trap interrupted INT TERM HUP

# Normally the workload gets its own process group. Protocol-owned adapters
# inherit their client's group so they remain reachable after a parent exits.
# Explicit stdin forwarding avoids Bash's /dev/null default for background jobs.
if [ "${COMPAT_KEEP_PROCESS_GROUP:-0}" = 1 ]; then set +m; else set -m; fi
: >"$operation/stdout"
: >"$operation/stderr"
exec 3>&1 4>&2
node "$(dirname "$0")/relay.mjs" "$operation/stdout" "$operation/streams.complete" </dev/null >&3 3>&- 4>&- &
stdout_pid=$!
node "$(dirname "$0")/relay.mjs" "$operation/stderr" "$operation/streams.complete" </dev/null >&4 3>&- 4>&- &
stderr_pid=$!
if [ "$was_interrupted" -eq 0 ]; then
  "$@" <&0 >"$operation/stdout" 2>"$operation/stderr" 3>&- 4>&- &
  command_pid=$!
  # A signal can arrive between launching the workload and assigning its PID.
  [ "$was_interrupted" -eq 0 ] || terminate_command interrupt
fi
exec 3>&- 4>&-
if [ "$was_interrupted" -eq 0 ]; then
  (
    timer=""
    timer_interrupted=0
    trap 'timer_interrupted=1; if [ -n "$timer" ]; then kill "$timer" 2>/dev/null || true; fi' INT TERM HUP
    [ ! -f "$operation/interrupted" ] || exit 0
    sleep "$limit" &
    timer=$!
    if [ "$timer_interrupted" -eq 1 ] || [ -f "$operation/interrupted" ]; then kill "$timer" 2>/dev/null || true; fi
    wait "$timer" || true
    if [ "$timer_interrupted" -eq 1 ] || [ -f "$operation/interrupted" ]; then
      kill "$timer" 2>/dev/null || true; wait "$timer" 2>/dev/null || true; exit 0
    fi
    printf '%s\n' timeout >"$operation/termination"
    terminate_command
  ) >/dev/null 2>&1 &
  watchdog_pid=$!
  if [ "$was_interrupted" -eq 1 ]; then kill "$watchdog_pid" 2>/dev/null || true; fi
fi
status=0
if [ -n "$command_pid" ]; then wait "$command_pid" 2>/dev/null || status=$?; fi
process_status="$status"
# Forward the final bytes without depending on FIFO EOF behavior on macOS.
: >"$operation/streams.complete"
stream_status=0
wait "$stdout_pid" 2>/dev/null || stream_status=$?
wait "$stderr_pid" 2>/dev/null || stream_status=$?
if [ -f "$operation/termination" ]; then
  if [ -f "$operation/interrupted" ]; then printf '%s\n' interrupted >"$operation/termination"; fi
  # Do not race the watchdog's KILL escalation after TERM completes the command.
  if [ -n "$watchdog_pid" ]; then wait "$watchdog_pid" 2>/dev/null || true; fi
  if [ "$(cat "$operation/termination")" = timeout ]; then status=124; else status=130; fi
  process_status=0
  if [ -n "$command_pid" ]; then wait "$command_pid" 2>/dev/null || process_status=$?; fi
else
  if [ -n "$watchdog_pid" ]; then
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
fi
[ "$status" -ne 0 ] || status="$stream_status"
set +m
trap - INT TERM HUP
elapsed=$(( $(date +%s) - started ))
termination="$(cat "$operation/termination" 2>/dev/null || true)"
case "$termination" in timeout) status=124 ;; interrupted) status=130 ;; esac
jq --argjson code "$status" --argjson process_code "$process_status" --argjson elapsed "$elapsed" --arg termination "$termination" \
  '. + {status:"complete",exit_code:$code,process_exit_code:$process_code,elapsed_seconds:$elapsed,timed_out:($termination=="timeout"),interrupted:($termination=="interrupted"),stdout:"stdout",stderr:"stderr"}' \
  "$operation/record.json" >"$operation/record.tmp"
mv "$operation/record.tmp" "$operation/record.json"
rm -f "$operation/supervisor.active"
rm -f "$operation/streams.complete"
exit "$status"
