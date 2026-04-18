# Getting Started

This guide is the longer version of the top-level README quick start.

## Prerequisites

You need:
- Apple Silicon
- Ollama installed
- Apple's `container` CLI installed

Recommended memory:
- for local-model workflows, plan for at least 32 GB RAM
- online-only workflows may work with less memory, but that is not yet verified
  in the current docs/test matrix

Install sources:
- `container`: <https://github.com/apple/container/releases>
- Ollama: <https://ollama.com/download>

## Initial setup

Open a Terminal in the repository root.

Make `agentctl` available on your `PATH`.

Recommended on macOS:

```bash
sudo ln -sf "$PWD/agentctl" /usr/local/bin/agentctl
```

User-local alternative:

```bash
mkdir -p "$HOME/bin"
ln -sf "$PWD/agentctl" "$HOME/bin/agentctl"
export PATH="$HOME/bin:$PATH"
```

Then run:

```bash
ollama pull gpt-oss:20b
ollama pull gemma4:26b-a4b-it-q4_K_M
ollama pull qwen3.5:35b-a3b-coding-nvfp4
container system start
```

If local runtime launches cannot reach Ollama, follow
[networking.md](networking.md).

## Workspace model

`agentctl run` does not make the agent operate on the whole host machine by
default. Instead, it mounts a chosen host directory into the container at
`/workdir`.

In the default case:
- the current directory becomes `/workdir`
- the agent can read and write within that mounted directory tree
- the agent does **not** get unrestricted access to the rest of your host
  filesystem through `agentctl`
- this is why you normally start `agentctl` from the project or document folder
  you want the agent to work on

If you want to target a different directory, use:

```bash
agentctl run --workdir /path/to/project
```

## First build

Build the curated images:

```bash
agentctl build
```

To preinstall multiple runtimes and choose a default:

```bash
agentctl build --runtimes codex,claude --default-runtime claude
```

## First run

Start the default container for the current directory. That directory is mounted
into the container as `/workdir`:

```bash
agentctl run
```

Common alternatives:

```bash
# Run Codex with a specific local profile
agentctl run --profile gemma

# Test a specific model directly
agentctl run --model qwen3.5

# Install and launch Claude in the current container
agentctl run --runtime claude --install-runtime

# Use the runtime's online/provider-backed mode
agentctl run --online

# Start a shell instead of the runtime
agentctl run --shell

# Install Codex explicitly in the current container
agentctl run --runtime codex --install-runtime

# Start with a different curated image
agentctl run --image agent-python

# Keep the mounted workdir read-only
agentctl run --read-only

# Use a temporary container
agentctl run --temp
```

Useful follow-ups:

```bash
agentctl runtime list
agentctl feature list
agentctl refresh
```

## Existing containers

When `agentctl`, runtime manifests, or runtime adapters change, update existing
containers in place with:

```bash
agentctl refresh
```

This is the normal non-destructive update path.

To restore image-owned defaults such as `config.toml`, `local_models.json`, or
the `AGENTS.md` symlink:

```bash
agentctl run --name <container> --reset-config --cmd true
agentctl runtime reset-config codex
```

## Next guides

- [runtimes.md](runtimes.md)
- [local-vs-online.md](local-vs-online.md)
- [images.md](images.md)
- [auth.md](auth.md)
