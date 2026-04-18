# Local agent container on your Mac

>
> **Run agent CLIs locally on macOS, powered by Ollama**
>

This repository combines multiple open-source tools to run an agentic AI safely and privately on a Mac.

It runs OpenAI's [Codex CLI](https://github.com/openai/codex) on your Mac using Apple's Containerization tool, connecting to the locally running Ollama instance.

All tools are available as Open Source on GitHub:

- `container`: [https://github.com/apple/container/](https://github.com/apple/container/)
- Codex CLI: [https://github.com/openai/codex](https://github.com/openai/codex)
- Ollama: [https://github.com/ollama/ollama](https://github.com/ollama/ollama)

## Prerequisites

You need a **Mac with Apple Silicon and at least 32 GB RAM**. The setup is currently only tested on macOS 26 but might also work on macOS 15 (possible restrictions apply to the `container` tool).

## Preliminary setup

I suppose you do not want to install everything from source (which would be doable). Therefore here are links to install the official releases of Ollama and Apple's `container` tool:

- `container` GitHub releases: [https://github.com/apple/container/releases](https://github.com/apple/container/releases)
- Ollama download page: [https://ollama.com/download](https://ollama.com/download)

After installing both tools, open Terminal app and run the following commands:

```bash
# Pull the default gpt-oss profile model (requires 13 GB on disk!)
ollama pull gpt-oss:20b

# Optionally pull the Gemma and Qwen profile models for use with gemma and qwen profiles
ollama pull gemma4:26b-a4b-it-q4_K_M
ollama pull qwen3.5:35b-a3b-coding-nvfp4

# start the container API server (required for building container images)
container system start
```

## Local model connectivity

The default `config.toml` in these images points Codex at Ollama on `http://192.168.64.1:11434/v1`. On many Apple container setups that is the host-side address visible from the container, but the actual gateway can differ. A plain default Ollama setup only listens on `localhost`, so `agentctl run` will not be able to reach it until you expose or proxy the service onto the host address visible from the container network.

Before your first local-model run, choose one of the network setups described in [Network configuration](#network-configuration):

- Option 1: expose Ollama to the network in the Ollama app (**broadest exposure; least safe**)
- Option 2: start a second Ollama listener on the host address visible from the container network
- Option 3: run a proxy such as `socat` or OllamaProxy between that host address on port `11434` and `127.0.0.1:11434`

If you want a quick host-side verification before launching Codex, run this on hosts where `192.168.64.1` is the container-visible address:

```bash
curl -fsS http://192.168.64.1:11434/api/version
```

That command should return a short JSON object with Ollama's version. If it fails, fix the network path first; otherwise Codex inside the container will fail to reach Ollama.

`agentctl run` performs a local-mode preflight only when starting the default Codex command. If the configured Ollama endpoint is unreachable, it checks the container's detected host gateway and prints an actionable error when the config points at the wrong address or Ollama is not exposed on that gateway. `--cmd` and `--shell` skip this check.

## Use `agentctl` (recommended)

`agentctl` is the entry point for running containers. It wraps the Apple `container` CLI,
handles naming, and automates OpenAI device-auth when requested. The current branch still
uses `codexctl` as the underlying implementation binary, so some transition wording may
remain visible in command output.

The basic idea is to start a container in the directory where your sources and/or documents are located. The container ensures that `codex` can only access files in the current directory tree (this directory and its subdirectories), but still the container contains many development tools `codex` needs to be useful/efficient in its work.

By installing `agentctl` somewhere in your system PATH (e.g. `/usr/local/bin/` or better
privately in `~/bin/`), you can run a container in any directory you currently work, as
easy as running `agentctl run`.

```bash
chmod 700 agentctl                            # restrict it to your user
sudo ln -s "$PWD/agentctl" /usr/local/bin/    # link it to system directory
```

## Testing

Run the host integration suite from the repository root on macOS:

```bash
bash tests/run-tests.sh
```

These tests are black-box checks around `agentctl` and Apple's `container` CLI. They must
run on the host, not inside a container. For broader manual coverage, see
`TESTING.md`.

### Quick start

```bash
# Build images once
agentctl build

# Build images with both Codex and Claude preinstalled, defaulting to Claude
agentctl build --runtimes codex,claude --default-runtime claude

# Snapshot current images without rebuilding
agentctl build --snapshot

# Run the current directory (persistent by default)
agentctl run

# Create or reuse a container, install Codex if needed, set it preferred, and launch it
agentctl run --runtime codex --install-runtime

# Run Codex with the Gemma or qwen profile from config.toml
agentctl run --profile gemma
agentctl run --profile qwen

# Run Codex for a specific directory
agentctl run --workdir /path/to/project

# Run with a specific base image when you need a toolchain
agentctl run --image agent-python

# Run a specific historical build
agentctl run --image agent-plain:20260313-154500

# Create or reuse a container, install Claude if needed, set it preferred, and launch it
agentctl run --runtime claude --install-runtime

# Read-only workdir mount
agentctl run --read-only

# Throwaway session (container is deleted when codex is quit)
agentctl run --temp

# Override the launch model for the selected runtime
agentctl run --runtime claude --model qwen3:14b

# Online mode (auto-auth if needed)
agentctl run --online

# Update codex package in the running container
agentctl run --update

# List or inspect runtimes in an existing container
agentctl runtime list
agentctl runtime info codex

# Install or select the preferred runtime in an existing container
agentctl runtime install codex
agentctl use codex

# Inspect installable feature packs in an existing container
agentctl feature list
agentctl feature info office
agentctl feature install office

# Bootstrap agentctl into an existing compatible Alpine or Debian/Ubuntu container
agentctl bootstrap --name existing-devbox

# Create and bootstrap a new Alpine-based container from a custom image
agentctl bootstrap --name my-alpine-devbox --image docker.io/library/alpine:latest

# Bootstrap an existing Debian/Ubuntu-style container
agentctl bootstrap --name existing-swift-devbox

# Recreate a container from the latest image while preserving config
agentctl refresh

# List stable tags, timestamped snapshots, and backup images (like upgrade backups)
agentctl images

# Prune old snapshot tags by family while keeping one newest (dry-run)
agentctl images prune --keep 1 --dry-run

# Remove a custom image family entirely, including its stable tag and snapshots
agentctl images rm --image agent-custom --dry-run

# Start a shell inside the container
agentctl run --shell

# Run a custom command (must be last)
agentctl run --cmd bash
```

#### Quick start notes

- Builds create stable local image tags and also add immutable UTC snapshot tags such as `agent-plain:20260313-154500`. By default `agentctl build` discovers local `DockerFile*` definitions in the repo, resolves local `FROM agent...` dependencies, and builds them in dependency order. Use `agentctl build --snapshot` to add fresh timestamp tags to the current images without rebuilding them.
- `agentctl build --runtimes <runtime[,runtime...]>` changes which runtimes are preinstalled in newly built images, and `--default-runtime <runtime>` chooses which one becomes preferred at startup. If you omit `--default-runtime`, the first runtime in the list becomes the default. For the single-runtime case, `agentctl build --default-runtime claude` still works and installs only Claude. Image builds now invoke the copied in-image `agent.sh runtime install ...` path, so the same runtime adapter logic is used during builds and later in-container installs.
- Local mode is now runtime-specific. Codex local runs use a profile from `config.toml`; the default profile is `gpt-oss`, and `agentctl run --profile gemma` launches the bundled Gemma profile after pulling `gemma4:26b-a4b-it-q4_K_M` into Ollama. Claude local runs now default to Ollama-backed `gpt-oss:20b` using the Anthropic-compatible endpoint exported by the runtime adapter.
- `agentctl run --model <name>` passes a runtime-neutral model override into the launch path. Codex maps it to `-m <name>` and Claude maps it to `--model <name>`. In Claude local mode, that override replaces the default `gpt-oss:20b` model.
- `--cmd` consumes the remaining arguments, cannot be combined with `--shell`, and should be placed last. If you pass one quoted string with spaces, it runs via `$CODEX_SHELL -lc`. The same behavior applies to `agentctl exec`.
- `agentctl run --runtime <runtime>` selects the preferred runtime to launch in the target container before executing the default entrypoint. Add `--install-runtime` to install that runtime first when needed. A practical Claude bootstrap path is now just `agentctl run --runtime claude --install-runtime`.
- For most new setups, prefer runtime-first flows such as `agentctl run --runtime codex --install-runtime` or `agentctl run --runtime claude --install-runtime` over choosing an image because it happens to bundle a specific agent/runtime.
- `agentctl run` now performs best-effort pre-run auth replay from Keychain for the effective runtime it is about to launch, whether that runtime comes from `--runtime <runtime>` or from the image/container preferred runtime. This means a previously authenticated Claude runtime can come up already logged in on a fresh container without a separate manual auth write step.
- Claude’s native installer can be OOM-killed on Linux if the container is too small. For fresh Claude bootstrap and temporary Claude auth containers, `agentctl` now defaults the create-time memory limit to `4G` unless you explicitly override it.
- In local mode, the Ollama reachability preflight runs for the effective runtime that is about to launch. For Codex it validates the configured `base_url`; for Claude it validates the detected host-gateway Ollama endpoint. `--cmd` and `--shell` skip that check so image inspection and ad hoc commands still work without a running Ollama listener.
- `CODEX_SHELL` overrides the shell used by `run --shell` and `exec` (default: `bash`). You can also set `DEFAULT_SHELL` in `agentctl` for a static default. All default images include both `bash` and `zsh`.
- `agentctl run --update` upgrades `@openai/codex` inside the target container before starting. If the container does not exist yet, it is created first. With `--temp`, the update is ephemeral; `agentctl build --rebuild` remains the persistent way to refresh image content.
- `agentctl runtime list` shows installed runtimes in the current container. `agentctl runtime info <runtime>` and `agentctl runtime capabilities <runtime>` query the in-container `agent.sh` runtime contract for a declared runtime, including explicit capability booleans and supported auth formats. The current branch fully wires `codex` and now also ships a real Claude install/update/reset-config/auth adapter.
- Runtime metadata now lives under `/etc/agentctl/runtimes.d`, and runtime-specific handlers live under `/usr/local/lib/agentctl/runtimes`. `agentctl refresh` updates those directories in-place for existing containers.
- Feature-pack metadata now lives under `/etc/agentctl/features.d`, and feature-pack handlers live under `/usr/local/lib/agentctl/features`. `agentctl refresh` updates those directories in-place for existing containers too.
- `agentctl runtime install codex` installs or refreshes the Codex runtime inside an existing container and marks it as preferred for that container.
- `agentctl runtime install claude` now runs the official native installer (`curl -fsSL https://claude.ai/install.sh | bash`) and, on Alpine, expects `libgcc`, `libstdc++`, and `ripgrep` to be present first.
- `agentctl runtime update claude` now runs `claude update`.
- `agentctl runtime reset-config claude` restores a default `~/.claude/settings.json` with `USE_BUILTIN_RIPGREP=0`.
- `agentctl feature list`, `agentctl feature info office`, and `agentctl feature install office` now expose the first real feature-pack flow. The initial `office` feature targets `agent-python` and installs the core document/PDF/spreadsheet/OCR tooling that previously required `agent-office`.
- `agentctl bootstrap --name <container>` is the first bring-your-own-base path. The current slice is intentionally narrow: it supports Alpine and Debian/Ubuntu-style containers, can either bootstrap an existing container or create one first via `--image`, installs the current managed control surface into it, and then lets you use `agentctl runtime ...`, `agentctl feature ...`, and `agentctl refresh` against that container afterward.
- refreshed and rebuilt containers now ship `/etc/profile.d/agentctl-path.sh`, so bash login shells prepend `~/.local/bin` to `PATH` and native Claude installs are available as `claude` without manual shell edits.
- `agentctl use codex` updates the container-local preferred runtime without changing the default image selection used by `agentctl run`.
- `agentctl run` is now runtime-neutral at the host layer. Codex still starts with its default `--cd /workdir` behavior, but that default now lives in the Codex runtime adapter instead of being forced on every runtime.
- `--cpu` and `--mem` on `agentctl run` only apply when creating a new container. If the named container already exists, `agentctl run` fails fast and tells you to use `agentctl refresh` instead of silently ignoring the resource request.
- `agentctl refresh` is the normal non-destructive update path for an existing named container. It updates `agent.sh`, the agentctl-managed default config files, runtime manifests, and runtime adapters in place, and preserves the container's running or stopped state.
- `agentctl refresh` does not recreate the container, export backup images, or touch user-installed packages. Use `agentctl upgrade` only for the heavier recreate-and-restore flow.
- If you want to reset image-owned defaults such as `config.toml`, `local_models.json`, or the `AGENTS.md` symlink, use `agentctl run --name <container> --reset-config` or `agentctl runtime reset-config codex`.
- Use `agentctl images rm --image <name>` when you want to remove an image family entirely, including the stable tag. This is the cleanup path for temporary custom images such as `agent-custom`.
- Use `--rebuild`, `--refresh-base`, and `--pull-base` only for occasional refreshes when you want newer Codex or base image content. See the build cache section below for details.
- `agentctl` was authored by Codex itself, running inside an Apple `container` in online mode.

#### Image selection

Use `--image` when you need a specific toolchain, or set `DEFAULT_IMAGE` in `agentctl` for a permanent default. For agent/runtime choice, prefer `--runtime` plus `--install-runtime`.

When to use which image:

- `agent-plain`: general-purpose CLI work or small scripts without a heavy runtime.
- `agent-python`: Python-heavy tasks, data wrangling, and libraries not in the base image.
- `agent-swift`: Swift projects, SwiftPM builds, and Swift tooling.

`agent-office` remains available only as a legacy compatibility image for older
document-centric setups. It is no longer part of the primary image strategy.

#### Curated Images vs Bootstrap

Use curated images when you want the simplest supported path:

- `agent-plain`, `agent-python`, and `agent-swift` are the easiest way to start
- they already contain the expected base tooling, `coder` user, and managed control surface
- they remain the recommended default for most users

Use `agentctl bootstrap` when you already have, or specifically want, a non-agentctl base container:

- bootstrap is the extensibility path for bringing the current `agentctl` control surface onto a compatible container
- the current supported families are Alpine (`apk`) and Debian/Ubuntu (`apt-get`)
- bootstrap can either:
  - convert an existing compatible container in place
  - create and bootstrap a new compatible container when you pass `--image`

Examples:

```bash
# Existing compatible container
agentctl bootstrap --name existing-devbox

# Create and bootstrap a fresh compatible container from a base image
agentctl bootstrap --name my-alpine-devbox --image docker.io/library/alpine:latest
```

If you do not already have a reason to start from a custom base image, prefer the curated images.

### Configuration tweaks

`agentctl` exposes a few top-level constants (in `agentctl`) that you can edit to adjust default behavior:

- `DEFAULT_IMAGE` (default image for `run` and `auth`, e.g. `agent-plain`, `agent-python`, `agent-swift`)
- `DEFAULT_NAME_PREFIX` (default local container prefix)
- `AUTH_NAME_PREFIX` (default auth container prefix)
- `DEFAULT_SHELL` (default shell for `run --shell` and `exec`)
- `DEFAULT_CODEX_PROFILE` (default profile passed to codex in local mode)
- `DEFAULT_CODEX_CMD` (base codex command/flags used when launching codex)

### Model profiles

Local-model runs use profiles defined in `config.toml`:

- `gpt-oss`: default profile backed by Ollama model `gpt-oss:20b`
- `gemma`: optional profile backed by Ollama model `gemma4:26b-a4b-it-q4_K_M`

Choose a profile per run with:

```bash
agentctl run --profile gemma
```

If you want Gemma to become the default local model, either set `CODEX_PROFILE=gemma` in your shell environment or change `DEFAULT_CODEX_PROFILE` in `agentctl`.

### Other useful commands

```bash
agentctl --help          # show command overview and available subcommands/options
agentctl auth            # run codex device-auth and store it in Keychain
agentctl auth --runtime codex  # explicit equivalent of the default auth flow
agentctl auth --runtime claude  # install/login Claude in a temp auth container and store credentials in Keychain
agentctl run --runtime claude --install-runtime  # bootstrap and launch Claude in one command
agentctl bootstrap --name existing-devbox  # bootstrap agentctl into an existing Alpine or Debian/Ubuntu container
agentctl bootstrap --name my-alpine-devbox --image docker.io/library/alpine:latest  # create and bootstrap a custom Alpine container
agentctl runtime list    # list installed runtimes in the current container
agentctl runtime info codex  # inspect manifest-backed runtime metadata
agentctl runtime info claude  # inspect Claude runtime metadata/capabilities
agentctl runtime capabilities codex  # inspect runtime commands/capabilities
agentctl runtime install codex  # install/refresh Codex in the current container
agentctl use codex       # set Codex as the preferred runtime in the current container
agentctl images          # list local agent image refs
agentctl images --backup # list local agent backup image refs
agentctl refresh         # update agent.sh and runtime contract files in place
agentctl run --name my-devbox --reset-config --cmd true  # restore image-owned defaults
agentctl runtime reset-config codex  # restore Codex-owned defaults inside the current container
agentctl images prune --backup --keep 2 --dry-run  # preview backup pruning
agentctl exec            # shell into running container
agentctl ls              # list managed containers (hides runtime support containers like buildkit)
agentctl rm              # remove the default container for this directory
```

Notes:

- `--auth` only works together with `--online`.
- `--temp` creates a disposable container that is removed after the command exits.
- `--read-only` mounts the workdir as read-only; agentctl can use its home directory or `/tmp` for scratch data, but cannot modify the workdir.
- `--cpu` and `--mem` on `agentctl run` are create-time settings. If you pass them for an existing named container, `agentctl run` exits with an error and points you to `agentctl refresh`.
- The mount mode is fixed on first creation for a given container name. To switch between read-only and read-write, remove the container (e.g. `agentctl rm`) or use `--temp`/`--name` to create a fresh one.
- `agentctl ls` only shows managed containers whose image name starts with `agent`; it hides runtime support containers such as `buildkit`.
- After a successful `agentctl build`, the temporary `buildkit` support container is stopped so it does not linger in the runtime list.
- Backup-enabled `agentctl refresh` requires a container runtime that supports `container export --output <path>`.
- `--online --temp` still injects Keychain auth before running the command when the effective runtime supports host-managed auth.
- Keychain auth is the source of truth for `--online`; it is synced into running containers before each online run.
- After a run, if the container refresh time is newer (and present), the updated auth is saved back into Keychain.
- After `agentctl auth`, exit any running online sessions and re-run `agentctl run --online` to pick up the new token.
- `agentctl auth --runtime <runtime>` only works for runtimes whose manifest declares `auth_login` and `auth_read` capability support plus at least one host-storable `auth_format`. In this branch, both `codex` and `claude` meet that contract.
- Claude auth on Linux is synchronized through `~/.claude/.credentials.json`. The host-storable Claude blob now preserves the credential file plus the minimal proven replay state from `~/.claude.json`: `oauthAccount` and `hasCompletedOnboarding`. That is enough to replay auth into a fresh Claude container in current testing, while keeping the credential boundary at `.credentials.json`.
- host-side Keychain storage is now keyed per runtime and auth format. Codex keeps the legacy `codex-OpenAI-auth` slot so existing setups continue to work unchanged.

Security notes:

- Containers run as a non-root `coder` user with Linux capabilities dropped.
- `config.toml` sets `sandbox_mode = "danger-full-access"` to maximize capabilities. Codex can read/write anything in the mounted directory tree and run tools inside the container. Use only with trusted workspaces or change it to `workspace-write` for tighter guardrails.
- Containers have full outbound network access by default. `--online` needs outbound access; if you want to constrain networking, use host firewall rules or a restricted container network.
- If you need root for maintenance tasks, use `agentctl su-exec` (or `container exec -u 0 ...`).
- Some scripts that assume root access to system paths may fail; run them via `su-exec` or update them.

The rest of this README explains what `agentctl` does behind the scenes and how to run the underlying `container` commands directly.

## Behind the scenes

### Build agent container images

To build the agent container images for later use, I have written three primary `DockerFile`s which are installing `agentctl`, `git` and other basic tools (`bash`, `zsh`, `npm`, `file`, `curl`):

- `DockerFile` for `agent-plain`, a plain Alpine Linux runtime (~191 MB)
- `DockerFile.python` for `agent-python`, an Alpine-based Python installation (~203 MB, built on top of `agent-plain`)
- `DockerFile.swift` for `agent-swift`, an Ubuntu-based Swift installation (~1.41 GB)

The curated image set is `agent-plain`, `agent-python`, and `agent-swift`.
`DockerFile.office` and `agent-office` remain in the repo only as a legacy
compatibility bridge for older office-heavy workflows. They are not part of the
default Phase 4 image matrix and are not built by `agentctl build` unless you
request them explicitly.

`agentctl build` derives local image names from Dockerfile names using this convention:

- `DockerFile` -> `agent-plain`
- `DockerFile.<name>` -> `agent-<name>`

That means a custom `DockerFile.custom` becomes the local image `agent-custom`.
If it starts with `FROM agent-python`, `agentctl build --image agent-custom`
will automatically build `agent-plain`, `agent-python`, and then `agent-custom`.
If you still have a legacy `FROM agent-office` image, that compatibility path
continues to work when requested explicitly.

The image build process uses `npm` to install the latest `openai/codex` package, and configures `git` to use "Codex CLI" and `codex@localhost` as the container user's identity when interacting with git and to use `main` as the default branch when initializing a new repository.

Further the build process copies `config.toml` and `local_models.json` into the container at `/home/coder/.codex/` so that Codex can both reach the locally running Ollama instance on the `default` network's host IP address `192.168.64.1` and resolve local model metadata, and also mirrors both files into `/etc/codexctl/` so upgrade resets can source the image-owned defaults reliably.

Each image also writes `/etc/codexctl/image.md` during build. That file describes the image name, build time, workspace conventions, and key built-in tools/toolchains. It intentionally lives outside `/home/coder/.codex`, so `agentctl refresh` does not treat it as user state to back up and restore.

The image build also creates `~/.codex/AGENTS.md` as a symlink to `/etc/codexctl/image.md`. This follows the official Codex `AGENTS.md` discovery flow for global guidance while keeping the source metadata image-owned instead of backed up as mutable user state. Codex still starts with `--cd /workdir`, but that default is now injected by the Codex runtime adapter rather than the generic `agentctl run` host wrapper.

The image-specific `image.md` files describe the intended toolchain focus:

- `agent-plain`: general shell and Git tooling
- `agent-python`: Python runtime and the default `/opt/venv`
- `agent-swift`: Swift-on-Linux tooling and related platform constraints

Use the following `container` commands to build the primary agent images
`agent-plain`, `agent-python`, and `agent-swift` from the corresponding
`DockerFile` (build the Alpine images in order so the bases exist):

```bash
STAMP="$(date -u +%Y%m%d-%H%M%S)"

container build -t agent-plain -f DockerFile .
container image tag agent-plain "agent-plain:${STAMP}"

container build -t agent-python -f DockerFile.python .
container image tag agent-python "agent-python:${STAMP}"

container build -t agent-swift -f DockerFile.swift .
container image tag agent-swift "agent-swift:${STAMP}"
```

This keeps the stable image names for normal use and also creates immutable timestamped tags for A/B testing and rollback. `agentctl build` automates that same dependency ordering for both the built-in images and any custom local `DockerFile.<name>` images that follow the naming convention above.

To change which runtimes are preinstalled at build time:

```bash
agentctl build --runtimes codex,claude --default-runtime claude

# Direct container build equivalent for agent-plain
container build \
  -t agent-plain \
  -f DockerFile \
  --build-arg AGENT_RUNTIMES=codex,claude \
  --build-arg AGENT_DEFAULT_RUNTIME=claude \
  .
```

When you set `--runtimes` or `--default-runtime`, `agentctl build` performs a real rebuild instead of reusing an existing stable image, because the selected runtime set changes the image contents.
Notes:
- The Swift image includes `format` and `lint` wrappers for `swift-format` and initializes `swiftly` for toolchain management.
- `agent-office` is still buildable manually from `DockerFile.office` if you need the legacy compatibility image for an existing workflow.

#### Build cache behavior (agentctl)

- `--rebuild` disables Dockerfile layer cache (`--no-cache`) for every image selected by the dependency-aware build plan. It does not pull newer remote `FROM` tags by itself. Use `--pull-base` as well when you want newer upstream base image content.
- `--snapshot` creates a new timestamp tag for the current stable image without rebuilding it. Use when you want an immutable test reference for the image you already have locally.
- `--pull-base` pulls the latest base image tag before building. Use when you want to update base images without deleting them first (preferred).
- `--refresh-base` deletes the base image first, forcing a re-fetch on build. Use when you need a brute-force refresh; this may fail if the base image is still referenced by containers.
- `agentctl images prune` removes only old timestamp tags. It deliberately keeps the stable image tag.
- `agentctl images rm --image <name>` removes the whole image family, including the stable tag and all timestamp tags.

### Network configuration

By default, Ollama is only listening on localhost connections, i.e. on <http://localhost:11434> or <http://127.0.0.1:11434>. Containers have outbound network access enabled (required for `--online`), so be deliberate about exposing host services. To be able to connect from a container (through a virtual network) to the Ollama service running on localhost, we have three options:

### Option 1: Expose Ollama service on network (**risky**) ⚠️

Expose the Ollama service to **ALL** network connections, by activating the setting "Expose Ollama to the network" in the Ollama GUI.  
The **problem** of this approach: when connected to a "untrusted" public network, the Ollama service is visible to other computers and risks to be abused or attacked.  
You should consider stopping the service on such networks!

### Option 2: Additional service on virtual network

Instead of using the GUI setting within Ollama you can launch a second Ollama service listening only on the virtual network interface using the following command:

```bash
OLLAMA_HOST=192.168.64.1 ollama serve
```

⚠️ Be aware: This command only works when a container is already running! (see "Run a codex container in the current directory").  
Otherwise you will get the following error:

```log
Error: listen tcp 192.168.64.1:11434: bind: can't assign requested address
```

### Option 3: Proxy service connecting virtual network to localhost

The following sub‑options provide ways to forward traffic from the container's network interface to the Ollama service running on the host.

#### Option 3.1: socat proxy

In this option we are running a tool which listens on the virtual network interface `192.168.64.1` and forwards to the service running on localhost.

This can be done using `socat` (install with `brew install socat`):

```bash
socat TCP-LISTEN:11434,fork,bind=192.168.64.1 TCP:127.0.0.1:11434
```

⚠️ This command only works when a container is already running! (see "Run a codex container in the current directory"). Otherwise you will get the following error:

```bash
socat[12345] E bind(5, {LEN=16 AF=2 192.168.64.1:11434}, 16): Can't assign requested address
```

#### Option 3.2: OllamaProxy

Alternatively if you are interested in also reading what the container is talking with Ollama, you can use my [OllamaProxy Swift app](https://github.com/pd95/OllamaProxy).

This tool should be run in a separate Terminal window, as it will log all the "chat" running proxied to/from Ollama.

```bash
swift build
HOST=192.168.64.1 PORT=11434 swift run
```

### Run a codex container in the current directory

The following command runs a "throwaway" `codex` container with the current directory as 'workdir'

```bash
container run --rm -it --mount type=bind,src="$(pwd)",dst=/workdir codex
```

You can name the container using the '--name' argument:

```bash
container run --rm -it --name "my-codex" --mount type=bind,src="$(pwd)",dst=/workdir codex
```

To start a `bash` within the same (running!) container, you can use

```bash
container exec -it "my-codex" bash
```

If you want to keep your session/chat history over multiple container restarts/runs, do not remove the container after termination (=omit `--rm` argument and make sure you give it a unique name – here derived from the current directory):

```bash
container run -it --name "codex-`basename $PWD`" --mount type=bind,src="$(pwd)",dst=/workdir codex
```

This is basically a shortcut for two commands below: create a new named container and start it (interactively)

```bash
container create -t --name "codex-`basename $PWD`" --mount type=bind,src="$(pwd)",dst=/workdir codex
container start -i "codex-`basename $PWD`"
```

After quitting the current session in the container using CTRL+D, you can start the container again:

```bash
container start -i "codex-`basename $PWD`"
```

To remove the container later after you finished working with it, use the following command to remove it:

```bash
container rm "codex-`basename $PWD`"
```

To check what containers (even stopped ones) are lingering around use:

```bash
container ls -a
```

If you want to run more CPU and memory hungry builds within the codex container, you can specify CPU and memory when starting:

```bash
container run -it -c 6 -m 8G --name "codex-`basename $PWD`" --mount type=bind,src="$(pwd)",dst=/workdir codex
```

### Running OpenAI models in an isolated container

If you really want to connect to an OpenAI model, you have to connect codex within the container to OpenAI using either an API key or a device key. This means, you have to preserve the configuration within the container.

Basically we will create a container keeping the configuration around (`auth.json` generated by `codex login`), then always restart the same container as long as we need it. The example below uses the base `codex` image; swap in another image if you need a different toolchain.

1. Create the desired container, launching bash upon start:

    ```bash
    container run -it --name "codex-`basename $PWD`" --mount type=bind,src="$(pwd)",dst=/workdir codex bash
    ```

2. Within the container's shell, log in to codex using device auth:

    ```bash
    codex login --device-auth
    ```

3. After successful login you can launch codex using the OpenAI models:

   ```bash
   codex
   ```

To restart the container later, start the container:

```bash
container start -i "codex-`basename $PWD`" 
```

and launch codex again:

```bash
codex
```

Remove the container to destroy the device configuration:

```bash
container rm "codex-`basename $PWD`"
```

#### Store auth.json in macOS Keychain

After you complete the Codex device-auth login flow, you may want to keep a copy of the device authorization tokens in your macOS Keychain. This is only relevant when `auth.json` exists (device-auth creates it). The runtime keeps that file in its own private state, but `agentctl run --online` and `agentctl auth` now sync through `agent.sh auth read/write` rather than reading the runtime-private path directly from the host.

If you want to move the current container file into the Keychain manually, `codex-auth-keychain.sh` still provides direct compatibility helpers:

```bash
codex-auth-keychain.sh store-from-container "codex-`basename $PWD`"
```

If you created a fresh container and want to restore the authorization from the Keychain, use:

```bash
codex-auth-keychain.sh load-to-container "codex-`basename $PWD`"
```

Notes:

- The container must be running for both commands.
- The default path is `/home/coder/.codex/auth.json` unless you pass an explicit path.
- `agentctl run --online` and `agentctl auth` automatically sync the Keychain auth into running containers when it differs, using `agent.sh auth read/write`.
- `agentctl run --online` saves refreshed auth back to Keychain when the container reports a newer refresh time (and that field is present).
- `agentctl` now chooses Keychain slots per runtime/auth-format pair. Codex still uses the legacy `codex-OpenAI-auth` entry so the current OpenAI workflow stays compatible.
- Claude credentials are stored under a runtime-specific Keychain slot rather than the Codex legacy slot.
- `agentctl run --profile <name>` sets the Codex profile used by the container.
  Profiles are defined in `config.toml` and control which model to use.

# Qwen Profile
You can also use the Qwen profile for coding-specific tasks:
```bash
# Optional: pull the Qwen profile model before using --profile qwen
ollama pull qwen3.5:35b-a3b-coding-nvfp4
```
