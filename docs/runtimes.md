# Runtimes

`agentctl` separates image/toolchain choice from runtime choice.

Examples of runtimes currently wired into the runtime contract:
- `codex`
- `claude`

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
```

Curated image builds install configured runtimes during image creation. Runtime
install/update commands place launchers and package caches under `/opt/agentctl`
so mounting external state over `/home/coder` does not hide image-baked tools.
Runtime config, auth, history, and sessions remain under `/home/coder`.

To install before launch, opt in explicitly:

```bash
agentctl run --runtime claude --install-runtime
```
Running a selected runtime does not install it automatically:

```bash
agentctl run --runtime claude
```

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
agentctl build --runtimes codex,claude --default-runtime claude
```

That image starts with Claude as the default runtime, but you can later switch
back to Codex inside a container with:

```bash
agentctl runtime use codex
```

## Related docs

- [local-vs-online.md](local-vs-online.md)
- [auth.md](auth.md)
- [images.md](images.md)
