CLAUDE_HOME_DIR="${HOME}/.claude"
CLAUDE_SETTINGS_FILE="${CLAUDE_HOME_DIR}/settings.json"
CLAUDE_CREDENTIALS_FILE="${CLAUDE_HOME_DIR}/.credentials.json"
CLAUDE_HOME_STATE_FILE="${HOME}/.claude.json"
CLAUDE_LOCAL_MODEL="${AGENTCTL_CLAUDE_LOCAL_MODEL:-gpt-oss:20b}"

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

claude_home_owner() {
  stat -c '%u:%g' "$HOME" 2>/dev/null \
    || stat -f '%u:%g' "$HOME" 2>/dev/null \
    || printf '%s\n' "coder:coder"
}

claude_fix_state_ownership() {
  local owner=""

  [ "$(id -u)" -eq 0 ] || return 0
  owner="$(claude_home_owner)"
  if [ -e "$CLAUDE_HOME_DIR" ]; then
    chown -R "$owner" "$CLAUDE_HOME_DIR"
  fi
  if [ -e "$CLAUDE_HOME_STATE_FILE" ]; then
    chown "$owner" "$CLAUDE_HOME_STATE_FILE"
  fi
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

claude_detect_gateway() {
  local route_file="${AGENTCTL_CLAUDE_ROUTE_FILE:-/proc/net/route}"
  awk '
    function hex2dec(hex,   i, c, n, v) {
      n = 0
      hex = toupper(hex)
      for (i = 1; i <= length(hex); i++) {
        c = substr(hex, i, 1)
        v = index("0123456789ABCDEF", c) - 1
        if (v < 0) {
          exit 1
        }
        n = (n * 16) + v
      }
      return n
    }
    $2 == "00000000" && length($3) == 8 {
      printf "%s.%s.%s.%s\n",
        hex2dec(substr($3, 7, 2)),
        hex2dec(substr($3, 5, 2)),
        hex2dec(substr($3, 3, 2)),
        hex2dec(substr($3, 1, 2))
      exit
    }
  ' "$route_file" 2>/dev/null || true
}

claude_has_explicit_model() {
  local arg=""
  for arg in "$@"; do
    case "$arg" in
      --model|--model=*) return 0 ;;
    esac
  done
  return 1
}

claude_has_explicit_flag() {
  local flag="$1"
  shift
  local arg=""
  for arg in "$@"; do
    [ "$arg" = "$flag" ] && return 0
  done
  return 1
}

agent_runtime_run() {
  local runtime="$1"
  shift

  [ "$runtime" = "claude" ] || die "unsupported runtime adapter: $runtime"
  local gateway=""
  local -a claude_args=("$@")

  if runtime_config_enabled "dangerously-skip-permissions"; then
    if [ "${#claude_args[@]}" -eq 0 ]; then
      claude_args=(--dangerously-skip-permissions)
    elif ! claude_has_explicit_flag "--dangerously-skip-permissions" "${claude_args[@]}"; then
      claude_args=(--dangerously-skip-permissions "${claude_args[@]}")
    fi
  fi

  case "$RUN_MODE" in
    online)
      if [ "${#claude_args[@]}" -eq 0 ]; then
        if [ -n "$MODEL_OVERRIDE" ]; then
          exec "$(claude_command_path)" --model "$MODEL_OVERRIDE"
        fi
        exec "$(claude_command_path)"
      fi
      if [ -n "$MODEL_OVERRIDE" ] && ! claude_has_explicit_model "${claude_args[@]}"; then
        exec "$(claude_command_path)" --model "$MODEL_OVERRIDE" "${claude_args[@]}"
      fi
      exec "$(claude_command_path)" "${claude_args[@]}"
      ;;
  esac

  gateway="$(claude_detect_gateway)"
  [ -n "$gateway" ] || die "unable to detect host gateway for claude local mode"
  export ANTHROPIC_AUTH_TOKEN=ollama
  export ANTHROPIC_API_KEY=""
  export ANTHROPIC_BASE_URL="http://${gateway}:11434"

  if [ "${#claude_args[@]}" -eq 0 ]; then
    exec "$(claude_command_path)" --model "${MODEL_OVERRIDE:-$CLAUDE_LOCAL_MODEL}"
  fi
  if claude_has_explicit_model "${claude_args[@]}"; then
    exec "$(claude_command_path)" "${claude_args[@]}"
  fi
  exec "$(claude_command_path)" --model "${MODEL_OVERRIDE:-$CLAUDE_LOCAL_MODEL}" "${claude_args[@]}"
}

agent_runtime_install() {
  local runtime="$1"

  [ "$runtime" = "claude" ] || die "unsupported runtime adapter: $runtime"
  claude_verify_alpine_dependencies
  curl -fsSL https://claude.ai/install.sh | bash
  claude_command_path >/dev/null 2>&1 || die "claude installer finished but launcher was not found on PATH or in ~/.local/bin"
  agent_runtime_reset_config "$runtime" "$(runtime_default_config_dir "$runtime")"
  if [ "${AGENTCTL_SKIP_PREFERRED_SET:-0}" != "1" ]; then
    preferred_set "$runtime"
  fi
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
  claude_fix_state_ownership
  rm -f "$USER_RUNTIME_FILE"
}

agent_runtime_state_paths() {
  local runtime="$1"

  [ "$runtime" = "claude" ] || die "unsupported runtime adapter: $runtime"
  [ -e "$CLAUDE_HOME_DIR" ] && printf '%s\n' ".claude"
  [ -e "$CLAUDE_HOME_STATE_FILE" ] && printf '%s\n' ".claude.json"
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
  claude_fix_state_ownership
}

agent_runtime_auth_login() {
  local runtime="$1"

  [ "$runtime" = "claude" ] || die "unsupported runtime adapter: $runtime"
  exec "$(claude_command_path)"
}
