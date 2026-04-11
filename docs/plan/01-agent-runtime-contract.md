# Agent Runtime Contract

## Goal

Define the minimum contract an image must implement to be launchable by the generic controller.

## Required Files

Each supported image should provide:

- `/usr/local/bin/agent.sh`
- `/etc/agentctl/agent.env`
- `/etc/agentctl/image.md`

Optional:

- `/etc/agentctl/defaults/`

## `agent.sh`

`agent.sh` is the only runtime command the host controller should call by default.

Required subcommands:

- `agent.sh run`
- `agent.sh login`
- `agent.sh version`
- `agent.sh home-dir`
- `agent.sh config-dir`
- `agent.sh auth-path`
- `agent.sh update`

Recommended optional subcommands:

- `agent.sh auth-format`
- `agent.sh supports <capability>`
- `agent.sh print-env`

### Subcommand Semantics

`run`

- launch the runtime in its default interactive mode
- accept environment such as profile or mode when relevant

`login`

- perform the runtime’s supported interactive login flow
- return non-zero if the runtime does not support scripted login bootstrap

`version`

- print the runtime version in a stable human-readable form

`home-dir`

- print the runtime home directory used for mutable state

`config-dir`

- print the directory containing mutable runtime config

`auth-path`

- print the runtime auth file path when auth is file-based
- print a canonical directory path when auth is directory-based

`update`

- perform the runtime-specific package update

## `agent.env`

`agent.env` is the machine-readable metadata source for the host controller.

Minimum fields:

```sh
AGENT_ID=
AGENT_DISPLAY_NAME=
AGENT_BIN=
AGENT_HOME_DIR=
AGENT_CONFIG_DIR=
AGENT_AUTH_PATH=
AGENT_AUTH_FORMAT=
AGENT_IMAGE_DEFAULTS_DIR=
AGENT_KEYCHAIN_SERVICE=
AGENT_KEYCHAIN_ACCOUNT=
AGENT_SUPPORTS_INTERACTIVE_LOGIN=
AGENT_SUPPORTS_KEYCHAIN_SYNC=
AGENT_SUPPORTS_UPDATE=
```

Additional recommended fields:

```sh
AGENT_SUPPORTS_LOCAL_MODEL_MODE=
AGENT_SUPPORTS_OPENAI_MODE=
AGENT_DEFAULT_PROFILE=
AGENT_IMAGE_FAMILY=
```

## Auth Format Types

The host controller should support multiple auth storage strategies.

Initial supported values:

- `json_refresh_token`
- `opaque_blob`
- `directory_tarball`

Semantics:

`json_refresh_token`

- parse refresh token and refresh timestamp if present
- compare container state with Keychain state semantically

`opaque_blob`

- treat auth as a single opaque file
- compare raw bytes when possible
- otherwise use conservative overwrite/store behavior

`directory_tarball`

- treat auth state as a directory tree
- archive and restore the directory as a bundle

## Image-Owned Defaults

Image-owned defaults should live under:

- `/etc/agentctl/defaults/`

This keeps:

- static image defaults separate from mutable runtime state
- reset and upgrade behavior precise

Do not require every runtime to expose the same files. Codex may ship `config.toml` and `local_models.json`, while other runtimes may ship different defaults or none at all.

## Compatibility Expectations

The contract should be designed so:

- Codex can implement it without changing user-visible behavior
- Claude can implement it without pretending to be Codex
- future runtimes can be added without editing the generic controller in many places
