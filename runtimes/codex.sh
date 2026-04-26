CODEX_DEFAULT_PROFILE="${AGENTCTL_CODEX_PROFILE:-gpt-oss}"

codex_home_dir() {
  printf '%s\n' "${HOME}/.codex"
}

codex_config_file() {
  printf '%s\n' "$(codex_home_dir)/config.toml"
}

codex_model_catalog_file() {
  printf '%s\n' "$(codex_home_dir)/local_models.json"
}

codex_auth_file() {
  printf '%s\n' "$(codex_home_dir)/auth.json"
}

codex_ensure_home_dir() {
  mkdir -p "$(codex_home_dir)"
}

codex_ensure_config_file() {
  local config_file=""

  codex_ensure_home_dir
  config_file="$(codex_config_file)"
  [ -f "$config_file" ] && return 0
  if [ -f /etc/codexctl/config.toml ]; then
    cp /etc/codexctl/config.toml "$config_file"
    return 0
  fi
  die "missing Codex config: $config_file"
}

codex_warn_mcp_config_reset() {
  local config_file="$1"
  local mcp_config=""

  [ -f "$config_file" ] || return 0
  mcp_config="$(awk '
    function is_header(line) {
      return line ~ /^\[[^]]+\][[:space:]]*$/
    }
    function is_mcp_header(line) {
      return line ~ /^\[mcp_servers\.[^]]+\][[:space:]]*$/
    }
    {
      if (is_header($0)) {
        in_mcp = is_mcp_header($0)
      }
      if (in_mcp) {
        print
      }
    }
  ' "$config_file")"
  if [ -n "$mcp_config" ]; then
    printf 'Existing Codex MCP configuration that reset-config will replace:\n%s\n' "$mcp_config" >&2
  fi
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

codex_arg_value() {
  local flag_short="$1"
  local flag_long="$2"
  shift 2
  local arg=""
  local previous=""

  for arg in "$@"; do
    if { [ -n "$flag_short" ] && [ "$previous" = "$flag_short" ]; } || { [ -n "$flag_long" ] && [ "$previous" = "$flag_long" ]; }; then
      printf '%s\n' "$arg"
      return 0
    fi
    case "$arg" in
      "$flag_short"=*)
        if [ -n "$flag_short" ]; then
          printf '%s\n' "${arg#*=}"
          return 0
        fi
        ;;
      "$flag_long"=*)
        printf '%s\n' "${arg#*=}"
        return 0
        ;;
    esac
    previous="$arg"
  done
  return 1
}

codex_profile_model() {
  local profile="$1"
  local config_file=""

  codex_ensure_config_file
  config_file="$(codex_config_file)"
  awk -v profile="$profile" '
    /^\[profiles\.[^]]+\][[:space:]]*$/ {
      current=$0
      sub(/^\[profiles\./, "", current)
      sub(/\][[:space:]]*$/, "", current)
      in_profile=(current == profile)
      next
    }
    /^\[[^]]+\][[:space:]]*$/ {
      in_profile=0
    }
    in_profile && /^[[:space:]]*model[[:space:]]*=/ {
      line=$0
      sub(/^[^"]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ' "$config_file"
}

codex_profile_provider() {
  local profile="$1"
  local config_file=""

  codex_ensure_config_file
  config_file="$(codex_config_file)"
  awk -v profile="$profile" '
    /^\[profiles\.[^]]+\][[:space:]]*$/ {
      current=$0
      sub(/^\[profiles\./, "", current)
      sub(/\][[:space:]]*$/, "", current)
      in_profile=(current == profile)
      next
    }
    /^\[[^]]+\][[:space:]]*$/ {
      in_profile=0
    }
    in_profile && /^[[:space:]]*model_provider[[:space:]]*=/ {
      line=$0
      sub(/^[^"]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ' "$config_file"
}

codex_require_myollama_profile() {
  local profile="$1"
  local provider=""

  provider="$(codex_profile_provider "$profile")"
  [ "$provider" = "myollama" ] || die "Codex profile must use model_provider \"myollama\" for local Ollama mode: $profile"
}

codex_effective_model() {
  local profile="$1"
  shift
  local model=""

  model="$(codex_arg_value -m --model "$@" || true)"
  if [ -n "$model" ]; then
    printf '%s\n' "$model"
    return 0
  fi
  model="$(codex_profile_model "$profile")"
  [ -n "$model" ] || die "unable to determine Codex model for profile: $profile"
  printf '%s\n' "$model"
}

codex_update_ollama_base_url() {
  local ollama_base_url="$1"
  local config_file=""
  local tmp_file=""
  local openai_base_url="${ollama_base_url%/}/v1"

  codex_ensure_config_file
  config_file="$(codex_config_file)"
  tmp_file="$(mktemp)"
  awk -v provider="myollama" -v base_url="$openai_base_url" '
    BEGIN {
      section_header = "[model_providers." provider "]"
      in_provider = 0
      wrote_base_url = 0
    }
    /^\[[^]]+\][[:space:]]*$/ {
      if (in_provider && !wrote_base_url) {
        print "base_url = \"" base_url "\""
        wrote_base_url = 1
      }
      in_provider = ($0 == section_header)
      print
      next
    }
    in_provider && /^[[:space:]]*base_url[[:space:]]*=/ {
      print "base_url = \"" base_url "\""
      wrote_base_url = 1
      next
    }
    {
      print
    }
    END {
      if (in_provider && !wrote_base_url) {
        print "base_url = \"" base_url "\""
      }
    }
  ' "$config_file" >"$tmp_file"
  if ! awk -v provider="myollama" '
    BEGIN { section_header = "[model_providers." provider "]" }
    $0 == section_header { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$tmp_file"; then
    rm -f "$tmp_file"
    die "missing Codex model provider in config: myollama"
  fi
  if cmp -s "$tmp_file" "$config_file"; then
    rm -f "$tmp_file"
    return 0
  fi
  mv "$tmp_file" "$config_file" || {
    rm -f "$tmp_file"
    die "failed to update Codex config: $config_file"
  }
}

codex_parse_positive_int() {
  local value="$1"
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$value" -gt 0 ] || return 1
  printf '%s\n' "$value"
}

codex_show_model() {
  local ollama_base_url="$1"
  local model="$2"
  local show_file="$3"

  command -v jq >/dev/null 2>&1 || die "Missing jq required for Codex model metadata"
  command -v curl >/dev/null 2>&1 || die "Missing curl required for Codex model metadata"
  if ! jq -n --arg model "$model" '{model: $model}' \
    | curl -fsS --max-time 10 \
      -H 'Content-Type: application/json' \
      -d @- \
      "${ollama_base_url%/}/api/show" >"$show_file"; then
    die "failed to query Ollama model metadata for: $model"
  fi
  jq -e 'type == "object"' "$show_file" >/dev/null || die "invalid Ollama /api/show response for: $model"
}

codex_build_model_entry() {
  local model="$1"
  local show_file="$2"
  local entry_file="$3"
  local context_window=""
  local base_instructions=""
  local input_modalities=""
  local reasoning_levels=""
  local supports_reasoning_summaries="false"
  local reasoning_defaults=""

  context_window="$(jq -r '
    [ .model_info? // {} | to_entries[]
      | select(.key | test("\\.context_length$"))
      | .value
      | numbers
    ] | max // 0
  ' "$show_file")"
  if [ "$(jq -r '.details.format // ""' "$show_file")" != "safetensors" ]; then
    local num_ctx=""
    num_ctx="$(jq -r '
      (.parameters // "")
      | split("\n")[]
      | capture("^[[:space:]]*num_ctx[[:space:]]+(?<value>[0-9]+(?:\\.[0-9]+)?)")?
      | .value
      | tonumber
      | floor
    ' "$show_file" 2>/dev/null | tail -n 1 || true)"
    if [ -n "$num_ctx" ] && codex_parse_positive_int "$num_ctx" >/dev/null; then
      context_window="$num_ctx"
    fi
  fi
  if [ "$context_window" = "0" ]; then
    printf 'Warning: Ollama model metadata did not include a context length for %s; using context_window=0\n' "$model" >&2
  fi

  base_instructions="$(jq -r '.system // ""' "$show_file")"
  input_modalities="$(jq -c '
    if ((.capabilities // []) | index("vision")) then
      ["text", "image"]
    else
      ["text"]
    end
  ' "$show_file")"
  if jq -e '(.capabilities // []) | index("thinking")' "$show_file" >/dev/null; then
    supports_reasoning_summaries="true"
    reasoning_levels='[
      {"effort":"low","description":"Low reasoning effort"},
      {"effort":"medium","description":"Medium reasoning effort"},
      {"effort":"high","description":"High reasoning effort"}
    ]'
    reasoning_defaults='{
      "reasoning_summary_format": "none",
      "default_reasoning_summary": "auto",
      "default_reasoning_level": "medium"
    }'
  else
    reasoning_levels='[]'
    reasoning_defaults='{}'
  fi

  jq -n \
    --arg slug "$model" \
    --arg display_name "$model" \
    --arg base_instructions "$base_instructions" \
    --argjson context_window "$context_window" \
    --argjson input_modalities "$input_modalities" \
    --argjson supports_reasoning_summaries "$supports_reasoning_summaries" \
    --argjson supported_reasoning_levels "$reasoning_levels" \
    --argjson reasoning_defaults "$reasoning_defaults" \
    '({
      slug: $slug,
      display_name: $display_name,
      context_window: $context_window,
      apply_patch_tool_type: "function",
      shell_type: "default",
      visibility: "list",
      supported_in_api: true,
      priority: 0,
      truncation_policy: {
        mode: "bytes",
        limit: 10000
      },
      input_modalities: $input_modalities,
      base_instructions: $base_instructions,
      support_verbosity: true,
      default_verbosity: "low",
      supports_parallel_tool_calls: false,
      supports_reasoning_summaries: $supports_reasoning_summaries,
      supported_reasoning_levels: $supported_reasoning_levels,
      experimental_supported_tools: []
    } + $reasoning_defaults)' >"$entry_file"
}

codex_upsert_model_catalog() {
  local model="$1"
  local entry_file="$2"
  local tmp_dir="${3:-}"
  local catalog_file=""
  local catalog_tmp=""
  local updated_file=""
  local own_tmp_dir=0
  local changed_fields=""
  local status=""

  catalog_file="$(codex_model_catalog_file)"
  mkdir -p "$(dirname "$catalog_file")"
  if [ -z "$tmp_dir" ]; then
    tmp_dir="$(mktemp -d)"
    own_tmp_dir=1
    trap 'rm -rf "${tmp_dir:-}"' EXIT
  fi
  catalog_tmp="$tmp_dir/catalog.json"
  updated_file="$tmp_dir/updated.json"

  if [ -f "$catalog_file" ]; then
    jq '
      if type != "object" then
        error("catalog must be a JSON object")
      elif has("models") and (.models | type != "array") then
        error("catalog .models must be an array")
      elif has("models") then
        .
      else
        . + {models: []}
      end
    ' "$catalog_file" >"$catalog_tmp" || die "invalid Codex model catalog: $catalog_file"
  else
    printf '{ "models": [] }\n' >"$catalog_tmp"
  fi

  changed_fields="$(jq -r --slurpfile entry "$entry_file" --arg slug "$model" '
    ($entry[0]) as $new
    | (.models[]? | select(.slug == $slug)) as $old
    | if $old == null then
        ""
      else
        [ ([ $new | keys_unsorted[] ] + [
            "reasoning_summary_format",
            "default_reasoning_summary",
            "default_reasoning_level"
          ])[]
          | . as $key
          | select(($old | has($key)) or ($new | has($key)))
          | select(($old[$key] // null) != ($new[$key] // null))
        ] | join(",")
      end
  ' "$catalog_tmp")"

  status="$(jq -r --arg slug "$model" '.models[]? | select(.slug == $slug) | .slug' "$catalog_tmp" | head -n 1)"
  jq --slurpfile entry "$entry_file" '
    ($entry[0]) as $new
    | (.models | any(.slug == $new.slug)) as $exists
    | .models = (
        (.models | map(
          if .slug == $new.slug then
            del(.reasoning_summary_format, .default_reasoning_summary, .default_reasoning_level) + $new
          else
            .
          end
        ))
        + (if $exists then [] else [$new] end)
      )
  ' "$catalog_tmp" >"$updated_file"
  jq -e 'type == "object" and (.models | type == "array")' "$updated_file" >/dev/null || die "failed to build Codex model catalog"
  if [ -f "$catalog_file" ] && cmp -s "$updated_file" "$catalog_file"; then
    :
  else
    mv "$updated_file" "$catalog_file"
  fi
  if [ "$own_tmp_dir" -eq 1 ]; then
    rm -rf "$tmp_dir"
    trap - EXIT
  fi

  if [ -z "$status" ]; then
    printf 'added model metadata: %s\n' "$model" >&2
  elif [ -n "$changed_fields" ]; then
    printf 'updated model metadata: %s fields=%s\n' "$model" "$changed_fields" >&2
  else
    printf 'model metadata unchanged: %s\n' "$model" >&2
  fi
}

codex_prepare_local_ollama_model() {
  local profile="$1"
  shift
  local ollama_base_url=""
  local model=""
  local show_file=""
  local entry_file=""
  local tmp_dir=""

  codex_require_myollama_profile "$profile"
  ollama_base_url="$(ollama_resolve_base_url)"
  codex_update_ollama_base_url "$ollama_base_url"
  model="$(codex_effective_model "$profile" "$@")"
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir:-}"' EXIT
  show_file="$tmp_dir/show.json"
  entry_file="$tmp_dir/entry.json"
  codex_show_model "$ollama_base_url" "$model" "$show_file"
  codex_build_model_entry "$model" "$show_file" "$entry_file"
  codex_upsert_model_catalog "$model" "$entry_file" "$tmp_dir"
  rm -rf "$tmp_dir"
  trap - EXIT
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
    if [ "$RUN_MODE" = "local" ]; then
      profile="$(codex_arg_value "" --profile "${codex_args[@]}" || true)"
      profile="${profile:-$CODEX_DEFAULT_PROFILE}"
      codex_prepare_local_ollama_model "$profile" "${codex_args[@]}"
    fi
    exec codex "${codex_args[@]}"
  fi
  profile="${profile:-$(runtime_config_value profile "$CODEX_DEFAULT_PROFILE")}"
  if [ "$RUN_MODE" = "local" ]; then
    codex_prepare_local_ollama_model "$profile" "${codex_args[@]}"
  fi
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
  printf 'Warning: resetting Codex configuration will replace ~/.codex/config.toml, ~/.codex/local_models.json, ~/.codex/AGENTS.md, and may remove custom profiles, MCP servers, providers, local model metadata, and runtime preference.\n' >&2
  codex_warn_mcp_config_reset "$codex_dir/config.toml"
  cp "$config_dir/config.toml" "$codex_dir/config.toml"
  if [ -f "$config_dir/local_models.json" ]; then
    cp "$config_dir/local_models.json" "$codex_dir/local_models.json"
  else
    rm -f "$codex_dir/local_models.json"
  fi
  ln -sf "$config_dir/image.md" "$codex_dir/AGENTS.md"
  rm -f "$USER_RUNTIME_FILE"
}

agent_runtime_state_paths() {
  local runtime="$1"
  local codex_dir=""

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  codex_dir="$(codex_home_dir)"
  [ -e "$codex_dir" ] || return 0
  printf '%s\n' ".codex"
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
