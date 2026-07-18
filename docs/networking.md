# Networking and Ollama connectivity

Local runtime launches need a path from the container network to the Ollama
process running on the host.

Run the commands in this guide on the **macOS host**, not inside a container.

## Recommended first-success setup

If you just want local mode to work with the least amount of debugging:

> [!WARNING]
> **This is the easiest setup, not the safest setup.**
>
> Enabling **Expose Ollama to the network** makes Ollama reachable beyond
> `localhost`. Only use this when your Mac is connected to a **private, trusted
> network**. If you are on a public, shared, or otherwise untrusted network,
> prefer one of the more controlled [options below](#options) instead.

1. In the Ollama app, enable **Expose Ollama to the network**.
2. With an agent container running, verify that its stable host alias can reach
   Ollama:

   ```bash
   agentctl exec --no-tty -- curl -fsS \
     http://host.container.internal:11434/api/version
   ```

3. If that prints a small JSON response, try:

   ```bash
   agentctl run
   ```

This is the easiest path to first success. The tradeoff is that exposing Ollama
to the network is the broadest and least restrictive option. Safer alternatives
are documented below.

## What this means

The agentctl-managed local runtime setup expects local model traffic to go to a
host-visible Ollama listener, typically:

```text
http://host.container.internal:11434
```

Agentctl refreshes this name in the managed container's `/etc/hosts` using the
current gateway reported by Apple container. The underlying subnet may change
without requiring Codex or MCP configuration edits.

Ollama itself usually listens only on:
- `http://localhost:11434`
- `http://127.0.0.1:11434`

So the container often cannot reach it until you expose or proxy it.

For an isolated Ollama server or a non-default port, pass the base URL that is
reachable from inside the container:

```bash
OLLAMA_HOST=http://host.container.internal:11439 agentctl run ...
agentctl run -c ollama_host=http://host.container.internal:11439 ...
```

The `-c ollama_host=...` value takes precedence over `OLLAMA_HOST`. Use the
container-reachable address, not the macOS listener value such as
`http://0.0.0.0:11439`.

## Quick verification

With the container running, run this on the macOS host:

```bash
agentctl exec --no-tty -- curl -fsS \
  http://host.container.internal:11434/api/version
```

If that fails, fix networking before expecting local runtime launches to work.

## What agentctl checks

In local mode, `agentctl run` performs a runtime-aware Ollama preflight for the
default entrypoint:

- Codex:
  - probes `<ollama_host>/api/version` when an explicit host is provided
  - otherwise probes the detected host gateway on port `11434`
  - writes the Codex provider `base_url` as `<ollama_host>/v1`
- Claude:
  - uses the same explicit-host or detected-gateway Ollama resolution and sets
    the Anthropic-compatible endpoint

`--shell` skips this preflight. `--cmd` only performs it when the command runs
through `agent.sh run`.

## Options

### Option 1: expose Ollama on the network

This is the easiest option and the one recommended above for first success. It
is also the broadest and least safe option.

Enable Ollama's "Expose to network" setting in the GUI if you are comfortable
with that exposure.

### Option 2: run a second Ollama listener on the host-visible address

```bash
AGENTCTL_HOST_ADDRESS="$(agentctl host-address)"
OLLAMA_HOST="${AGENTCTL_HOST_ADDRESS}:11434" ollama serve
```

Run that on the macOS host.

This only works when the container-visible address exists, which usually means a
container is already running.

### Option 3: proxy the host-visible address back to localhost

#### 3.1 `socat`

```bash
AGENTCTL_HOST_ADDRESS="$(agentctl host-address)"
socat TCP-LISTEN:11434,fork,bind="$AGENTCTL_HOST_ADDRESS" TCP:127.0.0.1:11434
```

Install with:

```bash
brew install socat
```

#### 3.2 OllamaProxy

If you want a transparent proxy with logging, see:

<https://github.com/pd95/OllamaProxy>

## Security note

Containers have outbound network access enabled by default. Be deliberate about
which host services you expose onto the container-visible network.

## Related docs

- [local-vs-online.md](local-vs-online.md)
- [auth.md](auth.md)
