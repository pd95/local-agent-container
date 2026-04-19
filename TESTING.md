# Testing

This repository includes a small host-side integration test harness for `agentctl`.
Run these tests on the macOS host where Apple's `container` CLI is installed. Do not
run them from inside a container.

For user-facing setup and product docs, start with:
- [README.md](README.md)
- [docs/getting-started.md](docs/getting-started.md)
- [docs/runtimes.md](docs/runtimes.md)
- [docs/local-vs-online.md](docs/local-vs-online.md)

## Automated host tests

The automated suite exercises the highest-risk container lifecycle flows without extra
dependencies:

- `run --temp` removes the container after exit
- named `run` keeps the container until explicit removal
- `build --rebuild` stops the temporary `buildkit` support container after a successful build
- `run` rejects `--cpu` and `--mem` for existing named containers
- backup-enabled `refresh` requires a container runtime with `export --output`
- `refresh --no-backup` preserves user state without creating a backup image
- default `refresh` creates a recovery backup image
- `refresh` accepts explicit `--cpu` and `--mem` overrides when recreating a container
- refresh preflight failures do not remove the original container
- `run --reset-config` restores image-owned config, model metadata, and `AGENTS.md`
- `refresh --overwrite-config` restores image-owned config, model metadata, and `AGENTS.md`

Run the suite from the repository root on the host:

```bash
bash tests/run-tests.sh
```

You can point the harness at another `agentctl` binary or container runtime command:

```bash
AGENTCTL=/path/to/agentctl CONTAINER_CMD=container bash tests/run-tests.sh
```

## Automated shell unit tests

These lightweight tests validate `agentctl` argument plumbing without needing the macOS
`container` runtime:

```bash
bash tests/run-unit-tests.sh
```

Use the image-specific manual checks below when you need broader smoke coverage,
interactive Codex validation, or image/toolchain verification that is not yet automated.

## Smoke tests

These checks confirm the curated image set is present and the expected tools exist. Run
each command from its corresponding `testing/<image>` directory so the container only
mounts that subtree. The `--cmd` checks should work even when Ollama is not running on
the host.

```bash
agentctl run --image agent-plain --temp --workdir testing/agent-plain --cmd bash -lc 'zsh --version && bash --version && git --version && rg --version && jq --version && codex --version'
agentctl run --image agent-python --temp --workdir testing/agent-python --cmd bash -lc 'zsh --version && which python && python -c "import sys; print(sys.executable)"'
agentctl run --image agent-swift --temp --workdir testing/agent-swift --cmd bash -lc 'zsh --version && swift --version && swift-format --version && command -v format >/dev/null && command -v lint >/dev/null'
agentctl run --image agent-office --temp --workdir testing/agent-office --cmd bash -lc 'zsh --version && python -c "import docx, openpyxl, reportlab; print(\"python-ok\")" && node -e "require(\"pptxgenjs\"); console.log(\"node-ok\")"'
```

Also verify the image metadata file is present and readable:

```bash
agentctl run --image agent-plain --temp --workdir testing/agent-plain --cmd bash -lc 'test -f /etc/codexctl/image.md && sed -n "1,20p" /etc/codexctl/image.md'
agentctl run --image agent-python --temp --workdir testing/agent-python --cmd bash -lc 'test -f /etc/codexctl/image.md && sed -n "1,20p" /etc/codexctl/image.md'
agentctl run --image agent-swift --temp --workdir testing/agent-swift --cmd bash -lc 'test -f /etc/codexctl/image.md && sed -n "1,20p" /etc/codexctl/image.md'
agentctl run --image agent-office --temp --workdir testing/agent-office --cmd bash -lc 'test -f /etc/codexctl/image.md && sed -n "1,20p" /etc/codexctl/image.md'
```

Also verify the image-owned config and model metadata are present and match the default
user copies inside the image:

```bash
agentctl run --image agent-plain --temp --workdir testing/agent-plain --cmd bash -lc 'test -f /etc/codexctl/config.toml && test -f /etc/codexctl/local_models.json && diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml && diff -q /etc/codexctl/local_models.json /home/coder/.codex/local_models.json'
agentctl run --image agent-python --temp --workdir testing/agent-python --cmd bash -lc 'test -f /etc/codexctl/config.toml && test -f /etc/codexctl/local_models.json && diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml && diff -q /etc/codexctl/local_models.json /home/coder/.codex/local_models.json'
agentctl run --image agent-swift --temp --workdir testing/agent-swift --cmd bash -lc 'test -f /etc/codexctl/config.toml && test -f /etc/codexctl/local_models.json && diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml && diff -q /etc/codexctl/local_models.json /home/coder/.codex/local_models.json'
agentctl run --image agent-office --temp --workdir testing/agent-office --cmd bash -lc 'test -f /etc/codexctl/config.toml && test -f /etc/codexctl/local_models.json && diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml && diff -q /etc/codexctl/local_models.json /home/coder/.codex/local_models.json'
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
- `/etc/codexctl/image.md`

`run --reset-config` should restore config and local model metadata from the image before
launching the container session:

```bash
agentctl run --name agent-run-reset-config --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'mkdir -p /home/coder/.codex && printf "# legacy-config\n" >/home/coder/.codex/config.toml && rm -f /home/coder/.codex/local_models.json'
agentctl run --name agent-run-reset-config --image agent-plain --workdir testing/agent-plain --reset-config --cmd bash -lc 'if diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml && diff -q /etc/codexctl/local_models.json /home/coder/.codex/local_models.json && grep -q "trust_level = \"trusted\"" /home/coder/.codex/config.toml; then echo reset-config-ok; else exit 1; fi'
```

Expected output after the reset run should include:

- `reset-config-ok`

`--overwrite-config` now sources from the upgraded image's immutable config and local
model metadata; verify it by changing user config, removing user metadata, refreshing,
and checking that both restored files match `/etc/codexctl/`:

```bash
agentctl run --name agent-refresh-overwrite-config-test --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'mkdir -p /home/coder/.codex && printf "# PRE-OVERWRITE\n[ollama]\nhost = \"http://127.0.0.1:11434\"\n" > /home/coder/.codex/config.toml && rm -f /home/coder/.codex/local_models.json'
agentctl refresh --name agent-refresh-overwrite-config-test --no-backup
agentctl run --name agent-refresh-overwrite-config-test --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'cp /etc/codexctl/config.toml /tmp/image-config.toml && cp /home/coder/.codex/config.toml /tmp/container-config.toml && sha256sum /tmp/image-config.toml /tmp/container-config.toml && test ! -f /home/coder/.codex/local_models.json'
agentctl refresh --name agent-refresh-overwrite-config-test --overwrite-config --no-backup
agentctl run --name agent-refresh-overwrite-config-test --image agent-plain --workdir testing/agent-plain --cmd bash -lc 'cp /etc/codexctl/config.toml /tmp/image-config.toml && cp /home/coder/.codex/config.toml /tmp/container-config.toml && cp /etc/codexctl/local_models.json /tmp/image-models.json && cp /home/coder/.codex/local_models.json /tmp/container-models.json && diff -q /tmp/image-config.toml /tmp/container-config.toml && diff -q /tmp/image-models.json /tmp/container-models.json && grep -q "trust_level = \"trusted\"" /home/coder/.codex/config.toml'
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
'

agentctl upgrade --name state-hook-smoke --image agent-python --no-backup
agentctl exec --name state-hook-smoke sh -lc '
cat /home/coder/.codex/auth.json
cat /home/coder/.config/agentctl/preferred-runtime
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
