# Multi-Agent Container Runtime Plan

## Objective

Turn the current Codex-focused container runner into a generic agent runtime system while preserving the existing Codex/OpenAI behavior.

The target state is:

- Codex still works as before
- new agent runtimes such as Claude Code can be added without shims
- container lifecycle remains simple
- auth storage and restore can be handled consistently on macOS through Keychain

## Naming Decisions

Target names:

- controller CLI: `agentctl`
- image family prefix: `agent-`
- default container prefix: `agent-`
- auth container prefix: `agent-auth-`

Target image examples:

- `agent-codex`
- `agent-claude`
- `agent-python`
- `agent-swift`
- `agent-office`

Migration policy:

- do not rename everything first
- first build the abstraction behind the existing `codexctl`
- then introduce `agentctl`
- keep `codexctl` as a compatibility wrapper during transition

## Current Problem

The current implementation works because the host-side logic assumes the selected runtime is always Codex. These assumptions are spread across:

- default command construction
- auth login command
- auth file path
- config and state path layout
- token parsing
- reset and upgrade behavior

This makes alternate agent CLIs possible only through compatibility tricks, such as the current `codex -> claude` shim in the Claude image.

## Design Direction

The project should be split into:

1. Generic container orchestration
2. Runtime-specific agent adapters

The generic layer handles:

- image discovery and build order
- create/start/stop/remove container lifecycle
- persistent vs temporary runs
- read-only vs writable mounts
- upgrade and backup
- generic state preservation

The runtime-specific layer handles:

- how to launch the agent
- how to log in
- where auth is stored
- how updates work
- what the runtime supports

## Core Rule

The host controller must stop speaking directly to `codex` or `claude`.

Instead it should speak to a runtime contract:

- metadata file: `/etc/agentctl/agent.env`
- runtime entrypoint: `/usr/local/bin/agent.sh`

That contract is the compatibility layer for all future agent integrations.
