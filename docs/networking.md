# Networking and Ollama connectivity

Local runtime launches need a path from the container network to the Ollama
process running on the host.

## Default assumption

The default Codex config points at:

```text
http://192.168.64.1:11434/v1
```

On many Apple container setups, `192.168.64.1` is the host-visible address from
inside the container. The actual gateway can differ.

Ollama itself usually listens only on:
- `http://localhost:11434`
- `http://127.0.0.1:11434`

So the container often cannot reach it until you expose or proxy it.

## Quick verification

If `192.168.64.1` is your container-visible host address, try:

```bash
curl -fsS http://192.168.64.1:11434/api/version
```

If that fails, fix networking first.

## What agentctl checks

In local mode, `agentctl run` performs a runtime-aware Ollama preflight for the
default entrypoint:

- Codex:
  - validates the configured `base_url`
  - also probes the detected host gateway
- Claude:
  - probes the detected host gateway and uses the Anthropic-compatible endpoint

`--cmd` and `--shell` skip this preflight.

## Options

### Option 1: expose Ollama on the network

This is the broadest and least safe option.

Enable Ollama's "Expose to network" setting in the GUI if you are comfortable
with that exposure.

### Option 2: run a second Ollama listener on the host-visible address

```bash
OLLAMA_HOST=192.168.64.1 ollama serve
```

This only works when the container-visible address exists, which usually means a
container is already running.

### Option 3: proxy the host-visible address back to localhost

#### 3.1 `socat`

```bash
socat TCP-LISTEN:11434,fork,bind=192.168.64.1 TCP:127.0.0.1:11434
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
