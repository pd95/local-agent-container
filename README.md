# Local agent container on your Mac

> **Run agent CLIs locally on macOS, powered by Ollama**

This repository packages a practical local setup for running agent CLIs on Apple
Silicon Macs with Apple’s `container` tool.

The main entry point is `agentctl`, which manages:
- curated images such as `agent-plain`, `agent-python`, and `agent-swift`
- runtime selection (`codex`, `claude`, and more over time)
- local vs online launch modes
- runtime auth sync through the in-container `agent.sh` contract
- feature packs and bootstrap flows

## Prerequisites

You need:
- a Mac with Apple Silicon
- Ollama installed
- Apple’s `container` CLI installed

Recommended memory:
- for local-model workflows, plan for at least 32 GB RAM
- online-only workflows may work with less memory, but that is not yet verified
  in the current docs/test matrix

Official releases:
- `container`: <https://github.com/apple/container/releases>
- Ollama: <https://ollama.com/download>

## Preliminary setup

After installing Ollama and `container`, clone this repository and open a
Terminal in the repository root.

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
- many setups use `192.168.64.1:11434` as the host-visible Ollama address
- default Ollama only listens on `localhost`
- you may need to expose or proxy Ollama onto the container-visible host address

Details and options are in [docs/networking.md](docs/networking.md).

## Workspace model

`agentctl run` starts an agent inside a container, but it mounts a host
directory into that container at `/workdir`.

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
agentctl run --profile gemma

# Test a specific model directly
agentctl run --model qwen3.5:9b-nvfp4

# Use the runtime's online/provider-backed mode after logging in once
agentctl auth --runtime codex
agentctl run --runtime codex --online

# Start a shell instead of the runtime
agentctl run --shell

# Install and launch Claude in the current container
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

If you already have a compatible base container and want to bring the managed
control surface onto it, use `agentctl bootstrap` instead of starting from a
curated image. More on that in [docs/bootstrap.md](docs/bootstrap.md).

## Testing

Host integration and shell unit tests are documented in [TESTING.md](TESTING.md).

Fast checks:

```bash
bash tests/run-unit-tests.sh
bash tests/run-tests.sh
```

## Documentation

Deeper documentation now lives under `docs/`:

- [docs/getting-started.md](docs/getting-started.md)
- [docs/networking.md](docs/networking.md)
- [docs/runtimes.md](docs/runtimes.md)
- [docs/local-vs-online.md](docs/local-vs-online.md)
- [docs/images.md](docs/images.md)
- [docs/bootstrap.md](docs/bootstrap.md)
- [docs/auth.md](docs/auth.md)
- [docs/advanced-container-usage.md](docs/advanced-container-usage.md)
- [TESTING.md](TESTING.md)
