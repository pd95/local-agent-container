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
agentctl run --model qwen3.5:9b-nvfp4
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

Before the first online run for a runtime, you need to log in once with
`agentctl auth` so `agentctl` has host-stored credentials to replay:

```bash
agentctl auth --runtime codex
agentctl auth --runtime claude
```

Online mode also assumes you have a valid account, subscription, API access, or
other provider entitlement for the selected runtime. Logging in alone is not
enough if that runtime's online service is not available to your account.

After that, use:

```bash
agentctl run --runtime codex --online
agentctl run --runtime claude --online
```

In online mode:
- the effective runtime decides the provider-backed behavior
- the first online run requires a prior `agentctl auth --runtime ...` login for
  that runtime
- the selected runtime must also have whatever provider access or subscription
  its online service requires
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
