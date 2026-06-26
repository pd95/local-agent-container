OPENCODE_LOCAL_MODEL="${AGENTCTL_OPENCODE_LOCAL_MODEL:-gpt-oss:20b}"

opencode_command_path() {
  runtime_command_path opencode
}

opencode_config_dir() {
  printf '%s\n' "${HOME}/.config/opencode"
}

opencode_config_file() {
  printf '%s\n' "$(opencode_config_dir)/opencode.json"
}

opencode_share_dir() {
  printf '%s\n' "${HOME}/.local/share/opencode"
}

opencode_model_arg() {
  local model="$1"

  case "$model" in
    */*) printf '%s\n' "$model" ;;
    *) printf 'ollama/%s\n' "$model" ;;
  esac
}

opencode_write_config() {
  local target_file="$1"
  local ollama_base_url="$2"
  local model="$3"
  local openai_base_url="${ollama_base_url%/}/v1"

  command -v jq >/dev/null 2>&1 || die "Missing jq required for OpenCode config generation"
  mkdir -p "$(dirname "$target_file")"
  jq -n \
    --arg schema "https://opencode.ai/config.json" \
    --arg base_url "$openai_base_url" \
    --arg model "$model" \
    '{
      "$schema": $schema,
      model: ("ollama/" + $model),
      provider: {
        ollama: {
          npm: "@ai-sdk/openai-compatible",
          name: "Ollama (local)",
          options: {
            baseURL: $base_url,
            apiKey: "ollama"
          },
          models: {
            ($model): {
              name: ($model + " (local)")
            }
          }
        }
      }
    }' >"$target_file"
}

opencode_ensure_config_file() {
  local ollama_base_url="$1"
  local model="$2"
  local config_file=""

  config_file="$(opencode_config_file)"
  [ -f "$config_file" ] && return 0
  opencode_write_config "$config_file" "$ollama_base_url" "$model"
}

opencode_link_tool_launcher() {
  local tools_bin=""
  local tool_home=""
  local candidate=""

  tools_bin="$(agent_tools_bin_dir)"
  tool_home="$(runtime_tool_home opencode)"
  candidate="$tool_home/node_modules/.bin/opencode"
  mkdir -p "$tools_bin"
  [ -x "$candidate" ] || return 1
  ln -sf "$candidate" "$tools_bin/opencode"
}

opencode_npm_install() {
  local install_home="$1"
  local install_dir="$2"
  local package="opencode-ai@${OPENCODE_VERSION:-latest}"

  command -v npm >/dev/null 2>&1 || die "npm is required to install OpenCode"
  mkdir -p "$install_home" "$install_dir"
  npm install --prefix "$install_home" "$package"
  opencode_link_tool_launcher || die "opencode npm install finished but launcher was not found under $install_home/node_modules/.bin"
  opencode_command_path >/dev/null 2>&1 || die "opencode launcher was not found in $(agent_tools_bin_dir)"
}

agent_runtime_run() {
  local runtime="$1"
  shift

  [ "$runtime" = "opencode" ] || die "unsupported runtime adapter: $runtime"
  local -a opencode_args=("$@")
  local ollama_base_url=""
  local model=""

  case "$RUN_MODE" in
    online)
      die "OpenCode runtime does not support agentctl online/auth mode yet"
      ;;
  esac

  model="${MODEL_OVERRIDE:-$OPENCODE_LOCAL_MODEL}"
  ollama_base_url="$(ollama_resolve_base_url)"
  opencode_ensure_config_file "$ollama_base_url" "$model"

  if [ "${#opencode_args[@]}" -eq 0 ]; then
    opencode_args=(--model "$(opencode_model_arg "$model")")
  elif [ -n "$MODEL_OVERRIDE" ] && ! has_explicit_runtime_model "${opencode_args[@]}"; then
    opencode_args=(--model "$(opencode_model_arg "$MODEL_OVERRIDE")" "${opencode_args[@]}")
  fi

  exec "$(opencode_command_path)" "${opencode_args[@]}"
}

agent_runtime_install() {
  local runtime="$1"
  local install_home=""
  local install_dir=""

  [ "$runtime" = "opencode" ] || die "unsupported runtime adapter: $runtime"
  install_home="$(runtime_tool_home "$runtime")"
  install_dir="$(agent_tools_bin_dir)"
  opencode_npm_install "$install_home" "$install_dir"
  if [ "${AGENTCTL_SKIP_PREFERRED_SET:-0}" != "1" ]; then
    preferred_set "$runtime"
  fi
}

agent_runtime_update() {
  local runtime="$1"
  local install_home=""
  local install_dir=""

  [ "$runtime" = "opencode" ] || die "unsupported runtime adapter: $runtime"
  install_home="$(runtime_tool_home "$runtime")"
  install_dir="$(agent_tools_bin_dir)"
  opencode_npm_install "$install_home" "$install_dir"
}

agent_runtime_reset_config() {
  local runtime="$1"
  local config_dir="${2:-}"
  local config_file=""
  local ollama_base_url=""
  local model="$OPENCODE_LOCAL_MODEL"

  [ "$runtime" = "opencode" ] || die "unsupported runtime adapter: $runtime"
  config_file="$(opencode_config_file)"
  printf 'Warning: resetting OpenCode configuration will replace ~/.config/opencode/opencode.json and may remove custom providers, models, and runtime preference.\n' >&2
  mkdir -p "$(dirname "$config_file")"
  if [ -n "$config_dir" ] && [ -f "$config_dir/opencode.json" ]; then
    cp "$config_dir/opencode.json" "$config_file"
  else
    ollama_base_url="$(ollama_resolve_base_url)"
    opencode_write_config "$config_file" "$ollama_base_url" "$model"
  fi
  rm -f "$USER_RUNTIME_FILE"
}

agent_runtime_state_paths() {
  local runtime="$1"

  [ "$runtime" = "opencode" ] || die "unsupported runtime adapter: $runtime"
  [ -e "$(opencode_config_dir)" ] && printf '%s\n' ".config/opencode"
  [ -e "$(opencode_share_dir)" ] && printf '%s\n' ".local/share/opencode"
}

agent_runtime_auth_read() {
  local runtime="$1"

  [ "$runtime" = "opencode" ] || die "unsupported runtime adapter: $runtime"
  die "OpenCode runtime does not support agentctl-managed auth yet"
}

agent_runtime_auth_write() {
  local runtime="$1"

  [ "$runtime" = "opencode" ] || die "unsupported runtime adapter: $runtime"
  die "OpenCode runtime does not support agentctl-managed auth yet"
}

agent_runtime_auth_login() {
  local runtime="$1"

  [ "$runtime" = "opencode" ] || die "unsupported runtime adapter: $runtime"
  die "OpenCode runtime does not support agentctl-managed auth yet"
}
