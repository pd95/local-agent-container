QWEN_LOCAL_MODEL="${AGENTCTL_QWEN_LOCAL_MODEL:-gpt-oss:20b}"

qwen_command_path() {
  runtime_command_path qwen
}

qwen_config_dir() {
  printf '%s\n' "${HOME}/.qwen"
}

qwen_settings_file() {
  printf '%s\n' "$(qwen_config_dir)/settings.json"
}

qwen_require_node_version() {
  local min_version="$1"
  local current_version=""

  command -v node >/dev/null 2>&1 || die "Node.js is required to install Qwen Code"
  current_version="$(node -p 'process.versions.node' 2>/dev/null || true)"
  [ -n "$current_version" ] || die "Unable to determine Node.js version for Qwen Code"
  node -e '
const current = process.argv[1].split(".").map(Number);
const minimum = process.argv[2].split(".").map(Number);
for (let i = 0; i < 3; i++) {
  const c = current[i] || 0;
  const m = minimum[i] || 0;
  if (c > m) process.exit(0);
  if (c < m) process.exit(1);
}
' "$current_version" "$min_version" \
    || die "Qwen Code requires Node.js >= $min_version; found $current_version"
}

qwen_write_settings() {
  local target_file="$1"
  local ollama_base_url="$2"
  local model="$3"
  local openai_base_url="${ollama_base_url%/}/v1"

  command -v jq >/dev/null 2>&1 || die "Missing jq required for Qwen Code config generation"
  mkdir -p "$(dirname "$target_file")"
  jq -n \
    --arg base_url "$openai_base_url" \
    --arg model "$model" \
    '{
      modelProviders: {
        openai: {
          protocol: "openai",
          models: [
            {
              id: $model,
              name: ($model + " (local Ollama)"),
              baseUrl: $base_url,
              envKey: "OLLAMA_API_KEY"
            }
          ]
        }
      },
      env: {
        OLLAMA_API_KEY: "ollama"
      },
      security: {
        auth: {
          selectedType: "openai"
        }
      },
      model: {
        name: $model
      },
      telemetry: {
        enabled: false
      },
      privacy: {
        usageStatisticsEnabled: false
      }
    }' >"$target_file"
}

qwen_merge_settings() {
  local target_file="$1"
  local ollama_base_url="$2"
  local model="$3"
  local openai_base_url="${ollama_base_url%/}/v1"
  local tmp_file=""

  command -v jq >/dev/null 2>&1 || die "Missing jq required for Qwen Code config generation"
  mkdir -p "$(dirname "$target_file")"
  tmp_file="$(mktemp)"
  jq \
    --arg base_url "$openai_base_url" \
    --arg model "$model" \
    '
      . as $root
      | .modelProviders.openai.protocol = "openai"
      | .modelProviders.openai.models =
          (
            ((.modelProviders.openai.models // [])
              | map(select(.id != $model or .baseUrl != $base_url)))
            + [{
                id: $model,
                name: ($model + " (local Ollama)"),
                baseUrl: $base_url,
                envKey: "OLLAMA_API_KEY"
              }]
          )
      | .env.OLLAMA_API_KEY = "ollama"
      | .security.auth.selectedType = "openai"
      | .model.name = $model
      | .telemetry.enabled = false
      | .privacy.usageStatisticsEnabled = false
    ' "$target_file" >"$tmp_file" || {
      rm -f "$tmp_file"
      die "failed to update Qwen Code settings: $target_file"
    }
  mv "$tmp_file" "$target_file"
}

qwen_ensure_settings_file() {
  local ollama_base_url="$1"
  local model="$2"
  local settings_file=""
  local default_file=""

  settings_file="$(qwen_settings_file)"
  default_file="$(runtime_default_config_dir qwen)/settings.json"
  if [ ! -f "$settings_file" ] && [ -f "$default_file" ]; then
    mkdir -p "$(dirname "$settings_file")"
    cp "$default_file" "$settings_file"
  fi
  if [ -f "$settings_file" ]; then
    qwen_merge_settings "$settings_file" "$ollama_base_url" "$model"
  else
    qwen_write_settings "$settings_file" "$ollama_base_url" "$model"
  fi
}

qwen_has_explicit_auth_type() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --auth-type|--auth-type=*) return 0 ;;
    esac
  done
  return 1
}

qwen_link_tool_launcher() {
  local tools_bin=""
  local tool_home=""
  local candidate=""

  tools_bin="$(agent_tools_bin_dir)"
  tool_home="$(runtime_tool_home qwen)"
  candidate="$tool_home/node_modules/.bin/qwen"
  mkdir -p "$tools_bin"
  [ -x "$candidate" ] || return 1
  ln -sf "$candidate" "$tools_bin/qwen"
}

qwen_npm_install() {
  local install_home="$1"
  local install_dir="$2"
  local package="@qwen-code/qwen-code@${QWEN_CODE_VERSION:-latest}"

  qwen_require_node_version "22.0.0"
  command -v npm >/dev/null 2>&1 || die "npm is required to install Qwen Code"
  mkdir -p "$install_home" "$install_dir"
  npm install --prefix "$install_home" "$package"
  qwen_link_tool_launcher || die "qwen npm install finished but launcher was not found under $install_home/node_modules/.bin"
  qwen_command_path >/dev/null 2>&1 || die "qwen launcher was not found in $(agent_tools_bin_dir)"
}

agent_runtime_run() {
  local runtime="$1"
  shift

  [ "$runtime" = "qwen" ] || die "unsupported runtime adapter: $runtime"
  local -a qwen_args=("$@")
  local ollama_base_url=""
  local openai_base_url=""
  local model=""
  local launch_model=""

  case "$RUN_MODE" in
    online)
      die "Qwen Code runtime does not support agentctl online/auth mode yet"
      ;;
  esac

  model="${MODEL_OVERRIDE:-$QWEN_LOCAL_MODEL}"
  ollama_base_url="$(ollama_resolve_base_url)"
  openai_base_url="${ollama_base_url%/}/v1"
  qwen_ensure_settings_file "$ollama_base_url" "$model"

  if [ "${#qwen_args[@]}" -eq 0 ]; then
    qwen_args=(--auth-type openai --model "$model")
    launch_model="$model"
  elif [ -n "$MODEL_OVERRIDE" ] && ! has_explicit_runtime_model "${qwen_args[@]}"; then
    qwen_args=(--model "$MODEL_OVERRIDE" "${qwen_args[@]}")
    if ! qwen_has_explicit_auth_type "${qwen_args[@]}"; then
      qwen_args=(--auth-type openai "${qwen_args[@]}")
    fi
    launch_model="$MODEL_OVERRIDE"
  elif has_explicit_runtime_model "${qwen_args[@]}"; then
    launch_model="$(runtime_model_arg_value "${qwen_args[@]}")"
    if ! qwen_has_explicit_auth_type "${qwen_args[@]}"; then
      qwen_args=(--auth-type openai "${qwen_args[@]}")
    fi
  else
    if ! qwen_has_explicit_auth_type "${qwen_args[@]}"; then
      qwen_args=(--auth-type openai "${qwen_args[@]}")
    fi
    launch_model="$model"
  fi
  ollama_require_model "$ollama_base_url" "$launch_model"

  OLLAMA_API_KEY="${OLLAMA_API_KEY:-ollama}" \
    OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}" \
    OPENAI_BASE_URL="${OPENAI_BASE_URL:-$openai_base_url}" \
    OPENAI_MODEL="${OPENAI_MODEL:-$model}" \
    exec "$(qwen_command_path)" "${qwen_args[@]}"
}

agent_runtime_install() {
  local runtime="$1"
  local install_home=""
  local install_dir=""

  [ "$runtime" = "qwen" ] || die "unsupported runtime adapter: $runtime"
  install_home="$(runtime_tool_home "$runtime")"
  install_dir="$(agent_tools_bin_dir)"
  qwen_npm_install "$install_home" "$install_dir"
  if [ "${AGENTCTL_SKIP_PREFERRED_SET:-0}" != "1" ]; then
    preferred_set "$runtime"
  fi
}

agent_runtime_update() {
  local runtime="$1"
  local install_home=""
  local install_dir=""

  [ "$runtime" = "qwen" ] || die "unsupported runtime adapter: $runtime"
  install_home="$(runtime_tool_home "$runtime")"
  install_dir="$(agent_tools_bin_dir)"
  qwen_npm_install "$install_home" "$install_dir"
}

agent_runtime_reset_config() {
  local runtime="$1"
  local config_dir="${2:-}"
  local settings_file=""
  local ollama_base_url=""
  local model="$QWEN_LOCAL_MODEL"

  [ "$runtime" = "qwen" ] || die "unsupported runtime adapter: $runtime"
  settings_file="$(qwen_settings_file)"
  printf 'Warning: resetting Qwen Code configuration will replace ~/.qwen/settings.json and may remove custom providers, models, and runtime preference.\n' >&2
  mkdir -p "$(dirname "$settings_file")"
  if [ -n "$config_dir" ] && [ -f "$config_dir/settings.json" ]; then
    cp "$config_dir/settings.json" "$settings_file"
  else
    ollama_base_url="$(ollama_resolve_base_url)"
    qwen_write_settings "$settings_file" "$ollama_base_url" "$model"
  fi
  rm -f "$USER_RUNTIME_FILE"
}

agent_runtime_state_paths() {
  local runtime="$1"

  [ "$runtime" = "qwen" ] || die "unsupported runtime adapter: $runtime"
  [ -e "$(qwen_config_dir)" ] && printf '%s\n' ".qwen"
}

agent_runtime_auth_read() {
  local runtime="$1"

  [ "$runtime" = "qwen" ] || die "unsupported runtime adapter: $runtime"
  die "Qwen Code runtime does not support agentctl-managed auth yet"
}

agent_runtime_auth_write() {
  local runtime="$1"

  [ "$runtime" = "qwen" ] || die "unsupported runtime adapter: $runtime"
  die "Qwen Code runtime does not support agentctl-managed auth yet"
}

agent_runtime_auth_login() {
  local runtime="$1"

  [ "$runtime" = "qwen" ] || die "unsupported runtime adapter: $runtime"
  die "Qwen Code runtime does not support agentctl-managed auth yet"
}
