# Runtimes

`agentctl` separates image/toolchain choice from runtime choice.

Examples of runtimes currently wired into the runtime contract:
- `codex`
- `claude`
- `opencode`
- `qwen`
- `pi`

## Inspect runtimes

```bash
agentctl runtime list
agentctl runtime info codex
agentctl runtime capabilities claude
```

`runtime info` and `runtime capabilities` query the in-container `agent.sh`
runtime contract.

## Install runtimes

```bash
agentctl runtime install codex
agentctl runtime install claude
agentctl runtime install opencode
agentctl runtime install qwen
agentctl runtime install pi
```

Curated image builds install configured runtimes during image creation. Runtime
install/update commands place launchers and package caches under `/opt/agentctl`
so mounting external state over `/home/coder` does not hide image-baked tools.
Runtime config, auth, history, and sessions remain under `/home/coder`.
Image-owned default configuration is grouped under `/etc/agentctl/<runtime>`;
it is copied into runtime-owned home directories only when needed.
Tracked host baselines mirror that structure under `defaults/<runtime>`, with
ignored personal overrides under `defaults.local/<runtime>`.

To install before launch, opt in explicitly:

```bash
agentctl run --runtime claude --install-runtime
```
Running a selected runtime does not install it automatically:

```bash
agentctl run --runtime claude
```

## Update a runtime

Update an installed runtime in the existing container selected by the current
project directory:

```bash
agentctl runtime update codex
```

For Codex, `run --update` is the convenient update-and-launch form. It updates
the Codex CLI in the target container immediately before starting the session
and can be combined with online mode:

```bash
agentctl run --online --update
```

Runtime updates persist in a named container. They do not update the agentctl
Git checkout or rebuild the container image.

## Select the preferred runtime

Two equivalent commands exist:

```bash
agentctl use claude
agentctl runtime use claude
```

This updates the container-local preferred runtime. The next default `agentctl run`
for that container launches the selected runtime unless you override it.

## Runtime metadata locations

Managed runtime metadata lives at:

- `/etc/agentctl/runtimes.d`
- `/usr/local/lib/agentctl/runtimes`

`agentctl refresh` updates both in existing containers.

## Multi-runtime images

Images can preinstall multiple runtimes:

```bash
agentctl build --runtimes codex,claude,opencode,qwen,pi --default-runtime opencode
# Equivalent registry-driven installation of every available runtime:
agentctl build --runtimes all --default-runtime opencode
```

That image starts with OpenCode as the default runtime, but you can later switch
back to Codex inside a container with:

```bash
agentctl runtime use codex
```

OpenCode is wired as a local-first Ollama runtime. It writes a default
`~/.config/opencode/opencode.json` only when the file is missing or when you run
`runtime reset-config opencode`.

Qwen Code and Pi are also wired as local-first Ollama runtimes. Qwen writes
`~/.qwen/settings.json`; Pi writes `~/.pi/agent/models.json`. These files are
created at runtime when missing so mounted `/home/coder` state can use
image-baked runtime tools without needing image-baked home config.

## Codex background server on Alpine

Current Codex releases can start a PID-managed App Server daemon for interactive
sessions. That native daemon cannot reliably read the managed process start time
inside Alpine containers. Agentctl therefore launches ordinary Codex sessions
with `--no-daemon` on Alpine when the installed CLI supports that option.

This fallback does not enable Remote Control and does not affect authentication,
session persistence, or runtime tool use. Features that specifically require a
shared background server remain unavailable for that session. When an
agentctl-managed App Server is already healthy—for example, after an explicit
`agentctl remote-control start`—agentctl leaves daemon selection unchanged so
the local client can attach to the shared server.

If the standalone Codex package ships a broken `rg`, agentctl repairs it by
copying a working system executable into the package. Keeping the repaired path
as a regular file is required because Codex rejects external package symlinks
when installing its daemon payload.

## Related docs

- [local-vs-online.md](local-vs-online.md)
- [auth.md](auth.md)
- [images.md](images.md)
