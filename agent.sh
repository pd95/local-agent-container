#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-run}"
shift || true

runtime_mode="${AGENTCTL_RUNTIME_MODE:-local}"
profile="${CODEX_PROFILE:-gpt-oss}"

case "$cmd" in
  run)
    case "$runtime_mode" in
      openai) exec codex --cd /workdir ;;
      local|*) exec codex --profile "$profile" --cd /workdir ;;
    esac
    ;;
  login)
    exec codex login --device-auth
    ;;
  version)
    exec codex --version
    ;;
  home-dir|config-dir)
    printf '%s\n' /home/coder/.codex
    ;;
  auth-path)
    printf '%s\n' /home/coder/.codex/auth.json
    ;;
  update)
    exec npm install -g @openai/codex --omit=dev --no-fund --no-audit
    ;;
  supports)
    case "${1:-}" in
      interactive-login|keychain-sync|local-model-mode|openai-mode|update)
        printf '%s\n' 1
        ;;
      *)
        printf '%s\n' 0
        ;;
    esac
    ;;
  *)
    echo "Usage: agent.sh {run|login|version|home-dir|config-dir|auth-path|update|supports}" >&2
    exit 64
    ;;
esac
