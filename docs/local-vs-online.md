# Local vs Online

`agentctl run` has two launch modes:

- `local` (default)
- `online` (`agentctl run --online`)

## Local mode

Local mode is runtime-specific.

### Codex local mode

Codex local runs use profiles from `config.toml`.

Examples:

```bash
agentctl run
agentctl run --profile gemma
agentctl run --profile qwen
agentctl run --model qwen3:14b
```

Notes:
- `--profile` is Codex-specific
- `--model` is runtime-neutral and maps to `codex -m <model>`

### Claude local mode

Claude local mode uses Ollama through Anthropic-compatible environment variables.

The adapter exports:
- `ANTHROPIC_AUTH_TOKEN=ollama`
- `ANTHROPIC_API_KEY=""`
- `ANTHROPIC_BASE_URL=http://<host-gateway>:11434`

By default it launches:

```bash
claude --model gpt-oss:20b
```

You can override that with:

```bash
agentctl run --runtime claude --model qwen3:14b
```

The runtime adapter maps that to `claude --model qwen3:14b`.

## Online mode

Use:

```bash
agentctl run --online
```

or, explicitly with a runtime:

```bash
agentctl run --runtime claude --online
agentctl run --runtime codex --online
```

In online mode:
- the effective runtime decides the provider-backed behavior
- `agentctl` does best-effort Keychain auth replay before launch
- refreshed auth can be written back to Keychain after the run

`--auth` only works together with `--online`.

## Model override

`agentctl run --model <name>` is runtime-neutral. The runtime adapter decides
how to interpret it:

- Codex: `-m <name>`
- Claude: `--model <name>`

If you pass a runtime-native explicit model argument yourself, that wins over
the generic override.

## Related docs

- [networking.md](networking.md)
- [auth.md](auth.md)
- [runtimes.md](runtimes.md)
