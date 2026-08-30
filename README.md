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

For a standard local run, no Ollama network reconfiguration is needed: add
`--start-ollama` to `agentctl run`. It starts a second listener only on the
container's default-route gateway while leaving Ollama's normal localhost
listener unchanged. Use it again after restarting Ollama or the Mac. For a
custom endpoint, a remote Ollama server, or a proxy setup, see
[docs/networking.md](docs/networking.md).

When `--start-ollama` starts a listener, it remains running after the agent
session. Check it with `agentctl ollama status` and stop agentctl-managed
listeners with `agentctl ollama stop`. To start the listener before launching
an agent session, use `agentctl ollama start` (optionally `--name NAME`).
When several gateways are listed, target one with `agentctl ollama stop
--gateway IP`.

## Quick start

Build the curated images once:

```bash
agentctl build
```

Then start the agent against the current directory, which will be mounted into
the container as `/workdir`:

```bash
agentctl run --start-ollama
```

Common first-run workflows:

```bash
# Run Codex with a specific local profile (add --start-ollama if needed)
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

## Workspace model

`agentctl run` starts an agent inside a container, but it mounts a host
directory into that container at `/workdir`.

The mounted host directory supplies the files the agent works on, while the
selected image supplies its development tools. By default, agentctl creates or
reuses a named container for the current directory, so container-local runtime
state and history remain available between runs. Use `--temp` when you want a
disposable container.

In the normal case:
- the directory you run `agentctl run` from becomes the mounted work directory
- everything under that directory is visible to the agent
- the agent can read and write files in that mounted directory tree
- the agent does **not** get unrestricted access to the rest of your host
  filesystem through `agentctl`

So the normal workflow is:
1. `cd` into the project or document folder you want the agent to work on
2. run `agentctl run`
3. let the agent work inside that mounted directory tree

If you want a different directory than the current one, give the container an
explicit name so later lifecycle commands do not depend on your current
directory:

```bash
agentctl run --name agent-my-project --workdir /path/to/project
```

## Common workflows

You can tailor the container environment along three independent axes:

- **Image**: choose the base toolchain with `agent-plain`, `agent-python`,
  `agent-swift`, or a custom image.
- **Runtime**: choose the agent CLI, such as Codex or Claude.
- **Features**: add optional tooling to a compatible image; for example, the
  `office` feature adds document and report tooling to `agent-python`.

See [Choosing an image](#choosing-an-image),
[docs/images.md](docs/images.md), and [docs/runtimes.md](docs/runtimes.md) for
the available choices and build-time configuration.

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

For an Xcode installation on a separate macOS VM, the managed MCP relay can
instead run the Mac host's SSH client and bridge `xcrun mcpbridge` over the
connection. This lets the relay use the Mac's SSH configuration and identities
without exposing them to the container; see [Remote Xcode MCP bridge over
SSH](docs/managed-mcp.md#remote-xcode-mcp-bridge-over-ssh).

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

### Experimental Codex Remote Control

Remote Control lets an eligible ChatGPT desktop or mobile client work with a
Codex environment running inside an existing agentctl container. Agentctl starts
the Codex App Server in the container using the same `~/.codex` state as local
Codex sessions. The App Server establishes the provider connection itself, so
agentctl does not publish an inbound App Server port or socket on the host.

```bash
agentctl remote-control start
agentctl remote-control pair
agentctl remote-control stop
```

`start` prepares the existing container, synchronizes online authentication,
and starts the App Server. It also starts the container itself when necessary.
Remote Control is provider-backed and therefore implies online operation; it
does not use the local Ollama profile.

Pairing is the explicit authorization step for a new ChatGPT controller. The
`pair` command asks Codex for a short-lived code; enter that code only in the
intended ChatGPT client to allow it to discover and connect to this running
environment. Agentctl never pairs automatically, stores the code, or writes it
to logs. Existing enrollment state under `~/.codex` is reused across normal
container stop/start cycles, so pairing is not part of every startup.

`remote-control stop` disables the service until it is explicitly started
again. In contrast, an ordinary `agentctl stop` preserves Remote Control intent,
and the next `agentctl start` restores the App Server automatically.

This integration wraps experimental Codex CLI behavior. Availability depends on
the ChatGPT account, workspace policy, and client rollout. Agentctl keeps the
App Server on its local Unix socket and does not expose it on the network.
See [docs/remote-control.md](docs/remote-control.md) for lifecycle behavior,
authentication synchronization, status semantics, diagnostics, and testing.

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

For upgrade recovery workflows, package and Python restoration policies, and
resumable recovery plans, see [Upgrade recovery](docs/images.md#upgrade-recovery).
For backup-image rescue and restore examples, see [docs/rescue.md](docs/rescue.md).

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

Start here, then move into the more specialized guides as needed:

- [docs/getting-started.md](docs/getting-started.md)
- [docs/local-vs-online.md](docs/local-vs-online.md)
- [docs/runtimes.md](docs/runtimes.md)
- [docs/images.md](docs/images.md)
- [docs/auth.md](docs/auth.md)
- [docs/networking.md](docs/networking.md)
- [docs/bootstrap.md](docs/bootstrap.md)
- [docs/rescue.md](docs/rescue.md)
- [docs/managed-mcp.md](docs/managed-mcp.md)
- [docs/unix-sockets.md](docs/unix-sockets.md)
- [docs/remote-control.md](docs/remote-control.md)
- [docs/advanced-container-usage.md](docs/advanced-container-usage.md)
- [TESTING.md](TESTING.md)
