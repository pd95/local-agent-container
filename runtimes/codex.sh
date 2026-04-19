CODEX_DEFAULT_PROFILE="${AGENTCTL_CODEX_PROFILE:-gpt-oss}"

codex_home_dir() {
  printf '%s\n' "${HOME}/.codex"
}

codex_auth_file() {
  printf '%s\n' "$(codex_home_dir)/auth.json"
}

codex_ensure_home_dir() {
  mkdir -p "$(codex_home_dir)"
}

codex_has_explicit_profile() {
  local arg=""
  for arg in "$@"; do
    case "$arg" in
      --profile|--profile=*) return 0 ;;
    esac
  done
  return 1
}

codex_has_explicit_cd() {
  local arg=""
  for arg in "$@"; do
    case "$arg" in
      --cd|--cd=*) return 0 ;;
    esac
  done
  return 1
}

agent_runtime_run() {
  local runtime="$1"
  shift

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  local -a codex_args=()
  local profile=""

  if [ "$#" -gt 0 ]; then
    codex_args=("$@")
  fi

  if [ "${#codex_args[@]}" -eq 0 ]; then
    codex_args=(--cd /workdir)
  elif ! codex_has_explicit_cd "${codex_args[@]}"; then
    codex_args=(--cd /workdir "${codex_args[@]}")
  fi

  if [ -n "$MODEL_OVERRIDE" ] && ! has_explicit_runtime_model "${codex_args[@]}"; then
    codex_args=(-m "$MODEL_OVERRIDE" "${codex_args[@]}")
  fi

  profile="$(runtime_config_value profile)"
  case "$RUN_MODE" in
    online)
      if [ -n "$profile" ] && ! codex_has_explicit_profile "${codex_args[@]}"; then
        codex_args=(--profile "$profile" "${codex_args[@]}")
      fi
      exec codex "${codex_args[@]}"
      ;;
  esac
  if [ "${#codex_args[@]}" -gt 0 ] && codex_has_explicit_profile "${codex_args[@]}"; then
    exec codex "${codex_args[@]}"
  fi
  profile="${profile:-$(runtime_config_value profile "$CODEX_DEFAULT_PROFILE")}"
  if [ "${#codex_args[@]}" -eq 0 ]; then
    exec codex --profile "$profile"
  fi
  exec codex --profile "$profile" "${codex_args[@]}"
}

agent_runtime_install() {
  local runtime="$1"

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  npm install -g @openai/codex --omit=dev --no-fund --no-audit
  if [ "${AGENTCTL_SKIP_PREFERRED_SET:-0}" != "1" ]; then
    preferred_set "$runtime"
  fi
}

agent_runtime_update() {
  local runtime="$1"

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  npm install -g @openai/codex --omit=dev --no-fund --no-audit
}

agent_runtime_reset_config() {
  local runtime="$1"
  local config_dir="$2"
  local codex_dir=""

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  codex_dir="$(codex_home_dir)"
  codex_ensure_home_dir
  cp "$config_dir/config.toml" "$codex_dir/config.toml"
  if [ -f "$config_dir/local_models.json" ]; then
    cp "$config_dir/local_models.json" "$codex_dir/local_models.json"
  else
    rm -f "$codex_dir/local_models.json"
  fi
  ln -sf "$config_dir/image.md" "$codex_dir/AGENTS.md"
  rm -f "$USER_RUNTIME_FILE"
}

codex_auth_payload_valid() {
  jq -e '
    type == "object" and (
      ((.refresh_token? // "") | type == "string" and length > 0) or
      ((.tokens.refresh_token? // "") | type == "string" and length > 0)
    )
  ' >/dev/null 2>&1
}

agent_runtime_auth_read() {
  local runtime="$1"
  local key="$2"
  local auth_file=""

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  [ "$key" = "json_refresh_token" ] || die "unsupported auth format: $key"
  auth_file="$(codex_auth_file)"
  [ -f "$auth_file" ] || exit 1
  codex_auth_payload_valid <"$auth_file" || die "invalid auth state: $auth_file"
  cat "$auth_file"
}

agent_runtime_auth_write() {
  local runtime="$1"
  local key="$2"
  local value="${3:-}"
  local auth_file=""

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  [ "$key" = "json_refresh_token" ] || die "unsupported auth format: $key"
  codex_ensure_home_dir
  auth_file="$(codex_auth_file)"
  if [ -z "$value" ] && [ ! -t 0 ]; then
    value="$(cat)"
  fi
  [ -n "$value" ] || die "empty auth payload for codex"
  printf '%s' "$value" | codex_auth_payload_valid || die "invalid auth payload for codex"
  printf '%s' "$value" >"$auth_file"
}

agent_runtime_auth_login() {
  local runtime="$1"

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  exec codex login --device-auth
}
