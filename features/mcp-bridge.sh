#!/usr/bin/env bash

mcp_bridge_marker() { printf '%s/mcp-bridge/install-complete\n' "${AGENTCTL_FEATURE_STATE_DIR:-/var/lib/agentctl/features}"; }
agent_feature_installed() { [ -f "$(mcp_bridge_marker)" ] && command -v node >/dev/null 2>&1; }
agent_feature_install() {
  [ "$1" = mcp-bridge ] || die "unsupported feature adapter: $1"
  if ! command -v node >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then apk add --no-cache nodejs
    elif command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs
    else die "mcp-bridge requires Node.js"; fi
  fi
  mkdir -p "$(dirname "$(mcp_bridge_marker)")" /run/agentctl
  printf '%s\n' 'mcp-bridge feature installed' >"$(mcp_bridge_marker)"
}
agent_feature_remove() { die 'feature removal not implemented: mcp-bridge'; }
agent_feature_update() { agent_feature_install "$@"; }
