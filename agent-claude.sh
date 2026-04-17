#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-run}"
shift || true

runtime_mode="${AGENTCTL_RUNTIME_MODE:-local}"
profile="${CODEX_PROFILE:-gpt-oss}"

case "$cmd" in
  run)
    case "$runtime_mode" in
      openai|local|*)
        if ! command -v claude >/dev/null 2>&1; then
          echo "Error: claude binary not available in PATH" >&2
          exit 127
        fi
        echo "Launching Claude Code runtime" >&2
        exec claude
        ;;
    esac
    ;;
  login)
    exec claude login
    ;;
  version)
    exec claude --version
    ;;
  home-dir)
    printf '%s\n' /home/coder
    ;;
  config-dir)
    printf '%s\n' /home/coder/.claude
    ;;
  auth-path)
    printf '%s\n' /home/coder/.claude/.credentials.json
    ;;
  update)
    exec claude update
    ;;
  supports)
    case "${1:-}" in
      update)
        printf '%s\n' 1
        ;;
      interactive-login|keychain-sync|local-model-mode)
        printf '%s\n' 0
        ;;
      openai-mode)
        printf '%s\n' 0
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
