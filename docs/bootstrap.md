# Bootstrap

`agentctl bootstrap` is the bring-your-own-base path.

Use it when you already have, or specifically want, a compatible non-agentctl
container and want to install the managed control surface into it.

## When to prefer bootstrap

Use bootstrap when:
- you already have a compatible container
- you want a custom base image outside the curated set

Prefer curated images when:
- you want the simplest supported setup
- you do not need a special base image

## Supported bootstrap families

Current supported families:
- Alpine (`apk`)
- Debian/Ubuntu (`apt-get`)

Supported flows:
- bootstrap an existing compatible container
- create and bootstrap a new Alpine container with `--image`

## Examples

Bootstrap an existing container:

```bash
agentctl bootstrap --name existing-devbox
```

Create and bootstrap a new Alpine container:

```bash
agentctl bootstrap --name my-alpine-devbox --image docker.io/library/alpine:latest
```

## What bootstrap installs

Bootstrap installs the managed control surface so later `agentctl` commands work
against that container, including:

- `/usr/local/bin/agent.sh`
- `/etc/agentctl`
- runtime manifests/adapters
- feature manifests/adapters

After bootstrap, commands like these work:

```bash
agentctl runtime --name existing-devbox info codex
agentctl feature --name existing-devbox info office
agentctl refresh --name existing-devbox
```

## Limits

Bootstrap support is intentionally narrower than the curated-image path.

Treat it as an extensibility path, not the default recommendation.

## Related docs

- [images.md](images.md)
- [runtimes.md](runtimes.md)
