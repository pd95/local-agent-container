CODEX_DEFAULT_PROFILE="${AGENTCTL_CODEX_PROFILE:-gpt-oss}"

codex_normalize_release() {
  case "$1" in
    ""|latest) printf '%s\n' latest ;;
    rust-v*) printf '%s\n' "${1#rust-v}" ;;
    v*) printf '%s\n' "${1#v}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

codex_resolve_release() {
  local release=""
  local release_json=""
  local resolved=""

  release="$(codex_normalize_release "${CODEX_RELEASE:-latest}")"
  if [ "$release" != "latest" ]; then
    printf '%s\n' "$release"
    return 0
  fi
  release_json="$(curl -fsSL https://api.github.com/repos/openai/codex/releases/latest)"
  resolved="$(printf '%s\n' "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"rust-v\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$resolved" ] || die "Failed to resolve the latest Codex release version"
  printf '%s\n' "$resolved"
}

codex_vendor_target() {
  local os=""
  local arch=""

  os="$(uname -s)"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="aarch64" ;;
    *) die "Unsupported architecture for Codex install: $(uname -m)" ;;
  esac

  case "$os:$arch" in
    Linux:aarch64) printf '%s\n' "aarch64-unknown-linux-musl" ;;
    Linux:x86_64) printf '%s\n' "x86_64-unknown-linux-musl" ;;
    Darwin:aarch64) printf '%s\n' "aarch64-apple-darwin" ;;
    Darwin:x86_64) printf '%s\n' "x86_64-apple-darwin" ;;
    *) die "Unsupported OS for Codex install: $os" ;;
  esac
}

codex_file_sha256() {
  local path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return 0
  fi
  die "sha256sum or shasum is required to verify Codex downloads"
}

codex_install_standalone_package_direct() {
  local install_home="$1"
  local install_dir="$2"
  local version=""
  local target=""
  local asset=""
  local base_url=""
  local tmp_dir=""
  local archive_path=""
  local checksum_path=""
  local expected_digest=""
  local actual_digest=""
  local release_name=""
  local release_dir=""
  local releases_dir=""
  local standalone_root=""
  local stage_release=""

  version="$(codex_resolve_release)"
  target="$(codex_vendor_target)"
  asset="codex-package-${target}.tar.gz"
  base_url="https://github.com/openai/codex/releases/download/rust-v${version}"
  tmp_dir="$(mktemp -d)"
  archive_path="$tmp_dir/$asset"
  checksum_path="$tmp_dir/codex-package_SHA256SUMS"
  standalone_root="$install_home/packages/standalone"
  releases_dir="$standalone_root/releases"
  release_name="${version}-${target}"
  release_dir="$releases_dir/$release_name"
  stage_release="$releases_dir/.staging.$release_name.$$"

  trap 'rm -rf "${tmp_dir:-}" "${stage_release:-}"' RETURN
  mkdir -p "$releases_dir" "$install_dir"
  curl -fsSL "$base_url/codex-package_SHA256SUMS" -o "$checksum_path"
  expected_digest="$(awk -v asset="$asset" '$2 == asset && $1 ~ /^[0-9a-fA-F]{64}$/ { print tolower($1); found = 1; exit } END { if (!found) exit 1 }' "$checksum_path" 2>/dev/null || true)"
  [ -n "$expected_digest" ] || die "Could not find SHA-256 digest for $asset in codex-package_SHA256SUMS"
  curl -fsSL "$base_url/$asset" -o "$archive_path"
  actual_digest="$(codex_file_sha256 "$archive_path")"
  [ "$actual_digest" = "$expected_digest" ] || die "Downloaded Codex archive checksum did not match expected digest"

  rm -rf "$stage_release"
  mkdir -p "$stage_release"
  tar -xzf "$archive_path" -C "$stage_release"
  chmod 0755 "$stage_release/bin/codex" "$stage_release/codex-path/rg"
  if [ -f "$stage_release/codex-resources/bwrap" ]; then
    chmod 0755 "$stage_release/codex-resources/bwrap"
  fi
  ln -sf "bin/codex" "$stage_release/codex"
  rm -rf "$release_dir"
  mv "$stage_release" "$release_dir"
  ln -sfn "$release_dir" "$standalone_root/current"
  ln -sfn "$standalone_root/current/bin/codex" "$install_dir/codex"
  rm -rf "$tmp_dir"
  trap - RETURN
}

codex_home_dir() {
  printf '%s\n' "${HOME}/.codex"
}

codex_config_file() {
  printf '%s\n' "$(codex_home_dir)/config.toml"
}

codex_profile_config_file() {
  local profile="$1"

  codex_profile_name_is_safe "$profile" || return 1
  printf '%s\n' "$(codex_home_dir)/${profile}.config.toml"
}

codex_profile_name_is_safe() {
  local profile="$1"

  case "$profile" in
    ''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-]*)
      return 1
      ;;
  esac
  return 0
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
  if [ -f "$config_file" ]; then
    codex_copy_missing_default_profile_configs
    return 0
  fi
  if [ -f /etc/codexctl/config.toml ]; then
    cp /etc/codexctl/config.toml "$config_file"
    codex_copy_missing_default_profile_configs
    return 0
  fi
  die "missing Codex config: $config_file"
}

codex_copy_missing_default_profile_configs() {
  local profile_config=""
  local target=""

  [ -d /etc/codexctl ] || return 0
  for profile_config in /etc/codexctl/*.config.toml; do
    [ -e "$profile_config" ] || continue
    target="$(codex_home_dir)/$(basename "$profile_config")"
    [ -f "$target" ] && continue
    cp "$profile_config" "$target"
  done
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
  local model=""

  codex_ensure_config_file
  model="$(codex_profile_value "$profile" model || true)"
  [ -n "$model" ] && printf '%s\n' "$model"
}

codex_profile_provider() {
  local profile="$1"
  local provider=""

  codex_ensure_config_file
  provider="$(codex_profile_value "$profile" model_provider || true)"
  [ -n "$provider" ] && printf '%s\n' "$provider"
}

codex_profile_value() {
  local profile="$1"
  local key="$2"
  local profile_file=""
  local value=""

  profile_file="$(codex_profile_config_file "$profile" || true)"
  if [ -n "$profile_file" ] && [ -f "$profile_file" ]; then
    value="$(codex_top_level_config_value "$profile_file" "$key")"
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  codex_legacy_profile_value "$profile" "$key"
}

codex_top_level_config_value() {
  local config_file="$1"
  local key="$2"

  awk -v key="$key" '
    /^\[[^]]+\][[:space:]]*$/ {
      in_section=1
      next
    }
    in_section {
      next
    }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      line=$0
      sub(/^[^"]*"/, "", line)
      sub(/".*$/, "", line)
      print line
      exit
    }
  ' "$config_file"
}

codex_legacy_profile_value() {
  local profile="$1"
  local key="$2"
  local config_file=""

  config_file="$(codex_config_file)"
  awk -v profile="$profile" -v key="$key" '
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
    in_profile && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
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
      apply_patch_tool_type: "freeform",
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
            if .apply_patch_tool_type == "function" then
              .apply_patch_tool_type = "freeform"
            else
              .
            end
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
  local codex_command=""
  local profile=""

  codex_command="$(runtime_command_path "$runtime")" || die "runtime not installed: $runtime (run: agent.sh runtime install $runtime)"
  export CODEX_HOME="$(codex_home_dir)"

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
      exec "$codex_command" "${codex_args[@]}"
      ;;
  esac
  if [ "${#codex_args[@]}" -gt 0 ] && codex_has_explicit_profile "${codex_args[@]}"; then
    if [ "$RUN_MODE" = "local" ]; then
      profile="$(codex_arg_value "" --profile "${codex_args[@]}" || true)"
      profile="${profile:-$CODEX_DEFAULT_PROFILE}"
      codex_prepare_local_ollama_model "$profile" "${codex_args[@]}"
    fi
    exec "$codex_command" "${codex_args[@]}"
  fi
  profile="${profile:-$(runtime_config_value profile "$CODEX_DEFAULT_PROFILE")}"
  if [ "$RUN_MODE" = "local" ]; then
    codex_prepare_local_ollama_model "$profile" "${codex_args[@]}"
  fi
  if [ "${#codex_args[@]}" -eq 0 ]; then
    exec "$codex_command" --profile "$profile"
  fi
  exec "$codex_command" --profile "$profile" "${codex_args[@]}"
}

agent_runtime_install() {
  local runtime="$1"
  local install_home=""
  local install_dir=""
  local install_log=""

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  install_home="$(runtime_tool_home "$runtime")"
  install_dir="$(agent_tools_bin_dir)"
  mkdir -p "$install_home" "$install_dir"
  install_log="$(mktemp)"
  if ! {
    curl -fsSL https://chatgpt.com/codex/install.sh | \
      CODEX_HOME="$install_home" \
      CODEX_INSTALL_DIR="$install_dir" \
      CODEX_NON_INTERACTIVE=1 \
      PATH="$install_dir:$PATH" \
      sh
  } >"$install_log" 2>&1; then
    if grep -Fq "Could not find Codex package or platform npm release assets" "$install_log"; then
      cat "$install_log" >&2
      printf '%s\n' "Falling back to direct Codex standalone package install." >&2
      codex_install_standalone_package_direct "$install_home" "$install_dir"
    else
      cat "$install_log" >&2
      rm -f "$install_log"
      return 1
    fi
  else
    cat "$install_log"
  fi
  rm -f "$install_log"
  runtime_command_path "$runtime" >/dev/null 2>&1 || die "codex installer finished but launcher was not found in $(agent_tools_bin_dir) or legacy user bin dirs"
  if [ "${AGENTCTL_SKIP_PREFERRED_SET:-0}" != "1" ]; then
    preferred_set "$runtime"
  fi
}

agent_runtime_update() {
  local runtime="$1"
  local install_home=""
  local install_dir=""

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  install_home="$(runtime_tool_home "$runtime")"
  install_dir="$(agent_tools_bin_dir)"
  mkdir -p "$install_home" "$install_dir"
  CODEX_HOME="$install_home" \
    CODEX_INSTALL_DIR="$install_dir" \
    PATH="$install_dir:$PATH" \
    "$(runtime_command_path "$runtime")" update
}

agent_runtime_reset_config() {
  local runtime="$1"
  local config_dir="$2"
  local codex_dir=""
  local profile_config=""

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  codex_dir="$(codex_home_dir)"
  codex_ensure_home_dir
  printf 'Warning: resetting Codex configuration will replace ~/.codex/config.toml, default ~/.codex/*.config.toml profiles, ~/.codex/local_models.json, ~/.codex/AGENTS.md, and may remove custom profiles, MCP servers, providers, local model metadata, and runtime preference.\n' >&2
  codex_warn_mcp_config_reset "$codex_dir/config.toml"
  cp "$config_dir/config.toml" "$codex_dir/config.toml"
  for profile_config in "$config_dir"/*.config.toml; do
    [ -e "$profile_config" ] || continue
    cp "$profile_config" "$codex_dir/"
  done
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
  local path=""

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  codex_dir="$(codex_home_dir)"
  [ -e "$codex_dir" ] || return 0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    printf '%s\n' ".codex/$path"
  done < <(
    cd "$codex_dir" && \
      find . -mindepth 1 -maxdepth 1 ! -name packages -exec basename {} \;
  )
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
  local codex_command=""

  [ "$runtime" = "codex" ] || die "unsupported runtime adapter: $runtime"
  codex_command="$(runtime_command_path "$runtime")" || die "runtime not installed: $runtime (run: agent.sh runtime install $runtime)"
  CODEX_HOME="$(codex_home_dir)" exec "$codex_command" login --device-auth
}
