# Images

`agentctl build` manages the curated image set, timestamped snapshots, and
image-local dependency resolution.

## Curated images

The primary curated images are:

- `agent-plain`
- `agent-python`
- `agent-swift`

`agent-office` remains only as a legacy compatibility image.

Image naming convention:

- `DockerFile` -> `agent-plain`
- `DockerFile.<name>` -> `agent-<name>`

## Building images

Basic examples:

```bash
agentctl build
agentctl build --image agent-python
agentctl build --snapshot
```

Each successful build keeps the stable tag and also creates an immutable UTC
timestamp tag.

### Preinstalled runtimes

You can choose which runtimes are built into an image:

```bash
agentctl build --runtimes codex,claude --default-runtime claude
# Or install every runtime currently registered with agentctl:
agentctl build --runtimes all --default-runtime codex
```

Rules:

- if `--default-runtime` is omitted, the first runtime in `--runtimes` becomes
  the default
- `--runtimes all` expands to every manifest in `runtimes.d`, keeping `codex`
  first as the default unless `--default-runtime` is supplied
- `--default-runtime <name>` still works by itself for the single-runtime case

Image builds use the copied in-image `agent.sh runtime install ...` flow, so
runtime installation logic is shared with later in-container installs.

### Runtime startup implications

The image default runtime becomes `/etc/agentctl/preferred-runtime` in the built
image. `agentctl run` then uses that effective preferred runtime for:

- startup behavior
- auth replay
- local/online launch-mode decisions

### Custom Dockerfiles

If a custom local Dockerfile uses `FROM agent-python`, `agentctl build` resolves
the local dependency chain first.

### Direct build equivalent

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

## Refreshing vs upgrading

Use `refresh` when you want to update an existing container in place from the
same image family after pulling or rebuilding a newer local checkout.

Use `upgrade --image ...` when you want to recreate an existing container from a
different curated image.

In short:

- `refresh`: keep the same container and update managed files in place
- `upgrade`: recreate the container with a different image and preserve user
  state

## Upgrade examples

Move a container from `agent-plain` to `agent-python`:

```bash
agentctl upgrade --name my-project --image agent-python
```

If you also want the new image's owned defaults restored into `~/.codex`, add:

```bash
agentctl upgrade --name my-project --image agent-python --overwrite-config
```

If the project directory moved on the host, update the bind mount at the same
time:

```bash
agentctl upgrade --name my-project --image agent-python --workdir /new/path/to/project
```

If you also want the recreated container to follow the new project name:

```bash
agentctl upgrade --name my-project --new-name my-project-renamed --workdir /new/path/to/project
```

If you want to test the new image or mount settings without touching the source
container, use copy mode:

```bash
agentctl upgrade --name my-project --new-name my-project-copy --copy --image agent-python
```

To preview the plan before recreating anything:

```bash
agentctl upgrade --name my-project --new-name my-project-renamed --workdir /new/path/to/project --dry-run
```

## What Upgrade Preserves

`upgrade` keeps the `/workdir` mount and named-container identity by default
while switching the image underneath the container.

Modern upgrades preserve broader user state, not just `~/.codex`. The state
transfer path includes:

- `~/.codex`
- `~/.config/agentctl`
- `~/.claude`
- `~/.claude.json`
- common shell startup files and history for `coder`, including `~/.profile`,
  `~/.bashrc`, `~/.bash_history`, and zsh/ash/sh equivalents

New containers and upgrades also persist an image baseline snapshot at
`/etc/agentctl/system-manifest.json`. That lets later upgrades compare against
the original image even if it is no longer present locally.

The stored baseline records:

- image package list
- installed runtimes
- installed features
- image default runtime
- image preferred/default effective runtime metadata

## Upgrade Behavior

Before recreation, `upgrade` warns about extra OS packages that were added after
the source baseline and are not present in the target image, because those
packages are not preserved automatically.

When an upgrade detects runtimes or features that were added after the source
image baseline and are still installable in the target image, it reinstalls
them automatically before restoring user state.

If the current preferred runtime is not available after the upgrade, `agentctl`
warns and drops the stale user override so the recreated container falls back to
the target image default instead of keeping a broken preference.

## Legacy Upgrade Caveats

For older source containers that do not support the modern `agent.sh state`
contract, `upgrade --no-backup` is rejected.

In that case, keep the backup image enabled so the original container
filesystem can be recovered if needed.

## Backup Image Rescue

Use `rescue` to temporarily inspect an upgrade backup image without refreshing
it or mounting the current workdir:

```bash
agentctl rescue --image agent-my-project-backup-20260516113757
```

By default, `rescue` creates a temporary container, opens `/bin/sh` as root, and
removes the container when the shell exits. Use `--cmd` for a single command:

```bash
agentctl rescue --image agent-my-project-backup-20260516113757 --cmd sh -lc 'cat /etc/agentctl/smoke-marker'
```

Use `--keep --name NAME` when you want to leave the rescue container running for
multiple inspection commands:

```bash
agentctl rescue --image agent-my-project-backup-20260516113757 --name recover-my-project --keep
```

For a fuller recovery checklist, runtime state counting, and restore examples,
see [rescue.md](rescue.md).

## Snapshots, Rebuilds, and Cache

Snapshot and rebuild options:

- `--snapshot`: add a new timestamp tag without rebuilding
- `--rebuild`: rebuild without Dockerfile layer cache
- `--pull-base`: refresh upstream base tags before build
- `--refresh-base`: delete the base image first to force a refetch

Notes:

- `--rebuild` does not pull newer upstream `FROM` tags by itself
- use `--pull-base` when you want newer remote base image content
- use `--snapshot` when you only want an immutable tag for the image you
  already have locally

## Image Management

```bash
agentctl images
agentctl images --latest
agentctl images prune --keep 1 --dry-run
agentctl images rm --image agent-custom --dry-run
```

- `agentctl images prune`: remove old timestamp tags while keeping stable tags
- `agentctl images rm --image <name>`: remove an image family entirely

## Image-Owned Defaults

The curated images carry image-owned defaults used by `refresh`,
`reset-config`, and runtime adapters, including:

- `/etc/agentctl/codex/config.toml`
- `/etc/agentctl/codex/local_models.json`
- `/etc/agentctl/image.md`
- `/etc/agentctl/image-version`
- `/etc/agentctl/tooling-version`
- `/etc/agentctl/claude/settings.json`

`agent.sh system manifest` (and therefore `agentctl system-manifest`) exposes
the two version markers as `image_version` and `tooling_version`. Images that
predate version tracking report `unknown`.

The global `AGENTS.md` guidance inside the image points at the image-owned
metadata file instead of storing mutable user state inside `~/.codex`.

Host-side baselines use the same runtime grouping:

- `defaults/codex/`
- `defaults/claude/`
- `defaults/opencode/`
- `defaults/qwen/`
- `defaults/pi/`

These files are tracked and provide working starting points. Personal defaults
belong in the ignored `defaults.local/<runtime>/` overlay. A file there replaces
the tracked file with the same name during image builds and `agentctl refresh`.
For example:

```bash
cp defaults/codex/config.toml defaults.local/codex/config.toml
# Edit defaults.local/codex/config.toml, then rebuild the desired images.
agentctl build
```

Additional Codex `*.config.toml` profiles placed in
`defaults.local/codex/` are included as image defaults. Avoid putting auth
tokens or other secrets in either defaults directory: image layers and
container defaults are not secret storage.

OpenCode, Qwen Code, and Pi normally generate their Ollama provider settings at
runtime because the endpoint and selected model can vary. Their tracked folders
are therefore intentionally empty. Optional local defaults use these filenames:

- `defaults.local/opencode/opencode.json`
- `defaults.local/qwen/settings.json`
- `defaults.local/pi/models.json`

Builds place supplied files in the matching `/etc/agentctl/<runtime>` directory;
refresh deploys them to existing containers. Qwen Code and Pi merge their
launch-time model and endpoint into user configuration. OpenCode uses an
existing configuration unchanged, so a local OpenCode default should use a
portable endpoint such as `http://host.container.internal:11434/v1` unless a
fixed endpoint is intentional.

## Related docs

- [runtimes.md](runtimes.md)
- [bootstrap.md](bootstrap.md)
