# Managed host MCP bridge

Use `agentctl run --mcp` to expose an explicitly authorized host stdio MCP
server or fixed HTTP/HTTPS MCP upstream to a container. Agentctl uses a private
Unix socket and a guest proxy bound only to `127.0.0.1`; it does not open a host
TCP port. Container requests cannot alter the authorized host command or
upstream definition.

Codex endpoint registration is the only runtime configuration currently
managed automatically.

## Start with an MCP server

Definitions can use the built-in Xcode preset, inline JSON, or a private JSON
file containing one definition or an array:

```bash
# Built-in Xcode preset (host command: xcrun mcpbridge)
agentctl run --mcp xcode

# Generic inline definition
agentctl run --mcp '{"name":"example","command":"/absolute/path/to/server","args":[]}'

# Host-loopback HTTP upstream with a named macOS Keychain token
agentctl mcp credential set macos-ui-helper-token
agentctl run --mcp '{"name":"macos-ui-helper","type":"http","url":"http://127.0.0.1:9876/mcp","bearer_token_keychain":"macos-ui-helper-token"}'

# Private file containing one definition or an array
agentctl run --mcp @"$HOME/.config/agentctl/private-mcp.json"
```

For Codex, agentctl automatically registers every enabled server as a
Streamable HTTP endpoint before launching the runtime. This also works in
temporary containers. Persisted containers retain both the safe host
definitions and Codex endpoint registration, so later `run --online` sessions
do not need to repeat `--mcp`.

Other runtimes currently require manual configuration using URLs such as:

```text
http://127.0.0.1:47123/mcp/xcode
http://127.0.0.1:47123/mcp/example
```

## Definition fields

Stdio definitions accept:

- `name`
- `command`
- `args`
- `cwd`
- `env`
- `env_vars`
- `shared`

The Xcode preset enables `shared`, allowing reconnecting HTTP sessions to reuse
one `xcrun mcpbridge` process. Generic definitions default to per-session
process isolation. Literal `env` values live only for the active invocation.

HTTP definitions use `type: "http"`, a fixed `url`, and optional literal,
environment-backed, or Keychain-backed headers. Plaintext HTTP is limited to
host loopback. HTTPS uses normal certificate and hostname verification.

The private host registry persists safe definitions and credential references,
never literal values or resolved credentials. A container request cannot change
the authorized command, upstream URL, or configured authentication header.

For the complete HTTP schema and implementation security model, see
[Managed HTTP MCP upstreams](managed-mcp-http-upstreams.md).

## Credentials

Named MCP credentials use the macOS Keychain adapter, with slots separate from
Codex and Claude authentication:

```bash
agentctl mcp credential set macos-ui-helper-token
op read 'op://Engineering/MCP/token' | agentctl mcp credential set macos-ui-helper-token --stdin
agentctl mcp credential status macos-ui-helper-token
agentctl mcp credential list
agentctl mcp credential delete macos-ui-helper-token
```

An interactive start offers a hidden prompt for a missing credential. A
noninteractive start leaves that route available with a redacted `503`.
Restart running containers after credential rotation so their relay resolves
the new value.

## Existing containers

Containers created without MCP wiring need an explicit migration:

```bash
agentctl upgrade --name agent-project --enable-mcp
```

The MCP port can be changed during an upgrade, or MCP support can be removed:

```bash
agentctl upgrade --name agent-project --mcp-port 48123
agentctl upgrade --name agent-project --disable-mcp
```

## Lifecycle and diagnostics

Managed relays are container-scoped background services and normally appear
with parent PID 1 after `agentctl` exits. Their process label includes the
container name, for example `agentctl-mcp-relay:agent-project`.

Use `agentctl doctor --host` for the authoritative mapping of relay PIDs,
containers, definitions, leases, sockets, and host/guest route health. Health
checks do not initialize a server or invoke MCP tools. For a stopped MCP-enabled
container, `agentctl doctor --name agent-project` may temporarily start the
persisted relay, container, and guest proxy for its live checks, then restore
the stopped state.

Use `agentctl start`, `agentctl stop`, and `agentctl restart` for MCP-enabled
containers so host relay supervision follows the container lifecycle. If the
lower-level `container stop` command is used, `agentctl doctor --host`
highlights the relay left behind and suggests:

```bash
agentctl stop --name NAME
```

Upgrade can inspect and back up a stopped MCP-enabled container by temporarily
starting only its lazy host relay. It preserves the container's original
stopped state and does not initialize the configured MCP server.

## Related documentation

- [Unix-socket forwarding](unix-sockets.md)
- [Networking and Ollama connectivity](networking.md)
