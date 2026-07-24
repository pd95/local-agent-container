# Phase 4: Managed HTTP MCP upstreams

## Status

Accepted for implementation. Phase 3 implements host stdio MCP servers over
the private managed Unix-socket bridge. Phase 4 adds fixed HTTP upstreams and
reuses agentctl's existing macOS Keychain adapter for host-managed credentials.

## Goal

Allow an MCP-enabled container to use an HTTP or HTTPS MCP server reachable
from macOS, including a service bound only to host `127.0.0.1`, without:

- exposing the host service on a VM-facing TCP interface
- creating Apple localhost DNS or packet-filter rules
- opening a host TCP listener in `agentctl`
- persisting bearer tokens or literal header values in agentctl registries,
  configuration, diagnostics, or logs (user-authorized macOS Keychain storage
  is supported)
- allowing a container request to select a different upstream

The existing guest endpoint remains stable:

```text
http://127.0.0.1:47123/mcp/<name>
```

The host relay chooses either a supervised stdio child or a fixed HTTP upstream
from the authorized host-side definition.

## Proposed interface

Keep existing definitions backward compatible. A missing `type` continues to
mean `stdio`; `type: "stdio"` may also be accepted explicitly.

```json
{
  "name": "xcode",
  "type": "stdio",
  "command": "/usr/bin/xcrun",
  "args": ["mcpbridge"],
  "shared": true
}
```

Add a discriminated HTTP definition:

```json
{
  "name": "macos-ui-helper",
  "type": "http",
  "url": "http://127.0.0.1:9876/mcp",
  "bearer_token_env_var": "MACOS_UI_HELPER_TOKEN"
}
```

For normal interactive macOS use, prefer a named Keychain credential:

```json
{
  "name": "macos-ui-helper",
  "type": "http",
  "url": "http://127.0.0.1:9876/mcp",
  "bearer_token_keychain": "macos-ui-helper-token"
}
```

For non-bearer authentication or additional headers:

```json
{
  "name": "example",
  "type": "http",
  "url": "https://mcp.example.test/mcp",
  "headers": {
    "X-Static-Session": "literal-session-only-value"
  },
  "header_env_vars": {
    "Authorization": "EXAMPLE_AUTHORIZATION",
    "X-Tenant": "EXAMPLE_TENANT"
  }
}
```

Arbitrary header values may also reference separate named Keychain items:

```json
{
  "name": "example",
  "type": "http",
  "url": "https://mcp.example.test/mcp",
  "header_keychain_credentials": {
    "Authorization": "example-authorization",
    "X-Tenant": "example-tenant"
  }
}
```

Rules:

- `url` is required for HTTP definitions.
- `command`, `args`, `cwd`, `env`, `env_vars`, and `shared` are stdio-only.
- `headers` contains literal invocation-scoped values and is never persisted.
- `bearer_token_env_var` and `header_env_vars` persist only host environment
  variable names. Their current values are resolved on the host when a relay
  lease is created or a persisted container is started.
- `bearer_token_keychain` and `header_keychain_credentials` persist only safe,
  explicit credential identifiers. Values live in separate macOS Keychain
  generic-password items managed through the existing agentctl Keychain
  adapter. A bearer item stores the raw token; the relay adds `Bearer `.
- A header may have only one literal, environment, Keychain, or bearer source,
  compared case-insensitively.
- Configured authentication headers override same-named request headers from
  the container.
- Unknown and mixed-transport fields are rejected.
- Duplicate names remain forbidden across both transport types.

The original shape supplied during manual testing remains valid for one active
invocation, with its literal authorization value treated as a transient secret:

```json
{
  "name": "macos-ui-helper",
  "type": "http",
  "url": "http://127.0.0.1:9876/mcp",
  "headers": {
    "Authorization": "Bearer <token>"
  }
}
```

The Keychain-backed form is the documented default for interactive macOS use.
Environment-backed values remain supported for automation and external secret
managers. Both forms can be reconstructed after `start` or `restart` without
placing values in a registry or shell startup file.

## Keychain credential lifecycle

MCP credentials reuse `agentctl-keychain.sh` and its existing service/account
override mechanism. Runtime authentication items for Codex and Claude remain
unchanged. Each explicit MCP credential identifier uses its own slot:

```text
service: agentctl-mcp-credential-<id>
account: mcp-credential-<id>
```

The management interface is:

```text
agentctl mcp credential set ID
agentctl mcp credential set ID --stdin
agentctl mcp credential status ID
agentctl mcp credential delete ID
agentctl mcp credential list
```

`set` prompts without echo when attached to a terminal; `--stdin` supports
password-manager pipelines without placing values in shell history. Status,
list, doctor, and dry-run never print or read values. Set/delete report affected
running containers and exact restart commands but do not restart them.

When relay startup encounters a missing referenced item and a terminal is
available, agentctl offers to capture and store it. Empty or declined input, or
a noninteractive invocation, leaves that route present but unavailable with a
redacted `503`. Doctor reports the missing credential identifier. An existing
relay retains its resolved value until restarted, so rotation takes effect on
the next agentctl-managed restart.

## Transport behavior

The existing guest proxy continues forwarding raw HTTP over the mounted Unix
socket. In the host relay, each route has a fixed transport selected from the
private definition registry:

```text
Codex in container
  -> 127.0.0.1:47123/mcp/macos-ui-helper
  -> guest proxy
  -> private mounted Unix socket
  -> agentctl host relay
  -> 127.0.0.1:9876/mcp on macOS
```

For HTTP routes, the relay must:

- preserve method, body, response status, supported headers, streaming, SSE,
  cancellation, and `Mcp-Session-Id`/`Last-Event-ID` semantics
- reuse normal HTTP keep-alive connections where safe while leaving MCP session
  ownership to the upstream server
- close the upstream request promptly when the container client disconnects
- strip hop-by-hop headers and set the upstream `Host` header itself
- add only configured literal, environment-derived, or Keychain-derived headers
- reject redirects by default so credentials cannot leak to another origin
- use normal TLS certificate and hostname verification for HTTPS
- impose connect, header, idle-stream, and total request limits separately
- return a redacted `502`/`504` response for connection and timeout failures
- never log request bodies, response bodies, header values, or URL credentials

No host TCP listener is added. Loopback upstreams work because the outbound HTTP
connection originates in the macOS relay process.

## Validation and security

HTTP definitions are host execution authority and receive the same strict input
handling as stdio definitions:

- accept only absolute `http:` or `https:` URLs
- reject fragments, embedded usernames/passwords, control characters, and
  unsupported schemes
- require a non-empty hostname and valid port
- preserve the configured path and query exactly; container requests cannot
  replace the upstream origin or base path
- validate header names as HTTP tokens and reject CR/LF in literal values
- reject managed health paths and route-name collisions
- reserve proxy-controlled and hop-by-hop headers from user configuration
- redact all literal headers, inherited values, and URL query data in errors,
  dry-run output, doctor output, and logs
- allow plaintext HTTP only for exact host-loopback targets (`localhost`,
  `localhost.`, `127.0.0.0/8`, or `::1`); normally verified HTTPS may target a
  local or remote host

Explicit host configuration authorizes the destination, including localhost or
private-network targets. A container request cannot add definitions, change a
URL, choose arbitrary headers, or turn the relay into a general HTTP proxy.

## Persistence and leases

Increment the private registry schema while continuing to read Phase 3 schema
version 1. Persist only:

- transport type
- normalized URL without user information
- header names associated with host environment-variable names
- bearer-token environment-variable name
- named Keychain credential identifiers associated with bearer or arbitrary
  headers
- existing safe stdio fields

Never persist literal `headers` values. Include normalized HTTP definitions in
the existing definition fingerprint so concurrent identical leases can share a
relay and conflicting definitions for the same container are rejected.

When the final transient lease exits, discard literal headers. A persisted HTTP
route with a missing required host variable or Keychain item remains present but
returns a clear, redacted `503`. `doctor --host` reports the missing variable
name or credential identifier, not its value.

## Runtime integration

Codex automatic registration remains unchanged: every route is registered as
the local guest URL, not as the real upstream URL. This keeps credentials and
host topology outside the container's runtime configuration and allows temporary
containers to use authenticated host HTTP MCP immediately.

Other runtimes continue using the same manual local URL until they gain runtime
adapters. No runtime receives the upstream URL or authorization headers.

## Lifecycle and diagnostics

HTTP-only definitions do not spawn an MCP child. They still require the
container-scoped relay and follow the existing start, restart, stop, removal,
upgrade, copy, rename, disable, lease, and verified cleanup behavior.

`doctor --host` should report, without sending MCP protocol requests:

- route name and transport (`stdio` or `http`)
- redacted upstream origin, with path/query omitted or redacted
- whether required host environment variables and Keychain items are present
- host relay identity and ownership
- guest proxy and guest-to-host route health
- optional TCP/TLS reachability only if implemented without HTTP requests;
  otherwise report `upstream not probed`

Doctor must not initialize the MCP server, send an HTTP request to its route, or
print configured headers. Direct `container stop` detection and suggested safe
cleanup remain unchanged.

## Upgrade and compatibility

- Existing stdio registry files and definitions continue working unchanged.
- Upgrade/copy/rename preserve safe HTTP definitions, environment-variable
  names, and Keychain credential identifiers, never transient header values.
- `--disable-mcp` removes both stdio and HTTP definitions after successful
  recreation.
- Dry-run reports route names, transport types, target MCP state, and redacted
  origins without resolving DNS, connecting, or reading secret values.
- Existing containers without MCP socket wiring still require
  `upgrade --enable-mcp`.

## Implementation slices

### Phase 4A: schema and relay

- add discriminated stdio/HTTP parsing and validation
- add safe persistence and fingerprint normalization
- implement raw streaming HTTP upstream proxying
- add redaction and redirect/header controls
- retain compatibility with registry schema version 1

### Phase 4B: lifecycle and diagnostics

- integrate host environment resolution with leases and persisted starts
- cover start/restart/stop, upgrade/copy/rename/disable, and crash recovery
- extend host and container doctor output with transport-aware diagnostics
- keep Codex automatic registration pointed at the local route

### Phase 4C: verification and documentation

- add Node protocol/proxy tests
- add focused macOS host integration with a loopback-only fake HTTP MCP server
- add opt-in testing against a real authenticated macOS MCP server
- document secure token rotation and environment-backed configuration

## Test plan

Unit tests:

- backward-compatible stdio parsing and explicit `type: "stdio"`
- HTTP/HTTPS URL validation, mixed-field rejection, duplicates, and unknown keys
- header-name/value validation and reserved-header rejection
- literal-header redaction and persistence filtering
- environment-name validation, missing values, fingerprints, and lease conflicts
- registry migration, copy/rename, dry-run, and exact Codex registration URLs

Node tests with a fake loopback HTTP MCP server:

- initialize, notifications, tools/list, tool calls, SSE, cancellation, session
  deletion, reconnect, multiple sessions, timeout, and upstream failure
- raw status and supported headers survive both Unix proxy layers
- authentication headers are injected but never logged or returned
- client-supplied authentication cannot override configured authentication
- redirects do not receive credentials
- disconnects abort upstream work
- no host TCP listener is created by agentctl

Focused macOS integration:

- bind the fake upstream only to host `127.0.0.1`
- prove it is unreachable through `host.container.internal`
- connect successfully through the managed MCP route without DNS/PF changes
- verify automatic Codex registration in a temporary and persisted container
- verify literal tokens disappear after the final lease
- verify environment-backed tokens survive start/restart when present
- verify concurrent sessions, stopped upgrade, copy isolation, disable, external
  stop diagnostics, crash recovery, and complete cleanup

## Non-goals

- acting as a general-purpose HTTP forward proxy
- automatically importing arbitrary MCP entries from Codex or other runtimes
- OAuth browser flows or refresh-token storage in the first slice
- disabling TLS verification
- rewriting upstream MCP payloads
- exposing the upstream directly to the container network
- changing the experimental Xcode ACP shim

## Fresh-agent implementation handoff

This section is intentionally operational. A new agent session should be able
to continue without access to the conversation that produced this proposal.

### Repository state to establish first

1. Read the workspace `AGENTS.md` and follow its Bash 3.2, testing, commit, and
   macOS-host delegation rules. Do not add that workspace-only file to Git.
2. Run `git status --short --branch`. Preserve unrelated user work, especially
   untracked research documents, and stage only files belonging to Phase 4.
3. Confirm Phase 3 is present. The relevant implementation commits at the time
   this proposal was written are:
   - `e1989cd Add managed MCP bridge`
   - `cf03cf8 Keep shared MCP relay alive across sessions`
   - `671d30f Diagnose managed MCP relay health`
   - `1a303e9 Make stopped MCP upgrades relay-aware`
   - `fb5db98 Document managed MCP lifecycle`
4. Create a dedicated Phase 4 feature branch if the current branch is shared or
   already represents completed Phase 3 work. Do not implement directly on
   `main`.
5. Re-read this entire document, then inspect the current code rather than
   assuming the line numbers below remain exact.

### Current implementation map

- `agentctl`
  - `mcp_definition_json` and `mcp_add_definition` parse and normalize the
    current stdio-only public schema.
  - `mcp_persist_registry`, `mcp_config_fingerprint`, and
    `mcp_start_from_registry` enforce persistence and lease boundaries.
  - `mcp_start_relay`, `mcp_acquire_relay`, `mcp_stop_managed`, and the lifecycle
    commands own host relay processes and private sockets.
  - `doctor_mcp_status` and `host_doctor_mcp_status` render container and host
    diagnostics.
  - `run_mode` registers local route URLs through the selected runtime adapter.
- `mcp/host-relay.mjs` owns route dispatch, stdio children, MCP sessions, SSE,
  cancellation, health identity, lease shutdown, and signal handling. Add HTTP
  upstream dispatch here; do not create a second host daemon.
- `mcp/guest-proxy.mjs` is a raw HTTP-over-Unix-socket proxy. It should require
  little or no transport-specific change; extend its tests if new header or
  streaming behavior exposes a generic proxy defect.
- `runtimes/codex.sh` implements `agent_runtime_mcp_add`. It should continue
  receiving only `http://127.0.0.1:<port>/mcp/<name>` and must not learn upstream
  URLs or secrets.
- `features.d/mcp-bridge.json` declares the installed container feature.
- `tests/run-mcp-node-tests.mjs` is the Linux-compatible protocol test harness.
- `tests/fixtures/fake-mcp-server.mjs` is the current fake stdio server. Add a
  separate fake HTTP upstream fixture rather than overloading stdio behavior.
- `tests/run-unit-tests.sh` covers Bash parsing, persistence, permissions,
  lifecycle construction, dry-run, and doctor output.
- `tests/run-tests.sh`, filter `managed-mcp`, is the focused macOS lifecycle
  integration and already stores redacted diagnostics under `./tmp/mcp/`.
- `README.md`, `TESTING.md`, and this document own user and verification
  guidance. Keep `docs/ssh-socket-forwarding-research.md` as historical status,
  not the primary Phase 4 specification.

### Required planning pass before editing code

Before implementation, compare this proposal with the current source and write
a short execution plan covering:

1. normalized in-memory schema and registry schema migration
2. secret lifetime and fingerprint representation
3. HTTP request/response header policy
4. redirect, timeout, abort, keep-alive, SSE, and session behavior
5. lifecycle and doctor behavior for missing credentials or unreachable hosts
6. unit, Node, and macOS integration coverage

Resolve any divergence in favor of the security invariants in this document and
the current Phase 3 ownership checks. Update this document when implementation
requires a material design change; do not silently let code and plan diverge.

Resolved defaults for implementation are:

- accept literal `headers` with the same transient-secret semantics as stdio
  literal `env`, without another acknowledgement flag
- keep container start successful when a required host variable is missing;
  return a redacted route-level `503` and report the variable name in doctor
- never persist any literal header value, even if a caller considers it safe
- support host loopback HTTP and normally verified HTTPS in the first release;
  do not support plaintext non-loopback HTTP until separately justified
- prefer named macOS Keychain credentials for interactive use while retaining
  environment-backed sources for automation

These decisions are not permission to weaken validation or secret handling.

### Suggested implementation order

1. Add failing Bash unit tests for schema discrimination, compatibility,
   persistence filtering, fingerprints, environment resolution, dry-run, and
   doctor redaction.
2. Implement Bash schema version 2 while preserving version 1 reads. Keep the
   normalized definition shape explicit: every entry should contain
   `transport: "stdio"` or `transport: "http"` internally.
3. Add a fake loopback HTTP MCP server and failing Node tests for transparent
   streaming, session headers, configured authentication, aborts, redirects,
   timeout, failure, and log redaction.
4. Refactor `mcp/host-relay.mjs` route handling only enough to dispatch to a
   stdio handler or HTTP handler. Preserve all passing stdio behavior before
   adding HTTP success cases.
5. Integrate leases, persisted starts, lifecycle cleanup, upgrade/copy/rename,
   and doctor output. Do not duplicate relay ownership logic.
6. Extend automatic Codex registration tests. The expected registered URL is
   always the local guest route.
7. Extend the focused macOS integration with a host loopback-only fake HTTP MCP
   server. The test must first prove direct gateway access fails, then prove the
   managed route succeeds.
8. Update README and TESTING only after behavior and exact commands are stable.
9. Request senior review focused on SSRF/proxy boundaries, credential lifetime,
   header forwarding, redirects, process ownership, and backward compatibility.
10. Fix findings, rerun verification, and return the focused macOS command to
    the user before asking for the full host suite.

### Mandatory invariants during implementation

- Never introduce a host TCP listener.
- Never forward an arbitrary destination selected by a container request.
- Never log or persist literal header values, resolved environment values,
  request bodies, or response bodies.
- Never send configured credentials across a redirect.
- Never disable HTTPS certificate verification.
- Never let HTTP changes regress existing stdio/Xcode sharing semantics.
- Never signal or unlink a relay without the existing nonce/identity proof.
- Never auto-upgrade an existing container that lacks MCP wiring.
- Keep dry-run free of filesystem, process, container, DNS, and network changes.
- Keep `agentctl` compatible with macOS Bash 3.2.

### Verification gates

The implementation is not complete until all applicable checks pass:

```bash
bash tests/run-unit-tests.sh
/workdir/.bin/bash3 -n agentctl
/workdir/.bin/bash3 tests/run-unit-tests.sh
bash -n agentctl
zsh -n agentctl
node tests/run-mcp-node-tests.mjs
git diff --check
```

The containerized agent cannot execute Apple container lifecycle tests. It must
ask the user to run the focused macOS test and share failures, beginning with:

```bash
bash tests/run-tests.sh --tier full --filter managed-mcp
```

The focused test should be extended so its HTTP portion does not require the
user's real token or real MCP service. Keep a separate opt-in smoke for the real
authenticated macOS server. Do not place tokens in shell history, test output,
fixtures, committed JSON, Codex configuration, or `./tmp/mcp/` logs.

### Definition of done

- Both old stdio definitions and new HTTP definitions work through the same
  guest URL namespace.
- A fake MCP server bound only to macOS `127.0.0.1` is usable from a container
  without Apple DNS/PF forwarding or a VM-facing bind.
- Temporary Codex containers work from one `run --mcp` invocation.
- Persisted definitions work after start/restart when referenced host variables
  are present, and fail safely and clearly when they are absent.
- Literal headers disappear after the final lease and never enter the registry.
- Streaming, SSE, MCP sessions, cancellation, deletion, and status/headers are
  preserved end to end.
- Upgrade, copy, rename, disable, external stop diagnostics, crash recovery, and
  cleanup remain ownership-safe.
- Doctor and dry-run are useful without contacting MCP endpoints or revealing
  secrets.
- `lsof` confirms agentctl creates no host TCP listener.
- Existing Xcode and generic stdio tests remain green.
- Documentation states exactly which transports, credential sources, and
  persistence guarantees are supported.

## Resolved implementation decisions

1. Literal `headers` are accepted for one invocation without another flag and
   are never persisted. Named Keychain credentials are the documented default.
2. Missing environment or Keychain credentials leave the route present with a
   redacted `503`; interactive lifecycle commands may securely capture a
   missing Keychain value.
3. No literal header value is persistable, regardless of whether a caller
   considers it secret.
4. Plaintext HTTP is restricted to exact loopback targets. Normally verified
   HTTPS supports local or remote hosts.
5. Credential rotation is explicit: credential commands update Keychain and
   report affected running containers, but do not restart them automatically.
