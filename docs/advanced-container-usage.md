# Advanced container usage

This page collects lower-level workflows that are useful for debugging or when
you want to use Apple’s `container` CLI directly instead of `agentctl`.

## Run a throwaway container

```bash
container run --rm -it --mount type=bind,src="$(pwd)",dst=/workdir agent-plain
```

## Use a named persistent container

```bash
container run -it --name "agent-$(basename "$PWD")" --mount type=bind,src="$(pwd)",dst=/workdir agent-plain
```

Equivalent create/start split:

```bash
container create -t --name "agent-$(basename "$PWD")" --mount type=bind,src="$(pwd)",dst=/workdir agent-plain
container start -i "agent-$(basename "$PWD")"
```

Restart later:

```bash
container start -i "agent-$(basename "$PWD")"
```

Remove later:

```bash
container rm "agent-$(basename "$PWD")"
```

List even stopped containers:

```bash
container ls -a
```

## Exec into a running container

```bash
container exec -it "my-agent" bash
```

## Resource overrides

If you need a heavier direct container:

```bash
container run -it -c 6 -m 8G --name "agent-$(basename "$PWD")" --mount type=bind,src="$(pwd)",dst=/workdir agent-plain
```

## Manual provider-backed Codex flow

If you want a fully manual isolated Codex login flow:

1. Start a named container:

   ```bash
   container run -it --name "agent-$(basename "$PWD")" --mount type=bind,src="$(pwd)",dst=/workdir agent-plain bash
   ```

2. Log in inside the container:

   ```bash
   codex login --device-auth
   ```

3. Launch Codex:

   ```bash
   codex
   ```

This is the lower-level equivalent of the `agentctl auth` and `agentctl run --online`
workflow.

## Why use agentctl instead

`agentctl` exists so you do not need to manually manage:
- naming
- image selection
- runtime selection
- auth sync
- refresh/upgrade flows
- feature packs
- bootstrap
