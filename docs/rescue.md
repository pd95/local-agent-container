# Rescue and Recovery

Use this guide when an upgrade finishes but a container does not start cleanly,
runtime configuration looks wrong, or conversation history appears missing.

The safest default is:

1. do not prune backup images yet
2. inspect the current container with `doctor`
3. inspect backup images before restoring anything
4. recover only the specific state you need
5. prune backups after the recovered container passes `doctor`

## Check The Current Container

Run `doctor` first:

```bash
agentctl doctor --name <container>
```

`doctor` checks that the container stays running, verifies known user-state
permissions, checks runtime health, and prints runtime state counts.

If it reports a fixable runtime/config problem, test repair on a copy when the
container may contain custom runtime configuration:

```bash
agentctl upgrade --name <container> --copy --new-name <container>-doctor-test
agentctl doctor --name <container>-doctor-test --fix
agentctl doctor --name <container>-doctor-test
```

Then apply the same fix to the real container if the copy is healthy.

## List Backup Images

```bash
agentctl images --backup
```

Backup images are named like:

```text
agent-my-project-backup-20260612155405
```

The timestamp is UTC. Newer backups are usually safer, but inspect counts before
assuming the newest one has the state you need.

## Count Runtime State In Backups

Use the rescue helper to count Codex and Claude state across all backup images:

```bash
./rescue/count-backup-runtime-state.sh
```

Save the result before pruning:

```bash
./rescue/count-backup-runtime-state.sh > backup-state-counts.tsv
```

The columns are:

- `codex_history_lines`
- `codex_session_files`
- `codex_session_index_lines`
- `claude_credentials_files`
- `claude_settings_files`
- `claude_home_state_files`
- `claude_project_files`

For one or two specific images:

```bash
./rescue/count-backup-runtime-state.sh \
  agent-my-project-backup-20260612155405 \
  agent-my-project-backup-20260612151908
```

## Inspect One Backup Image

Use a short rescue container name. Long generated names can be inconvenient on
some container runtimes.

```bash
agentctl rescue \
  --image agent-my-project-backup-20260612155405 \
  --name r1 \
  --cmd sh -lc 'find /home/coder/.codex /home/coder/.claude -maxdepth 3 -type f 2>/dev/null | sort | head -100'
```

For an interactive shell:

```bash
agentctl rescue --image agent-my-project-backup-20260612155405 --name r1
```

The temporary rescue container is removed when the command or shell exits.

## Recover Codex State

If the backup has the Codex history/session counts you need, export only the
Codex state from the backup:

```bash
agentctl rescue \
  --image agent-my-project-backup-20260612155405 \
  --name r1 \
  --cmd sh -lc 'cd /home/coder && set --; for path in .codex/history.jsonl .codex/session_index.jsonl .codex/sessions .codex/archived_sessions; do [ -e "$path" ] && set -- "$@" "$path"; done; tar -cf - "$@"' \
  > codex-state-from-backup.tar
```

Restore it into the current container:

```bash
agentctl su-exec --name <container> sh -lc 'cd /home/coder && tar -xf - && chown -R coder:coder /home/coder/.codex' < codex-state-from-backup.tar
```

Then verify:

```bash
agentctl doctor --name <container>
```

## Recover Claude State

If the backup has the Claude state you need:

```bash
agentctl rescue \
  --image agent-my-project-backup-20260612155405 \
  --name r1 \
  --cmd sh -lc 'cd /home/coder && set --; for path in .claude .claude.json; do [ -e "$path" ] && set -- "$@" "$path"; done; tar -cf - "$@"' \
  > claude-state-from-backup.tar
```

Restore it:

```bash
agentctl su-exec --name <container> sh -lc 'cd /home/coder && tar -xf - && chown -R coder:coder /home/coder/.claude /home/coder/.claude.json 2>/dev/null || true' < claude-state-from-backup.tar
```

Then verify:

```bash
agentctl doctor --name <container>
```

## Common Upgrade Symptoms

If `agentctl run` reports a missing Codex provider:

```text
missing Codex model provider in config: myollama
```

Run:

```bash
agentctl doctor --name <container>
agentctl doctor --name <container> --fix
```

`doctor --fix` resets broken image-managed Codex config. It may replace custom
Codex profiles, providers, or MCP configuration, so use a copy first if the
container has custom Codex config.

If a runtime launcher is present but broken, `doctor` reports it and `--fix`
reinstalls the runtime when the runtime supports installation.

## Prune Backups After Verification

After all containers pass `doctor` and the backup state counts look safe, keep
the newest backup per image family:

```bash
agentctl images prune --backup --keep 1
```

Re-check what remains:

```bash
agentctl images --backup
./rescue/count-backup-runtime-state.sh
```
