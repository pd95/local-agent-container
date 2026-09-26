# Local agent container on your Mac

> **Run agent CLIs in project-scoped containers on macOS**

This repository provides a practical way to run coding agents on Apple Silicon
Macs with Apple’s `container` tool. Use provider-backed online models or keep
inference local with Ollama.

Run `agentctl --version` to inspect the installed release. Published versions
are listed on the [GitHub Releases
page](https://github.com/pd95/local-agent-container/releases); the maintainer
release process is documented in [docs/releases.md](docs/releases.md).

The main entry point is `agentctl`, which manages:

- curated images such as `agent-plain`, `agent-python`, and `agent-swift`
- runtime selection (`codex`, `claude`, and more over time)
- local vs online launch modes
- runtime credentials stored through macOS Keychain
- optional host MCP servers, feature packs, and container lifecycle

## Prerequisites

You need:

- an Apple Silicon Mac running macOS 26
- Apple’s `container` CLI 1.1 or newer
- Git for cloning the repository and selecting releases
- the system Bash and Apple-provided `jq` (jq 1.6 or newer; macOS 26
  provides `jq 1.7.1-apple`)

This baseline is Homebrew-free and does not require host-side Python or another
package manager. The managed MCP bridge requires host-side Node.js. Ollama is
required only for local-model workflows; online runtime workflows do not need
it.

Recommended memory:

- for local-model workflows, plan for at least 32 GB RAM
- online-only workflows may work with less memory, but that is not yet verified
  in the current docs/test matrix

Official releases:

- `agentctl`: <https://github.com/pd95/local-agent-container/releases>
- `container`: <https://github.com/apple/container/releases>
- Ollama: <https://ollama.com/download>

## Install agentctl

After installing `container` (and Ollama if you plan to use local models), make
a Git clone so you can select and return to published agentctl releases later:

```bash
git clone https://github.com/pd95/local-agent-container.git
cd local-agent-container
```

The default checkout follows the `main` branch. To pin the installation to a
specific published release, fetch its tag and check it out. This example uses
`v0.7.1`; replace it with the version you want:

```bash
release=v0.7.1
git fetch origin tag "$release"
git switch --detach "$release"
```

A detached checkout is expected when using a release tag. To return to the
development branch later, run `git switch main` followed by `git pull
--ff-only`.

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

Add the `PATH` export to `~/.zprofile` if `$HOME/bin` should remain available in
new Terminal sessions. Both installation methods use a symlink, so selecting a
different version in the Git clone immediately changes the host-side
`agentctl` version.

Start Apple's container service:

```bash
container system start
```

See [Use a specific agentctl release](#use-a-specific-agentctl-release) for the
complete checkout-and-refresh workflow.

## Quick start

Build the Python image once, then change to the project you want the agent to
work on:

```bash
agentctl build --image agent-python
cd /path/to/project
```

For provider-backed Codex, authenticate once and start an online session:

```bash
agentctl auth --runtime codex
agentctl run --image agent-python --online
```

Later runs from the same directory reuse that container:

```bash
agentctl run --online
```

For local inference, install Ollama, pull the default model, and let agentctl
start a container-accessible listener:

```bash
ollama pull gpt-oss:20b
agentctl run --image agent-python --start-ollama
```

If you prefer the smaller general-purpose image, replace `agent-python` in the
build and first-run commands with `agent-plain`:

```bash
agentctl build --image agent-plain
agentctl run --image agent-plain --online
```

See [docs/local-vs-online.md](docs/local-vs-online.md) for other local profiles,
model overrides, and additional runtimes.

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

### Keep a container for each project

By default, the current directory selects a persistent container. Choose its
image on the first run; later runs from the same directory reuse the container,
installed tools, runtime state, and conversation history:

```bash
cd /path/to/project
agentctl run --image agent-python --online

# Later, from the same directory:
agentctl run --online
```

`agent-python` is a practical default when the agent needs Python tooling. Use
`agent-plain` for a smaller general-purpose environment, and choose
`agent-swift` when the project actually needs the Swift toolchain. To change an
existing container's image, use `agentctl upgrade --image ...`; see
[Choosing an image](#choosing-an-image).

### Use online models

Authenticate once, then add `--online` whenever the runtime should use its
provider-backed cloud models instead of the local Ollama profile:

```bash
agentctl auth --runtime codex
agentctl run --online
```

Authentication is synchronized with the persistent container. See
[docs/auth.md](docs/auth.md) for additional runtimes and credential handling.

### Update Codex before launching it

Add `--update` when you want agentctl to update the Codex CLI inside the
project's container immediately before starting the session:

```bash
agentctl run --online --update
```

The updated Codex installation remains in a persistent container for later
runs. This updates Codex itself; it does not update the agentctl Git checkout or
rebuild the container image. See [Runtime management](docs/runtimes.md) for the
standalone runtime update command.

### Use a temporary container for a quick task

`--temp` creates an unnamed container for the current directory and removes it
after the session. Files written in the mounted project directory remain on the
Mac, while container-local packages and runtime state are discarded:

```bash
agentctl run --temp --online
agentctl run --temp --image agent-python --online
```

### Give an agent access to Xcode or another host MCP server

For a new persistent container, the built-in `xcode` preset enables the managed
MCP bridge and exposes the Mac's `xcrun mcpbridge` to Codex:

```bash
agentctl run --image agent-python --online --mcp xcode
```

An existing container created without MCP wiring needs a one-time upgrade.
Definitions can then be added without recreating it again:

```bash
agentctl upgrade --enable-mcp
agentctl mcp add xcode
```

Add custom host MCP servers with an inline definition or a private definition
file, then inspect the configured routes and their health:

```bash
agentctl mcp add \
  '{"name":"macos-ui-helper","command":"/absolute/path/to/server","args":[]}'
agentctl mcp add @"$HOME/.config/agentctl/private-mcp.json"
agentctl mcp list
agentctl mcp status
```

The host command remains outside the container and is reachable through a
private managed bridge. See [docs/managed-mcp.md](docs/managed-mcp.md) for
credentials, HTTP upstreams, lifecycle behavior, and additional definitions.

### Continue a project from your phone

Enable Remote Control for a persistent project when you want an eligible
ChatGPT mobile or desktop client to notify you and let you continue working
with its Codex environment:

```bash
agentctl remote-control start
agentctl remote-control pair
```

Run these commands from the project's directory. Pairing is needed when you
authorize a new client, not every time the container starts. Agentctl remembers
that Remote Control is enabled and restores it through normal container
start/stop cycles. The integration is experimental and uses online Codex; see
[Remote Control details and limitations](#remote-control-details-and-limitations).

### Manage runtimes and optional features

The image supplies the base toolchain, the runtime selects the agent CLI, and
features add optional tools to a compatible image:

```bash
agentctl runtime list
agentctl runtime info codex
agentctl runtime install claude
agentctl runtime use claude

# Add office tooling to an agent-python container.
agentctl feature info office
agentctl feature install office
```

## Choosing an image

Use these curated images for most workflows:

- `agent-plain`: general shell, Git, and runtime work
- `agent-python`: Python-heavy tasks and libraries
- `agent-swift`: Swift toolchain and SwiftPM workflows

`agent-office` remains only as a legacy compatibility image. For new work, use
`agent-python` plus the `office` feature pack.

Build only the images you need:

```bash
agentctl build --image agent-plain
agentctl build --image agent-python
agentctl build --image agent-swift
```

If you started with one curated image and later need another one for the same
container, build the target image and recreate the container with `agentctl
upgrade --image ...`. For example:

```bash
agentctl build --image agent-python
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

## Use a specific agentctl release

The installed symlink points into your Git clone, so the checked-out commit
determines which host-side agentctl code is used. Fetch the tags and select the
published release you want:

```bash
cd /path/to/local-agent-container
git fetch origin --tags
git switch --detach v0.7.1  # Replace with the desired release.
agentctl --version
```

Then change to each project whose existing container should receive that
release's managed scripts and defaults:

```bash
cd /path/to/project
agentctl refresh
```

The directory change matters because the current project normally selects the
persistent container. From another directory, target it explicitly with
`agentctl refresh --name <container>`.

`refresh` preserves the container, installed packages, and active runtime
configuration. It does not rebuild images or change the container's image.
Read the selected release's notes in case that release also calls for an image
build or `agentctl upgrade`.

To follow current development again:

```bash
cd /path/to/local-agent-container
git switch main
git pull --ff-only
```

## Remote Control and advanced integrations

### Remote Control details and limitations

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

SSH-agent forwarding, Unix-socket forwarding, and stdio protocol bridges are
available for specialized integrations. See
[docs/advanced-container-usage.md](docs/advanced-container-usage.md) and
[docs/unix-sockets.md](docs/unix-sockets.md).

## Development and testing

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

- [Getting started](docs/getting-started.md)
- [Local and online models](docs/local-vs-online.md)
- [Runtime management](docs/runtimes.md)
- [Images, upgrades, and configuration](docs/images.md)
- [Authentication](docs/auth.md)
- [Networking and Ollama](docs/networking.md)
- [Managed host MCP servers](docs/managed-mcp.md)
- [Remote Control](docs/remote-control.md)
- [Bootstrap existing containers](docs/bootstrap.md)
- [Rescue backup images](docs/rescue.md)
- [Unix-socket forwarding](docs/unix-sockets.md)
- [Advanced container usage](docs/advanced-container-usage.md)
- [Testing](TESTING.md)
