# Networking and Ollama connectivity

Local runtime launches need a path from the container network to the Ollama
process running on the host.

Run the commands in this guide on the **macOS host**, not inside a container.

## Recommended first-success setup

If you just want local mode to work with the least amount of debugging:

1. In the Ollama app, enable **Expose Ollama to the network**.
2. In a macOS host terminal, verify that the container-visible host address can
   reach Ollama:

   ```bash
   curl -fsS http://192.168.64.1:11434/api/version
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
http://192.168.64.1:11434
```

On many Apple container setups, `192.168.64.1` is the host-visible address from
inside the container. The actual gateway can differ.

Ollama itself usually listens only on:
- `http://localhost:11434`
- `http://127.0.0.1:11434`

So the container often cannot reach it until you expose or proxy it.

## Quick verification

If `192.168.64.1` is your container-visible host address, run this on the
macOS host:

```bash
curl -fsS http://192.168.64.1:11434/api/version
```

If that fails, fix networking before expecting local runtime launches to work.

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

This is the easiest option and the one recommended above for first success. It
is also the broadest and least safe option.

Enable Ollama's "Expose to network" setting in the GUI if you are comfortable
with that exposure.

### Option 2: run a second Ollama listener on the host-visible address

```bash
OLLAMA_HOST=192.168.64.1 ollama serve
```

Run that on the macOS host.

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
