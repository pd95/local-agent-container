# Claude Runtime Integration Plan

## Objective

Make Claude Code a first-class runtime that uses the same generic controller as Codex without pretending to be Codex.

## Current State

Current proof of concept:

- the image builds
- the runtime launches
- a `codex -> claude` shim allows `codexctl` to start it
- the Claude login screen appears

Current limitation:

- the host controller still believes it is launching Codex
- auth persistence is not yet modeled

## Required Claude Runtime Work

### 1. Confirm Runtime Facts

These items must be verified before final integration:

- the correct login command
- the runtime home directory
- the auth storage path or directory
- the auth file format or bundle format
- whether token refresh mutates a single file or multiple files
- whether update should happen through npm or another mechanism

### 2. Implement Claude `agent.sh`

Claude `agent.sh` should support:

- `run`
- `login`
- `version`
- `home-dir`
- `config-dir`
- `auth-path`
- `update`

Likely values:

- runtime binary: `claude`
- home/config base: `/home/coder/.claude`
- update command: npm package update for `@anthropic-ai/claude-code`

### 3. Implement Claude `agent.env`

Claude metadata should describe actual Claude behavior, not mimic Codex values.

Expected shape:

```sh
AGENT_ID=claude
AGENT_DISPLAY_NAME="Claude Code"
AGENT_BIN=claude
AGENT_HOME_DIR=/home/coder/.claude
AGENT_CONFIG_DIR=/home/coder/.claude
AGENT_AUTH_PATH=<confirmed-value>
AGENT_AUTH_FORMAT=<confirmed-value>
AGENT_IMAGE_DEFAULTS_DIR=/etc/agentctl/defaults
AGENT_KEYCHAIN_SERVICE=agentctl-claude-auth
AGENT_KEYCHAIN_ACCOUNT=interactive-login
AGENT_SUPPORTS_INTERACTIVE_LOGIN=1
AGENT_SUPPORTS_KEYCHAIN_SYNC=1
AGENT_SUPPORTS_UPDATE=1
AGENT_SUPPORTS_LOCAL_MODEL_MODE=0
AGENT_SUPPORTS_OPENAI_MODE=0
```

## Claude Auth Strategy

The most important unresolved design point is Claude auth persistence.

Implementation options:

1. `json_refresh_token`
- use if Claude stores auth in a JSON file with semantically useful fields

2. `opaque_blob`
- use if Claude stores a single file in an undocumented format

3. `directory_tarball`
- use if Claude auth spans multiple files under `~/.claude`

Conservative default:

- prefer correctness over clever parsing
- if format is unclear, store and restore the runtime auth as an opaque file or tarball first
- semantic parsing can be added later if it proves stable

## Claude Validation Matrix

Minimum acceptance checks:

- image builds cleanly
- `agent.sh version` returns Claude version
- `agent.sh run` launches Claude
- `agent.sh login` reaches the expected login flow
- `codexctl run --image codex-claude` works through the generic runtime contract
- Keychain restore can populate auth into a fresh container
- a persistent container reuses auth across runs

## Claude-Specific Non-Goals for the First Pass

Do not require in phase 1 of Claude support:

- local model profiles
- Codex-style `--openai` mode
- feature parity with Codex-specific local model behavior

The first target is first-class launch, auth persistence, and stable container reuse.
