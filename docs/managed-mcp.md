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

## Remote Xcode MCP bridge over SSH

When Xcode is installed on a macOS VM rather than on the Mac that runs the
container, the host relay can run `ssh` as its authorized stdio command. This
keeps the SSH configuration and identities on the Mac while carrying the
remote `mcpbridge` standard input and output to the container.

First, configure a host alias (for example `macos-beta-vm`) in the Mac user's
`~/.ssh/config`, using a key that can authenticate without a prompt. If a
dedicated key is needed, create one on the Mac and add its public half to the
VM account's `~/.ssh/authorized_keys` using the VM's normal provisioning or
console-access procedure:

```bash
ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519_macos_beta_vm" \
  -C "macos-beta-vm MCP relay"
ssh-add --apple-use-keychain "$HOME/.ssh/id_ed25519_macos_beta_vm"
```

Do not copy the private key to the VM or to a container. Protect the VM's
`~/.ssh` directory and `authorized_keys` with owner-only permissions.

Add an alias to the Mac user's `~/.ssh/config`, replacing the placeholder host
and user values:

```sshconfig
Host macos-beta-vm
  HostName vm.example.internal
  User developer
  IdentityFile ~/.ssh/id_ed25519_macos_beta_vm
  IdentitiesOnly yes
  AddKeysToAgent yes
  UseKeychain yes
```

`UseKeychain` and `--apple-use-keychain` are macOS-specific conveniences; omit
them if the key is managed by another SSH agent. Verify the connection and the
Xcode bridge before configuring MCP:

```bash
ssh -T macos-beta-vm true
ssh -T macos-beta-vm \
  'env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer /usr/bin/xcrun --find mcpbridge'
```

Then start the container with a fixed SSH-based MCP definition:

```bash
agentctl run --name my-agent --mcp \
  '{"name":"xcode-vm","command":"/usr/bin/ssh","args":["-T","macos-beta-vm","env","DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer","/usr/bin/xcrun","mcpbridge"],"shared":true}'
```

`-T` prevents SSH from allocating a pseudo-terminal, which would corrupt the
stdio MCP protocol. `shared: true` allows reconnecting HTTP sessions to reuse
one remote `mcpbridge` process. Put `DEVELOPER_DIR` in the remote `env`
command arguments as shown: a definition's `env` field applies to the Mac
host process, not to the VM.

The relay starts `/usr/bin/ssh` on the Mac, so it uses the Mac's SSH alias,
known-hosts file, and SSH agent or Keychain-backed identities; no private key
is copied into the container. Password prompts and first-use host-key
confirmation cannot be answered by the background relay, so complete those
steps before starting the container.

## Definition fields

Stdio definitions accept:

- `name`
- `command`
- `args`
- `cwd`
- `env`
- `env_vars`
- `shared`
- `timeout_ms` (optional integer from 1,000 to 3,600,000)

The Xcode preset enables `shared`, allowing reconnecting HTTP sessions to reuse
one `xcrun mcpbridge` process and sets a 10-minute response timeout. Generic
stdio definitions default to a 30-second response timeout and per-session
process isolation. Set `timeout_ms` when a known server has longer-running
operations, for example `{"name":"builder","command":"/path/to/server","timeout_ms":600000}`.
Literal `env` values live only for the active invocation.
`env_vars` persists only selected host environment-variable names and resolves
their current values whenever the host relay starts. Use it for host toolchain
selection, for example `DEVELOPER_DIR` when running Xcode beta.

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

Enabling MCP adds bridge wiring only; it does not configure an MCP server. A
running managed relay retains its current definitions and cannot be
reconfigured in place. To configure the first server after an upgrade, or to
replace existing definitions, stop the container and relay, then rerun the
desired `run --mcp` command:

```bash
agentctl stop --name agent-project
agentctl run --name agent-project --mcp xcode
```

For an Xcode beta definition, export `DEVELOPER_DIR` before the `run` command
and include it in the definition's `env_vars`. Export the variable again before
later `agentctl start` or `agentctl restart` commands so the host relay can
resolve it.

The MCP port can be changed during an upgrade, or MCP support can be removed:

```bash
agentctl upgrade --name agent-project --mcp-port 48123
agentctl upgrade --name agent-project --disable-mcp
```

## Lifecycle and diagnostics

Managed relays are container-scoped background services and normally appear
with parent PID 1 after `agentctl` exits. Their process label includes the
container name, for example `agentctl-mcp-relay:agent-project`.

Relay log lines begin with an ISO-8601 UTC timestamp. A stdio timeout log also
includes the configured deadline in milliseconds, making it possible to tell a
slow tool call from an immediate bridge failure.

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
