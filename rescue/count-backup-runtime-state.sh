#!/usr/bin/env bash
set -euo pipefail

AGENTCTL="${AGENTCTL:-agentctl}"
PREFIX="${PREFIX:-bst}"

usage() {
  cat <<EOF
Usage: $0 [backup-image ...]

Counts Codex and Claude state files in agentctl backup images.

If no backup images are passed, the script reads them from:
  $AGENTCTL images --backup

Environment:
  AGENTCTL  agentctl command to use (default: agentctl)
  PREFIX    short rescue container name prefix (default: bst)
EOF
}

rescue_name() {
  local index="$1"
  printf '%s%s\n' "$PREFIX" "$index"
}

state_count_command() {
  cat <<'EOF'
set -eu
codex_history=0
codex_index=0
codex_sessions=0
claude_credentials=0
claude_settings=0
claude_home_state=0
claude_projects=0

if [ -f /home/coder/.codex/history.jsonl ]; then
  codex_history="$(wc -l < /home/coder/.codex/history.jsonl | tr -d "[:space:]")"
fi
if [ -f /home/coder/.codex/session_index.jsonl ]; then
  codex_index="$(wc -l < /home/coder/.codex/session_index.jsonl | tr -d "[:space:]")"
fi
if [ -d /home/coder/.codex ]; then
  codex_sessions="$(find /home/coder/.codex \( -path "*/sessions/*" -o -path "*/archived_sessions/*" \) -type f 2>/dev/null | wc -l | tr -d "[:space:]")"
fi

[ -f /home/coder/.claude/.credentials.json ] && claude_credentials=1
[ -f /home/coder/.claude/settings.json ] && claude_settings=1
[ -f /home/coder/.claude.json ] && claude_home_state=1
if [ -d /home/coder/.claude/projects ]; then
  claude_projects="$(find /home/coder/.claude/projects -type f 2>/dev/null | wc -l | tr -d "[:space:]")"
fi

printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
  "$codex_history" \
  "$codex_sessions" \
  "$codex_index" \
  "$claude_credentials" \
  "$claude_settings" \
  "$claude_home_state" \
  "$claude_projects"
EOF
}

backup_images() {
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
    return 0
  fi
  "$AGENTCTL" images --backup | awk 'NF { print $1 }'
}

main() {
  local image=""
  local index=0
  local name=""
  local counts=""
  local status="ok"
  local command=""

  case "${1:-}" in
    -h|--help)
      usage
      return 0
      ;;
  esac

  command="$(state_count_command)"
  printf 'image\tcodex_history_lines\tcodex_session_files\tcodex_session_index_lines\tclaude_credentials_files\tclaude_settings_files\tclaude_home_state_files\tclaude_project_files\tstatus\n'

  while IFS= read -r image; do
    [ -n "$image" ] || continue
    index=$((index + 1))
    name="$(rescue_name "$index")"
    status="ok"
    if counts="$("$AGENTCTL" rescue --image "$image" --name "$name" --cmd sh -lc "$command" 2>/dev/null)"; then
      printf '%s\t%s\t%s\n' "$image" "$counts" "$status"
    else
      status="rescue_failed"
      printf '%s\t0\t0\t0\t0\t0\t0\t0\t%s\n' "$image" "$status"
    fi
  done < <(backup_images "$@")
}

main "$@"
