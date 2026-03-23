# Local Codex on Mac

>
> **Run Codex AI locally on macOS, powered by Ollama**
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
# Pull gpt-oss:20b model (requires 13 GB on disk!)
ollama pull gpt-oss:20b

# start the container API server (required for building container images)
container system start
```

## Local model connectivity

The default `config.toml` in these images points Codex at Ollama on `http://192.168.64.1:11434/v1`. On many Apple container setups that is the host-side address visible from the container, but the actual gateway can differ. A plain default Ollama setup only listens on `localhost`, so `codexctl run` will not be able to reach it until you expose or proxy the service onto the host address visible from the container network.

Before your first local-model run, choose one of the network setups described in [Network configuration](#network-configuration):

- Option 1: expose Ollama to the network in the Ollama app (**broadest exposure; least safe**)
- Option 2: start a second Ollama listener on the host address visible from the container network
- Option 3: run a proxy such as `socat` or OllamaProxy between that host address on port `11434` and `127.0.0.1:11434`

If you want a quick host-side verification before launching Codex, run this on hosts where `192.168.64.1` is the container-visible address:

```bash
curl -fsS http://192.168.64.1:11434/api/version
```

That command should return a short JSON object with Ollama's version. If it fails, fix the network path first; otherwise Codex inside the container will fail to reach Ollama.

`codexctl run` performs a local-mode preflight only when starting the default Codex command. If the configured Ollama endpoint is unreachable, it checks the container's detected host gateway and prints an actionable error when the config points at the wrong address or Ollama is not exposed on that gateway. `--cmd` and `--shell` skip this check.

## Use `codexctl` (recommended)

`codexctl` is the entry point for running Codex containers. It wraps the Apple `container` CLI, handles naming, and automates OpenAI device-auth when requested.

The basic idea is to start a container in the directory where your sources and/or documents are located. The container ensures that `codex` can only access files in the current directory tree (this directory and its subdirectories), but still the container contains many development tools `codex` needs to be useful/efficient in its work.

By installing `codexctl` somewhere in your system PATH (e.g. /usr/local/bin/ or better privately in ~/bin/), you can run a codex container in any directory you currently work, as easy as running `codexctl run`.

```bash
chmod 700 codexctl                            # restrict it to your user
sudo ln -s "$PWD/codexctl" /usr/local/bin/    # link it to system directory
```

### Quick start

```bash
# Build images once
codexctl build

# Snapshot current images without rebuilding
codexctl build --snapshot

# Run Codex for the current directory (persistent by default)
codexctl run

# Run Codex for a specific directory
codexctl run --workdir /path/to/project

# Run with a specific image
codexctl run --image codex-office

# Run a specific historical build
codexctl run --image codex:20260313-154500

# Read-only workdir mount
codexctl run --read-only

# Throwaway session (container is deleted when codex is quit)
codexctl run --temp

# OpenAI mode (auto-auth if needed)
codexctl run --openai

# Update codex package in the running container
codexctl run --update

# Recreate a container from the latest image while preserving config
codexctl upgrade

# List stable tags, timestamped snapshots, and backup images (like upgrade backups)
codexctl images

# Prune old snapshot tags by family while keeping one newest (dry-run)
codexctl images prune --keep 1 --dry-run

# Start a shell inside the container
codexctl run --shell

# Run a custom command (must be last)
codexctl run --cmd bash
```

#### Quick start notes

- Builds create the stable `codex`, `codex-python`, `codex-swift`, and `codex-office` tags and also add immutable UTC snapshot tags such as `codex:20260313-154500`. Use `codexctl build --snapshot` to add fresh timestamp tags to the current images without rebuilding them.
- `--cmd` consumes the remaining arguments, cannot be combined with `--shell`, and should be placed last. If you pass one quoted string with spaces, it runs via `$CODEX_SHELL -lc`. The same behavior applies to `codexctl exec`.
- In local-model mode, the Ollama reachability preflight only runs for the default Codex startup path. `--cmd` and `--shell` skip that check so image inspection and ad hoc commands still work without a running Ollama listener.
- `CODEX_SHELL` overrides the shell used by `run --shell` and `exec` (default: `bash`). You can also set `DEFAULT_SHELL` in `codexctl` for a static default. All default images include both `bash` and `zsh`.
- `codexctl run --update` upgrades `@openai/codex` inside the target container before starting. If the container does not exist yet, it is created first. With `--temp`, the update is ephemeral; `codexctl build --rebuild` remains the persistent way to refresh image content.
- `codexctl upgrade` is the persistent refresh path for an existing named container. It exports the current container to a backup image, preserves `/home/coder/.codex`, recreates the container from the selected image, restores the saved config, and returns the container to its previous running or stopped state.
- If an older container has `~/.codex/AGENTS.md` as a regular file instead of the expected symlink to `/etc/codexctl/image.md`, `codexctl upgrade` stops and asks you to re-run with `--overwrite-config`. You can also reset image-owned defaults with `codexctl run --name <container> --reset-config`.
- After a successful `codexctl upgrade`, the command prints the backup image name. Remove it later with `codexctl images prune --backup --image <backup-image> --keep 0` after you have verified the upgraded container works as expected.
- Use `--rebuild`, `--refresh-base`, and `--pull-base` only for occasional refreshes when you want newer Codex or base image content. See the build cache section below for details.
- `codexctl` was authored by Codex itself, running inside an Apple `container` in `--openai` mode.

#### Image selection

Use `--image` when you need a specific toolchain, or set `DEFAULT_IMAGE` in `codexctl` for a permanent default.

When to use which image:

- `codex`: general-purpose CLI work or small scripts without a heavy runtime.
- `codex-python`: Python-heavy tasks, data wrangling, and libraries not in the base image.
- `codex-swift`: Swift projects, SwiftPM builds, and Swift tooling.
- `codex-office`: document-centric workflows (docx/xlsx/pdf parsing, report generation).

### Configuration tweaks

`codexctl` exposes a few top-level constants (in `codexctl`) that you can edit to adjust default behavior:

- `DEFAULT_IMAGE` (default image for `run` and `auth`, e.g. `codex`, `codex-python`, `codex-swift`, `codex-office`)
- `DEFAULT_NAME_PREFIX` (default local container prefix)
- `AUTH_NAME_PREFIX` (default auth container prefix)
- `DEFAULT_SHELL` (default shell for `run --shell` and `exec`)
- `DEFAULT_CODEX_PROFILE` (default profile passed to codex in local mode)
- `DEFAULT_CODEX_CMD` (base codex command/flags used when launching codex)

### Other useful commands

```bash
codexctl --help          # show command overview and available subcommands/options
codexctl auth              # run device-auth and store in Keychain
codexctl images            # list local codex image refs
codexctl images --backup    # list local codex backup image refs
codexctl upgrade           # recreate the current container from the latest image
codexctl upgrade --overwrite-config  # reset config.toml from upgraded image and recreate ~/.codex/AGENTS.md symlink
codexctl images prune --backup --keep 2 --dry-run  # preview backup pruning
codexctl exec              # shell into running container
codexctl ls                # list containers
codexctl rm                # remove the default container for this directory
```

Notes:

- `--auth` only works together with `--openai`.
- `--temp` creates a disposable container that is removed after the command exits.
- `--read-only` mounts the workdir as read-only; codex can use its home directory or `/tmp` for scratch data. But cannot modify the workdir.
- The mount mode is fixed on first creation for a given container name. To switch between read-only and read-write, remove the container (e.g. `codexctl rm`) or use `--temp`/`--name` to create a fresh one.
- `--openai --temp` still injects Keychain auth before running the command.
- Keychain auth is the source of truth for `--openai`; it is synced into running containers before each run.
- After a run, if the container refresh time is newer (and present), the updated auth is saved back into Keychain.
- After `codexctl auth`, exit any running `--openai` sessions and re-run `codexctl run --openai` to pick up the new token.

Security notes:

- Containers run as a non-root `coder` user with Linux capabilities dropped.
- `config.toml` sets `sandbox_mode = "danger-full-access"` to maximize capabilities. Codex can read/write anything in the mounted directory tree and run tools inside the container. Use only with trusted workspaces or change it to `workspace-write` for tighter guardrails.
- Containers have full outbound network access by default. `--openai` needs outbound access; if you want to constrain networking, use host firewall rules or a restricted container network.
- If you need root for maintenance tasks, use `codexctl su-exec` (or `container exec -u 0 ...`).
- Some scripts that assume root access to system paths may fail; run them via `su-exec` or update them.

The rest of this README explains what `codexctl` does behind the scenes and how to run the underlying `container` commands directly.

## Behind the scenes

### Build codex container images

To build the codex container images for later use, I have written four `DockerFile`s which are installing `codex`, `git` and other basic tools (`bash`, `zsh`, `npm`, `file`, `curl`):

- `DockerFile` for a plain Alpine Linux (~191 MB)
- `DockerFile.python` for a Alpine based Python installation (~203 MB, built on top of `codex`)
- `DockerFile.swift` for an Ubuntu based Swift installation (~1.41 GB)
- `DockerFile.office` for Alpine + Python + Office tooling (~417 MB, built on top of `codex-python`)

The Alpine-based images are layered for incremental builds: `codex` -> `codex-python` -> `codex-office`.

The image build process uses `npm` to install the latest `openai/codex` package, and configures `git` to use "Codex CLI" and `codex@localhost` as the container user's identity when interacting with git and to use `main` as the default branch when initializing a new repository.

Further the build process copies `config.toml` into the container at `/home/coder/.codex/` so that codex will properly connect to the locally running Ollama instance on the `default` network's host IP address `192.168.64.1`, and also mirrors it into `/etc/codexctl/config.toml` so upgrade resets can source the image-owned default reliably.

Each image also writes `/etc/codexctl/image.md` during build. That file describes the image name, build time, workspace conventions, and key built-in tools/toolchains. It intentionally lives outside `/home/coder/.codex`, so `codexctl upgrade` does not treat it as user state to back up and restore.

The image build also creates `~/.codex/AGENTS.md` as a symlink to `/etc/codexctl/image.md`. This follows the official Codex `AGENTS.md` discovery flow for global guidance while keeping the source metadata image-owned instead of backed up as mutable user state. `codexctl run` still starts Codex with `--cd /workdir` so the working root is explicit.

The image-specific `image.md` files describe the intended toolchain focus:

- `codex`: general shell and Git tooling
- `codex-python`: Python runtime and the default `/opt/venv`
- `codex-office`: document, PDF, spreadsheet, and report-generation tooling
- `codex-swift`: Swift-on-Linux tooling and related platform constraints

Use the following `container` commands to build the codex images `codex`, `codex-python`, `codex-swift`, and `codex-office` from the corresponding `DockerFile` (build the Alpine images in order so the bases exist):

```bash
STAMP="$(date -u +%Y%m%d-%H%M%S)"

container build -t codex -f DockerFile .
container image tag codex "codex:${STAMP}"

container build -t codex-python -f DockerFile.python .
container image tag codex-python "codex-python:${STAMP}"

container build -t codex-office -f DockerFile.office .
container image tag codex-office "codex-office:${STAMP}"

container build -t codex-swift -f DockerFile.swift .
container image tag codex-swift "codex-swift:${STAMP}"
```

This keeps the stable image names for normal use and also creates immutable timestamped tags for A/B testing and rollback.
Notes:
- The Swift image includes `format` and `lint` wrappers for `swift-format` and initializes `swiftly` for toolchain management.
- The Office image sets up a writable venv at `/opt/venv` and puts it on `PATH` by default.

#### Build cache behavior (codexctl)

- `--rebuild` disables Dockerfile layer cache (`--no-cache`). Use when Codex warns you about an outdated version and you want all new containers to start from a fresh image.
- `--snapshot` creates a new timestamp tag for the current stable image without rebuilding it. Use when you want an immutable test reference for the image you already have locally.
- `--pull-base` pulls the latest base image tag before building. Use when you want to update base images without deleting them first (preferred).
- `--refresh-base` deletes the base image first, forcing a re-fetch on build. Use when you need a brute-force refresh; this may fail if the base image is still referenced by containers.

### Network configuration

By default, Ollama is only listening on localhost connections, i.e. on <http://localhost:11434> or <http://127.0.0.1:11434>. Containers have outbound network access enabled (required for `--openai`), so be deliberate about exposing host services. To be able to connect from a container (through a virtual network) to the Ollama service running on localhost, we have three options:

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

After you complete the OpenAI device-auth login flow, you may want to keep a copy of the device authorization tokens in your macOS Keychain. This is only relevant when `auth.json` exists (device-auth creates it). The file lives at `/home/coder/.codex/auth.json` inside the container and contains sensitive tokens. Use `codex-auth-keychain.sh` to move it into the Keychain:

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
- `codexctl run --openai` and `codexctl auth` automatically sync the Keychain auth into running containers when it differs.
- `codexctl run --openai` saves refreshed auth back to Keychain when the container reports a newer refresh time (and that field is present).
