# Networking and Ollama connectivity

Local runtime launches need a path from the container network to the Ollama
process running on the host.

Run the commands in this guide on the **macOS host**, not inside a container.

## Recommended first-success setup

For the normal local Ollama installation, use:

```bash
agentctl run --start-ollama
```

`agentctl` starts the container, derives its default-route gateway, and starts
a detached Ollama listener only if nothing already answers at that gateway on
port `11434`. It leaves Ollama's ordinary localhost listener unchanged. The
gateway listener remains after the agent session, so later sessions can reuse
it; use `--start-ollama` again after restarting Ollama or the Mac.

When the agent session ends, agentctl prints a reminder if it started this
listener. Inspect active agentctl-managed listeners with `agentctl ollama
status`; stop them with `agentctl ollama stop`. These commands never stop a
listener that was started manually, by a proxy, or by an older agentctl version
that did not record ownership.

If `status` reports multiple listeners, target one endpoint with `agentctl
ollama stop --gateway <IP>`.

To create the listener without starting an agent session, use `agentctl ollama
start` after creating the container. It briefly starts a stopped container to
derive its default route, then restores that container's stopped state.

This avoids enabling Ollama's broad **Expose Ollama to the network** setting.
Use one of the [options below](#options) for a custom endpoint, a remote Ollama
server, a proxy, or a manually managed listener.

## What this means

The agentctl-managed local runtime setup expects local model traffic to go to a
host-visible Ollama listener, typically:

```text
http://host.container.internal:11434
```

Agentctl refreshes this name in the managed container's `/etc/hosts` using the
gateway of the container's selected network. The underlying subnet may change
without requiring Codex or MCP configuration edits.

## Custom and host-only networks

Apple container 1.1 supports reusable named networks. Agentctl exposes the
standard vmnet lifecycle without exposing custom network plugins:

```bash
agentctl network list
agentctl network create shared --subnet 10.40.0.0/24
agentctl network create --internal isolated
agentctl network inspect isolated
agentctl network rm isolated
```

Every network created by `agentctl` receives an ownership label. Listings show
all Apple container networks and whether each is managed. `agentctl network rm`
only removes managed networks, so a user-created network is never deleted based
on its name. Apple container will also reject removal while a container still
references the network.

Attach one or more NAT networks with repeated flags:

```bash
agentctl run --network frontend --network services
agentctl bootstrap --name imported --image alpine --network services
agentctl rescue --backup-image agent-backup --network services
```

A host-only (`--internal`) network cannot be combined with another network.
This prevents a second attachment from restoring an external route. Containers
on the same host-only network can communicate with one another and can address
the Mac through that network's gateway and `host.container.internal`, but they
cannot reach the internet. Consequently `agentctl run --online` is rejected for
an existing or newly selected host-only network. The macOS integration suite
verifies host access with a temporary HTTP server bound specifically to the
selected network's gateway; a host service bound only to `127.0.0.1` remains
unreachable without a separate proxy or localhost DNS forwarding.

Upgrade preserves the ordered network attachments by default, including
explicitly configured MAC addresses and MTU options. Runtime-assigned MAC
addresses are not converted into persistent configuration. Copy mode preserves
the networks and MTUs but requests fresh MAC addresses so the source and copy
can coexist safely. Repeated `upgrade --network NAME` flags explicitly replace
the preserved attachments. Changing an existing named container's network
through `run` is rejected; use `upgrade` to recreate it.

Host-only behavior depends on macOS and Apple container 1.1. Run the focused
host integration test after upgrading the runtime:

```bash
bash tests/run-tests.sh --tier full --filter host-only
```

Ollama itself usually listens only on:
- `http://localhost:11434`
- `http://127.0.0.1:11434`

So the container often cannot reach it until you start a gateway listener,
expose it, or proxy it.

For an isolated Ollama server or a non-default port, pass the base URL that is
reachable from inside the container:

```bash
OLLAMA_HOST=http://host.container.internal:11439 agentctl run ...
agentctl run -c ollama_host=http://host.container.internal:11439 ...
```

The `-c ollama_host=...` value takes precedence over `OLLAMA_HOST`. Use the
container-reachable address, not the macOS listener value such as
`http://0.0.0.0:11439`.

For `agentctl run`, `OLLAMA_HOST` is a client base URL and must include an
`http://` or `https://` scheme. This differs from `ollama serve`, which also
accepts bind-style values such as `192.168.64.1:11434` in `OLLAMA_HOST`.

## Quick verification

With the container running, run this on the macOS host:

```bash
agentctl exec --no-tty -- curl -fsS \
  http://host.container.internal:11434/api/version
```

If that fails for the default local endpoint, start the session with
`agentctl run --start-ollama`. For a custom endpoint, use the matching option
below.

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

With `--start-ollama`, agentctl performs the gateway listener check and startup
before this preflight. It waits up to 30 seconds for a listener it starts to
become healthy. The flag deliberately uses the default gateway and therefore
cannot be combined with `--online`, `--shell`, `--cmd`, `OLLAMA_HOST`, or
`-c ollama_host=...`.

`--shell` skips this preflight. `--cmd` only performs it when the command runs
through `agent.sh run`.

## Options

### Option 1: let agentctl start a gateway listener

```bash
agentctl run --start-ollama
```

It creates and starts the container first, derives its default-route gateway,
then starts a detached Ollama listener only when that gateway does not already
answer on port `11434`. The listener remains available after the agent session
ends so later local sessions can reuse it. `--start-ollama` intentionally uses
the default gateway endpoint and cannot be combined with `--online`, `--shell`,
`--cmd`, `OLLAMA_HOST`, or `-c ollama_host=...`.

Use `agentctl ollama status` to list the listeners agentctl started and
`agentctl ollama stop` to stop all of them. A listener started before this
metadata-based lifecycle support is not managed; stop it manually by targeting
its gateway-bound process.

### Option 2: run a gateway listener yourself

Use this when you want to manage the listener outside `agentctl`.

To start the listener yourself, run:

```bash
AGENTCTL_HOST_ADDRESS="$(agentctl host-address)"
OLLAMA_HOST="http://${AGENTCTL_HOST_ADDRESS}:11434" ollama serve
```

Run that on the macOS host.

This only works when the container-visible address exists, which usually means a
container is already running.

### Option 3: expose Ollama on the network

> [!WARNING]
> Enabling **Expose Ollama to the network** makes Ollama reachable beyond
> `localhost`. Only use this on a private, trusted network.

Enable Ollama's **Expose to network** setting in the GUI if you accept that
broader exposure.

### Option 4: proxy the host-visible address back to localhost

#### 4.1 `socat`

```bash
AGENTCTL_HOST_ADDRESS="$(agentctl host-address)"
socat TCP-LISTEN:11434,fork,bind="$AGENTCTL_HOST_ADDRESS" TCP:127.0.0.1:11434
```

Install with:

```bash
brew install socat
```

#### 4.2 OllamaProxy

If you want a transparent proxy with logging, see:

<https://github.com/pd95/OllamaProxy>

## Security note

Containers have outbound network access enabled by default. Be deliberate about
which host services you expose onto the container-visible network.

## Related docs

- [local-vs-online.md](local-vs-online.md)
- [auth.md](auth.md)
