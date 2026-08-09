# Codex Remote Control

Agentctl can run Codex Remote Control inside an existing managed container so
eligible ChatGPT desktop and mobile clients can reach that development
environment. This integration is experimental because the underlying Codex CLI
and headless Linux workflow are experimental.

Remote Control is provider-backed and implies online operation. It does not use
the local Ollama profile and it does not publish an App Server TCP port. Codex
uses its local Unix control socket and makes the provider connection itself.

The components work together as follows:

1. Agentctl starts the Codex App Server inside the container with
   `CODEX_HOME=/home/coder/.codex`.
2. The App Server uses the container's Codex state, authentication, threads, and
   enrollment and establishes the outbound Remote Control connection.
3. An authorized ChatGPT client reaches that environment through the Remote
   Control service; no inbound host port is opened.
4. Local Codex sessions and remote clients operate against the same persisted
   Codex environment.

## Requirements

- An existing agentctl container with the Codex runtime and Node.js installed.
- Codex authentication stored through `agentctl auth`.
- A ChatGPT account, workspace policy, and client rollout that support Remote
  Control.

An image rebuild is not required. `remote-control start` installs its small
status helper into the existing container automatically; a separate
`agentctl refresh` is optional.

## Start and pair

From the project directory associated with the container:

```bash
agentctl remote-control start
agentctl remote-control pair
```

Pairing authorizes a new ChatGPT controller to discover and connect to the
running environment. Codex generates a short-lived code, which the user enters
in the intended ChatGPT client. Pairing does not copy the container's OpenAI
tokens to the controller, and agentctl neither stores nor logs the code.
`start` never pairs or authorizes a controller automatically.

Enrollment is stored with the existing Codex state under `~/.codex` and is
reused across normal service and container restarts. Run `pair` when authorizing
a new controller or when the ChatGPT client requests a new code; it is not a
required step on every startup.

`start` requires an existing Codex container. It starts a stopped container when
necessary, synchronizes online authentication, and returns after the App Server
is locally healthy. The App Server runs detached with
`CODEX_HOME=/home/coder/.codex`, so existing conversations, configuration,
authentication, and enrollment remain available.

For the most reliable transition from a local-only Codex session, start Remote
Control before opening a new local Codex session. A session that was already an
active thread writer before the App Server started can produce a
`thread-store conflict`; close that old session and open a new one after Remote
Control is running. Local and remote sessions can then coexist, including
simultaneous interaction, as long as Codex accepts their thread ownership.

## Optional status diagnostics

The normal workflow does not require a separate status check: `start` validates
local health, and `pair` reports when pairing cannot proceed. The status command
is available for scripts and lifecycle troubleshooting:

```bash
agentctl remote-control status
agentctl remote-control status --json
```

Human output reports the actionable service state:

| State | Meaning |
| --- | --- |
| `missing_container` | The named container does not exist. |
| `container_stopped` | The container is stopped; persisted Remote Control intent may still exist. |
| `stopped` | The container is running but its managed App Server is not. |
| `running` | The managed App Server and local control socket are healthy. |
| `connecting` | Codex reported that its provider connection is being established. |
| `connected` | Codex reported that its provider connection is established. |
| `errored` | Codex reported a Remote Control connection error. |
| `unmanaged` | An App Server not owned by agentctl is already running. |

Codex 0.147.0 exposes Remote Control connection changes as notifications but
does not replay the current value to a later status observer. Consequently, an
already-connected service normally reports `running`. In JSON,
`remote_status` is `null` unless agentctl actually observes `connecting`,
`connected`, `errored`, or `disabled`. A null value does not mean disconnected,
and absent remote telemetry is omitted from human output.

`remote_status` describes the App Server's provider connection. It does not
report pairing state, attached controller count, or whether ChatGPT currently
has a thread open.

## Stop and lifecycle behavior

```bash
agentctl remote-control stop
```

This explicitly disables Remote Control, stops the managed App Server, and
removes persisted Remote Control intent. A later ordinary `agentctl start` will
therefore start only the container until `remote-control start` is invoked
again.

Ordinary lifecycle commands behave differently:

- `agentctl stop` quiesces the App Server but preserves intent.
- `agentctl start` restores Remote Control when preserved intent exists.
- `agentctl restart` quiesces and restores it around the restart.
- A normal `agentctl run` that starts a container restores preserved intent and
  leaves the container running for Remote Control.
- An in-place `agentctl upgrade` quiesces, migrates, and restores the service.
- `agentctl upgrade --copy` does not copy Remote Control intent to the new
  container; enable the copy explicitly after stopping the source service.
- `agentctl rm` removes the service and its persisted intent.

If `remote-control start` started a previously stopped container,
`remote-control stop` stops that container only when it is still the same
container boot and no managed MCP lease needs it. Otherwise the container is
left running.

## Authentication synchronization

The App Server may refresh ChatGPT authentication while it is online. Agentctl
therefore synchronizes authentication at the online-service boundary:

- Before start, it compares Keychain and container authentication and preserves
  the newer state.
- During `remote-control stop` or an ordinary container stop, it first stops the
  App Server so state is flushed, then promotes newer container authentication
  back to Keychain.
- A Keychain read/write failure makes the managed stop fail rather than
  silently discarding the opportunity to preserve refreshed authentication.
  If the Keychain item itself is missing or contains no refresh token, agentctl
  warns and leaves the container copy untouched; run `agentctl auth` before the
  next online start.

If the container is stopped outside agentctl, an immediate sync is impossible.
The container state persists, and the next managed start compares both copies
before starting the online service.

## Diagnostics and security

Remote Control does not expose the App Server socket over TCP. Agentctl refuses
to adopt or terminate an App Server it cannot prove it owns. On Alpine it uses a
detached direct App Server because the current Codex PID-managed daemon startup
is incompatible with that environment; other systems prefer the native daemon
commands when available.

For the direct backend, stderr is stored at:

```text
/tmp/agentctl-remote-control/service.log
```

An empty log is normal. Successful startup, pairing, and remote connections do
not normally write entries; inspect it only for crashes, authentication errors,
network errors, or thread-store conflicts:

```bash
agentctl exec --no-tty -- \
  tail -n 100 /tmp/agentctl-remote-control/service.log
```

Useful process and health checks are:

```bash
agentctl remote-control status --json
agentctl exec --no-tty -- ps -o pid,ppid,stat,args
agentctl exec --no-tty -- env CODEX_HOME=/home/coder/.codex \
  codex app-server daemon version
```

Pairing codes are short-lived, are not persisted by agentctl, and are not
written to the service log. Do not expose the App Server socket or its transport
directly to a public network.

See [../TESTING.md](../TESTING.md#manual-remote-control-smoke-test) for the
macOS manual acceptance procedure.
