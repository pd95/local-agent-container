# Codex Compatibility Plan

## Objective

Codex must remain the reference runtime and continue to work as before during and after the refactor.

This means:

- OpenAI device auth continues to work
- local-model mode continues to work
- existing config persistence continues to work
- upgrade behavior continues to work
- current users can keep using `codexctl` initially

## What Must Not Regress

Required preserved behavior:

- `codexctl build`
- `codexctl run`
- `codexctl run --openai`
- `codexctl auth`
- `codexctl run --profile <name>`
- `codexctl run --update`
- `codexctl upgrade`
- config preservation in `/home/coder/.codex`

## Codex Runtime Contract Mapping

Codex should implement the generic contract with these effective values:

```sh
AGENT_ID=codex
AGENT_DISPLAY_NAME="OpenAI Codex"
AGENT_BIN=codex
AGENT_HOME_DIR=/home/coder/.codex
AGENT_CONFIG_DIR=/home/coder/.codex
AGENT_AUTH_PATH=/home/coder/.codex/auth.json
AGENT_AUTH_FORMAT=json_refresh_token
AGENT_IMAGE_DEFAULTS_DIR=/etc/agentctl/defaults
AGENT_KEYCHAIN_SERVICE=agentctl-codex-auth
AGENT_KEYCHAIN_ACCOUNT=device-auth-openai
AGENT_SUPPORTS_INTERACTIVE_LOGIN=1
AGENT_SUPPORTS_KEYCHAIN_SYNC=1
AGENT_SUPPORTS_UPDATE=1
AGENT_SUPPORTS_LOCAL_MODEL_MODE=1
AGENT_SUPPORTS_OPENAI_MODE=1
```

## Codex `agent.sh`

Codex `agent.sh` should preserve current semantics:

- `run`
  - default local mode: `codex --profile "${CODEX_PROFILE:-gpt-oss}" --cd /workdir`
  - OpenAI mode when requested by env or flag: `codex --cd /workdir`
- `login`
  - `codex login --device-auth`
- `update`
  - `npm install -g @openai/codex --omit=dev --no-fund --no-audit`

The host controller should not rebuild these rules itself. It should pass mode information to `agent.sh`, and `agent.sh` should interpret it.

## Host-Side Migration Constraints

When refactoring the host script:

- keep local-model preflight for Codex
- only run that preflight when the selected runtime declares support
- preserve current post-run token sync behavior for Codex
- preserve current config overwrite behavior for Codex defaults

## Codex Validation Matrix

After each phase, Codex should be tested for:

- image build
- `run`
- `run --openai`
- `auth`
- `run --update`
- `run --profile gemma`
- `upgrade`
- backup and restore of `.codex`

If any of those regress, the phase should not be considered complete.
