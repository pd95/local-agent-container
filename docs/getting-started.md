# Getting Started

This guide is the longer version of the top-level README quick start.

## Prerequisites

You need:
- an Apple Silicon Mac running macOS 26
- Apple's `container` CLI 1.1 or newer
- the system Bash and Apple-provided `jq` (jq 1.6 or newer; macOS 26
  provides `jq 1.7.1-apple`)

No Homebrew installation, host Python, host Node.js, or other package manager is
required. Install Ollama only when using local-model workflows; online runtime
workflows do not require it.

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

For local-model workflows, install Ollama and then run:

```bash
ollama pull gpt-oss:20b
ollama pull gemma4:26b-a4b-it-q4_K_M
# Matches the built-in Codex `qwen` profile
ollama pull qwen3.5:35b-a3b-coding-nvfp4
# Smaller model for direct `agentctl run --model ...` testing
ollama pull qwen3.5:9b-nvfp4
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

If you want to target a different directory, give the container an explicit
name so later lifecycle commands do not depend on your current directory:

```bash
agentctl run --name agent-my-project --workdir /path/to/project
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

# Install Codex explicitly in an existing container
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

Tracked image defaults live in `defaults/<runtime>/`. To maintain personal
defaults without creating Git changes, copy the relevant file to the ignored
`defaults.local/<runtime>/` directory and edit that copy. During builds and
refreshes, a local file replaces the tracked file with the same name in the
image-owned baseline under `/etc/agentctl/<runtime>`.

A normal refresh does not overwrite active runtime configuration under
`/home/coder`. This preserves changes made inside an existing container. To
apply the refreshed baseline to the active configuration, reset that runtime:

```bash
agentctl run --name <container> --reset-config --cmd true
agentctl runtime reset-config codex
```

This is a broad reset rather than an update of one file. For Codex it replaces
the managed `config.toml`, default `*.config.toml` profiles,
`local_models.json`, and `AGENTS.md`, and may remove custom providers, MCP
servers, profiles, model metadata, or the runtime preference. See
[Image-owned and active configuration](images.md#image-owned-and-active-configuration)
before using it on a customized container.

## Next guides

- [networking.md](networking.md)
- [runtimes.md](runtimes.md)
- [local-vs-online.md](local-vs-online.md)
- [images.md](images.md)
- [auth.md](auth.md)
