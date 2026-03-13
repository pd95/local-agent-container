# Testing

This repository does not include automated tests. Use the image-specific manual checks below.

## Smoke tests (all images)

These are lightweight sanity checks to confirm core tools are present. Run each
command from its corresponding `testing/<image>` directory so the container only
mounts that subtree.

```bash
codexctl run --image codex --temp --workdir testing/codex --cmd bash -lc 'bash --version && git --version && rg --version && jq --version && codex --version'
codexctl run --image codex-python --temp --workdir testing/codex-python --cmd bash -lc 'which python && python -c "import sys; print(sys.executable)"'
codexctl run --image codex-office --temp --workdir testing/codex-office --cmd bash -lc 'python -c "import docx, openpyxl, reportlab; print(\"python-ok\")" && node -e "require(\"pptxgenjs\"); console.log(\"node-ok\")"'
codexctl run --image codex-swift --temp --workdir testing/codex-swift --cmd bash -lc 'swift --version && swift-format --version && command -v format >/dev/null && command -v lint >/dev/null'
```

## Upgrade flow

Use a persistent container so there is state to preserve, then recreate it with `codexctl upgrade`.

```bash
codexctl run --name codex-upgrade-smoke --image codex --workdir testing/codex --cmd bash -lc 'mkdir -p /home/coder/.codex && echo upgrade-ok >/home/coder/.codex/upgrade-smoke.txt'
codexctl upgrade --name codex-upgrade-smoke
codexctl run --name codex-upgrade-smoke --image codex --workdir testing/codex --cmd bash -lc 'cat /home/coder/.codex/upgrade-smoke.txt'
```

Expected output includes `upgrade-ok`, and `codexctl upgrade` should print the backup image name it created via `container export`.

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

## Codex CLI sanity checks (interactive)

These steps confirm Codex itself can connect to the local model, execute shell commands,
and write to the mounted workdir. You need the local model endpoint (Ollama) running.

Base image:

```bash
codexctl run --image codex --temp --workdir testing/codex
```

In the Codex prompt, paste:

```
Create /workdir/codex-smoke.txt with the text "codex-ok".
Then run: ls -l /workdir/codex-smoke.txt and cat the file.
```

Python image:

```bash
codexctl run --image codex-python --temp --workdir testing/codex-python
```

Prompt:

```
Create /workdir/codex-python-smoke.txt with the text "python-ok".
Then run: python -c "import sys; print(sys.executable)" and cat the file.
```

Office image:

```bash
codexctl run --image codex-office --temp --workdir testing/codex-office
```

Prompt:

```
Use python to create /workdir/codex-office-smoke.docx with a single heading "office-ok".
Then run: ls -l /workdir/codex-office-smoke.docx
```

Swift image:

```bash
codexctl run --image codex-swift --temp --workdir testing/codex-swift
```

Prompt:

```
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
