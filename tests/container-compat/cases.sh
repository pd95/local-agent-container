#!/usr/bin/env bash
set -euo pipefail

compat_test_health() {
  compat_health
  compat_capture 0 "$CONTAINER_CMD" system version --format json
  printf '%s' "$COMPAT_STDOUT" | jq -e 'type=="array" and length>=2' >/dev/null || compat_fail 'Missing CLI/API version entries'
}

compat_test_lifecycle() {
  local name workload
  name="$(compat_name lifecycle)"; workload="$(compat_name failed-workload)"
  compat_register container "$name"
  compat_capture 0 "$CONTAINER_CMD" create -t --name "$name" "$COMPAT_IMAGE" sh -ec 'sleep infinity'
  compat_assert_running "$name" 0
  compat_capture 0 "$CONTAINER_CMD" ls -a
  printf '%s' "$COMPAT_STDOUT" | grep -F "$name" >/dev/null || compat_fail 'Stopped container missing from list'
  compat_capture 0 "$CONTAINER_CMD" ls -a --format json
  printf '%s' "$COMPAT_STDOUT" | jq -e --arg name "$name" 'type=="array" and any(.[]; (.id // .name // .configuration.id)==$name)' >/dev/null || compat_fail 'Container missing from JSON list'
  compat_capture 0 "$CONTAINER_CMD" inspect "$name"
  printf '%s' "$COMPAT_STDOUT" | jq -e 'type=="array" or type=="object"' >/dev/null || compat_fail 'Invalid inspect JSON'
  compat_capture 0 "$CONTAINER_CMD" start "$name"
  compat_assert_running "$name" 1
  compat_capture 0 "$CONTAINER_CMD" exec "$name" true
  compat_capture 0 "$CONTAINER_CMD" stop "$name"
  compat_assert_running "$name" 0
  compat_capture 0 "$CONTAINER_CMD" start "$name"
  compat_assert_running "$name" 1
  compat_capture 0 "$COMPAT_ROOT/agentctl" restart --name "$name"
  compat_assert_running "$name" 1
  compat_capture 0 "$CONTAINER_CMD" stop "$name"
  compat_capture 0 "$CONTAINER_CMD" rm "$name"
  compat_assert_absent "$name"
  compat_register container "$workload"
  compat_capture 17 "$CONTAINER_CMD" run --name "$workload" "$COMPAT_IMAGE" sh -ec 'printf workload-out; printf workload-err >&2; exit 17'
  [ "$COMPAT_STDOUT" = workload-out ] || compat_fail 'Workload stdout changed'
  case "$COMPAT_STDERR" in *workload-err) ;; *) compat_fail 'Workload stderr missing (CLI progress may precede it)' ;; esac
  compat_capture 0 "$CONTAINER_CMD" logs "$workload"
  printf '%s%s' "$COMPAT_STDOUT" "$COMPAT_STDERR" | grep -F workload-out >/dev/null || compat_fail 'Workload logs missing'
  compat_health
  compat_create "$name"
}

compat_test_images() {
  local first second name digest context directory architecture repository reference
  # Unique layer bytes force an actual candidate download, even with warm caches.
  directory="$COMPAT_WORK_DIR/pull"
  mkdir -p "$directory/root"
  printf '%s\n' "$COMPAT_RUN_ID" >"$directory/root/compat-pull-marker"
  tar -C "$directory/root" -cf "$directory/layer.tar" compat-pull-marker
  architecture="$(uname -m)"
  case "$architecture" in arm64|aarch64) architecture=arm64 ;; x86_64) architecture=amd64 ;; *) compat_fail 'Unsupported registry fixture architecture' ;; esac
  repository="$(compat_name pull)"
  compat_start_helper node "$COMPAT_DIR/registry-helper.mjs" "$directory/layer.tar" "$architecture" "$repository" "$COMPAT_TEST_DIR/pull-requests.txt"
  cp "$COMPAT_TEST_DIR/server.address" "$COMPAT_TEST_DIR/pull-registry.json"
  reference="127.0.0.1:$(jq -er '.port' "$COMPAT_TEST_DIR/server.address")/$repository:latest"
  compat_register image "$reference"
  compat_capture 0 "$CONTAINER_CMD" image pull --scheme http "$reference"
  compat_capture 0 "$CONTAINER_CMD" image inspect "$reference"
  digest="$(jq -er '.index_digest' "$COMPAT_TEST_DIR/server.address")"
  printf '%s' "$COMPAT_STDOUT" | jq -e --arg digest "$digest" '(if type=="array" then .[0] else . end) | (.descriptor.digest // .configuration.descriptor.digest)==$digest' >/dev/null || compat_fail 'Pulled image digest differs from registry fixture'
  digest="$(jq -er '.manifest_digest' "$COMPAT_TEST_DIR/server.address")"
  printf '%s' "$COMPAT_STDOUT" | jq -e --arg digest "$digest" '(if type=="array" then .[0] else . end) | any(.variants[]; .digest==$digest)' >/dev/null || compat_fail 'Pulled image manifest differs from registry fixture'
  grep -Fx "GET /v2/$repository/blobs/$(jq -er '.layer_digest' "$COMPAT_TEST_DIR/server.address")" "$COMPAT_TEST_DIR/pull-requests.txt" >/dev/null || compat_fail 'Image pull did not download the unique fixture layer'
  compat_capture 0 remove_image_ref "$reference"
  compat_capture failure "$CONTAINER_CMD" image inspect "$reference"
  first="$(compat_name image-a):latest"; second="$(compat_name image-b):latest"; name="$(compat_name image-use)"
  context="$COMPAT_WORK_DIR/context"
  compat_fixture_context "$context"
  compat_build "$first" "$context"
  compat_capture 0 "$CONTAINER_CMD" image inspect "$first"
  printf '%s' "$COMPAT_STDOUT" | jq -e 'type=="object" or type=="array"' >/dev/null || compat_fail 'Invalid image inspect JSON'
  compat_register image "$second"
  compat_capture 0 "$CONTAINER_CMD" image tag "$first" "$second"
  compat_capture 0 "$CONTAINER_CMD" image ls
  printf '%s' "$COMPAT_STDOUT" | grep -F "${first%:latest}" >/dev/null || compat_fail 'Built image absent from table'
  compat_capture 0 "$CONTAINER_CMD" image ls --format json
  printf '%s' "$COMPAT_STDOUT" | jq -e --arg ref "$second" 'any(.[]; ((.reference // .configuration.name // .configuration.reference // "") | sub("^docker\\.io/library/"; ""))==$ref and ((.descriptor.digest // .configuration.descriptor.digest) | startswith("sha256:")))' >/dev/null || compat_fail 'Image reference/digest unavailable'
  compat_register container "$name"
  compat_capture 0 "$CONTAINER_CMD" create -t --name "$name" "$second" sh -ec 'sleep infinity'
  compat_capture 0 "$CONTAINER_CMD" inspect "$name"
  digest="$(printf '%s' "$COMPAT_STDOUT" | jq -er '.[0].configuration.image.descriptor.digest')"
  printf 'retagged\n' >"$context/retag-marker"
  printf '\nCOPY retag-marker /etc/compat-retag-marker\n' >>"$context/Dockerfile"
  compat_build "$first" "$context"
  compat_capture 0 "$CONTAINER_CMD" image tag "$first" "$second"
  compat_capture 0 "$CONTAINER_CMD" image ls --format json
  [ "$digest" != "$(printf '%s' "$COMPAT_STDOUT" | jq -er --arg ref "$second" '.[] | select(((.reference // .configuration.name // .configuration.reference // "") | sub("^docker\\.io/library/"; ""))==$ref) | (.descriptor.digest // .configuration.descriptor.digest)')" ] || compat_fail 'Rebuild did not change image digest'
  compat_capture 0 "$CONTAINER_CMD" inspect "$name"
  [ "$digest" = "$(printf '%s' "$COMPAT_STDOUT" | jq -er '.[0].configuration.image.descriptor.digest')" ] || compat_fail 'Existing container followed a moved image tag'
  compat_capture 0 "$CONTAINER_CMD" start "$name"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec 'test ! -e /etc/compat-retag-marker'
  compat_capture 0 "$CONTAINER_CMD" stop "$name"
  compat_capture 0 "$CONTAINER_CMD" rm "$name"
  compat_capture 0 remove_image_ref "$second"
  compat_capture failure "$CONTAINER_CMD" image inspect "$second"
}

compat_test_exec() {
  local name
  name="$(compat_name exec)"
  compat_create "$name"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" printf '%s\n' '' 'a b' '"quoted"' '$literal;*' 'back\slash' 'line
break'
  printf '%s\n' '' 'a b' '"quoted"' '$literal;*' 'back\slash' 'line
break' >"$COMPAT_TEST_DIR/expected"
  cmp "$COMPAT_TEST_DIR/expected" "$COMPAT_TEST_DIR/capture.stdout" || compat_fail 'Exec changed arguments'
  compat_capture 23 "$CONTAINER_CMD" exec "$name" sh -ec 'printf out; printf err >&2; exit 23'
  [ "$COMPAT_STDOUT" = out ] && [ "$COMPAT_STDERR" = err ] || compat_fail 'Exec merged or changed streams'
  compat_capture 0 "$COMPAT_ROOT/agentctl" exec --name "$name" --no-tty -- env 'COMPAT_VALUE=a b;$literal' sh -ec 'test "$COMPAT_VALUE" = '\''a b;$literal'\''; test "$PWD" = /workdir; test ! -t 0; test ! -t 1; test "$(id -un)" = coder'
  compat_capture 0 "$CONTAINER_CMD" exec -u 0 "$name" id -u
  [ "$COMPAT_STDOUT" = 0 ] || compat_fail 'Root exec did not run as root'
  compat_capture 0 "$CONTAINER_CMD" exec --user root "$name" true
  # The real CLI must see the PTY; placing the capturing adapter inside script
  # would redirect its stdin/stdout and invalidate this check.
  compat_capture 0 bash "$COMPAT_DIR/supervise.sh" "${COMPAT_QUERY_TIMEOUT:-30}" \
    script -q "$COMPAT_TEST_DIR/pty.log" "$COMPAT_REAL_CONTAINER" exec -it "$name" sh -ec 'test -t 0 && test -t 1 && printf COMPAT_TTY_OK' </dev/null
  grep -F COMPAT_TTY_OK "$COMPAT_TEST_DIR/pty.log" >/dev/null || compat_fail 'Interactive exec did not allocate a TTY'
}

compat_test_streams() {
  local name
  name="$(compat_name streams)"
  compat_create "$name"
  printf '{"jsonrpc":"2.0","id":1,"method":"ping"}\n' >"$COMPAT_TEST_DIR/input"
  compat_capture 0 "$COMPAT_ROOT/agentctl" exec --name "$name" --stdio -- cat <"$COMPAT_TEST_DIR/input"
  cmp "$COMPAT_TEST_DIR/input" "$COMPAT_TEST_DIR/capture.stdout" || compat_fail 'agentctl stdio changed protocol bytes'
  compat_capture 0 bash "$COMPAT_DIR/supervise.sh" "${COMPAT_QUERY_TIMEOUT:-30}" \
    node "$COMPAT_DIR/protocol-client.mjs" "$COMPAT_ROOT/agentctl" exec --name "$name" --stdio -- cat
  compat_capture 0 "$CONTAINER_CMD" exec -i "$name" cat < /dev/null
  [ ! -s "$COMPAT_TEST_DIR/capture.stdout" ] || compat_fail 'Empty stdin/EOF produced data'
  node -e 'const b=Buffer.alloc(2*1024*1024); for(let i=0;i<b.length;i++)b[i]=i%256; process.stdout.write(b)' >"$COMPAT_TEST_DIR/binary"
  # Bulk managed transfers consume their input before producing their response.
  # Exercise those real production paths, separately from simultaneous echo.
  compat_capture 0 refresh_container_file "$name" "$COMPAT_TEST_DIR/binary" /tmp/compat-binary coder:coder 640
  compat_capture 0 "$COMPAT_ROOT/agentctl" exec --name "$name" --stdio -- cat /tmp/compat-binary </dev/null
  cmp "$COMPAT_TEST_DIR/binary" "$COMPAT_TEST_DIR/capture.stdout" || compat_fail 'Large binary stream corrupted or truncated'
  cp "$COMPAT_TEST_DIR/capture.stdout" "$COMPAT_TEST_DIR/binary-download"
  compat_capture 31 "$COMPAT_ROOT/agentctl" exec --name "$name" --stdio -- sh -ec 'cat; printf separate-stderr >&2; exit 31' <"$COMPAT_TEST_DIR/input"
  cmp "$COMPAT_TEST_DIR/input" "$COMPAT_TEST_DIR/capture.stdout" || compat_fail 'Failed stdio command changed stdout'
  [ "$COMPAT_STDERR" = separate-stderr ] || compat_fail 'Failed stdio command changed stderr'
  # A stress failure must not interfere with the remaining mandatory checks.
  compat_bulk_echo_diagnostic "$name"
  compat_health
}

compat_bulk_echo_diagnostic() {
  local name="$1" status=passed code bytes
  compat_capture any "$CONTAINER_CMD" exec -i "$name" cat <"$COMPAT_TEST_DIR/binary"
  code="$COMPAT_STATUS"
  bytes="$(wc -c <"$COMPAT_TEST_DIR/capture.stdout" | tr -d ' ')"
  if [ "$code" -eq 124 ]; then status=timed-out
  elif [ "$code" -ne 0 ] || ! cmp -s "$COMPAT_TEST_DIR/binary" "$COMPAT_TEST_DIR/capture.stdout"; then status=regression; fi
  jq -n --arg status "$status" --argjson code "$code" --argjson bytes "$bytes" \
    --argjson expected "$(wc -c <"$COMPAT_TEST_DIR/binary" | tr -d ' ')" \
    '{capability:"simultaneous bulk echo",gating:false,status:$status,exit_code:$code,expected_bytes:$expected,received_bytes:$bytes}' \
    >"$COMPAT_TEST_DIR/bulk-echo-diagnostic.json"
  compat_log "Simultaneous bulk echo diagnostic: $status ($bytes bytes; managed bulk transfers determine compatibility)"
}

compat_test_agentctl_run() {
  local name temporary work
  name="$(compat_name named-run)"; temporary="$(compat_name temp-run)"
  work="$COMPAT_TEST_DIR/work"
  mkdir -p "$work"
  printf '{"jsonrpc":"2.0","id":2,"method":"roundtrip"}\n' >"$COMPAT_TEST_DIR/input"
  compat_register container "$name"
  compat_capture 0 "$COMPAT_ROOT/agentctl" run --stdio --name "$name" --image "$COMPAT_IMAGE" --workdir "$work" --cmd cat <"$COMPAT_TEST_DIR/input"
  cmp "$COMPAT_TEST_DIR/input" "$COMPAT_TEST_DIR/capture.stdout" || compat_fail 'agentctl run changed stdio bytes'
  compat_assert_running "$name" 0
  compat_capture 0 "$CONTAINER_CMD" inspect "$name"
  compat_capture 21 "$COMPAT_ROOT/agentctl" run --stdio --name "$name" --image "$COMPAT_IMAGE" --workdir "$work" --cmd sh -ec 'cat; exit 21' <"$COMPAT_TEST_DIR/input"
  cmp "$COMPAT_TEST_DIR/input" "$COMPAT_TEST_DIR/capture.stdout" || compat_fail 'Failed agentctl run changed stdio bytes'
  compat_assert_running "$name" 0
  compat_register container "$temporary"
  compat_capture 0 "$COMPAT_ROOT/agentctl" run --temp --stdio --name "$temporary" --image "$COMPAT_IMAGE" --workdir "$work" --cmd cat <"$COMPAT_TEST_DIR/input"
  cmp "$COMPAT_TEST_DIR/input" "$COMPAT_TEST_DIR/capture.stdout" || compat_fail 'Temporary agentctl run changed stdio bytes'
  compat_assert_absent "$temporary"
}

compat_check_transfers() {
  local name="$1" source="$COMPAT_TEST_DIR/source space:colon/$1" target='/tmp/managed space:colon'
  mkdir -p "$source/tree/nested"
  printf 'file\000bytes\n' >"$source/file"
  printf 'hidden\n' >"$source/tree/.hidden"
  printf 'nested\n' >"$source/tree/nested/file"
  ln -s nested/file "$source/tree/link"
  compat_capture 0 refresh_container_file "$name" "$source/file" "$target/file" coder:coder 640
  compat_capture 0 "$CONTAINER_CMD" exec "$name" cat "$target/file"
  cmp "$source/file" "$COMPAT_TEST_DIR/capture.stdout" || compat_fail 'Refreshed file content differs'
  compat_capture 0 "$CONTAINER_CMD" exec "$name" stat -c '%a %U %G' "$target/file"
  [ "$COMPAT_STDOUT" = '640 coder coder' ] || compat_fail 'Refreshed file mode/ownership differs'
  compat_capture 0 refresh_container_tree "$name" "$source/tree" "$target/tree" coder:coder 640 750
  compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec 'test "$(cat "$1/.hidden")" = hidden; test "$(cat "$1/link")" = nested; test "$(readlink "$1/link")" = nested/file; test "$(stat -c "%a %U %G" "$1/nested/file")" = "640 coder coder"; test "$(stat -c %a "$1")" = 750; printf stale >"$1/stale"' sh "$target/tree"
  printf 'replacement\n' >"$source/tree/nested/file"
  compat_capture 0 refresh_container_tree "$name" "$source/tree" "$target/tree" coder:coder 644 755
  compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec 'test ! -e "$1/stale"; test "$(cat "$1/link")" = replacement; leftovers=$(find "$2" -name "*.agentctl-stage.*" -o -name "*.agentctl-backup.*"); test -z "$leftovers"' sh "$target/tree" "$target"
  # A missing source is a real preflight failure; the installed target survives.
  compat_capture failure bash "$COMPAT_DIR/function.sh" refresh_container_file "$name" "$source/missing" "$target/file"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" cat "$target/file"
  cmp "$source/file" "$COMPAT_TEST_DIR/capture.stdout" || compat_fail 'Failed transfer damaged installed file'
}

compat_check_state() {
  local name="$1"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec 'mkdir -p "$HOME/.codex"; printf state-marker >"$HOME/.codex/compat-state"'
  "$CONTAINER_CMD" exec "$name" "${SETPRIV_ARGS[@]}" bash /usr/local/bin/agent.sh state export >"$COMPAT_TEST_DIR/state.tar"
  tar -tf "$COMPAT_TEST_DIR/state.tar" >"$COMPAT_TEST_DIR/state.entries"
  grep -F .codex/compat-state "$COMPAT_TEST_DIR/state.entries" >/dev/null || compat_fail 'State export omitted marker'
  compat_capture 0 "$CONTAINER_CMD" exec "$name" rm /home/coder/.codex/compat-state
  compat_capture 0 "$CONTAINER_CMD" exec -i "$name" "${SETPRIV_ARGS[@]}" bash /usr/local/bin/agent.sh state import <"$COMPAT_TEST_DIR/state.tar"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" cat /home/coder/.codex/compat-state
  [ "$COMPAT_STDOUT" = state-marker ] || compat_fail 'State archive did not round-trip'
}

compat_copy_diagnostic() {
  local name="$1" status=passed out_status in_status
  printf 'copy-marker:%s\n' "$COMPAT_RUN_ID-$name" >"$COMPAT_TEST_DIR/copy-source"
  rm -f "$COMPAT_TEST_DIR/copy-destination"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" rm -f /tmp/compat-copy
  compat_capture any "$CONTAINER_CMD" copy "$COMPAT_TEST_DIR/copy-source" "$name:/tmp/compat-copy"
  in_status="$COMPAT_STATUS"
  if [ "$in_status" -ne 0 ]; then status=regression
  else
    compat_capture any "$CONTAINER_CMD" exec "$name" cat /tmp/compat-copy
    if [ "$COMPAT_STATUS" -ne 0 ] || ! cmp -s "$COMPAT_TEST_DIR/copy-source" "$COMPAT_TEST_DIR/capture.stdout"; then status=regression; fi
  fi
  compat_capture 0 "$CONTAINER_CMD" exec -i "$name" sh -ec 'cat >/tmp/compat-copy-out' <"$COMPAT_TEST_DIR/copy-source"
  compat_capture any "$CONTAINER_CMD" copy "$name:/tmp/compat-copy-out" "$COMPAT_TEST_DIR/copy-destination"
  out_status="$COMPAT_STATUS"
  if [ "$out_status" -ne 0 ] || ! cmp -s "$COMPAT_TEST_DIR/copy-source" "$COMPAT_TEST_DIR/copy-destination"; then status=regression; fi
  jq -n --arg status "$status" --argjson incoming "$in_status" --argjson outgoing "$out_status" \
    '{capability:"container copy",gating:false,status:$status,copy_in_exit_code:$incoming,copy_out_exit_code:$outgoing}' >"$COMPAT_TEST_DIR/copy-diagnostic.json"
  compat_log "Direct copy diagnostic: $status (streamed transfers determine compatibility)"
}

compat_test_transfers() {
  local name
  name="$(compat_name transfers)"
  compat_create "$name"
  compat_check_transfers "$name"
  compat_check_state "$name"
  compat_copy_diagnostic "$name"
}

compat_test_recovery() {
  local name image restored
  name="$(compat_name recovery-source)"; image="$(compat_name recovery):latest"; restored="$(compat_name recovery-restored)"
  compat_create "$name"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec 'printf restored >"$HOME/.codex/compat-recovery"; chmod 640 "$HOME/.codex/compat-recovery"; ln -s .codex/compat-recovery "$HOME/compat-link"'
  compat_capture 0 "$CONTAINER_CMD" stop "$name"
  compat_capture 0 export_container_for_upgrade "$name" "$COMPAT_WORK_DIR/export.tar" 0
  extract_container_export_rootfs "$COMPAT_WORK_DIR/export.tar" "$COMPAT_WORK_DIR/extracted"
  [ "$(cat "$COMPAT_WORK_DIR/extracted/home/coder/.codex/compat-recovery")" = restored ] || compat_fail 'Export lost changed filesystem contents'
  compat_register image "$image"
  compat_capture 0 build_backup_image_from_export "$image" "$name" "$COMPAT_WORK_DIR/export.tar" "$COMPAT_WORK_DIR/recovery-root" "$COMPAT_WORK_DIR/recovery.Dockerfile" 0
  compat_register container "$restored"
  compat_capture 0 "$CONTAINER_CMD" create -t --name "$restored" "$image" sh -ec 'sleep infinity'
  compat_capture 0 "$CONTAINER_CMD" start "$restored"
  compat_capture 0 "$CONTAINER_CMD" exec -u 0 "$restored" sh -ec 'test "$(cat /home/coder/compat-link)" = restored; test "$(stat -c "%a %U %G" /home/coder/.codex/compat-recovery)" = "640 coder coder"'
}

compat_test_mounts() {
  local name readonly work home
  name="$(compat_name mounts)"; readonly="$(compat_name readonly)"
  work="$COMPAT_TEST_DIR/work space"; home="$COMPAT_TEST_DIR/home space"
  mkdir -p "$work" "$home"
  printf host-marker >"$work/host-marker"
  compat_create "$name" --mount "type=bind,src=$work,dst=/workdir" --mount "type=bind,src=$home,dst=/home/coder"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec 'test "$(cat /workdir/host-marker)" = host-marker; test "$PWD" = /workdir; printf guest-marker >/workdir/guest-marker; printf home-marker >"$HOME/home-marker"'
  [ "$(cat "$work/guest-marker")" = guest-marker ] && [ "$(cat "$home/home-marker")" = home-marker ] || compat_fail 'Guest writes not visible on host'
  compat_capture 0 "$CONTAINER_CMD" stop "$name"
  compat_capture 0 "$CONTAINER_CMD" start "$name"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec 'test "$(cat /workdir/guest-marker)" = guest-marker; test "$(cat "$HOME/home-marker")" = home-marker'
  compat_capture 0 "$CONTAINER_CMD" inspect "$name"
  printf '%s' "$COMPAT_STDOUT" | container_upgrade_info >"$COMPAT_TEST_DIR/config.tsv"
  [ "$(cut -f2 "$COMPAT_TEST_DIR/config.tsv")" = "$work" ] && [ "$(cut -f3 "$COMPAT_TEST_DIR/config.tsv")" = rw ] || compat_fail 'agentctl cannot recover workdir/mount mode'
  compat_create "$readonly" --mount "type=bind,src=$work,dst=/workdir,readonly"
  compat_capture failure "$CONTAINER_CMD" exec -u 0 "$readonly" sh -ec 'printf forbidden >/workdir/forbidden'
  [ ! -e "$work/forbidden" ] || compat_fail 'Read-only bind permitted a write'
  compat_capture 0 "$CONTAINER_CMD" exec "$readonly" cat /workdir/host-marker
  [ "$COMPAT_STDOUT" = host-marker ] || compat_fail 'Read-only bind not readable'
}

compat_test_resources() {
  local name shm
  name="$(compat_name resources)"
  compat_create "$name" -c 1 -m 256M
  compat_capture 0 "$CONTAINER_CMD" inspect "$name"
  printf '%s' "$COMPAT_STDOUT" | container_upgrade_info >"$COMPAT_TEST_DIR/resources.tsv"
  [ "$(cut -f4 "$COMPAT_TEST_DIR/resources.tsv")" = 1 ] || compat_fail 'CPU configuration not observable'
  case "$(cut -f5 "$COMPAT_TEST_DIR/resources.tsv")" in 268435456|256M|256MiB) ;; *) compat_fail 'Memory configuration not observable' ;; esac
  # Guest hardware includes the runtime's VM allocation and overhead. The
  # contract agentctl consumes is the requested configuration in inspect.
  compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec 'printf "online_cpus=%s\n" "$(getconf _NPROCESSORS_ONLN)"; grep "^MemTotal:" /proc/meminfo'
  cp "$COMPAT_TEST_DIR/capture.stdout" "$COMPAT_TEST_DIR/guest-resources.txt"
  compat_capture 0 "$CONTAINER_CMD" stop "$name"
  compat_capture 0 "$CONTAINER_CMD" start "$name"
  compat_capture 0 "$CONTAINER_CMD" inspect "$name"
  printf '%s' "$COMPAT_STDOUT" | container_upgrade_info >"$COMPAT_TEST_DIR/resources-after-restart.tsv"
  cmp "$COMPAT_TEST_DIR/resources.tsv" "$COMPAT_TEST_DIR/resources-after-restart.tsv" || compat_fail 'Resource configuration changed after restart'
  if ! compat_feature shared-memory --shm-size create; then return 0; fi
  shm="$(compat_name shm)"
  compat_create "$shm" --shm-size 32M
  compat_capture 0 container_shm_size "$shm"
  case "$COMPAT_STDOUT" in 33554432|32M|32MiB) ;; *) compat_fail 'Shared-memory configuration missing' ;; esac
  compat_capture 0 "$CONTAINER_CMD" exec "$shm" sh -ec 'test "$(df -k /dev/shm | awk '\''NR==2 {print $2}'\'')" = 32768'
}

compat_test_default_network() {
  local name gateway port
  name="$(compat_name default-network)"
  compat_create "$name"
  compat_capture 0 configure_container_host_alias "$name"
  compat_capture 0 container_network_host_address default
  gateway="$COMPAT_STDOUT"
  [ -n "$gateway" ] || compat_fail 'Default network gateway missing'
  compat_host_server tcp-server 0.0.0.0 0
  port="$(jq -er '.port' "$COMPAT_TEST_DIR/server.address")"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" node /usr/local/lib/agentctl/compat-socket.mjs tcp-client host.container.internal "$port"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec 'ip route | grep -E "^default "'
}

compat_network_address() {
  local name="$1" network="$2"
  "$CONTAINER_CMD" inspect "$name" | jq -er --arg network "$network" \
    '(if type=="array" then .[0] else . end) | first((.networks // .status.networks // [])[] | select((.network // .name // .id)==$network) | (.address // .ipv4Address) | split("/")[0])'
}

compat_network_case() {
  local internal="$1" network other server peer outsider address gateway port control outside_gateway
  local -a options=()
  network="$(compat_name network)"; other="$(compat_name other-network)"
  server="$(compat_name network-server)"; peer="$(compat_name network-peer)"; outsider="$(compat_name network-outsider)"
  [ "$internal" -eq 0 ] || options=(--internal)
  compat_register network "$network"
  if [ "${#options[@]}" -gt 0 ]; then compat_capture 0 network_create_cmd "${options[@]}" "$network"
  else compat_capture 0 network_create_cmd "$network"; fi
  compat_capture 0 network_list_normalized_json
  printf '%s' "$COMPAT_STDOUT" | jq -e --arg name "$network" 'any(.[]; .name==$name and .managed)' >/dev/null || compat_fail 'Network labels/list cannot be parsed'
  compat_capture 0 network_inspect_normalized_json "$network"
  printf '%s' "$COMPAT_STDOUT" | jq -e --arg name "$network" '.name==$name and .managed' >/dev/null || compat_fail 'Network inspect cannot be parsed'
  compat_create "$server" --network "$network"
  compat_guest_server "$server" tcp-server 0.0.0.0 18080
  address="$(compat_network_address "$server" "$network")"
  if [ "$internal" -eq 0 ]; then
    compat_register network "$other"
    compat_capture 0 network_create_cmd "$other"
    compat_create "$peer" --network "$network" --network "$other"
    compat_capture 0 container_network_names "$peer"
    printf '%s\n' "$COMPAT_STDOUT" | grep -Fx "$other" >/dev/null || compat_fail 'Second network attachment missing'
  else compat_create "$peer" --network "$network"; fi
  compat_capture 0 "$CONTAINER_CMD" exec "$peer" node /usr/local/lib/agentctl/compat-socket.mjs tcp-client "$address" 18080
  compat_capture 0 "$CONTAINER_CMD" stop "$peer"
  compat_capture 0 "$CONTAINER_CMD" start "$peer"
  compat_capture 0 "$CONTAINER_CMD" exec "$peer" node /usr/local/lib/agentctl/compat-socket.mjs tcp-client "$address" 18080
  compat_capture failure "$CONTAINER_CMD" network delete "$network"
  compat_capture 0 container_network_host_address "$network"
  gateway="$COMPAT_STDOUT"
  compat_host_server tcp-server 0.0.0.0 0
  port="$(jq -er '.port' "$COMPAT_TEST_DIR/server.address")"
  compat_capture 0 "$CONTAINER_CMD" exec "$peer" node /usr/local/lib/agentctl/compat-socket.mjs tcp-client "$gateway" "$port"
  if [ "$internal" -eq 1 ]; then
    compat_capture 0 configure_container_host_alias "$peer"
    compat_capture 0 "$CONTAINER_CMD" exec "$peer" node /usr/local/lib/agentctl/compat-socket.mjs tcp-client host.container.internal "$port"
  fi
  if [ "$internal" -eq 1 ]; then
    compat_register network "$other"
    compat_capture 0 network_create_cmd --internal "$other"
    compat_create "$outsider" --network "$other"
    compat_capture failure "$CONTAINER_CMD" exec "$outsider" node /usr/local/lib/agentctl/compat-socket.mjs tcp-client "$address" 18080
    # A live listener outside the internal subnet gives a positive control for
    # egress isolation without relying on an unavailable public Internet service.
    control="$(compat_name egress-control)"
    compat_create "$control"
    compat_capture 0 container_network_host_address default
    outside_gateway="$COMPAT_STDOUT"
    compat_capture 0 "$CONTAINER_CMD" exec "$control" node /usr/local/lib/agentctl/compat-socket.mjs tcp-client "$outside_gateway" "$port"
    compat_capture failure "$CONTAINER_CMD" exec "$peer" node /usr/local/lib/agentctl/compat-socket.mjs tcp-client "$outside_gateway" "$port"
  fi
  compat_capture 0 "$CONTAINER_CMD" stop "$peer"
  compat_capture 0 "$CONTAINER_CMD" rm "$peer"
  compat_capture 0 "$CONTAINER_CMD" stop "$server"
  compat_capture 0 "$CONTAINER_CMD" rm "$server"
  compat_capture 0 "$CONTAINER_CMD" network delete "$network"
  compat_capture failure "$CONTAINER_CMD" network inspect "$network"
}

compat_test_named_network() {
  if ! compat_feature named-network create network; then return 0; fi
  compat_network_case 0
}

compat_test_internal_network() {
  if ! compat_feature internal-network --internal network create; then return 0; fi
  compat_network_case 1
}

compat_test_mounted_socket() {
  local name directory socket
  name="$(compat_name mounted-socket)"
  directory="$(compat_tmpdir sockets)"; socket="$directory/host.sock"
  compat_host_server server "$socket"
  compat_create "$name" --volume "$socket:/tmp/host.sock"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" node /usr/local/lib/agentctl/compat-socket.mjs client /tmp/host.sock
  compat_capture 0 "$CONTAINER_CMD" stop "$name"
  compat_capture 0 "$CONTAINER_CMD" start "$name"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" node /usr/local/lib/agentctl/compat-socket.mjs client /tmp/host.sock
  compat_capture 0 "$CONTAINER_CMD" inspect "$name"
  printf '%s' "$COMPAT_STDOUT" | container_extra_mounts | grep -F "$socket" >/dev/null || compat_fail 'Socket mount unavailable in inspect'
}

compat_test_published_socket() {
  local name directory socket
  if ! compat_feature published-socket --publish-socket create; then return 0; fi
  name="$(compat_name published-socket)"
  directory="$(compat_tmpdir published)"; socket="$directory/guest.sock"
  compat_create "$name" --publish-socket "$socket:/tmp/guest.sock"
  compat_guest_server "$name" server /tmp/guest.sock
  compat_capture 0 node "$COMPAT_DIR/socket-helper.mjs" client "$socket"
  compat_capture 0 container_published_sockets "$name"
  printf '%s' "$COMPAT_STDOUT" | grep -F "$socket" >/dev/null || compat_fail 'Published socket not visible in inspect'
  compat_capture 0 "$CONTAINER_CMD" stop "$name"
  [ ! -e "$socket" ] && [ ! -L "$socket" ] || compat_fail 'Published socket listener remained after stop'
  compat_capture 0 "$CONTAINER_CMD" start "$name"
  compat_guest_server "$name" server /tmp/guest.sock
  compat_capture 0 node "$COMPAT_DIR/socket-helper.mjs" client "$socket"
  compat_capture 0 "$CONTAINER_CMD" stop "$name"
  compat_capture 0 "$CONTAINER_CMD" rm "$name"
  [ ! -e "$socket" ] && [ ! -L "$socket" ] || compat_fail 'Published socket remained after deletion'
}

compat_test_ssh() {
  local name directory pid
  if ! compat_feature ssh-forwarding --ssh create; then return 0; fi
  name="$(compat_name ssh)"; directory="$(compat_tmpdir ssh)"
  ssh-keygen -q -t ed25519 -N '' -f "$directory/key"
  SSH_AUTH_SOCK="$directory/agent.sock"; export SSH_AUTH_SOCK
  ssh-agent -D -a "$SSH_AUTH_SOCK" >"$COMPAT_TEST_DIR/ssh-agent.stdout" 2>"$COMPAT_TEST_DIR/ssh-agent.stderr" &
  pid=$!
  COMPAT_HELPER_PIDS="${COMPAT_HELPER_PIDS:-} $pid"
  local attempts=0
  while [ ! -S "$SSH_AUTH_SOCK" ]; do
    kill -0 "$pid" 2>/dev/null || compat_fail 'Disposable SSH agent exited'
    attempts=$((attempts+1)); [ "$attempts" -lt 10 ] || compat_fail 'Disposable SSH agent did not become ready'
    sleep 1
  done
  ssh-add "$directory/key" >/dev/null 2>&1
  ssh-add -L >"$COMPAT_TEST_DIR/expected-key"
  compat_create "$name" --ssh
  compat_capture 0 container_ssh_enabled "$name"
  [ "$COMPAT_STDOUT" = true ] || compat_fail 'SSH forwarding missing from inspect'
  compat_capture 0 "$CONTAINER_CMD" exec -u 0 "$name" sh -ec 'export SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-/var/host-services/ssh-auth.sock}; ssh-add -L'
  cmp "$COMPAT_TEST_DIR/expected-key" "$COMPAT_TEST_DIR/capture.stdout" || compat_fail 'Root forwarding control returned wrong key'
  compat_capture 0 configure_container_ssh_socket "$name"
  compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec 'SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-/var/host-services/ssh-auth.sock}; export SSH_AUTH_SOCK; test -S "$SSH_AUTH_SOCK"; ssh-add -L || { id >&2; ls -ld /var/host-services "$SSH_AUTH_SOCK" >&2; exit 1; }'
  cmp "$COMPAT_TEST_DIR/expected-key" "$COMPAT_TEST_DIR/capture.stdout" || compat_fail 'Forwarded agent returned wrong key'
  compat_capture 0 "$COMPAT_ROOT/agentctl" restart --name "$name"
  compat_capture 0 "$COMPAT_ROOT/agentctl" exec --name "$name" --stdio -- sh -ec 'export SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-/var/host-services/ssh-auth.sock}; ssh-add -L'
  cmp "$COMPAT_TEST_DIR/expected-key" "$COMPAT_TEST_DIR/capture.stdout" || compat_fail 'SSH forwarding failed after restart'
}

compat_test_storage() {
  if ! compat_feature storage-accounting --format system df; then return 0; fi
  compat_capture 0 container_storage_usage_json
  printf '%s' "$COMPAT_STDOUT" | jq -e '.images.total>=0 and .containers.total>=0 and .volumes.total>=0' >/dev/null || compat_fail 'Storage response does not satisfy agentctl parser'
}

compat_test_retained_upgrade() {
  local state="$COMPAT_UPGRADE_STATE" variant name directory published restarted
  published="$(jq -r '.published_socket' "$state/upgrade.json")"
  for variant in running stopped; do
    name="$(jq -er --arg variant "$variant" '.[$variant]' "$state/upgrade.json")"
    compat_capture 0 "$CONTAINER_CMD" inspect "$name"
    # Compare the configuration agentctl actually consumes, allowing unrelated
    # inspect fields to evolve between runtime releases.
    printf '%s' "$COMPAT_STDOUT" | container_upgrade_info >"$COMPAT_TEST_DIR/current-$variant.tsv"
    container_upgrade_info <"$state/$variant.inspect.json" >"$COMPAT_TEST_DIR/baseline-$variant.tsv"
    cmp "$COMPAT_TEST_DIR/current-$variant.tsv" "$COMPAT_TEST_DIR/baseline-$variant.tsv" || compat_fail 'Retained fixture configuration changed before verification'
    [ "$variant" != stopped ] || compat_assert_running "$name" 0
    directory="$(cat "$state/$variant.socket-dir")"
    rm -f "$directory/host.sock"
    compat_host_server server "$directory/host.sock"
    compat_capture 0 "$CONTAINER_CMD" ls --quiet
    restarted=0
    if ! printf '%s\n' "$COMPAT_STDOUT" | grep -Fx "$name" >/dev/null; then
      compat_capture 0 "$CONTAINER_CMD" start "$name"; restarted=1
    fi
    compat_capture 0 "$CONTAINER_CMD" exec "$name" node /usr/local/lib/agentctl/compat-socket.mjs client /tmp/host.sock
    if [ "$published" = true ]; then
      [ "$restarted" -eq 0 ] || compat_guest_server "$name" server /tmp/guest.sock
      compat_capture 0 node "$COMPAT_DIR/socket-helper.mjs" client "$directory/guest.sock"
    fi
    compat_capture 0 "$CONTAINER_CMD" exec "$name" sh -ec 'test "$(cat "$HOME/.codex/compat-retained")" = "$1"; test "$(cat /workdir/host-marker)" = "$1"' sh "baseline-$variant"
    compat_capture 0 "$COMPAT_ROOT/agentctl" refresh --name "$name"
    compat_check_transfers "$name"
    compat_check_state "$name"
    compat_copy_diagnostic "$name"
    mv "$COMPAT_TEST_DIR/copy-diagnostic.json" "$COMPAT_TEST_DIR/copy-$variant.json"
    compat_capture 0 "$CONTAINER_CMD" stop "$name"
    compat_capture 0 export_container_for_upgrade "$name" "$COMPAT_WORK_DIR/$variant-export.tar" 0
    extract_container_export_rootfs "$COMPAT_WORK_DIR/$variant-export.tar" "$COMPAT_WORK_DIR/$variant-root"
    [ "$(cat "$COMPAT_WORK_DIR/$variant-root/home/coder/.codex/compat-retained")" = "baseline-$variant" ] || compat_fail 'Retained filesystem export lost baseline state'
    compat_capture 0 "$CONTAINER_CMD" start "$name"
    compat_capture 0 "$CONTAINER_CMD" exec "$name" true
    compat_capture 0 "$CONTAINER_CMD" exec "$name" node /usr/local/lib/agentctl/compat-socket.mjs client /tmp/host.sock
    if [ "$published" = true ]; then
      compat_guest_server "$name" server /tmp/guest.sock
      compat_capture 0 node "$COMPAT_DIR/socket-helper.mjs" client "$directory/guest.sock"
    fi
  done
}
