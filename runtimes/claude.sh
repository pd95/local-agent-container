CLAUDE_HOME_DIR="${HOME}/.claude"
CLAUDE_SETTINGS_FILE="${CLAUDE_HOME_DIR}/settings.json"
CLAUDE_CREDENTIALS_FILE="${CLAUDE_HOME_DIR}/.credentials.json"
CLAUDE_HOME_STATE_FILE="${HOME}/.claude.json"

claude_command_path() {
  runtime_command_path claude
}

claude_write_default_settings() {
  local target_file="$1"

  if [ -f /etc/claudectl/settings.json ]; then
    cp /etc/claudectl/settings.json "$target_file"
    return 0
  fi
  cat >"$target_file" <<'EOF'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "env": {
    "USE_BUILTIN_RIPGREP": "0"
  }
}
EOF
}

claude_verify_alpine_dependencies() {
  if ! command -v apk >/dev/null 2>&1; then
    return 0
  fi

  local missing=0
  local package=""
  for package in libgcc libstdc++ ripgrep; do
    if ! apk info -e "$package" >/dev/null 2>&1; then
      printf 'missing Alpine package for claude: %s\n' "$package" >&2
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    die "Install Claude prerequisites as root first: apk add libgcc libstdc++ ripgrep"
  fi
}

claude_auth_payload_valid() {
  jq -e '
    type == "object" and
    (.claudeAiOauth | type == "object") and
    ((.claudeAiOauth.accessToken // "") | type == "string" and length > 0) and
    ((.claudeAiOauth.refreshToken // "") | type == "string" and length > 0) and
    ((.claudeAiOauth.expiresAt // 0) | type == "number")
  ' >/dev/null 2>&1
}

claude_export_home_state() {
  [ -f "$CLAUDE_HOME_STATE_FILE" ] || return 0
  jq -c '
    {
      oauthAccount: (.oauthAccount // null),
      hasCompletedOnboarding: (.hasCompletedOnboarding // null)
    }
    | with_entries(select(.value != null))
  ' "$CLAUDE_HOME_STATE_FILE" 2>/dev/null
}

agent_runtime_run() {
  local runtime="$1"
  shift

  [ "$runtime" = "claude" ] || die "unsupported runtime adapter: $runtime"
  exec "$(claude_command_path)" "$@"
}

agent_runtime_install() {
  local runtime="$1"

  [ "$runtime" = "claude" ] || die "unsupported runtime adapter: $runtime"
  claude_verify_alpine_dependencies
  curl -fsSL https://claude.ai/install.sh | bash
  claude_command_path >/dev/null 2>&1 || die "claude installer finished but launcher was not found on PATH or in ~/.local/bin"
  agent_runtime_reset_config "$runtime" "$(runtime_default_config_dir "$runtime")"
  preferred_set "$runtime"
}

agent_runtime_update() {
  local runtime="$1"

  [ "$runtime" = "claude" ] || die "unsupported runtime adapter: $runtime"
  "$(claude_command_path)" update
}

agent_runtime_reset_config() {
  local runtime="$1"
  local config_dir="${2:-}"

  [ "$runtime" = "claude" ] || die "unsupported runtime adapter: $runtime"
  mkdir -p "$CLAUDE_HOME_DIR"
  if [ -n "$config_dir" ] && [ -f "$config_dir/settings.json" ]; then
    cp "$config_dir/settings.json" "$CLAUDE_SETTINGS_FILE"
  else
    claude_write_default_settings "$CLAUDE_SETTINGS_FILE"
  fi
  rm -f "$USER_RUNTIME_FILE"
}

agent_runtime_auth_read() {
  local runtime="$1"
  local key="$2"

  [ "$runtime" = "claude" ] || die "unsupported runtime adapter: $runtime"
  [ "$key" = "claude_ai_oauth_json" ] || die "unsupported auth format: $key"
  [ -f "$CLAUDE_CREDENTIALS_FILE" ] || exit 1
  claude_auth_payload_valid <"$CLAUDE_CREDENTIALS_FILE" || die "invalid auth state: $CLAUDE_CREDENTIALS_FILE"
  if home_state_json="$(claude_export_home_state)" && [ -n "$home_state_json" ] && [ "$home_state_json" != "{}" ]; then
    jq -c --argjson home_state "$home_state_json" '. + {claudeCodeState: $home_state}' "$CLAUDE_CREDENTIALS_FILE"
    return 0
  fi
  cat "$CLAUDE_CREDENTIALS_FILE"
}

agent_runtime_auth_write() {
  local runtime="$1"
  local key="$2"
  local value="${3:-}"

  [ "$runtime" = "claude" ] || die "unsupported runtime adapter: $runtime"
  [ "$key" = "claude_ai_oauth_json" ] || die "unsupported auth format: $key"
  mkdir -p "$CLAUDE_HOME_DIR"
  if [ -z "$value" ] && [ ! -t 0 ]; then
    value="$(cat)"
  fi
  [ -n "$value" ] || die "empty auth payload for claude"
  printf '%s' "$value" | claude_auth_payload_valid || die "invalid auth payload for claude"
  printf '%s' "$value" | jq -c 'del(.claudeCodeState)' >"$CLAUDE_CREDENTIALS_FILE"
  chmod 600 "$CLAUDE_CREDENTIALS_FILE"
  if printf '%s' "$value" | jq -e '.claudeCodeState | type == "object"' >/dev/null 2>&1; then
    if [ -f "$CLAUDE_HOME_STATE_FILE" ] && jq -e 'type == "object"' "$CLAUDE_HOME_STATE_FILE" >/dev/null 2>&1; then
      printf '%s' "$value" | jq -c --slurpfile current "$CLAUDE_HOME_STATE_FILE" '
        ($current[0] // {}) as $base
        | .claudeCodeState as $incoming
        | $base
        | .oauthAccount = ($incoming.oauthAccount // .oauthAccount)
        | .hasCompletedOnboarding = ($incoming.hasCompletedOnboarding // .hasCompletedOnboarding)
      ' >"$CLAUDE_HOME_STATE_FILE"
    else
      printf '%s' "$value" | jq -c '
        .claudeCodeState
        | {
            oauthAccount: (.oauthAccount // null),
            hasCompletedOnboarding: (.hasCompletedOnboarding // null)
          }
        | with_entries(select(.value != null))
      ' >"$CLAUDE_HOME_STATE_FILE"
    fi
    chmod 600 "$CLAUDE_HOME_STATE_FILE"
  fi
}

agent_runtime_auth_login() {
  local runtime="$1"

  [ "$runtime" = "claude" ] || die "unsupported runtime adapter: $runtime"
  exec "$(claude_command_path)"
}
