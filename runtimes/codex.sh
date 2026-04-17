agent_runtime_run() {
  local runtime="$1"
  shift

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"

  case "$RUN_MODE" in
    openai)
      exec codex "$@"
      ;;
  esac
  if has_explicit_profile "$@"; then
    exec codex "$@"
  fi
  exec codex --profile "$DEFAULT_PROFILE" "$@"
}

agent_runtime_install() {
  local runtime="$1"

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  npm install -g @openai/codex --omit=dev --no-fund --no-audit
  preferred_set "$runtime"
}

agent_runtime_update() {
  local runtime="$1"

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  npm install -g @openai/codex --omit=dev --no-fund --no-audit
}

agent_runtime_reset_config() {
  local runtime="$1"
  local config_dir="$2"

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  ensure_user_dirs
  cp "$config_dir/config.toml" "$CODEX_HOME_DIR/config.toml"
  if [ -f "$config_dir/local_models.json" ]; then
    cp "$config_dir/local_models.json" "$CODEX_HOME_DIR/local_models.json"
  else
    rm -f "$CODEX_HOME_DIR/local_models.json"
  fi
  ln -sf "$config_dir/image.md" "$CODEX_HOME_DIR/AGENTS.md"
  rm -f "$USER_RUNTIME_FILE"
}

agent_runtime_auth_read() {
  local runtime="$1"
  local key="$2"

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  [ "$key" = "json_refresh_token" ] || die "unsupported auth format: $key"
  [ -f "$CODEX_AUTH_FILE" ] || exit 1
  cat "$CODEX_AUTH_FILE"
}

agent_runtime_auth_write() {
  local runtime="$1"
  local key="$2"
  local value="${3:-}"

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  [ "$key" = "json_refresh_token" ] || die "unsupported auth format: $key"
  ensure_user_dirs
  if [ -z "$value" ] && [ ! -t 0 ]; then
    value="$(cat)"
  fi
  printf '%s' "$value" >"$CODEX_AUTH_FILE"
}

agent_runtime_auth_login() {
  local runtime="$1"

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  exec codex login --device-auth
}
