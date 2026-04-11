# Phased Rebuild Plan

## Objective

Introduce the abstraction in phases so the current Codex/OpenAI workflow stays operational throughout the migration.

## Phase 0: Preserve the Working Baseline

Goal:

- freeze the current working Codex behavior as the compatibility baseline

Actions:

- keep `codexctl` as the active entrypoint
- keep current `DockerFile` behavior intact
- keep the Claude proof of concept image buildable
- avoid broad renames until the generic runtime contract exists

Exit criteria:

- current Codex image still builds and runs
- current `codexctl run --openai` still works

## Phase 1: Add the Runtime Contract to Codex

Goal:

- make Codex the first image that implements the new contract

Actions:

- add `/usr/local/bin/agent.sh` to the Codex image
- add `/etc/agentctl/agent.env` to the Codex image
- move Codex image-owned defaults under `/etc/agentctl/defaults/`
- keep the existing Codex runtime behavior unchanged

Host changes:

- teach `codexctl` to detect `agent.env`
- teach `codexctl` to call `agent.sh run`, `login`, and `update`
- keep hardcoded Codex fallback behavior temporarily in case an image lacks the contract

Exit criteria:

- Codex launches through `agent.sh`
- OpenAI auth still works
- update flow still works
- existing users see no behavior change

## Phase 2: Generalize Host State and Auth Logic

Goal:

- remove Codex-specific assumptions from the host controller

Actions:

- replace fixed `.codex` backup and restore logic with metadata-driven runtime home handling
- replace the fixed Keychain script with a generic parameterized version
- introduce auth strategy selection by `AGENT_AUTH_FORMAT`
- make reset and overwrite logic use `/etc/agentctl/defaults/`

Exit criteria:

- no host-side auth path is hardcoded to `/home/coder/.codex/auth.json`
- backup and restore operate on the runtime-declared paths
- Codex still behaves the same

## Phase 3: Convert Claude from Shim to First-Class Runtime

Goal:

- make Claude work through the runtime contract rather than the `codex` shim

Actions:

- implement `agent.sh` and `agent.env` in the Claude image
- confirm the actual Claude login and auth storage layout
- wire Claude into the generic auth restore flow
- remove the `codex -> claude` symlink once no longer needed

Exit criteria:

- default run goes through `agent.sh run`
- `codexctl auth --image codex-claude` works through the generic auth flow
- persistent Claude containers retain usable auth state

## Phase 4: Introduce `agentctl`

Goal:

- expose the generic identity once the internals are already generic

Actions:

- add `agentctl` as the new main script
- keep `codexctl` as a thin compatibility wrapper
- update help text, docs, and image naming defaults

Exit criteria:

- new docs use `agentctl`
- legacy workflows still work via `codexctl`

## Phase 5: Rename Images and Expand Runtime Support

Goal:

- complete the rebrand and make additional agent integrations easy

Actions:

- rename stable image tags to `agent-*`
- keep temporary compatibility aliases if needed
- document the runtime integration contract for future agents

Exit criteria:

- `agent-codex` and `agent-claude` are the preferred image names
- adding a new runtime mostly involves implementing `agent.sh` and `agent.env`
