# Local agent container on your Mac

> **Run agent CLIs locally on macOS, with optional Ollama integration**

This repository packages a practical local setup for running agent CLIs on Apple
Silicon Macs with Apple’s `container` tool.

Run `agentctl --version` to inspect the checked-out release. Published versions
and the release process are documented in [docs/releases.md](docs/releases.md).

The main entry point is `agentctl`, which manages:
- curated images such as `agent-plain`, `agent-python`, and `agent-swift`
- runtime selection (`codex`, `claude`, and more over time)
- local vs online launch modes
- runtime auth sync through the in-container `agent.sh` contract
- feature packs and bootstrap flows

## Prerequisites

You need:
- an Apple Silicon Mac running macOS 26
- Apple’s `container` CLI 1.1 or newer
- the system Bash and Apple-provided `jq` (jq 1.6 or newer; macOS 26
  provides `jq 1.7.1-apple`)

This baseline is Homebrew-free and does not require host-side Python or another
package manager. The managed MCP bridge requires host-side Node.js. Ollama is only required for local-model workflows;
online runtime workflows do not require it.

Recommended memory:
- for local-model workflows, plan for at least 32 GB RAM
- online-only workflows may work with less memory, but that is not yet verified
  in the current docs/test matrix

Official releases:
- `container`: <https://github.com/apple/container/releases>
- Ollama: <https://ollama.com/download>

## Preliminary setup

After installing `container` (and Ollama if you plan to use local models), clone
this repository and open a Terminal in the repository root.

Then make `agentctl` available on your `PATH`. The easiest option on macOS is
usually a symlink into `/usr/local/bin`:

```bash
sudo ln -sf "$PWD/agentctl" /usr/local/bin/agentctl
```

If you prefer a user-local install instead:

```bash
mkdir -p "$HOME/bin"
ln -sf "$PWD/agentctl" "$HOME/bin/agentctl"
export PATH="$HOME/bin:$PATH"
```

After that, run:

```bash
# Pull the default local model used by current Codex and Claude local flows
ollama pull gpt-oss:20b

# Optional Codex profile models
ollama pull gemma4:26b-a4b-it-q4_K_M
ollama pull qwen3.5:35b-a3b-coding-nvfp4

# Optional smaller model for direct `--model` testing
ollama pull qwen3.5:9b-nvfp4

# Start the Apple container API service
container system start
```

Before your first local run, make sure containers can reach Ollama. The short
version is:
- agentctl maps `host.container.internal` to the current Apple container gateway
- default Ollama only listens on `localhost`
- you may need to expose or proxy Ollama onto the container-visible host address

Details and options are in [docs/networking.md](docs/networking.md).

## Managed host MCP bridge

`run --mcp` exposes an explicitly authorized host stdio MCP server to the
container through a private Unix socket and a guest proxy bound only to
`127.0.0.1`. It does not open a host TCP port or edit runtime configuration.

```bash
# Built-in Xcode preset (host command: xcrun mcpbridge)
agentctl run --mcp xcode

# Generic inline definition
agentctl run --mcp '{"name":"example","command":"/absolute/path/to/server","args":[]}'

# Private file containing one definition or an array
agentctl run --mcp @"$HOME/.config/agentctl/private-mcp.json"
```

For Codex, `agentctl` automatically registers every enabled server as a
Streamable HTTP endpoint before launching the runtime. This also works in
temporary containers. Other runtimes currently retain manual configuration
using URLs such as `http://127.0.0.1:47123/mcp/xcode` or
`http://127.0.0.1:47123/mcp/example`. Existing containers created without MCP
wiring need one explicit migration:

```bash
agentctl upgrade --name agent-project --enable-mcp
agentctl upgrade --name agent-project --mcp-port 48123
agentctl upgrade --name agent-project --disable-mcp
```

Definitions accept `name`, `command`, `args`, `cwd`, `env`, `env_vars`, and
`shared`. The Xcode preset enables `shared` so reconnecting HTTP sessions reuse
one `xcrun mcpbridge` process; generic definitions default to per-session
process isolation.
Literal `env` values live only for the active invocation. The private host
registry persists resolved commands and inherited variable names, never literal
values. A container request cannot add or change a host command.

Managed relays are container-scoped background services and therefore normally
appear with parent PID 1 after `agentctl` exits. Their process label includes the
container name, for example `agentctl-mcp-relay:agent-project`. Use
`agentctl doctor --host` for the authoritative mapping of relay PIDs, containers,
definitions, leases, sockets, and host/guest route health. The health checks do
not initialize a server or invoke MCP tools. For a stopped MCP-enabled container,
`agentctl doctor --name agent-project` may temporarily start the persisted relay,
container, and guest proxy for its existing live checks, then restore the stopped
state.

Apple container 1.1 custom networks can be managed and selected directly. For
example, create a host-only network for an offline workload:

```bash
agentctl network create --internal agent-isolated
agentctl run --network agent-isolated
```

`--network` is also available on `bootstrap`, `upgrade`, and `rescue`. Host-only
networks deliberately reject `--online`; see [docs/networking.md](docs/networking.md)
for lifecycle, isolation, and upgrade behavior.

For isolated Ollama listeners or non-default ports, pass the container-reachable
base URL explicitly:

```bash
OLLAMA_HOST=http://host.container.internal:11439 agentctl run ...
# or
agentctl run -c ollama_host=http://host.container.internal:11439 ...
```

## Workspace model

`agentctl run` starts an agent inside a container, but it mounts a host
directory into that container at `/workdir`.

In the normal case:
- the directory you run `agentctl run` from becomes the mounted work directory
- everything under that directory is visible to the agent
- the agent can read and write files in that mounted directory tree
- the agent does **not** get unrestricted access to the rest of your host
  filesystem through `agentctl`

Host Unix sockets can also be mounted at creation time:

```bash
agentctl run --mount-socket /tmp/my-service.sock:/run/host-services/my-service.sock
```

The option is repeatable and is also available to `bootstrap` and `upgrade`.
Use stable, absolute socket paths: generic socket mounts store the literal host
path and do not rediscover a moved socket. An existing container must exactly
match mappings requested by `run` or `bootstrap`; use `upgrade` to add, replace,
or remove mappings:

```bash
agentctl upgrade --name agent-my-project \
  --mount-socket /tmp/new.sock:/run/host-services/service.sock
agentctl upgrade --name agent-my-project \
  --unmount-socket /run/host-services/service.sock
```

Upgrade preserves mappings by default, including in `--copy` mode. A missing
preserved source is fatal until restored, replaced, or explicitly unmounted.
Access to a socket grants the container the service's effective authority; only
mount narrowly scoped sockets whose permissions are appropriate for `coder`.

Services running inside a container can be published as host Unix sockets:

```bash
mkdir -m 700 "$HOME/.agentctl-sockets"
agentctl run \
  --publish-socket "$HOME/.agentctl-sockets/service.sock:/run/service.sock"
```

`--publish-socket` is repeatable and is also available to `bootstrap` and
`upgrade`. The parent directory must already be canonical, owned by you,
writable/searchable by you, and inaccessible to group and other users. The host
destination must not already exist. agentctl never creates the directory or
deletes socket paths, including stale listeners left by the container runtime.

Existing containers must exactly match mappings requested by `run` or
`bootstrap`. Upgrade preserves mappings and merges replacements by host path:

```bash
agentctl upgrade --name agent-my-project \
  --publish-socket "$HOME/.agentctl-sockets/second.sock:/run/service.sock"
agentctl upgrade --name agent-my-project \
  --unpublish-socket "$HOME/.agentctl-sockets/service.sock"
```

Multiple private host paths may intentionally publish the same container
service. Published services and authentication are the user's responsibility.

So the normal workflow is:
1. `cd` into the project or document folder you want the agent to work on
2. run `agentctl run`
3. let the agent work inside that mounted directory tree

If you want a different directory than the current one, use:

```bash
agentctl run --workdir /path/to/project
```

## Quick start

Build the curated images once:

```bash
agentctl build
```

Then start the agent against the current directory, which will be mounted into
the container as `/workdir`:

```bash
agentctl run
```

Common first-run workflows:

```bash
# Run Codex with a specific local profile
agentctl run -c profile=gemma

# Test a specific model directly
agentctl run --model qwen3.5:9b-nvfp4

# Pass a runtime-specific Claude launch flag
agentctl run --runtime claude -c dangerously-skip-permissions=true

# Use the runtime's online/provider-backed mode after logging in once
agentctl auth --runtime codex
agentctl run --runtime codex --online

# Start a shell instead of the runtime
agentctl run --shell

# Launch with Claude when the image includes it, or install explicitly before launch
agentctl run --runtime claude
agentctl run --runtime claude --install-runtime

# Override the launch model for the selected runtime
agentctl run --runtime claude --model qwen3:14b

# Refresh an existing container in place after pulling a newer agentctl checkout
agentctl refresh
```

## Common workflows

Choose a toolchain image when needed:

```bash
agentctl run --image agent-python
agentctl run --image agent-swift
```

Inspect or manage runtimes:

```bash
agentctl runtime list
agentctl runtime info codex
agentctl runtime install claude
agentctl runtime use claude
```

Preinstall optional features while building an image:

```bash
# Features are opt-in; normal image builds remain lean.
agentctl build --image agent-plain --features ssh
agentctl build --image agent-python --features ssh,office
```

Use the macOS SSH agent from a container:

```bash
# Creates the relay and installs the SSH client feature if the image lacks it.
agentctl run --ssh

# Add forwarding to an existing container by recreating it safely.
agentctl upgrade --name agent-my-project --ssh

# Remove forwarding while retaining SSH client commands.
agentctl upgrade --name agent-my-project --no-ssh
```

Forwarding grants code inside the container access to every identity offered by
the host agent while the relay is available. It does not copy private keys, but
container code can request signatures and authentication. Use it only with
trusted images and projects. The `ssh` feature installs client tools only; it
does not install an SSH server or weaken host-key checking.

Run stdio-based protocol servers inside a container:

```bash
# ACP agent runtime with container lifecycle and online auth sync
agentctl run --stdio --name my-agent --image agent-swift --workdir /path/to/project \
  --runtime codex --online --cmd \
  sh -lc 'cd /workdir && npx -y @agentclientprotocol/codex-acp'

# ACP agent runtime in an already-running container
agentctl exec --stdio --name my-agent -- sh -lc 'cd /workdir && npx -y @agentclientprotocol/codex-acp'

# MCP stdio server
agentctl exec --stdio --name my-agent -- sh -lc 'cd /workdir && node ./my-mcp-server.js'
```

Use the `office` feature on an `agent-python` container:

```bash
agentctl run --image agent-python --cmd true
agentctl feature info office
agentctl feature install office
```

Bootstrap onto a compatible non-agentctl container:

```bash
agentctl bootstrap --name existing-devbox
agentctl bootstrap --name my-alpine-devbox --image docker.io/library/alpine:latest
```

## Choosing an image

Use these curated images for most workflows:

- `agent-plain`: general shell, Git, and runtime work
- `agent-python`: Python-heavy tasks and libraries
- `agent-swift`: Swift toolchain and SwiftPM workflows

`agent-office` remains only as a legacy compatibility image. For new work, use
`agent-python` plus the `office` feature pack.

If you started with one curated image and later need another one for the same
container, recreate it with `agentctl upgrade --image ...`. For example:

```bash
agentctl upgrade --name <container> --image agent-python
```

Upgrades create backup images by default. To inspect a backup image without
refreshing it or mounting the current workdir, use `rescue`:

```bash
agentctl rescue --image <container>-backup-<timestamp>
```

For upgrade recovery workflows, backup state inventory, and restore examples,
see [docs/rescue.md](docs/rescue.md).

If you already have a compatible base container and want to bring the managed
control surface onto it, use `agentctl bootstrap` instead of starting from a
curated image. More on that in [docs/bootstrap.md](docs/bootstrap.md).

## Testing

Host integration and shell unit tests are documented in [TESTING.md](TESTING.md).

Fast checks (the host runner defaults to its smoke tier):

```bash
bash tests/run-unit-tests.sh
bash tests/run-tests.sh
```

Use `bash tests/run-tests.sh --tier full` for release and runtime-upgrade
validation.

## Documentation

Deeper documentation now lives under `docs/`:

- [docs/getting-started.md](docs/getting-started.md)
- [docs/rescue.md](docs/rescue.md)
- [docs/networking.md](docs/networking.md)
- [docs/runtimes.md](docs/runtimes.md)
- [docs/local-vs-online.md](docs/local-vs-online.md)
- [docs/images.md](docs/images.md)
- [docs/bootstrap.md](docs/bootstrap.md)
- [docs/auth.md](docs/auth.md)
- [docs/advanced-container-usage.md](docs/advanced-container-usage.md)
- [TESTING.md](TESTING.md)
