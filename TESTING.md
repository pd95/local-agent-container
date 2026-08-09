# Testing

This repository includes a small host-side integration test harness for `agentctl`.
Run these tests on the macOS host where Apple's `container` CLI is installed. Do not
run them from inside a container.

For user-facing setup and product docs, start with:
- [README.md](README.md)
- [docs/getting-started.md](docs/getting-started.md)
- [docs/runtimes.md](docs/runtimes.md)
- [docs/local-vs-online.md](docs/local-vs-online.md)
- [docs/remote-control.md](docs/remote-control.md)

## Automated host tests

The automated suite exercises the highest-risk container lifecycle flows without extra
dependencies:

- `run --temp` removes the container after exit
- named `run` keeps the container until explicit removal
- `build --rebuild` stops the temporary `buildkit` support container after a successful build
- `run` rejects `--cpu` and `--mem` for existing named containers
- `run --shm-size` reuses an existing container only when the requested size matches
- backup-enabled `refresh` requires a container runtime with `export --output`
- `refresh --no-backup` preserves user state without creating a backup image
- default `refresh` creates a recovery backup image
- `upgrade` repeats repository restoration, `apk update`, and reinstall commands for
  packages installed through multiple tagged APK repositories
- `refresh` accepts explicit `--cpu` and `--mem` overrides when recreating a container
- refresh preflight failures do not remove the original container
- managed host-only networks enforce same-network communication, cross-network
  isolation, no external route, host-service access through the selected
  gateway, host alias selection, and upgrade preservation
- `run --reset-config` restores image-owned config, model metadata, and `AGENTS.md`
- `refresh --overwrite-config` restores image-owned config, model metadata, and `AGENTS.md`

The default tier is an eight-test smoke suite for quick lifecycle feedback:

```bash
bash tests/run-tests.sh
```

Before a release, runtime upgrade, or compatibility sign-off, run the full
host suite. The full tier includes the smoke tests plus build cleanup,
upgrade/backup/rescue, package manifests, feature installation, and Alpine and
Debian bootstrap coverage:

Run the focused host Unix-socket lifecycle test on macOS first:

```bash
bash tests/run-tests.sh --tier full --filter socket-mount
bash tests/run-tests.sh --tier full --filter published-socket
```

It uses temporary host socket servers and `agent-python` to verify non-root
`coder` data exchange, restart, upgrade preservation, destination replacement,
`--copy`, inspect-visible removal, and cleanup. Because it requires Apple's host
runtime it cannot run in the Linux development container.

The published-socket test uses an explicit mode-0700 host directory and a
non-root `coder` Unix-socket server. It verifies host data exchange, listener
removal and recreation across stop/start/restart, upgrade preservation and
addition/replacement, stopped-source copy, running-copy refusal, targeted
removal, inspect state, doctor diagnostics, unsafe permissions, and collisions
with files, directories, sockets, and symlinks. agentctl must report but never
delete a leftover or colliding host entry.

```bash
bash tests/run-tests.sh --tier full
```

The host-only network test creates two managed internal networks and three
containers, checks same-network and cross-network connectivity, verifies that
external and online access are rejected, starts a temporary host HTTP service
bound to the selected gateway and reaches it through `host.container.internal`,
and confirms upgrade preservation and attached-network deletion safety:

```bash
bash tests/run-tests.sh --tier full --filter host-only
```

The SSH forwarding test requires a working host `SSH_AUTH_SOCK`. It rebuilds
`agent-plain` with the SSH feature preinstalled, verifies non-root agent access,
checks upgrade preservation, and then disables the relay while retaining the
client feature:

```bash
bash tests/run-tests.sh --tier full --filter ssh-forwarding
```

The transport itself has a Linux-compatible Node test using fake stdio and HTTP
MCP servers. It checks lazy initialization, session reuse, streaming/SSE,
fixed paths, header injection, redirects, timeouts, failures, redaction, and the
nonce health endpoint without making the relay a TCP listener:

```bash
node tests/run-mcp-node-tests.mjs
```

The focused macOS MCP test writes redacted host-relay diagnostics beneath
`./tmp/mcp/`. On failure it also prints the guest proxy log before cleanup.
It covers lazy startup, a loopback-only authenticated HTTP upstream, automatic
Codex registration, a temporary Keychain credential, direct-gateway rejection,
repeated named-container reuse, start/restart supervision, stopped-container
doctor checks, upgrade preservation, disablement, and cleanup:

```bash
bash tests/run-tests.sh --tier full --filter managed-mcp
```

On macOS, additionally create a container with `agentctl run --mcp` and point a
client at `http://127.0.0.1:47123/mcp/<name>`. Use `lsof -nP -iTCP:47123` to
confirm the host has no TCP listener; the only host listener is the private
socket below `/tmp/agentctl-$(id -u)/`.

For a real authenticated HTTP MCP smoke, create a dedicated named credential
with `agentctl mcp credential set ID`, reference it through
`bearer_token_keychain` or `header_keychain_credentials`, and restart the
container after rotating it. Never place the value in JSON definitions, test
logs, shell history, Codex configuration, or `./tmp/mcp/`.

For a focused Apple container 1.1 storage-accounting smoke check, run:

```bash
agentctl doctor --host
```

Expected output includes a `Container storage` section with Images,
Containers, and Volumes rows. Values are global runtime accounting;
`Reclaimable` is not a statement that stopped containers or volumes are safe
to delete.

For MCP-enabled containers, the same command includes `Managed MCP relays` and
maps each `agentctl-mcp-relay:<container>` process to its registry, socket,
definitions, leases, and health. A stopped container is expected to report an
inactive relay. `agentctl doctor --name NAME` must treat the managed MCP mount
separately from user socket mounts and published sockets; when it temporarily
starts a stopped container, confirm it also starts and then removes the relay
without launching the configured MCP child.

Also stop a running MCP-enabled container once with the lower-level
`container stop NAME`. Host doctor must prominently report that the managed
relay remains and suggest `agentctl stop --name NAME`; running that suggested
action must remove the verified relay and socket. For Xcode, open a project,
start two `agentctl run --online` sessions against the same persisted container,
and verify closing either session does not break MCP calls in the other.

Focused integration filters are available for narrower validation. The tool-home smoke
builds or requires `agent-plain`, creates a real container with host directories mounted
over both `/workdir` and `/home/coder`, then verifies runtime launchers and package
caches stay under `/opt/agentctl` while user state remains under `/home/coder`:

```bash
bash tests/run-integration-tests.sh --filter tool-home
```

The tagged-package upgrade regression creates an `agent-plain` container, installs
`nano` and `tree` through two tagged aliases of its real APK repositories, performs a
real no-backup upgrade, and verifies that the complete repository and package commands
appear both during preflight and in the final reminder:

```bash
bash tests/run-integration-tests.sh --tier full --filter tagged-apk
```

This test requires macOS with Apple's `container` CLI. It uses `agentctl run --cmd true`
to create the container with a long-running internal `sleep infinity` command, then
starts it again and runs assertions with `agentctl exec --no-tty`. The image's default
command is not used for this smoke because `agent.sh run` launches a runtime and is not a
daemon.

To exercise the optional Claude tool-home assertions, rebuild the image with Claude
included first:

```bash
./agentctl build --image agent-plain --runtimes codex,claude --rebuild
bash tests/run-integration-tests.sh --filter tool-home
```

You can point the harness at another `agentctl` binary or container runtime command:

```bash
AGENTCTL=/path/to/agentctl CONTAINER_CMD=container \
  bash tests/run-tests.sh --tier full
```

## Manual Remote Control smoke test

Remote Control requires a real ChatGPT account, an eligible ChatGPT client, and
an interactive pairing action. It is intentionally not exercised by the
automated host suite. Automated unit tests cover the isolated parsing,
ownership, locking, authentication freshness, and stop-ordering rules without
reading or replacing real user credentials. The complete Apple-container
lifecycle remains part of this manual smoke test.

Run this smoke test on the macOS host with an existing Codex container. Do not
paste pairing codes, authentication payloads, or Keychain output into test logs
or issues.

Start the service and verify local health:

```bash
agentctl remote-control start --name NAME
agentctl remote-control status --name NAME
agentctl remote-control status --name NAME --json
agentctl exec --name NAME --no-tty -- ps -o pid,ppid,stat,args
```

Expected results:

- Start returns after reporting `running`, `connecting`, or `connected`.
- A `codex app-server --remote-control --listen unix://` process is present for
  the Alpine direct backend.
- `state` is `running` when local health is confirmed but Codex did not replay
  its current provider connection notification.
- `remote_status: null` is allowed and does not mean disconnected.

Pair explicitly, enter the short-lived code only in the intended ChatGPT
client, and confirm that the container environment and threads are reachable:

```bash
agentctl remote-control pair --name NAME
```

For local/remote coexistence, start Remote Control first, then open a new local
Codex session. Confirm that local and remote interactions both work. If the App
Server log reports `thread-store conflict`, close the older local-only session
that was active before Remote Control and open a new one:

```bash
agentctl exec --name NAME --no-tty -- \
  tail -n 100 /tmp/agentctl-remote-control/service.log
```

Verify persistence across ordinary lifecycle commands:

```bash
agentctl stop --name NAME
agentctl remote-control status --name NAME
# Expected: container_stopped

agentctl start --name NAME
agentctl remote-control status --name NAME
# Expected: running, connecting, or connected
```

The stop and subsequent start should print Keychain-auth synchronization
messages when comparison is required. Authentication token refresh timing is
controlled by Codex and cannot be forced deterministically. Validate the result
without inspecting secrets by confirming that a subsequent online Codex session
authenticates normally.

Finally, explicitly disable the service and verify that ordinary container
startup no longer restores it:

```bash
agentctl remote-control stop --name NAME
agentctl stop --name NAME
agentctl start --name NAME
agentctl remote-control status --name NAME
# Expected: stopped
```

An empty direct-backend service log is normal. It is an error log, not an
activity, pairing, or connected-client log.

## Automated shell unit tests

These lightweight tests validate `agentctl` argument plumbing without needing the macOS
`container` runtime:

```bash
bash tests/run-unit-tests.sh
```

Use the image-specific manual checks below when you need broader smoke coverage,
interactive Codex validation, or image/toolchain verification that is not yet automated.

## Manual stdio protocol bridge tests

Use these host-side checks when validating `agentctl exec --stdio` and
`agentctl run --stdio` for local stdio protocols such as ACP or MCP. Start or
create a persistent container first for the `exec --stdio` checks:

```bash
agentctl run --name agent-stdio-smoke --image agent-python --cmd true
```

Verify stdin/stdout round-trip behavior:

```bash
printf 'ping\n' | agentctl exec --stdio --name agent-stdio-smoke -- cat
```

Expected output:

```text
ping
```

Verify the command is not attached to a TTY:

```bash
agentctl exec --stdio --name agent-stdio-smoke -- \
  sh -lc 'test ! -t 0 && test ! -t 1 && echo no-tty'
```

Expected output:

```text
no-tty
```

Verify newline-delimited JSON-RPC can pass through unchanged:

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"ping"}\n' | \
  agentctl exec --stdio --name agent-stdio-smoke -- \
  node -e 'process.stdin.pipe(process.stdout)'
```

Expected output:

```json
{"jsonrpc":"2.0","id":1,"method":"ping"}
```

Verify the same bridge through `run` lifecycle handling:

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"ping"}\n' | \
  agentctl run --stdio --name agent-stdio-smoke --image agent-python \
  --workdir testing/agent-python --cmd \
  node -e 'process.stdin.pipe(process.stdout)'
```

Expected output:

```json
{"jsonrpc":"2.0","id":1,"method":"ping"}
```

For an MCP server smoke, start Codex as an MCP stdio server through the bridge
and initialize it with an MCP client. At minimum, a client should send
`initialize`, `notifications/initialized`, and `tools/list`; a healthy Codex MCP
server reports tools such as `codex` and `codex-reply`.

## Smoke tests

These checks confirm the curated image set is present and the expected tools exist. Run
each command from its corresponding `testing/<image>` directory so the container only
mounts that subtree. The `--cmd` checks should work even when Ollama is not running on
the host.

```bash
agentctl run --image agent-plain --temp --workdir testing/agent-plain --cmd bash -lc 'zsh --version && bash --version && git --version && rg --version && jq --version && node --version && npm --version && printf "%s" "$PATH" | grep -q /opt/agentctl/bin && codex_path="$(command -v codex)" && case "$codex_path" in /home/coder/*) exit 1 ;; esac && codex --version'
agentctl run --image agent-python --temp --workdir testing/agent-python --cmd bash -lc 'zsh --version && which python && python -c "import sys; print(sys.executable)" && node --version && npm --version'
agentctl run --image agent-swift --temp --workdir testing/agent-swift --cmd bash -lc 'zsh --version && swift --version && swift-format --version && command -v format >/dev/null && command -v lint >/dev/null && node --version && npm --version'
agentctl run --image agent-office --temp --workdir testing/agent-office --cmd bash -lc 'zsh --version && python -c "import docx, openpyxl, reportlab; print(\"python-ok\")" && node -e "require(\"pptxgenjs\"); console.log(\"node-ok\")"'
```

Also verify the image metadata file is present and readable:

```bash
agentctl run --image agent-plain --temp --workdir testing/agent-plain --cmd bash -lc 'test -f /etc/agentctl/image.md && sed -n "1,20p" /etc/agentctl/image.md'
agentctl run --image agent-python --temp --workdir testing/agent-python --cmd bash -lc 'test -f /etc/agentctl/image.md && sed -n "1,20p" /etc/agentctl/image.md'
agentctl run --image agent-swift --temp --workdir testing/agent-swift --cmd bash -lc 'test -f /etc/agentctl/image.md && sed -n "1,20p" /etc/agentctl/image.md'
agentctl run --image agent-office --temp --workdir testing/agent-office --cmd bash -lc 'test -f /etc/agentctl/image.md && sed -n "1,20p" /etc/agentctl/image.md'
```

Also verify the image-owned config, default profile files, model metadata, and
version provenance are present and match the default user copies inside the
image. No build scaffolding files should remain:

```bash
agentctl run --image agent-plain --temp --workdir testing/agent-plain --cmd bash -lc 'test -f /etc/agentctl/codex/config.toml && test -f /etc/agentctl/codex/gpt-oss.config.toml && test -f /etc/agentctl/codex/local_models.json && diff -q /etc/agentctl/codex/config.toml /home/coder/.codex/config.toml && diff -q /etc/agentctl/codex/gpt-oss.config.toml /home/coder/.codex/gpt-oss.config.toml && diff -q /etc/agentctl/codex/local_models.json /home/coder/.codex/local_models.json'
agentctl run --image agent-python --temp --workdir testing/agent-python --cmd bash -lc 'test -f /etc/agentctl/codex/config.toml && test -f /etc/agentctl/codex/gpt-oss.config.toml && test -f /etc/agentctl/codex/local_models.json && diff -q /etc/agentctl/codex/config.toml /home/coder/.codex/config.toml && diff -q /etc/agentctl/codex/gpt-oss.config.toml /home/coder/.codex/gpt-oss.config.toml && diff -q /etc/agentctl/codex/local_models.json /home/coder/.codex/local_models.json'
agentctl run --image agent-swift --temp --workdir testing/agent-swift --cmd bash -lc 'test -f /etc/agentctl/codex/config.toml && test -f /etc/agentctl/codex/gpt-oss.config.toml && test -f /etc/agentctl/codex/local_models.json && diff -q /etc/agentctl/codex/config.toml /home/coder/.codex/config.toml && diff -q /etc/agentctl/codex/gpt-oss.config.toml /home/coder/.codex/gpt-oss.config.toml && diff -q /etc/agentctl/codex/local_models.json /home/coder/.codex/local_models.json'
agentctl run --image agent-office --temp --workdir testing/agent-office --cmd bash -lc 'test -f /etc/agentctl/codex/config.toml && test -f /etc/agentctl/codex/gpt-oss.config.toml && test -f /etc/agentctl/codex/local_models.json && diff -q /etc/agentctl/codex/config.toml /home/coder/.codex/config.toml && diff -q /etc/agentctl/codex/gpt-oss.config.toml /home/coder/.codex/gpt-oss.config.toml && diff -q /etc/agentctl/codex/local_models.json /home/coder/.codex/local_models.json'
```

```bash
agentctl run --image agent-plain --temp --workdir testing/agent-plain --cmd sh -lc 'test -f /etc/agentctl/claude/settings.json && test -f /etc/agentctl/image-version && test -f /etc/agentctl/tooling-version && test "$(cat /etc/agentctl/image-version)" = "$(cat /etc/agentctl/tooling-version)" && ! find /etc/agentctl /home/coder/.codex -name .gitkeep -print | grep -q .'
```

Also verify global AGENTS guidance points at the image metadata file:

```bash
agentctl run --image agent-plain --temp --workdir testing/agent-plain --cmd bash -lc 'test -L /home/coder/.codex/AGENTS.md && readlink /home/coder/.codex/AGENTS.md'
agentctl run --image agent-python --temp --workdir testing/agent-python --cmd bash -lc 'test -L /home/coder/.codex/AGENTS.md && readlink /home/coder/.codex/AGENTS.md'
agentctl run --image agent-swift --temp --workdir testing/agent-swift --cmd bash -lc 'test -L /home/coder/.codex/AGENTS.md && readlink /home/coder/.codex/AGENTS.md'
agentctl run --image agent-office --temp --workdir testing/agent-office --cmd bash -lc 'test -L /home/coder/.codex/AGENTS.md && readlink /home/coder/.codex/AGENTS.md'
```

## Refresh flow

Use a persistent container so there is state to preserve, then recreate it with
`agentctl refresh`. Unless the test is specifically about backup images, prefer
`--no-backup` so the manual test does not leave export images behind. Remove each named
test container after the check completes.

```bash
agentctl run --name agent-refresh-smoke --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'mkdir -p /home/coder/.codex && echo refresh-ok >/home/coder/.codex/refresh-smoke.txt'
agentctl refresh --name agent-refresh-smoke --no-backup
agentctl run --name agent-refresh-smoke --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'cat /home/coder/.codex/refresh-smoke.txt'
agentctl rm --name agent-refresh-smoke
```

Expected output includes `refresh-ok`, and `agentctl refresh --no-backup` should report
that backup export was skipped while still printing the `agentctl run --name
agent-refresh-smoke --reset-config` hint.

Resource changes should go through `refresh`, and `run` should reject them once the
container already exists:

```bash
agentctl run --name agent-refresh-resources --image agent-plain --workdir testing/agent-plain --cpu 2 --mem 4G --cmd true
agentctl run --name agent-refresh-resources --image agent-plain --workdir testing/agent-plain --cpu 4 --mem 8G --cmd true
agentctl refresh --name agent-refresh-resources --cpu 4 --mem 8G --no-backup
agentctl rm --name agent-refresh-resources
```

Shared-memory sizing requires Apple container 1.1 or newer. Verify creation,
matching reuse, conflicting reuse, and upgrade preservation with a disposable
container:

```bash
agentctl run --name agent-shm-smoke --image agent-plain --workdir testing/agent-plain --shm-size 1G --cmd sh -lc 'df -h /dev/shm && mount | grep /dev/shm'
agentctl run --name agent-shm-smoke --image agent-plain --workdir testing/agent-plain --shm-size 1024MiB --cmd true
agentctl run --name agent-shm-smoke --image agent-plain --workdir testing/agent-plain --shm-size 2G --cmd true
agentctl upgrade --name agent-shm-smoke --no-backup --dry-run
agentctl upgrade --name agent-shm-smoke --no-backup --shm-size 2G
agentctl run --name agent-shm-smoke --image agent-plain --workdir testing/agent-plain --cmd sh -lc 'df -h /dev/shm && mount | grep /dev/shm'
agentctl rm --name agent-shm-smoke
```

The matching `1024MiB` reuse should succeed, the conflicting `2G` reuse should
fail with upgrade guidance, the dry run should report `1G -> 1G`, and the final
container should report approximately 2 GiB for `/dev/shm`.

Expected output includes:

- `Error: --cpu and --mem only apply when creating a new container.`
- `Use agentctl refresh --name agent-refresh-resources`
- `Refresh complete: agent-refresh-resources (backup skipped)`

For a running-container refresh, keep the container alive before refreshing:

```bash
agentctl run --name agent-refresh-live --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'mkdir -p /home/coder/.codex && echo live-refresh-ok >/home/coder/.codex/live-refresh-smoke.txt'
agentctl start --name agent-refresh-live
agentctl refresh --name agent-refresh-live --no-backup
agentctl exec --name agent-refresh-live -- cat /home/coder/.codex/live-refresh-smoke.txt
agentctl stop --name agent-refresh-live
agentctl rm --name agent-refresh-live
```

Expected output includes `live-refresh-ok`, and the container should still appear in
`container ls` after the refresh.

Mixed-case container names should also refresh cleanly:

```bash
agentctl run --name agent-Refresh-Smoke --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'mkdir -p /home/coder/.codex && echo mixed-case-ok >/home/coder/.codex/mixed-case.txt'
agentctl refresh --name agent-Refresh-Smoke --no-backup
agentctl run --name agent-Refresh-Smoke --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'cat /home/coder/.codex/mixed-case.txt'
agentctl rm --name agent-Refresh-Smoke
```

Expected output includes `mixed-case-ok`.

Backup-image creation should still work when `--no-backup` is omitted:

```bash
agentctl run --name agent-refresh-backup-smoke --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'mkdir -p /home/coder/.codex && echo backup-ok >/home/coder/.codex/backup-smoke.txt'
agentctl refresh --name agent-refresh-backup-smoke
agentctl run --name agent-refresh-backup-smoke --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'cat /home/coder/.codex/backup-smoke.txt'
agentctl rm --name agent-refresh-backup-smoke
agentctl images prune --backup --image agent-refresh-backup-smoke-backup --keep 0
```

Expected output includes `backup-ok`, and `agentctl refresh` should print a lowercased
backup image name similar to `agent-refresh-backup-smoke-backup-20260313141749` plus the
follow-up cleanup hint.

Refresh preflight failures should also abort before the original container is removed:

```bash
agentctl refresh --name agent-refresh-live --image does-not-exist
mkdir -p /tmp/agent-refresh-workdir
cd /tmp/agent-refresh-workdir
agentctl run --name agent-refresh-workdir-test --image agent-plain --workdir /tmp/agent-refresh-workdir --cmd bash -lc 'mkdir -p /home/coder/.codex && echo workdir-check >/home/coder/.codex/workdir-check.txt'
mv /tmp/agent-refresh-workdir /tmp/agent-refresh-workdir-moved
agentctl refresh --name agent-refresh-workdir-test
printf 'x' > /tmp/agent-refresh-workdir
agentctl refresh --name agent-refresh-workdir-test
rm -f /tmp/agent-refresh-workdir
mv /tmp/agent-refresh-workdir-moved /tmp/agent-refresh-workdir
agentctl rm --name agent-refresh-workdir-test
rm -rf /tmp/agent-refresh-workdir
```

Expected output includes:

- `Error: Image not found: does-not-exist`
- `Error: Preserved /workdir source does not exist: /tmp/agent-refresh-workdir`
- `Error: Preserved /workdir source is not a directory: /tmp/agent-refresh-workdir`

AGENTS migration behavior should also be verified:

```bash
agentctl run --name agent-refresh-agents-test --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'rm -f /home/coder/.codex/AGENTS.md && printf "legacy-agents\n" >/home/coder/.codex/AGENTS.md'
agentctl refresh --name agent-refresh-agents-test --no-backup
agentctl refresh --name agent-refresh-agents-test --overwrite-config --no-backup
agentctl run --name agent-refresh-agents-test --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'test -L /home/coder/.codex/AGENTS.md && readlink /home/coder/.codex/AGENTS.md && grep -q "trust_level = \"trusted\"" /home/coder/.codex/config.toml'
agentctl rm --name agent-refresh-agents-test
```

Expected output includes:

- `Error: Container has ~/.codex/AGENTS.md as a regular file. Re-run with --overwrite-config`
- `If no valid AGENTS.md configuration already exists, use agentctl run --name agent-refresh-agents-test --reset-config`
- `/etc/agentctl/image.md`

`run --reset-config` should restore config, default profile files, and local model
metadata from the image before launching the container session:

```bash
agentctl run --name agent-run-reset-config --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'mkdir -p /home/coder/.codex && printf "# legacy-config\n" >/home/coder/.codex/config.toml && rm -f /home/coder/.codex/local_models.json'
agentctl run --name agent-run-reset-config --image agent-plain --workdir testing/agent-plain --reset-config --cmd bash -lc 'if diff -q /etc/agentctl/codex/config.toml /home/coder/.codex/config.toml && diff -q /etc/agentctl/codex/gpt-oss.config.toml /home/coder/.codex/gpt-oss.config.toml && diff -q /etc/agentctl/codex/local_models.json /home/coder/.codex/local_models.json && grep -q "trust_level = \"trusted\"" /home/coder/.codex/config.toml; then echo reset-config-ok; else exit 1; fi'
```

Expected output after the reset run should include:

- `reset-config-ok`

`--overwrite-config` now sources from the upgraded image's immutable config, default
profile files, and local model metadata; verify it by changing user config, removing
user metadata, refreshing, and checking that restored files match `/etc/agentctl/codex/`:

```bash
agentctl run --name agent-refresh-overwrite-config-test --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'mkdir -p /home/coder/.codex && printf "# PRE-OVERWRITE\n[ollama]\nhost = \"http://127.0.0.1:11434\"\n" > /home/coder/.codex/config.toml && rm -f /home/coder/.codex/local_models.json'
agentctl refresh --name agent-refresh-overwrite-config-test --no-backup
agentctl run --name agent-refresh-overwrite-config-test --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'cp /etc/agentctl/codex/config.toml /tmp/image-config.toml && cp /home/coder/.codex/config.toml /tmp/container-config.toml && sha256sum /tmp/image-config.toml /tmp/container-config.toml && test ! -f /home/coder/.codex/local_models.json'
agentctl refresh --name agent-refresh-overwrite-config-test --overwrite-config --no-backup
agentctl run --name agent-refresh-overwrite-config-test --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'cp /etc/agentctl/codex/config.toml /tmp/image-config.toml && cp /home/coder/.codex/config.toml /tmp/container-config.toml && cp /etc/agentctl/codex/local_models.json /tmp/image-models.json && cp /home/coder/.codex/local_models.json /tmp/container-models.json && diff -q /tmp/image-config.toml /tmp/container-config.toml && diff -q /etc/agentctl/codex/gpt-oss.config.toml /home/coder/.codex/gpt-oss.config.toml && diff -q /tmp/image-models.json /tmp/container-models.json && grep -q "trust_level = \"trusted\"" /home/coder/.codex/config.toml'
agentctl rm --name agent-refresh-overwrite-config-test
```

Expected output after the overwrite refresh should show:

- matching hash line for `/tmp/image-config.toml` and `/tmp/container-config.toml`
- no diff output from either `diff -q` command

## Upgrade state persistence

Use this manual smoke test when validating the runtime-owned state export/import path
during `upgrade`. It covers both cases:

- Claude is not installed, so stray Claude state should be dropped
- Claude is installed, so Claude state should survive the upgrade

Run from the repository root on the host:

```bash
tmp_root="$(mktemp -d)"
workdir="$tmp_root/project"
mkdir -p "$workdir"
printf 'hook-test\n' > "$workdir/README.md"

agentctl run --name state-hook-smoke --image agent-python --mem 4G --workdir "$workdir" --cmd true
agentctl start --name state-hook-smoke
agentctl refresh --name state-hook-smoke

# Phase 1: Codex + generic agentctl state should survive, stray Claude state should not.
agentctl exec --name state-hook-smoke sh -lc '
mkdir -p /home/coder/.codex /home/coder/.claude /home/coder/.config/agentctl
printf "{\"refresh_token\":\"codex-token\"}\n" >/home/coder/.codex/auth.json
printf "{\"claudeAiOauth\":{\"accessToken\":\"a\",\"refreshToken\":\"should-not-survive\",\"expiresAt\":1}}\n" >/home/coder/.claude/.credentials.json
printf "{\"hasCompletedOnboarding\":true}\n" >/home/coder/.claude.json
printf "codex\n" >/home/coder/.config/agentctl/preferred-runtime
printf "export PATH=\"\$HOME/go/bin:\$PATH\"\n" >/home/coder/.profile
printf "apk add --no-cache go\n" >/home/coder/.bash_history
'

agentctl upgrade --name state-hook-smoke --image agent-python --no-backup
agentctl exec --name state-hook-smoke sh -lc '
cat /home/coder/.codex/auth.json
cat /home/coder/.config/agentctl/preferred-runtime
grep -q "go/bin" /home/coder/.profile && echo profile-restored
grep -q "apk add --no-cache go" /home/coder/.bash_history && echo bash-history-restored
test ! -e /home/coder/.claude/.credentials.json && echo claude-dir-missing
test ! -e /home/coder/.claude.json && echo claude-home-missing
'

# Phase 2: After Claude is installed, Claude state should survive too.
agentctl refresh --name state-hook-smoke
agentctl runtime install --name state-hook-smoke claude
agentctl exec --name state-hook-smoke sh -lc '
mkdir -p /home/coder/.codex /home/coder/.claude /home/coder/.config/agentctl
printf "{\"refresh_token\":\"codex-token\"}\n" >/home/coder/.codex/auth.json
printf "{\"claudeAiOauth\":{\"accessToken\":\"a\",\"refreshToken\":\"should-survive\",\"expiresAt\":1}}\n" >/home/coder/.claude/.credentials.json
printf "{\"hasCompletedOnboarding\":true}\n" >/home/coder/.claude.json
printf "codex\n" >/home/coder/.config/agentctl/preferred-runtime
'

agentctl upgrade --name state-hook-smoke --image agent-python --no-backup
agentctl exec --name state-hook-smoke sh -lc '
cat /home/coder/.codex/auth.json
cat /home/coder/.config/agentctl/preferred-runtime
jq -er ".claudeAiOauth.refreshToken == \"should-survive\"" /home/coder/.claude/.credentials.json >/dev/null && echo claude-dir-restored
jq -er ".hasCompletedOnboarding == true" /home/coder/.claude.json >/dev/null && echo claude-home-restored
'

agentctl rm --force --name state-hook-smoke
rm -rf "$tmp_root"
```

Expected output should include:

- Phase 1:
  - the Codex auth JSON payload
  - `codex`
  - `profile-restored`
  - `bash-history-restored`
  - `claude-dir-missing`
  - `claude-home-missing`
- Phase 2:
  - the Codex auth JSON payload
  - `codex`
  - `claude-dir-restored`
  - `claude-home-restored`

## Image management

Verify image discovery and retention behavior using `agentctl images`.

```bash
# Basic listing should be stable-tag and snapshot aware
agentctl images
agentctl images --latest

# --all should include non-agent images and ignore container headers/metadata
agentctl images --all
```

Expected output should include local agent family refs and timestamped snapshots.

```bash
# A fresh environment should build the image once, then detect the stable tag on repeat
agentctl build --image agent-plain
agentctl build --image agent-plain
```

Expected output should show the first command building `agent-plain`, and the second
command printing `Image already exists: agent-plain (use --rebuild to rebuild)`.

```bash
# Custom DockerFile names should map to agent-* images and build local bases first
cat > DockerFile.testing-build <<'EOF'
FROM agent-office
RUN echo testing-build >/tmp/testing-build.txt
EOF

agentctl build --image agent-testing-build
agentctl images | grep '^agent-testing-build'
rm DockerFile.testing-build
```

Expected behavior:

- `agentctl build --image agent-testing-build` should build `agent-plain`, `agent-python`, `agent-office`, then `agent-testing-build` when those local bases do not already exist.
- `agentctl images` should include `agent-testing-build` and its newest timestamp tag after the build.

```bash
# Removing an image family should remove the stable tag and all snapshots
agentctl images rm --image agent-testing-build --dry-run
```

Expected behavior:

- The dry-run output should list both `agent-testing-build` and any `agent-testing-build:<timestamp>` refs that exist locally.

```bash
# Create multiple refresh backups for the same container to exercise backup-family pruning
agentctl run --name agent-images-smoke --image agent-plain --workdir testing/agent-plain --cmd true
agentctl refresh --name agent-images-smoke
agentctl refresh --name agent-images-smoke
agentctl rm --name agent-images-smoke

# Refresh backups should be listed as agentctl-owned refs
agentctl images --backup
```

Expected output should include names matching `agent-*-backup-<timestamp>`, such as:

- `agent-images-smoke-backup-20260313142437`

```bash
# Backup images are pruned by backup family in descending timestamp order
agentctl images prune --backup --keep 1 --dry-run
```

Expected output should show `Would remove image:` lines only for older snapshot/backup
refs and never stable tags.

## Codex CLI sanity checks

These steps confirm Codex itself can connect to the local model, execute shell commands,
and write to the mounted workdir. You need the local model endpoint (Ollama) running.

Base image:

```bash
agentctl run --image agent-plain --temp --workdir testing/agent-plain
```

In the Codex prompt, paste:

```
Report your current working directory first, then summarize the environment information you were given about this image.
Create /workdir/agent-plain-smoke.txt with the text "agent-ok".
Then run: ls -l /workdir/agent-plain-smoke.txt and cat the file.
```

Python image:

```bash
agentctl run --image agent-python --temp --workdir testing/agent-python
```

Prompt:

```
Report your current working directory first, then summarize the environment information you were given about this image.
Create /workdir/agent-python-smoke.txt with the text "python-ok".
Then run: python -c "import sys; print(sys.executable)" and cat the file.
```

Office compatibility image:

```bash
agentctl run --image agent-office --temp --workdir testing/agent-office
```

Prompt:

```
Report your current working directory first, then summarize the environment information you were given about this image.
Use python to create /workdir/agent-office-smoke.docx with a single heading "office-ok".
Then run: ls -l /workdir/agent-office-smoke.docx
```

Swift image:

```bash
agentctl run --image agent-swift --temp --workdir testing/agent-swift
```

Prompt:

```
Report your current working directory first, then summarize the environment information you were given about this image.
Create /workdir/Hello.swift with a main that prints "swift-ok".
Then run: swiftc /workdir/Hello.swift -o /workdir/hello && /workdir/hello
```

## Office compatibility image

Run the existing office harness inside the `agent-office` image. This verifies the
bundled Python and Node libraries by generating PDF/DOCX/XLSX/PPTX fixtures and then
parsing them to confirm expected text, metadata, and structure.

First, copy the harness into the `testing/agent-office` folder so the container only
mounts that subtree:

```bash
rm -rf testing/agent-office/office_tool_tests
cp -R test-codex-office/office_tool_tests testing/agent-office/
```

```bash
agentctl run --image agent-office --temp --workdir testing/agent-office --cmd bash -lc './office_tool_tests/run.sh'
```

Expected output includes:

- `Fixtures generated in /workdir/office_tool_tests/fixtures`
- `PPTX verified.`
- `All fixtures verified.`
