# Advanced container usage

This page collects lower-level workflows that are useful for debugging or when
you want to use Apple’s `container` CLI directly instead of `agentctl`.

## Run a throwaway container

```bash
container run --rm -it --mount type=bind,src="$(pwd)",dst=/workdir codex
```

## Use a named persistent container

```bash
container run -it --name "codex-$(basename "$PWD")" --mount type=bind,src="$(pwd)",dst=/workdir codex
```

Equivalent create/start split:

```bash
container create -t --name "codex-$(basename "$PWD")" --mount type=bind,src="$(pwd)",dst=/workdir codex
container start -i "codex-$(basename "$PWD")"
```

Restart later:

```bash
container start -i "codex-$(basename "$PWD")"
```

Remove later:

```bash
container rm "codex-$(basename "$PWD")"
```

List even stopped containers:

```bash
container ls -a
```

## Exec into a running container

```bash
container exec -it "my-codex" bash
```

## Resource overrides

If you need a heavier direct container:

```bash
container run -it -c 6 -m 8G --name "codex-$(basename "$PWD")" --mount type=bind,src="$(pwd)",dst=/workdir codex
```

## Manual provider-backed Codex flow

If you want a fully manual isolated Codex login flow:

1. Start a named container:

   ```bash
   container run -it --name "codex-$(basename "$PWD")" --mount type=bind,src="$(pwd)",dst=/workdir codex bash
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
