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

## Bridge stdio protocols into a container

Use `agentctl exec --stdio` when a host application needs to launch a
line-oriented stdio protocol server inside an already-running container:

```bash
agentctl exec --stdio --name my-agent -- <command> [args...]
```

This mode keeps stdin open, does not allocate a TTY, and leaves stdout reserved
for the child process. It is intended for protocols such as ACP and MCP, where
the host process expects newline-delimited JSON-RPC on stdin/stdout. Send logs to
stderr or a file; protocol servers must not write non-protocol text to stdout.

Examples:

```bash
# ACP agent runtime for an editor such as Xcode.
agentctl exec --stdio --name my-agent -- \
  sh -lc 'cd /workdir && npx -y @agentclientprotocol/codex-acp'

# MCP stdio server.
agentctl exec --stdio --name my-agent -- \
  codex mcp-server
```

For GUI-launched clients, use a wrapper script with absolute paths and an
explicit PATH. Xcode, for example, launches helper processes with a reduced
environment, so a wrapper may need to include `/opt/homebrew/bin` or
`/usr/local/bin` so `agentctl` can find Apple's `container` CLI. The wrapper
should log to a file such as `~/Library/Logs/agentctl/<name>.log`, never stdout.

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
