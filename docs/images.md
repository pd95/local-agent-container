# Images

`agentctl build` manages the curated image set and timestamped snapshots.

## Curated images

The primary image set is:

- `agent-plain`
- `agent-python`
- `agent-swift`

`agent-office` remains only as a legacy compatibility image.

Image naming convention:

- `DockerFile` -> `agent-plain`
- `DockerFile.<name>` -> `agent-<name>`

## Build basics

```bash
agentctl build
agentctl build --image agent-python
agentctl build --snapshot
```

Each successful build keeps the stable tag and also creates an immutable UTC
timestamp tag.

## Preinstalled runtimes

You can choose which runtimes are built into an image:

```bash
agentctl build --runtimes codex,claude --default-runtime claude
```

Rules:
- if `--default-runtime` is omitted, the first runtime in `--runtimes` becomes
  the default
- `--default-runtime <name>` still works by itself for the single-runtime case

Image builds use the copied in-image `agent.sh runtime install ...` flow, so
runtime installation logic is shared with later in-container installs.

## Model/runtime startup implications

The image default runtime becomes `/etc/agentctl/preferred-runtime` in the built
image. `agentctl run` then uses that effective preferred runtime for:

- startup behavior
- auth replay
- local/online launch-mode decisions

## Changing images for an existing container

Use `refresh` when you want to recreate a container from the same image family
after pulling or rebuilding a newer local `agentctl` checkout.

Use `upgrade --image ...` when you want to move an existing container to a
different curated image.

Example: you started with `agent-plain`, but later need Python tooling in the
same named container:

```bash
agentctl upgrade --name my-project --image agent-python
```

If you also want the new image's owned defaults restored into `~/.codex`, add:

```bash
agentctl upgrade --name my-project --image agent-python --overwrite-config
```

This keeps the preserved `/workdir` mount and recreated container identity
while switching the base image family underneath it.

If the project directory moved on the host, you can update the bind mount at
the same time:

```bash
agentctl upgrade --name my-project --image agent-python --workdir /new/path/to/project
```

If you also want the recreated container to follow the new project name, you
can rename it during the same upgrade:

```bash
agentctl upgrade --name my-project --new-name my-project-renamed --workdir /new/path/to/project
```

If you want to test the new image or mount settings without touching the source
container, add `--copy` with `--new-name`:

```bash
agentctl upgrade --name my-project --new-name my-project-copy --copy --image agent-python
```

To preview the upgrade plan first without recreating anything, add `--dry-run`:

```bash
agentctl upgrade --name my-project --new-name my-project-renamed --workdir /new/path/to/project --dry-run
```

Before recreating the container, `upgrade` warns about extra OS packages that
were added after the container's stored baseline snapshot and are not present
in the target image, because those packages are not preserved automatically.

New containers and upgrades persist that baseline snapshot at
`/etc/agentctl/system-manifest.json` so later upgrades can still compare
against it even if the original image is no longer present locally. That
baseline now records the image package list, installed runtimes, installed
features, and the image default/preferred runtime.

Modern upgrades now preserve broader user state, not just `~/.codex`. The
state transfer path includes:

- `~/.codex`
- `~/.config/agentctl`
- `~/.claude`
- `~/.claude.json`

For older source containers that do not support the modern `agent.sh state`
contract, `upgrade --no-backup` is rejected. In that case keep the backup image
enabled so the original container filesystem can be recovered if needed.

## Snapshots and rebuilds

- `--snapshot`: add a new timestamp tag without rebuilding
- `--rebuild`: rebuild without Dockerfile layer cache
- `--pull-base`: refresh upstream base tags before build
- `--refresh-base`: delete the base image first to force a refetch
- `agentctl images prune`: remove old timestamp tags while keeping stable tags
- `agentctl images rm --image <name>`: remove an image family entirely

## Build cache behavior

Notes:
- `--rebuild` does not pull newer upstream `FROM` tags by itself
- use `--pull-base` when you want newer remote base image content
- use `--snapshot` when you only want an immutable tag for the image you
  already have locally

## Custom Dockerfiles

If a custom local Dockerfile uses `FROM agent-python`, `agentctl build` resolves
the local dependency chain first.

## Image management

```bash
agentctl images
agentctl images --latest
agentctl images prune --keep 1 --dry-run
agentctl images rm --image agent-custom --dry-run
```

## Direct build equivalent

Example for `agent-plain`:

```bash
container build -t agent-plain -f DockerFile .
```

Multi-runtime example:

```bash
container build \
  -t agent-plain \
  -f DockerFile \
  --build-arg AGENT_RUNTIMES=codex,claude \
  --build-arg AGENT_DEFAULT_RUNTIME=claude \
  .
```

## Image-owned defaults

The curated images also carry image-owned defaults used by `refresh`,
`reset-config`, and runtime adapters, including:

- `/etc/codexctl/config.toml`
- `/etc/codexctl/local_models.json`
- `/etc/codexctl/image.md`
- `/etc/claudectl/settings.json`

The global `AGENTS.md` guidance inside the image points at the image-owned
metadata file instead of storing mutable user state inside `~/.codex`.

## Related docs

- [runtimes.md](runtimes.md)
- [bootstrap.md](bootstrap.md)
