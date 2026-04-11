# Implementation Checklist

## Objective

Break the migration into concrete implementation work items that can be executed in sequence.

## Track A: Runtime Contract Foundation

### A1. Add Contract Files to the Codex Image

Files:

- `DockerFile`
- new runtime helper files copied into the image

Tasks:

- add `/usr/local/bin/agent.sh`
- add `/etc/agentctl/agent.env`
- add `/etc/agentctl/defaults/`
- keep current `config.toml`, `local_models.json`, and image description available

Done when:

- Codex image exposes `agent.sh` and `agent.env`
- Codex still behaves exactly as before

### A2. Add Contract Files to the Claude Image

Files:

- `DockerFile.claude`
- new Claude runtime helper files copied into the image

Tasks:

- add Claude `agent.sh`
- add Claude `agent.env`
- stop relying on the `codex` shim after host support lands

Done when:

- Claude runtime can be launched through the generic contract

## Track B: Host Controller Refactor

### B1. Add Metadata Discovery

File:

- `codexctl`

Tasks:

- detect whether the image or running container exposes `/etc/agentctl/agent.env`
- load metadata safely
- fall back to legacy Codex behavior if the contract is missing

Done when:

- the host controller can resolve runtime metadata for Codex

### B2. Replace Hardcoded Runtime Launch

File:

- `codexctl`

Tasks:

- replace hardcoded default command arrays with `agent.sh run`
- replace hardcoded login command with `agent.sh login`
- replace hardcoded update command with `agent.sh update`

Done when:

- Codex runs through `agent.sh`
- fallback path still exists if needed

### B3. Generalize Runtime State Handling

File:

- `codexctl`

Tasks:

- replace `.codex`-specific backup/restore logic with metadata-driven runtime home handling
- replace `.codex`-specific overwrite logic with defaults-directory logic
- preserve current upgrade behavior

Done when:

- backup, restore, reset, and upgrade use declared runtime paths

### B4. Generalize Capability Handling

File:

- `codexctl`

Tasks:

- gate local-model preflight on runtime capability
- gate OpenAI mode on runtime capability
- gate update and login features on runtime capability

Done when:

- unsupported runtime features fail early and clearly

## Track C: Auth and Keychain

### C1. Replace the Fixed Keychain Script

Files:

- `codex-auth-keychain.sh`
- possible rename to `agent-auth-keychain.sh`

Tasks:

- parameterize service name, account name, auth path, and container name
- keep read/store/load/verify operations
- preserve safe handling of binary or hex-returned data

Done when:

- the script can store and restore auth for more than one runtime

### C2. Add Auth Strategy Selection

File:

- `codexctl`

Tasks:

- implement strategy dispatch based on `AGENT_AUTH_FORMAT`
- support `json_refresh_token`
- support `opaque_blob`
- support `directory_tarball`

Done when:

- Codex uses semantic JSON sync
- Claude can use a conservative strategy if needed

## Track D: Rebrand and Compatibility

### D1. Introduce `agentctl`

Files:

- new `agentctl`
- compatibility wrapper `codexctl`

Tasks:

- expose the generic naming in the CLI
- keep `codexctl` forwarding to `agentctl`

Done when:

- the new controller name is usable without breaking old workflows

### D2. Rename Image Families

Files:

- Docker image definitions
- docs

Tasks:

- move from `codex*` naming to `agent-*`
- keep compatibility aliases if practical during migration

Done when:

- `agent-codex` and `agent-claude` are the preferred names

## Track E: Runtime-Toolchain Matrix Build Strategy

### E1. Add Runtime Metadata Overlays

Files:

- `agent-codex.env` and `agent-codex.sh` (or equivalent overlay files)
- `agent-claude.env` and `agent-claude.sh` (or equivalent overlay files)
- base image manifests and build docs

Tasks:

- define runtime-specific metadata/config bundles that apply on top of `agent-base`, `agent-python`, and `agent-swift`
- keep runtime naming explicit in resulting image tags (for example `agent-python-codex`, `agent-python-claude`)
- document default inference/alias behavior for runtime selection

Done when:

- runtime is no longer coupled to toolchain in image layout
- adding a new runtime does not require cloning every toolchain Dockerfile

### E2. Compose Toolchain Images from Base Layers

Files:

- existing toolchain Dockerfiles (`agent-python`, `agent-office`, `agent-swift`)
- build orchestration script or Makefile target (as source of truth)

Tasks:

- update toolchain definitions so they build from `agent-base` and apply runtime overlays
- add matrix build target (for example `agent-{toolchain}-{runtime}`) with deterministic tags and aliases
- preserve old single-runtime image names with compatibility tags where needed

Done when:

- matrix builds do not require N×M hand-authored Dockerfiles
- each matrix combination can be produced with composition inputs

### E3. Controller and User-Facing Selection

Files:

- `agentctl` / `codexctl`
- docs

Tasks:

- ensure the controller can launch and route by image tag and runtime metadata
- add documentation for selecting codex-vs-claude runtime stacks
- keep migration-safe aliases for previously known image names

Done when:

- users can switch runtime and toolchain independently with minimal rebuild steps

### E4. Close Matrix Gaps and Validate Rollout

Files:

- matrix playbook and issue log

Tasks:

- enumerate supported combinations (toolchain × runtime) and validate smoke behavior for each
- define rollback path when a runtime overlay breaks a specific toolchain

Done when:

- every supported matrix cell is documented and reproducibly buildable
- rollout has a clear fallback and deprecation plan

## Execution Sequence

Recommended sequence:

1. Track A1
2. Track B1
3. Track B2
4. Track C1
5. Track C2
6. Track B3
7. Track B4
8. Track A2
9. Claude auth verification and integration
10. Track E1
11. Track E2
12. Track E3
13. Track E4
14. Track D1
15. Track D2

## Acceptance Criteria

The migration is successful when all of the following are true:

- Codex works as before for build, run, auth, update, local mode, and upgrade
- Claude launches as a first-class runtime without the `codex` shim
- auth save and restore are metadata-driven rather than Codex-specific
- the controller can support future runtimes through `agent.sh` and `agent.env`
- runtime/toolchain combinations are composed via matrix naming (e.g. `agent-python-claude`) without Dockerfile duplication
