# Testing

This repository does not include automated tests. Use the image-specific manual checks below.

## Smoke tests (all images)

These are lightweight sanity checks to confirm core tools are present. Run each
command from its corresponding `testing/<image>` directory so the container only
mounts that subtree.

```bash
codexctl run --image codex --temp --workdir testing/codex --cmd bash -lc 'zsh --version && bash --version && git --version && rg --version && jq --version && codex --version'
codexctl run --image codex-python --temp --workdir testing/codex-python --cmd bash -lc 'zsh --version && which python && python -c "import sys; print(sys.executable)"'
codexctl run --image codex-office --temp --workdir testing/codex-office --cmd bash -lc 'zsh --version && python -c "import docx, openpyxl, reportlab; print(\"python-ok\")" && node -e "require(\"pptxgenjs\"); console.log(\"node-ok\")"'
codexctl run --image codex-swift --temp --workdir testing/codex-swift --cmd bash -lc 'zsh --version && swift --version && swift-format --version && command -v format >/dev/null && command -v lint >/dev/null'
```

Also verify the image metadata file is present and readable:

```bash
codexctl run --image codex --temp --workdir testing/codex --cmd bash -lc 'test -f /etc/codexctl/image.md && sed -n "1,20p" /etc/codexctl/image.md'
codexctl run --image codex-python --temp --workdir testing/codex-python --cmd bash -lc 'test -f /etc/codexctl/image.md && sed -n "1,20p" /etc/codexctl/image.md'
codexctl run --image codex-office --temp --workdir testing/codex-office --cmd bash -lc 'test -f /etc/codexctl/image.md && sed -n "1,20p" /etc/codexctl/image.md'
codexctl run --image codex-swift --temp --workdir testing/codex-swift --cmd bash -lc 'test -f /etc/codexctl/image.md && sed -n "1,20p" /etc/codexctl/image.md'
```

Also verify the image-owned config is present at `/etc/codexctl/config.toml` and matches the default user config inside the image:

```bash
codexctl run --image codex --temp --workdir testing/codex --cmd bash -lc 'test -f /etc/codexctl/config.toml && diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml'
codexctl run --image codex-python --temp --workdir testing/codex-python --cmd bash -lc 'test -f /etc/codexctl/config.toml && diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml'
codexctl run --image codex-office --temp --workdir testing/codex-office --cmd bash -lc 'test -f /etc/codexctl/config.toml && diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml'
codexctl run --image codex-swift --temp --workdir testing/codex-swift --cmd bash -lc 'test -f /etc/codexctl/config.toml && diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml'
```

Also verify global AGENTS guidance points at the image metadata file:

```bash
codexctl run --image codex --temp --workdir testing/codex --cmd bash -lc 'test -L /home/coder/.codex/AGENTS.md && readlink /home/coder/.codex/AGENTS.md'
codexctl run --image codex-python --temp --workdir testing/codex-python --cmd bash -lc 'test -L /home/coder/.codex/AGENTS.md && readlink /home/coder/.codex/AGENTS.md'
codexctl run --image codex-office --temp --workdir testing/codex-office --cmd bash -lc 'test -L /home/coder/.codex/AGENTS.md && readlink /home/coder/.codex/AGENTS.md'
codexctl run --image codex-swift --temp --workdir testing/codex-swift --cmd bash -lc 'test -L /home/coder/.codex/AGENTS.md && readlink /home/coder/.codex/AGENTS.md'
```

## Upgrade flow

Use a persistent container so there is state to preserve, then recreate it with `codexctl upgrade`.

```bash
codexctl run --name codex-upgrade-smoke --image codex --workdir testing/codex --cmd bash -lc 'mkdir -p /home/coder/.codex && echo upgrade-ok >/home/coder/.codex/upgrade-smoke.txt'
codexctl upgrade --name codex-upgrade-smoke
codexctl run --name codex-upgrade-smoke --image codex --workdir testing/codex --cmd bash -lc 'cat /home/coder/.codex/upgrade-smoke.txt'
```

Expected output includes `upgrade-ok`, and `codexctl upgrade` should print the backup image name it created via `container export` plus follow-up hints for `codexctl run --name codex-upgrade-smoke --reset-config` and `codexctl images prune --backup --image <backup-image> --keep 0`.

For a running-container upgrade, keep the container alive before upgrading:

```bash
codexctl run --name codex-upgrade-live --image codex --workdir testing/codex --cmd bash -lc 'mkdir -p /home/coder/.codex && echo live-upgrade-ok >/home/coder/.codex/live-upgrade-smoke.txt'
codexctl start --name codex-upgrade-live
codexctl upgrade --name codex-upgrade-live
codexctl exec --name codex-upgrade-live -- cat /home/coder/.codex/live-upgrade-smoke.txt
```

Expected output includes `live-upgrade-ok`, and the container should still appear in `container ls` after the upgrade.

Mixed-case container names should also upgrade cleanly, with a lowercased backup image reference:

```bash
codexctl run --name codex-Upgrade-Smoke --image codex --workdir testing/codex --cmd bash -lc 'mkdir -p /home/coder/.codex && echo mixed-case-ok >/home/coder/.codex/mixed-case.txt'
codexctl upgrade --name codex-Upgrade-Smoke
codexctl run --name codex-Upgrade-Smoke --image codex --workdir testing/codex --cmd bash -lc 'cat /home/coder/.codex/mixed-case.txt'
```

Expected output includes `mixed-case-ok`, and `codexctl upgrade` should print a backup image name similar to `codex-upgrade-smoke-backup-20260313141749`.

Upgrade preflight failures should also abort before the original container is removed:

```bash
codexctl upgrade --name codex-upgrade-live --image does-not-exist
mkdir -p /tmp/codex-upgrade-workdir
cd /tmp/codex-upgrade-workdir
codexctl run --name codex-upgrade-workdir-test --image codex --workdir /tmp/codex-upgrade-workdir --cmd bash -lc 'mkdir -p /home/coder/.codex && echo workdir-check >/home/coder/.codex/workdir-check.txt'
mv /tmp/codex-upgrade-workdir /tmp/codex-upgrade-workdir-moved
codexctl upgrade --name codex-upgrade-workdir-test
printf 'x' > /tmp/codex-upgrade-workdir
codexctl upgrade --name codex-upgrade-workdir-test
```

Expected output includes:

- `Error: Image not found: does-not-exist`
- `Error: Preserved /workdir source does not exist: /tmp/codex-upgrade-workdir`
- `Error: Preserved /workdir source is not a directory: /tmp/codex-upgrade-workdir`

AGENTS migration behavior should also be verified:

```bash
codexctl run --name codex-upgrade-agents-test --image codex --workdir testing/codex --cmd bash -lc 'rm -f /home/coder/.codex/AGENTS.md && printf "legacy-agents\\n" >/home/coder/.codex/AGENTS.md'
codexctl upgrade --name codex-upgrade-agents-test
codexctl upgrade --name codex-upgrade-agents-test --overwrite-config
codexctl run --name codex-upgrade-agents-test --image codex --workdir testing/codex --cmd bash -lc 'test -L /home/coder/.codex/AGENTS.md && readlink /home/coder/.codex/AGENTS.md && grep -q "trust_level = \"trusted\"" /home/coder/.codex/config.toml'
```

Expected output includes:

- `Error: Container has ~/.codex/AGENTS.md as a regular file. Re-run with --overwrite-config`
- `If no valid AGENTS.md configuration already exists, use codexctl run --name codex-upgrade-agents-test --reset-config`
- `/etc/codexctl/image.md`

`run --reset-config` should restore config from the image before launching container session:

```bash
codexctl run --name codex-run-reset-config --image codex --workdir testing/codex --cmd bash -lc 'mkdir -p /home/coder/.codex && printf "# legacy-config\n" >/home/coder/.codex/config.toml'
codexctl run --name codex-run-reset-config --image codex --workdir testing/codex --reset-config --cmd bash -lc 'if diff -q /etc/codexctl/config.toml /home/coder/.codex/config.toml && grep -q "trust_level = \"trusted\"" /home/coder/.codex/config.toml; then echo reset-config-ok; else exit 1; fi'
```

Expected output after the reset run should include:

- `reset-config-ok`

`--overwrite-config` now sources from the upgraded image’s immutable config; verify it by changing user config, upgrading, and checking that the restored `config.toml` matches `/etc/codexctl/config.toml`:

```bash
codexctl run --name codex-upgrade-overwrite-config-test --image codex --workdir testing/codex --cmd bash -lc 'mkdir -p /home/coder/.codex && printf "# PRE-OVERWRITE\n[ollama]\nhost = \"http://127.0.0.1:11434\"\n" > /home/coder/.codex/config.toml'
codexctl upgrade --name codex-upgrade-overwrite-config-test
codexctl run --name codex-upgrade-overwrite-config-test --image codex --workdir testing/codex --cmd bash -lc 'cp /etc/codexctl/config.toml /tmp/image-config.toml && cp /home/coder/.codex/config.toml /tmp/container-config.toml && sha256sum /tmp/image-config.toml /tmp/container-config.toml'
codexctl upgrade --name codex-upgrade-overwrite-config-test --overwrite-config
codexctl run --name codex-upgrade-overwrite-config-test --image codex --workdir testing/codex --cmd bash -lc 'cp /etc/codexctl/config.toml /tmp/image-config.toml && cp /home/coder/.codex/config.toml /tmp/container-config.toml && diff -q /tmp/image-config.toml /tmp/container-config.toml && grep -q "trust_level = \"trusted\"" /home/coder/.codex/config.toml'
```

Expected output after the overwrite upgrade should show:

- matching hash line for `/tmp/image-config.toml` and `/tmp/container-config.toml`
- no diff output from `diff -q` (identical files)

## Image management

Verify image discovery and retention behavior using `codexctl images`.

```bash
# Basic listing should be stable-tag and snapshot aware
codexctl images
codexctl images --latest

# --all should include non-codex images and ignore container headers/metadata
codexctl images --all
```

Expected output should include local codex family refs and timestamped snapshots.

```bash
# A fresh environment should build the image once, then detect the stable tag on repeat
codexctl build --image codex
codexctl build --image codex
```

Expected output should show the first command building `codex`, and the second command printing `Image already exists: codex (use --rebuild to rebuild)`.

```bash
# Create multiple upgrade backups for the same container to exercise backup-family pruning
codexctl run --name codex-images-smoke --image codex --workdir testing/codex --cmd true
codexctl upgrade --name codex-images-smoke
codexctl upgrade --name codex-images-smoke

# Upgrade backups should be listed as codexctl-owned refs
codexctl images --backup
```

Expected output should include names matching `codex-*-backup-<timestamp>`, such as:

- `codex-images-smoke-backup-20260313142437`

```bash
# Backup images are pruned by backup family in descending timestamp order
codexctl images prune --backup --keep 1 --dry-run
```

Expected output should show `Would remove image:` lines only for older snapshot/backup refs and never stable tags.

## Codex CLI sanity checks (interactive)

These steps confirm Codex itself can connect to the local model, execute shell commands,
and write to the mounted workdir. You need the local model endpoint (Ollama) running.

Base image:

```bash
codexctl run --image codex --temp --workdir testing/codex
```

In the Codex prompt, paste:

```
Report your current working directory first, then summarize the environment information you were given about this image.
Create /workdir/codex-smoke.txt with the text "codex-ok".
Then run: ls -l /workdir/codex-smoke.txt and cat the file.
```

Python image:

```bash
codexctl run --image codex-python --temp --workdir testing/codex-python
```

Prompt:

```
Report your current working directory first, then summarize the environment information you were given about this image.
Create /workdir/codex-python-smoke.txt with the text "python-ok".
Then run: python -c "import sys; print(sys.executable)" and cat the file.
```

Office image:

```bash
codexctl run --image codex-office --temp --workdir testing/codex-office
```

Prompt:

```
Report your current working directory first, then summarize the environment information you were given about this image.
Use python to create /workdir/codex-office-smoke.docx with a single heading "office-ok".
Then run: ls -l /workdir/codex-office-smoke.docx
```

Swift image:

```bash
codexctl run --image codex-swift --temp --workdir testing/codex-swift
```

Prompt:

```
Report your current working directory first, then summarize the environment information you were given about this image.
Create /workdir/Hello.swift with a main that prints "swift-ok".
Then run: swiftc /workdir/Hello.swift -o /workdir/hello && /workdir/hello
```

## Office image (fixtures + verification)

Run the existing office harness inside the `codex-office` image. This verifies the bundled
Python and Node libraries by generating PDF/DOCX/XLSX/PPTX fixtures and then parsing
them to confirm expected text, metadata, and structure.

First, copy the harness into the `testing/codex-office` folder so the container only
mounts that subtree:

```bash
rm -rf testing/codex-office/office_tool_tests
cp -R test-codex-office/office_tool_tests testing/codex-office/
```

```bash
codexctl run --image codex-office --temp --workdir testing/codex-office --cmd bash -lc './office_tool_tests/run.sh'
```

Expected output includes:

- `Fixtures generated in /workdir/office_tool_tests/fixtures`
- `PPTX verified.`
- `All fixtures verified.`
