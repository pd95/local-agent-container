# Runtime Composition Matrix Plan

## Goal

Make image selection composable so toolchain stacks and runtime adapters are orthogonal:

- toolchain dimension: `base`, `python`, `office`, `swift`
- runtime dimension: `codex`, `claude`

This allows users to pick the runtime per stack without introducing per-combination Dockerfiles.

## Current issue

Today each toolchain image is effectively hard-wired to a specific runtime, which creates hidden coupling:

- `agent-python` includes Codex runtime behavior
- `agent-office` includes Codex runtime behavior
- `agent-swift` includes Codex runtime behavior
- `agent-claude` is separate and not a generic overlay

## Desired naming model

- Core image families remain simple and few:
  - `agent-base` (shared Alpine base + Codex agent contract defaults)
  - `agent-python` / `agent-office` / `agent-swift` (toolchain-specific layers)
- Runtime variants are explicit suffixes:
  - `agent-<toolchain>-codex`
  - `agent-<toolchain>-claude`
- Preserve backward compatibility by mapping:
  - `agent-<toolchain>` -> `agent-<toolchain>-codex`

## Composition rule (high level)

1. Runtime adapter files describe only runtime behavior:
   - `agent-codex.sh`, `agent-codex.env`
   - `agent-claude.sh`, `agent-claude.env`
2. Toolchain Dockerfiles accept `AGENT_RUNTIME` build arg:
   - `FROM agent-codex` for legacy/compatibility
   - then copy runtime adapter files and install runtime package during build:
     - `agent-codex`: install `@openai/codex`, install `agent-codex.sh/env`
     - `agent-claude`: install `@anthropic-ai/claude-code`, install `agent-claude.sh/env`
3. Build logic resolves image families into toolchain/runtime components and passes
   `--build-arg AGENT_RUNTIME=<runtime>` when building explicit `-codex` / `-claude` image names.
4. Existing local naming aliases are preserved:
   - `agent-python` keeps working and still means Codex runtime by default
   - `codex-*` compatibility aliases map to `agent-*` where already planned

## Matrix

| Toolchain image | Codex runtime            | Claude runtime             |
|-----------------|--------------------------|----------------------------|
| base            | `agent-base-codex`       | `agent-base-claude`        |
| python          | `agent-python-codex`     | `agent-python-claude`      |
| office          | `agent-office-codex`     | `agent-office-claude`      |
| swift           | `agent-swift-codex`      | `agent-swift-claude`       |

Preferred aliases:

- `agent-base`, `agent-python`, `agent-office`, `agent-swift` map to their `-codex` variants.

## Required host/controller updates

- Parse image family and runtime suffix when selecting build targets:
  - `agent-python` with no suffix uses runtime `codex`
  - `agent-python-claude` uses runtime suffix `claude`
- Keep compatibility alias lookup:
  - `agent-<x>` and `codex-<x>` both resolve to the canonical family
- For each build target image, emit dependency graph using toolchain DAG only (base -> python -> office -> swift) and runtime overlay as a parameter, not a separate Dockerfile family.

## User story / workflow

- Default stay unchanged:
  - `codexctl run --image agent-office` keeps working and remains Codex runtime.
- Runtime flip is explicit by tag:
  - `codexctl run --image agent-office-claude`
  - rebuilds only required local image chain with the selected runtime layer.
- Custom teams can override `DockerFile` or add `DockerFile.office` extensions without exploding combinations.

## Why this prevents file explosion

- File count grows by runtime adapters, not Cartesian products.
- Toolchain Dockerfiles remain one per toolchain.
- New runtimes only require new runtime adapter files and optional build hooks, not N×M new file combinations.
