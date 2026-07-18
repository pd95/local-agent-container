PI_LOCAL_MODEL="${AGENTCTL_PI_LOCAL_MODEL:-gpt-oss:20b}"

pi_command_path() {
  runtime_command_path pi
}

pi_agent_dir() {
  printf '%s\n' "${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
}

pi_models_file() {
  printf '%s\n' "$(pi_agent_dir)/models.json"
}

pi_model_arg() {
  local model="$1"

  case "$model" in
    */*) printf '%s\n' "$model" ;;
    *) printf 'ollama/%s\n' "$model" ;;
  esac
}

pi_require_node_version() {
  local min_version="$1"
  local current_version=""

  command -v node >/dev/null 2>&1 || die "Node.js is required to install Pi"
  current_version="$(node -p 'process.versions.node' 2>/dev/null || true)"
  [ -n "$current_version" ] || die "Unable to determine Node.js version for Pi"
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
    || die "Pi requires Node.js >= $min_version; found $current_version"
}

pi_write_models() {
  local target_file="$1"
  local ollama_base_url="$2"
  local model="$3"
  local openai_base_url="${ollama_base_url%/}/v1"

  command -v jq >/dev/null 2>&1 || die "Missing jq required for Pi config generation"
  mkdir -p "$(dirname "$target_file")"
  jq -n \
    --arg base_url "$openai_base_url" \
    --arg model "$model" \
    '{
      providers: {
        ollama: {
          baseUrl: $base_url,
          api: "openai-completions",
          apiKey: "ollama",
          compat: {
            supportsDeveloperRole: false,
            supportsReasoningEffort: false
          },
          models: [
            {
              id: $model,
              name: ($model + " (local Ollama)"),
              reasoning: false,
              input: ["text"],
              cost: {
                input: 0,
                output: 0,
                cacheRead: 0,
                cacheWrite: 0
              }
            }
          ]
        }
      }
    }' >"$target_file"
}

pi_merge_models() {
  local target_file="$1"
  local ollama_base_url="$2"
  local model="$3"
  local openai_base_url="${ollama_base_url%/}/v1"
  local tmp_file=""

  command -v jq >/dev/null 2>&1 || die "Missing jq required for Pi config generation"
  mkdir -p "$(dirname "$target_file")"
  tmp_file="$(mktemp)"
  jq \
    --arg base_url "$openai_base_url" \
    --arg model "$model" \
    '
      .providers.ollama.baseUrl = $base_url
      | .providers.ollama.api = "openai-completions"
      | .providers.ollama.apiKey = "ollama"
      | .providers.ollama.compat.supportsDeveloperRole = false
      | .providers.ollama.compat.supportsReasoningEffort = false
      | .providers.ollama.models =
          (
            ((.providers.ollama.models // [])
              | map(select(.id != $model)))
            + [{
                id: $model,
                name: ($model + " (local Ollama)"),
                reasoning: false,
                input: ["text"],
                cost: {
                  input: 0,
                  output: 0,
                  cacheRead: 0,
                  cacheWrite: 0
                }
              }]
          )
    ' "$target_file" >"$tmp_file" || {
      rm -f "$tmp_file"
      die "failed to update Pi models config: $target_file"
    }
  mv "$tmp_file" "$target_file"
}

pi_ensure_models_file() {
  local ollama_base_url="$1"
  local model="$2"
  local models_file=""
  local default_file=""

  models_file="$(pi_models_file)"
  default_file="$(runtime_default_config_dir pi)/models.json"
  if [ ! -f "$models_file" ] && [ -f "$default_file" ]; then
    mkdir -p "$(dirname "$models_file")"
    cp "$default_file" "$models_file"
  fi
  if [ -f "$models_file" ]; then
    pi_merge_models "$models_file" "$ollama_base_url" "$model"
  else
    pi_write_models "$models_file" "$ollama_base_url" "$model"
  fi
}

pi_link_tool_launcher() {
  local tools_bin=""
  local tool_home=""
  local candidate=""

  tools_bin="$(agent_tools_bin_dir)"
  tool_home="$(runtime_tool_home pi)"
  candidate="$tool_home/node_modules/.bin/pi"
  mkdir -p "$tools_bin"
  [ -x "$candidate" ] || return 1
  ln -sf "$candidate" "$tools_bin/pi"
}

pi_npm_install() {
  local install_home="$1"
  local install_dir="$2"
  local package="@earendil-works/pi-coding-agent@${PI_CODING_AGENT_VERSION:-latest}"

  pi_require_node_version "22.19.0"
  command -v npm >/dev/null 2>&1 || die "npm is required to install Pi"
  mkdir -p "$install_home" "$install_dir"
  npm install --prefix "$install_home" "$package"
  pi_link_tool_launcher || die "pi npm install finished but launcher was not found under $install_home/node_modules/.bin"
  pi_command_path >/dev/null 2>&1 || die "pi launcher was not found in $(agent_tools_bin_dir)"
}

agent_runtime_run() {
  local runtime="$1"
  shift

  [ "$runtime" = "pi" ] || die "unsupported runtime adapter: $runtime"
  local -a pi_args=("$@")
  local ollama_base_url=""
  local model=""
  local launch_model=""
  local ollama_model=""

  case "$RUN_MODE" in
    online)
      die "Pi runtime does not support agentctl online/auth mode yet"
      ;;
  esac

  model="${MODEL_OVERRIDE:-$PI_LOCAL_MODEL}"
  ollama_base_url="$(ollama_resolve_base_url)"
  pi_ensure_models_file "$ollama_base_url" "$model"

  if [ "${#pi_args[@]}" -eq 0 ]; then
    pi_args=(--model "$(pi_model_arg "$model")")
    launch_model="$(pi_model_arg "$model")"
  elif [ -n "$MODEL_OVERRIDE" ] && ! has_explicit_runtime_model "${pi_args[@]}"; then
    pi_args=(--model "$(pi_model_arg "$MODEL_OVERRIDE")" "${pi_args[@]}")
    launch_model="$(pi_model_arg "$MODEL_OVERRIDE")"
  elif has_explicit_runtime_model "${pi_args[@]}"; then
    launch_model="$(runtime_model_arg_value "${pi_args[@]}")"
  else
    launch_model="$(pi_model_arg "$model")"
  fi
  case "$launch_model" in
    ollama/*) ollama_model="${launch_model#ollama/}" ;;
    */*) ollama_model="" ;;
    *) ollama_model="$launch_model" ;;
  esac
  [ -n "$ollama_model" ] && ollama_require_model "$ollama_base_url" "$ollama_model"

  PI_TELEMETRY="${PI_TELEMETRY:-0}" \
    PI_OFFLINE="${PI_OFFLINE:-1}" \
    PI_SKIP_VERSION_CHECK="${PI_SKIP_VERSION_CHECK:-1}" \
    exec "$(pi_command_path)" "${pi_args[@]}"
}

agent_runtime_install() {
  local runtime="$1"
  local install_home=""
  local install_dir=""

  [ "$runtime" = "pi" ] || die "unsupported runtime adapter: $runtime"
  install_home="$(runtime_tool_home "$runtime")"
  install_dir="$(agent_tools_bin_dir)"
  pi_npm_install "$install_home" "$install_dir"
  if [ "${AGENTCTL_SKIP_PREFERRED_SET:-0}" != "1" ]; then
    preferred_set "$runtime"
  fi
}

agent_runtime_update() {
  local runtime="$1"
  local install_home=""
  local install_dir=""

  [ "$runtime" = "pi" ] || die "unsupported runtime adapter: $runtime"
  install_home="$(runtime_tool_home "$runtime")"
  install_dir="$(agent_tools_bin_dir)"
  pi_npm_install "$install_home" "$install_dir"
}

agent_runtime_reset_config() {
  local runtime="$1"
  local config_dir="${2:-}"
  local models_file=""
  local ollama_base_url=""
  local model="$PI_LOCAL_MODEL"

  [ "$runtime" = "pi" ] || die "unsupported runtime adapter: $runtime"
  models_file="$(pi_models_file)"
  printf 'Warning: resetting Pi configuration will replace ~/.pi/agent/models.json and may remove custom providers, models, and runtime preference.\n' >&2
  mkdir -p "$(dirname "$models_file")"
  if [ -n "$config_dir" ] && [ -f "$config_dir/models.json" ]; then
    cp "$config_dir/models.json" "$models_file"
  else
    ollama_base_url="$(ollama_resolve_base_url)"
    pi_write_models "$models_file" "$ollama_base_url" "$model"
  fi
  rm -f "$USER_RUNTIME_FILE"
}

agent_runtime_state_paths() {
  local runtime="$1"

  [ "$runtime" = "pi" ] || die "unsupported runtime adapter: $runtime"
  [ -e "$(pi_agent_dir)" ] && printf '%s\n' ".pi/agent"
}

agent_runtime_auth_read() {
  local runtime="$1"

  [ "$runtime" = "pi" ] || die "unsupported runtime adapter: $runtime"
  die "Pi runtime does not support agentctl-managed auth yet"
}

agent_runtime_auth_write() {
  local runtime="$1"

  [ "$runtime" = "pi" ] || die "unsupported runtime adapter: $runtime"
  die "Pi runtime does not support agentctl-managed auth yet"
}

agent_runtime_auth_login() {
  local runtime="$1"

  [ "$runtime" = "pi" ] || die "unsupported runtime adapter: $runtime"
  die "Pi runtime does not support agentctl-managed auth yet"
}
