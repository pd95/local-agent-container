# SSH and Unix-socket forwarding research

This document evaluates Apple container 1.1 SSH-agent and Unix-domain-socket
forwarding for future `agentctl` development. It records upstream behavior,
host probe results, security constraints, possible command-line interfaces, and
a phased implementation direction. It is a design input, not an implementation
commitment.

## Agreed Phase 1 design

Phase 1 exposes repeatable host-to-container mappings as
`--mount-socket HOST_PATH:CONTAINER_PATH` on `run`, `bootstrap`, and `upgrade`.
`upgrade` additionally accepts repeatable `--unmount-socket CONTAINER_PATH`.
Mappings use Apple container's `--volume HOST_PATH:CONTAINER_PATH` form, which
activates its Unix-socket relay, and require no image feature. The equivalent
directory-oriented `--mount` spelling must not be used here because Apple 1.1
rejects a socket source as “not a directory” before relay setup.

An existing container may be used by `run` or `bootstrap` only when explicitly
requested mappings exactly match its inspected mappings. Upgrade preserves
socket mappings by default, merges explicit mappings by container destination,
and applies removals first. This makes it possible to remove a mapping after its
host socket disappears. Any other extra mount that cannot be proven to be a
live Unix socket blocks upgrade instead of being silently discarded.

Both endpoints must be absolute, short enough for a Unix-domain socket address,
and free of delimiters or control characters used by the container CLI. Host
sources must be real sockets rather than symlinks. `/workdir`, `/home/coder`,
and `/var/host-services/ssh-auth.sock` are reserved destinations. Stable literal
host paths are required: unlike `--ssh`, a generic mount does not follow a
launchd path change. Socket access grants the container the authority offered
by that service, so users should expose narrowly scoped sockets and permissions.

Dry-run and doctor output deliberately show endpoint paths needed for repair,
but agentctl never reads, logs, or proxies protocol payloads.

## Managed MCP integration

The completed structured integration uses:

```bash
agentctl run --mcp xcode
agentctl run --mcp '{"name":"example","command":"/absolute/path/to/server","args":[]}'
```

It installs the MCP bridge feature when needed, launches explicitly authorized
host commands such as `xcrun mcpbridge`, mounts a private host Unix-socket relay
with the Phase 1 primitive, and runs a guest loopback Streamable HTTP adapter.
Codex registration is automatic. The production bridge has no host TCP
listener or fallback.

## Agreed Phase 2 design

Phase 2 exposes repeatable container-to-host mappings as
`--publish-socket HOST_PATH:CONTAINER_PATH` on `run`, `bootstrap`, and
`upgrade`. Upgrade additionally accepts repeatable
`--unpublish-socket HOST_PATH`. Apple container stores these mappings in
`configuration.publishedSockets` and creates the host listener only while the
container is running.

Host paths are deliberately explicit and user-managed in this phase. Their
parent directory must already exist, resolve canonically, be owned by the
current user, be writable and searchable by that user, and grant no access to
group or other users. The destination must be absent before Apple creates a
listener. agentctl never creates the parent, removes a collision, or cleans up
a leftover listener. Generated paths such as `/tmp/agentctl-<uid>` were deferred
from Phase 2 and are now used only by the managed Phase 3 MCP integration, where
ownership and cleanup are defined together with the adapter lifecycle.

Existing-container reuse requires an order-independent exact mapping match.
Upgrade preserves mappings by default, applies unpublishes first, and merges
explicit mappings by unique host path. Distinct host paths may publish the same
container service. Published container paths may not collide with agentctl's
managed mounts, SSH relay, or a host-socket mount destination.
Unpublishing validates the host path syntax but does not require its parent to
still exist, so stale configuration remains removable.

Start refuses occupied destinations. Restart and destructive upgrade stop the
source and verify that Apple removed its listeners before continuing. Stop,
remove, and failed cleanup paths only report leftovers. A running copy cannot
retain any source host path because both containers cannot own the listener;
the source must first be stopped or the target mappings must be unpublished or
remapped. Doctor reports unsafe parents, missing/non-socket running listeners,
and entries left behind by stopped containers without connecting to the
published protocol.

Related documents:

- [Apple container 1.1 development opportunities](apple-container-1.1-development-opportunities.md)
- [Advanced container usage](advanced-container-usage.md)
- [Networking and Ollama connectivity](networking.md)
- [Xcode ACP agent proof of concept](../xcode-acp-agent/README.md)

Upstream references:

- [Apple container SSH forwarding guide](https://github.com/apple/container/blob/1.1.0/docs/how-to.md#mount-your-host-ssh-authentication-socket-in-your-container)
- [Apple container 1.1 command reference](https://github.com/apple/container/blob/1.1.0/docs/command-reference.md)
- [Apple container 1.1 non-root socket permission fix](https://github.com/apple/container/commit/888582b4c82dbd95832c0d8428ebbe8ef209a3e0)
- [Apple external-agent Xcode MCP guidance](https://developer.apple.com/documentation/Xcode/giving-external-agents-access-to-xcode)

## Goals

The feature area has three distinct goals:

1. let tools inside an `agentctl` container use the macOS SSH agent
2. let a container consume an arbitrary Unix-socket service on macOS
3. let macOS clients consume a Unix-socket service running in a container

These use different Apple container mechanisms and have different security and
lifecycle behavior. They should not be represented as one ambiguous `--socket`
option.

## Apple container mechanisms

### SSH agent into the container

Apple's `--ssh` flag is a specialized dynamic host-to-container socket relay.
For a running container it provides:

```text
host:      current $SSH_AUTH_SOCK
container: /var/host-services/ssh-auth.sock
env:       SSH_AUTH_SOCK=/var/host-services/ssh-auth.sock
```

The container configuration stores `ssh: true`, not the host's transient socket
path. On `container start`, the CLI sends its current `SSH_AUTH_SOCK` to the
service. This lets a stopped container use a new launchd socket after the user
logs out and back in.

If the starting process has no `SSH_AUTH_SOCK`, Apple logs a warning and cannot
create the relay. The stored container environment can still name the guest
path even when no socket exists, so callers should check the host environment
instead of assuming that the variable alone proves forwarding works.

### Arbitrary host socket into the container

A socket source supplied as a normal mount is detected and relayed into the
guest:

```bash
container run \
  --volume /host/service.sock:/run/host-services/service.sock \
  IMAGE
```

Apple 1.1 propagates the source socket's permission bits to the guest relay
socket. Unlike `--ssh`, the source path is stored literally in the container's
mount configuration. Apple does not dynamically rediscover a replacement path
after login or service restart.

This mechanism is suitable for stable host sockets such as a project daemon,
local API, or a dedicated MCP relay. It is a poor substitute for `--ssh`
because launchd SSH socket paths change.

### Container socket onto the host

`--publish-socket` creates the reverse relay:

```bash
container run \
  --publish-socket /host/service.sock:/run/service.sock \
  IMAGE
```

The argument order is `host_path:container_path`, even though traffic flows
from a host client to a service listening at the container path. Apple stores
the pair in `configuration.publishedSockets`.

The host listener exists while the container VM runs. A client connection is
relayed over vsock to the container socket. The container service may be the
initial process or a later `container exec` process; it only needs to bind the
configured container path before clients connect.

## Verified host behavior

The host probe ran on Apple container 1.1.0 using `agent-python`. Its complete
output is stored under:

```text
tmp/apple-container-ssh-sockets-20260719T114956Z.log
```

### SSH and generic incoming sockets

The macOS launchd SSH agent socket was:

```text
/var/run/com.apple.launchd.jJQgOM0045/Listeners
mode 0666, owner philipp:wheel
```

Inside the container, both the specialized SSH relay and a generic mount of the
same source were visible to `coder` as sockets:

```text
/var/host-services/ssh-auth.sock  mode 0666  root:root
/tmp/generic-agent.sock           mode 0666  root:root
```

The non-root user had UID 100 and GID 101 and successfully connected to both
sockets. This confirms that the Apple 1.1 permission fix works for the project's
normal non-root execution model.

After stop and start, the specialized SSH relay reappeared and `coder` connected
successfully. The exec process received:

```text
SSH_AUTH_SOCK=/var/host-services/ssh-auth.sock
```

The inspected initial environment did not include `SSH_AUTH_SOCK`; Apple adds it
to the effective runtime/exec environment. `agentctl` should inspect the stored
`ssh` Boolean rather than search `initProcess.environment`.

The generic socket appeared in inspect as a normal `virtiofs` mount. Runtime
code recognizes that its source is a socket and constructs a socket relay. This
means inspect parsing must not assume a distinct socket-mount type.

### Published outgoing socket

The container echo service was published at a short path under `/tmp`. The host
socket was:

```text
mode 0755, owner philipp:wheel
```

A host `nc -U` client received data from the container service in both the
initial run and after restart. Stopping the container removed the host socket;
starting it recreated the host listener.

Inspect reported:

```json
{
  "containerPath": "/tmp/echo.sock",
  "hostPath": "/tmp/agt-publish-48148.sock"
}
```

The default mode is too broad for sensitive protocols when the socket is placed
directly in world-searchable `/tmp`. The host user owns it, but the mode permits
other local users to attempt connections. A private parent directory is
required even if Apple does not expose a CLI permission option.

## Image prerequisites

The current base `agent-plain` image installs Git but not OpenSSH. The running
`agent-python` probe had no `ssh` executable, and Alpine's `git` package does not
depend on `openssh-client`.

SSH-agent forwarding alone therefore does not make this work:

```bash
git clone git@github.com:organization/private-repository.git
```

The selected policy is to keep the SSH client out of default base-image builds
and provide it as an installable `ssh` feature. The feature can also be
explicitly preinstalled with `agentctl build --features ssh`. This keeps normal
images smaller while allowing frequently used images to avoid per-container
package installation.

The feature has two separate responsibilities that cannot be conflated:

1. install the guest SSH client and supporting configuration
2. arrange Apple's creation-time `--ssh` relay for the container

The first responsibility can be applied to an existing running container. The
second cannot: Apple container stores `ssh: true` when the container is created,
and there is no command to add it afterward. Installing the package alone must
not claim that forwarding is active.

Possible user flows are:

```bash
# New container: create with the relay, then ensure the feature is installed.
agentctl run --ssh

# Existing container without the relay: install the client now, then recreate
# while preserving state and enabling the relay.
agentctl feature install ssh --name NAME
agentctl upgrade --name NAME --ssh
```

For the best normal experience, `agentctl run --ssh` should treat the feature as
a declared dependency and install it automatically when missing. The explicit
`feature install ssh` command remains useful for preparing an existing
container, offline image customization, and inspection through the standard
feature interface.

The feature implementation should support Alpine and Debian/Ubuntu bootstrap
targets using their native OpenSSH client packages. Its information output
should distinguish three states:

- SSH client installed, relay enabled
- SSH client installed, relay not enabled; recreation required
- relay enabled, SSH client missing; feature installation required

Earlier policy alternatives considered were:

1. add `openssh-client` to the base image
2. add a small installable SSH feature and require it with `--ssh` — selected
3. detect a missing client and offer only a targeted installation instruction

The feature should install client tools only. It should not install or start an
SSH server, expose TCP port 22, copy private keys into the container, or modify
the host SSH agent.

## Proposed agentctl interface

Use names that state direction and match Apple where possible:

```text
--ssh
--mount-socket HOST_PATH:CONTAINER_PATH
--publish-socket HOST_PATH:CONTAINER_PATH
```

`--mount-socket` and `--publish-socket` should be repeatable. Avoid a generic
`--socket` flag because users cannot infer which endpoint must already be
listening.

### Creation behavior

For a new container:

- `--ssh` passes Apple's `--ssh` after validating the host socket.
- `--mount-socket` passes a socket bind mount after validating both paths.
- `--publish-socket` passes Apple's flag after validating and reserving the host
  destination.
- `agentctl` records enough intent to explain the configuration later, while
  Apple container remains the runtime source of truth.

### Existing containers

Socket configuration is part of container creation and cannot be added to an
existing container. When a requested setting differs, `agentctl run` should
fail with a direct recreation instruction instead of silently ignoring it:

```text
Container NAME was created without SSH forwarding.
Recreate it with: agentctl upgrade --name NAME --ssh
```

When an existing container already has `ssh: true`, normal start and exec flows
should retain it without requiring the user to repeat `--ssh` every time.

### Upgrade behavior

Upgrade should preserve existing settings by default:

- stored `ssh`
- generic socket mounts
- published socket mappings

Explicit flags should add or replace requested mappings. A future `--no-ssh`
can deliberately remove SSH forwarding during recreation.

Literal generic socket paths and published host paths need validation at
upgrade time. A preserved mapping may refer to a service that no longer exists
or a host path now occupied by another process. Dry-run output should show every
preserved mapping.

### Start behavior

When starting an SSH-enabled container:

- if the host `SSH_AUTH_SOCK` exists and is a socket, start normally
- if it is missing, warn clearly that SSH forwarding will be unavailable
- if the user explicitly requested SSH for the current operation, fail before
  creation or recreation rather than create a misleading configuration

The container remains useful without its SSH socket, so an ordinary later start
does not necessarily need to be fatal.

## Path validation and lifecycle safety

### Absolute paths

Container socket paths should always be absolute. Host paths should either be
required to be absolute or resolved once before container creation and stored
as absolute paths. Relative paths are risky when the same container is started
from a different working directory.

### Host destination collisions

Apple's `--publish-socket` parser behaves differently by existing path type:

- existing socket: reject because it may be in use
- existing non-socket: attempt to remove it

`agentctl` must preflight the destination and reject any existing filesystem
entry. It should never pass a user path to behavior that might delete a regular
file or symlink.

### Private socket directory

For generated or managed host sockets, use a short user-private directory such
as:

```text
/tmp/agentctl-<uid>/
```

Create it with mode `0700` and verify its owner before use. Generated socket
names should be short hashes rather than full project/container names.

### Unix path length

macOS `sockaddr_un.sun_path` is approximately 104 bytes. Long repository paths,
Xcode CodingAssistant paths, and verbose container names can exceed it. Validate
the encoded byte length before creation and keep managed relay paths under
`/tmp`.

### Cleanup

Apple removes a published host socket on normal container stop. `agentctl`
should still handle:

- stale sockets left after a crash
- a path reused by another service
- container deletion while already stopped
- managed empty-directory cleanup

Never remove a stale-looking path unless `agentctl` can prove ownership and the
path is inside its private managed directory.

## Security model

### SSH agent authority

Forwarding an SSH agent normally does not reveal private-key bytes, but code in
the container can ask the agent to sign or authenticate while the socket is
available. A malicious process can use every identity offered by that agent,
subject to any confirmation or destination constraints configured on the host.

`--ssh` must be opt-in and documented as granting authentication authority to
the container. It should not be enabled automatically for every project.

Recommended host practices include:

- load only required keys
- use agent confirmation where supported
- use destination-constrained keys where supported
- avoid forwarding into untrusted images or recovery containers
- stop the container when access is no longer needed

### Arbitrary incoming host sockets

A forwarded daemon socket can grant much more authority than its pathname
suggests. Examples include container engines, credential agents, databases, IDE
bridges, and automation services. `agentctl` should not maintain an allowlist,
but documentation and dry-run output must make the trust boundary visible.

### Published container sockets

A published socket exposes a container service to local host processes that can
reach the socket path. Use a `0700` parent directory, avoid secrets in path
names, and require the service protocol to authenticate if crossing local user
boundaries matters.

## MCP integration analysis

### Current Xcode bridge

Apple's `xcrun mcpbridge` is a stdio MCP process on macOS. The existing Xcode
ACP shim starts it on the host, wraps its stdio protocol in an HTTP MCP relay,
listens on a host TCP address, and tells the container agent to connect through
`host.container.internal`.

This works but requires a host-network listener. It is the opposite direction
from `--publish-socket`: the MCP server is on macOS and the MCP client is in the
container.

### What socket forwarding can improve

A host-to-container socket mount can remove the externally reachable TCP relay:

```text
xcrun mcpbridge stdio
        |
host relay using HTTP over Unix socket
        |
Apple host-to-container socket relay
        |
guest MCP adapter
        |
container ACP agent
```

However, ACP/Codex MCP configuration currently describes stdio or HTTP servers,
not an HTTP URL over a Unix socket. One additional guest-side adapter is still
needed. Viable designs include:

1. run the existing HTTP relay on a host Unix socket and run a small guest
   loopback HTTP proxy whose upstream is that mounted socket
2. pass a guest stdio MCP command that translates JSON-RPC requests to HTTP over
   the mounted Unix socket
3. define a simple framed Unix-socket protocol between matching host and guest
   stdio adapters

The first option reuses the current HTTP MCP session logic and changes only the
transport boundary. The container agent still sees a normal loopback HTTP URL.
The second may integrate more naturally with ACP stdio server definitions but
requires careful request, notification, cancellation, and session handling.

### Where publish-socket helps MCP

`--publish-socket` is useful when an MCP server runs inside the container and a
host client needs it. Most host MCP clients accept stdio or HTTP URLs rather
than Unix-socket URLs, so a small host adapter may still be required. This is a
separate use case from exposing Xcode's MCP tools to a container agent.

### MCP recommendation

Do not make MCP bridging part of the first SSH implementation. First expose
safe generic socket primitives and verify them independently. Then prototype
the Xcode bridge with HTTP-over-Unix-socket while keeping the current TCP relay
as a fallback.

Success criteria for the socket-based Xcode bridge:

- no TCP listener on `0.0.0.0` or the host gateway
- Xcode tools list and execute through a container ACP agent
- initialize, notifications, sessions, cancellation, and shutdown still work
- host and guest adapters terminate when the ACP shim exits
- socket paths live in a private short directory
- logs redact MCP environment secrets

## Implementation status and remaining phases

### Completed foundation: SSH forwarding

- add `--ssh` to `run`, `bootstrap`, and `upgrade`
- inspect and preserve `configuration.ssh`
- validate host `SSH_AUTH_SOCK`
- define existing-container mismatch behavior
- add the installable `ssh` feature for client tooling
- make `run --ssh` ensure the feature is installed
- diagnose client-installed and relay-enabled state independently
- document authority and host-key verification
- add unit fixtures for 0.12.3 and 1.1 inspect shapes
- add a host integration test as non-root `coder`

This slice is implemented and host-verified.

### Completed Phase 1: generic host socket mounts

- add repeatable `--mount-socket`
- require an existing host socket
- validate absolute paths and guest destination collisions
- preserve mappings during upgrade
- document stable-path requirements
- test non-root access and restart lifecycle behavior

This slice is implemented and host-verified. It also includes targeted removal,
destination-based replacement, copy-mode preservation, conservative refusal of
unknown extra mounts, doctor diagnostics, and fail-safe missing-source checks.

### Completed Phase 2: published sockets

- add repeatable `--publish-socket`
- add targeted `--unpublish-socket` during upgrade
- reject all pre-existing host destinations
- require explicit paths in existing user-owned private directories
- validate path byte lengths
- preserve mappings and show them in dry-run
- diagnose listener state without deleting stale or user-owned entries
- test stop, start, restart, upgrade, copy, removal, data exchange, and collisions

This slice is implemented and host-verified. Phase 3 now uses generated managed
paths with verified ownership and cleanup for its private MCP relay.

### Completed Phase 3: managed MCP transport

- the host relay listens only on a generated private Unix socket
- Apple container mounts that socket at the reserved managed guest path
- a non-root guest adapter presents Streamable HTTP MCP on loopback
- Codex endpoint registration is automatic; other runtimes remain manual
- safe definitions persist on the host and literal environment values do not
- stdio children start lazily; the Xcode preset shares one child across sessions
- lifecycle, stopped upgrade, copy, disable, collision, and doctor behavior are
  covered without retaining a TCP fallback

## Test status

### Completed repo-local unit coverage

- argument parsing and repeatable mappings
- host and container path validation
- existing-container configuration comparisons
- 0.12.3 and 1.1 inspect parsing
- upgrade preservation, override, and dry-run output
- command construction with exact Apple flags
- rejection of missing sources, files, symlinks, invalid characters, reserved
  destinations, and overlong paths
- stdin-dependent commands retain `container exec -i`
- published-socket parsing, inspect shapes, exact matching, merge and removal
- private-parent ownership and mode checks, listener collisions, path limits,
  lifecycle safety, copy behavior, dry-run behavior, and doctor diagnostics

Run shell checks under current Bash and macOS-compatible Bash 3.2 when
implementation changes begin.

### Completed macOS integration coverage

- `coder` connects to the forwarded SSH agent
- an actual `ssh-add -L` or `ssh-add -l` request completes
- restart uses the current host SSH socket
- generic incoming sockets carry data as non-root `coder`
- restart and upgrade preserve generic mappings
- replacement, copy mode, and targeted removal behave as configured
- published sockets carry data as non-root `coder`
- stop removes listeners and start and restart recreate them
- upgrade preserves, adds, replaces, and removes selected mappings
- stopped-source copy preserves mappings
- file, directory, symlink, socket, and unsafe-parent collisions are rejected
- collision diagnostics do not delete host entries

### Additional optional MCP coverage

- Git SSH authentication reaches a disposable test remote or fails only at the
  expected authorization boundary
- explicitly compare generic guest socket permissions with the host socket

## Current decision

The structured MCP/Xcode adapter is complete as a separate Phase 3 integration.
Published sockets continue to serve host clients consuming container services;
managed MCP uses the host-to-container mount primitive plus a guest loopback
HTTP adapter. The production bridge is Unix-socket-only and has no TCP fallback.
