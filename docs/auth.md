# Authentication

`agentctl auth` uses the runtime contract behind `agent.sh` to log in and
synchronize host-storable auth data.

Use it when you want a runtime to talk to its online/provider-backed service
instead of the default local Ollama-backed mode.

In practice, `agentctl auth` is the command that:
- opens the runtime's login flow in a temporary auth container
- stores the resulting auth state in the macOS Keychain
- lets later `agentctl run --online` sessions replay that auth into containers

You do not need `agentctl auth` for normal local-model runs. It is only needed
for online runs such as:

```bash
agentctl auth --runtime codex
agentctl run --runtime codex --online

agentctl auth --runtime claude
agentctl run --runtime claude --online
```

## Basic commands

```bash
agentctl auth
agentctl auth --runtime codex
agentctl auth --runtime claude
```

## Online runs

In `--online` mode:
- `agentctl` resolves the effective runtime
- it performs best-effort auth replay from Keychain before launch
- after the run, refreshed auth may be saved back to Keychain

Examples:

```bash
agentctl run --runtime codex --online
agentctl run --runtime claude --online
```

`--auth` only works with `--online`:

```bash
agentctl run --runtime claude --online --auth
```

If you reauthenticate a runtime, restart any running online session for that
runtime before relying on the new credentials.

## Keychain behavior

Host-side Keychain storage is keyed per runtime and auth format.

Notes:
- Runtimes use runtime-specific Keychain slots
- Codex still reads the legacy `codex-OpenAI-auth` and older `agent-openai-auth` slots as fallbacks
- Keychain auth is the host-side source of truth for online launches when a
  runtime supports host-managed auth

## Runtime-specific notes

### Codex

Codex auth is stored in `~/.codex/auth.json` inside the container runtime state.
Device-auth login creates that file.

### Claude

Claude auth on Linux is synchronized through:

```text
~/.claude/.credentials.json
```

The host-storable Claude blob also preserves the minimal proven replay state
from `~/.claude.json`:
- `oauthAccount`
- `hasCompletedOnboarding`

That is enough to replay auth into a fresh Claude container in current testing.

## Keychain helper

`agentctl-keychain.sh` is the low-level macOS Keychain adapter used by `agentctl` for runtime auth state.

## Related docs

- [local-vs-online.md](local-vs-online.md)
- [advanced-container-usage.md](advanced-container-usage.md)
