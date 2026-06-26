# Xcode ACP Agent

Experimental bridge for running an Agent Client Protocol (ACP) agent inside an
`agentctl` Linux container from Xcode 27.

This is a proof of concept. The Codex path has been exercised from Xcode. Claude
is wired through the same mechanism, but still requires valid Claude/Anthropic
auth or a compatible local runtime before it can complete a prompt.

## Architecture

Xcode launches `xcode-acp-agent` as an ACP stdio process on macOS. The launcher
starts `xcode-acp-shim.mjs`, which:

- reads Xcode ACP `initialize`, `session/new`, and `session/resume` messages
- derives the Xcode CodingAssistant directory from `PWD`
- starts or reuses an `agentctl` container for the Xcode project
- runs the selected ACP runtime in the container through `agentctl run --stdio`
- maps Xcode's project `cwd` to `/workdir` inside the container
- optionally rewrites Xcode stdio MCP servers to HTTP MCP through
  `mcp-stdio-http-relay.mjs`
- exports Xcode skills and host global skills into the mounted agent home

The default runtime is Codex:

```sh
cd /workdir
npx -y @agentclientprotocol/codex-acp
```

Claude can be selected with `AGENTCTL_XCODE_AGENT=claude` or by using
`xcode-claude-acp-agent`:

```sh
cd /workdir
npx -y @agentclientprotocol/claude-agent-acp
```

## Requirements

- macOS host with Xcode 27 beta
- Apple's `container` CLI installed and available to Xcode
- Node.js available on the host
- an `agentctl` image such as `agent-plain`, `agent-python`, or `agent-swift`
- Codex auth stored through `agentctl auth --runtime codex` for the Codex path
- for Xcode MCP bridging, the container must be able to reach the host at
  `192.168.64.1`

Claude additionally needs one of:

- `agentctl auth --runtime claude`
- an Anthropic API key passed as `ANTHROPIC_API_KEY`
- a future local Claude-compatible setup

## Xcode Setup

Configure a custom ACP agent in Xcode with this command:

```sh
<repo>/xcode-acp-agent/xcode-acp-agent
```

The default configuration uses `agent-plain` and bridges Xcode MCP tools. For
project-specific dependencies, set a different image:

```sh
AGENTCTL_XCODE_IMAGE=agent-python
```

Use the Claude convenience launcher for Claude experiments:

```sh
<repo>/xcode-acp-agent/xcode-claude-acp-agent
```

or set:

```sh
AGENTCTL_XCODE_AGENT=claude
```

## Configuration

Common environment variables:

- `AGENTCTL`: path to `agentctl`; defaults to the repository `agentctl`
- `CONTAINER_CMD`: path to Apple's `container` CLI
- `AGENTCTL_XCODE_AGENT`: `codex` or `claude`; defaults to `codex`
- `AGENTCTL_XCODE_IMAGE`: container image; defaults to `agent-plain`
- `AGENTCTL_XCODE_CONTAINER_PREFIX`: generated container name prefix
- `AGENTCTL_XCODE_CONTAINER_NAME`: fixed container name override
- `AGENTCTL_XCODE_CONTAINER_SALT`: salt for generated per-project names
- `AGENTCTL_XCODE_BRIDGE_MCP=0`: disable Xcode stdio MCP to HTTP MCP bridging
- `AGENTCTL_XCODE_STRIP_MCP=0`: keep stdio MCP servers without bridging
- `AGENTCTL_XCODE_EXPORT_SKILLS=0`: disable Xcode skills export
- `AGENTCTL_XCODE_EXPORT_SKILLS_REPLACE=1`: force re-export of Xcode skills
- `AGENTCTL_XCODE_INSTALL_RUNTIME=1`: install the selected runtime if missing
- `AGENTCTL_XCODE_ACP_PACKAGE`: override the npm ACP package
- `AGENTCTL_XCODE_ACP_COMMAND`: override the full in-container ACP command

Claude API-key fallback variables passed into the container ACP command:

- `ANTHROPIC_API_KEY`
- `ANTHROPIC_AUTH_TOKEN`
- `ANTHROPIC_BASE_URL`
- `ANTHROPIC_MODEL`
- `CLAUDE_CODE_OAUTH_TOKEN`

## Files Created By The Shim

When Xcode launches the agent from a CodingAssistant directory, the shim uses
that directory as the agent home root:

```text
~/Library/Developer/Xcode/CodingAssistant/<agent-id>/
  home/
    .codex/skills/    # Codex mode
    .claude/skills/   # Claude mode
    .agents/skills -> ../.codex/skills or ../.claude/skills
  logs/
    xcode-codex-acp-shim.log
    xcode-codex-acp-sessions.json
    xcode-claude-acp-shim.log
    xcode-claude-acp-sessions.json
  skills/
    global -> ~/.agents/skills
```

The shim exports Xcode skills with:

```sh
xcrun mcpbridge run-agent skills export --output-dir <skills-dir> --replace-existing
```

Host global skills from `~/.agents/skills` are copied into the mounted skills
directory because absolute host symlinks do not resolve inside the Linux
container.

## Logs

Primary logs live under:

```sh
~/Library/Developer/Xcode/CodingAssistant/<agent-id>/logs/
```

Useful commands:

```sh
tail -f ~/Library/Developer/Xcode/CodingAssistant/*/logs/xcode-codex-acp-shim.log
tail -f ~/Library/Developer/Xcode/CodingAssistant/*/logs/xcode-claude-acp-shim.log
grep -E 'shim-start|agent-stderr|agent-exit|mcp-relay|failed|error' \
  ~/Library/Developer/Xcode/CodingAssistant/*/logs/xcode-codex-acp-shim.log
```

## Manual Smokes

Basic Codex ACP initialize through a container:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"terminal":true,"fs":{"readTextFile":true,"writeTextFile":true}},"clientInfo":{"name":"manual","version":"0","title":"manual"}}}' | \
  DEFAULT_AUTH_REQUEST='{"methodId":"chat-gpt"}' NO_BROWSER=1 \
  ./agentctl run --stdio --name agent-run-acp-smoke --image agent-python \
  --workdir tmp --runtime codex --online --cmd \
  sh -lc 'cd /workdir && npx -y @agentclientprotocol/codex-acp'
```

Basic stdio smoke:

```sh
printf '{"jsonrpc":"2.0","id":1,"method":"ping"}\n' | \
  ./agentctl run --stdio --name agent-run-stdio-smoke --image agent-python \
  --workdir tmp --cmd node -e 'process.stdin.pipe(process.stdout)'
```

## Known Limitations

- This is experimental Xcode 27 beta integration.
- Codex works; Claude reaches auth but still needs valid Claude/Anthropic
  credentials or a local compatible runtime.
- Xcode control commands such as `/skill` are not supported through this ACP
  path. Skills can still be used by natural-language prompting.
- Xcode MCP tools are relayed as HTTP MCP, so Xcode may display tool calls
  differently than native macOS Codex.
- Xcode may ask the user to confirm access to the Xcode MCP tools for each new
  conversation. This appears to be Xcode's per-conversation MCP trust flow, not
  something the shim can bypass.
- `RunProject` may report a launch failure for short-lived command-line tools
  even when `GetConsoleOutput` shows the process ran and exited with code `0`.
- The MCP stdio-to-HTTP relay is a temporary bridge. A longer-term design may
  use a dedicated host process or socket-based relay.
- Old Xcode conversations created before session context persistence may need
  fallback to the last project context or a fresh conversation.

## Troubleshooting

If Xcode does not start the agent, confirm the launcher path and check:

```sh
find ~/Library/Developer/Xcode/CodingAssistant -name 'xcode-*-acp-shim.log' -print
```

If Codex reports missing auth:

```sh
./agentctl auth --runtime codex --image agent-python
```

If Claude reports `401 Invalid authentication credentials`, the bridge is
working but Claude auth is invalid or unavailable. Retry after:

```sh
./agentctl auth --runtime claude --image agent-python
```

or provide `ANTHROPIC_API_KEY`.

If a container was created with the wrong mounted home, use a new salt:

```sh
AGENTCTL_XCODE_CONTAINER_SALT=assistant-home-v3
```

If MCP startup fails with `127.0.0.1`, make sure the relay advertises a host
address reachable from the container. The default is `192.168.64.1`.
