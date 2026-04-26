#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE_NAME="${IMAGE_NAME:-agent-plain}"
readonly DEFAULT_RUNTIME_FILE="/etc/agentctl/preferred-runtime"
readonly USER_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agentctl"
readonly USER_RUNTIME_FILE="${USER_CONFIG_DIR}/preferred-runtime"
readonly RUNTIME_CONFIG_JSON="${AGENTCTL_RUNTIME_CONFIG_JSON-}"
readonly MODEL_OVERRIDE="${AGENTCTL_MODEL_OVERRIDE:-}"
readonly RUN_MODE="${AGENTCTL_RUN_MODE:-local}"
readonly RUNTIME_REGISTRY_DIR="${AGENTCTL_RUNTIME_REGISTRY_DIR:-/etc/agentctl/runtimes.d}"
readonly RUNTIME_ADAPTER_DIR="${AGENTCTL_RUNTIME_ADAPTER_DIR:-/usr/local/lib/agentctl/runtimes}"
readonly FEATURE_REGISTRY_DIR="${AGENTCTL_FEATURE_REGISTRY_DIR:-/etc/agentctl/features.d}"
readonly FEATURE_ADAPTER_DIR="${AGENTCTL_FEATURE_ADAPTER_DIR:-/usr/local/lib/agentctl/features}"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

runtime_default() {
  if [ -f "$DEFAULT_RUNTIME_FILE" ]; then
    tr -d '[:space:]' <"$DEFAULT_RUNTIME_FILE"
    return
  fi
  printf '%s\n' codex
}

runtime_preferred() {
  if [ -n "${AGENTCTL_PREFERRED_RUNTIME:-}" ]; then
    printf '%s\n' "$AGENTCTL_PREFERRED_RUNTIME"
    return
  fi

  if [ -f "$USER_RUNTIME_FILE" ]; then
    tr -d '[:space:]' <"$USER_RUNTIME_FILE"
    return
  fi

  runtime_default
}

has_explicit_runtime_model() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -m|-m=*|--model|--model=*) return 0 ;;
    esac
  done
  return 1
}

ensure_user_config_dir() {
  mkdir -p "$USER_CONFIG_DIR"
  if [ "$(id -u)" -eq 0 ]; then
    chown "$(home_owner)" "$USER_CONFIG_DIR"
  fi
}

home_owner() {
  stat -c '%u:%g' "$HOME" 2>/dev/null \
    || stat -f '%u:%g' "$HOME" 2>/dev/null \
    || printf '%s\n' "coder:coder"
}

runtime_manifest_path() {
  local runtime="$1"
  local path="${RUNTIME_REGISTRY_DIR}/${runtime}.json"

  [ -f "$path" ] || return 1
  printf '%s\n' "$path"
}

runtime_adapter_path() {
  local runtime="$1"
  local path="${RUNTIME_ADAPTER_DIR}/${runtime}.sh"

  [ -f "$path" ] || return 1
  printf '%s\n' "$path"
}

feature_manifest_path() {
  local feature="$1"
  local path="${FEATURE_REGISTRY_DIR}/${feature}.json"

  [ -f "$path" ] || return 1
  printf '%s\n' "$path"
}

feature_adapter_path() {
  local feature="$1"
  local path="${FEATURE_ADAPTER_DIR}/${feature}.sh"

  [ -f "$path" ] || return 1
  printf '%s\n' "$path"
}

runtime_manifest_string() {
  local runtime="$1" key="$2"
  local manifest

  manifest="$(runtime_manifest_path "$runtime")" || return 1
  jq -er "$key // empty" "$manifest"
}

runtime_manifest_json() {
  local runtime="$1" key="$2"
  local manifest

  manifest="$(runtime_manifest_path "$runtime")" || return 1
  jq -c "$key // []" "$manifest"
}

feature_manifest_string() {
  local feature="$1" key="$2"
  local manifest

  manifest="$(feature_manifest_path "$feature")" || return 1
  jq -er "$key // empty" "$manifest"
}

feature_manifest_json() {
  local feature="$1" key="$2"
  local manifest

  manifest="$(feature_manifest_path "$feature")" || return 1
  jq -c "$key // []" "$manifest"
}

runtime_known() {
  runtime_manifest_path "$1" >/dev/null 2>&1
}

feature_known() {
  feature_manifest_path "$1" >/dev/null 2>&1
}

runtime_ids() {
  local path

  [ -d "$RUNTIME_REGISTRY_DIR" ] || return 0
  for path in "$RUNTIME_REGISTRY_DIR"/*.json; do
    [ -e "$path" ] || continue
    basename "$path" .json
  done | sort
}

feature_ids() {
  local path

  [ -d "$FEATURE_REGISTRY_DIR" ] || return 0
  for path in "$FEATURE_REGISTRY_DIR"/*.json; do
    [ -e "$path" ] || continue
    basename "$path" .json
  done | sort
}

runtime_ids_installed() {
  local runtime

  while IFS= read -r runtime; do
    [ -n "$runtime" ] || continue
    if runtime_command_exists "$runtime"; then
      printf '%s\n' "$runtime"
    fi
  done < <(runtime_ids)
}

feature_ids_installed() {
  local feature

  while IFS= read -r feature; do
    [ -n "$feature" ] || continue
    if [ "$(feature_installed_json "$feature")" = "true" ]; then
      printf '%s\n' "$feature"
    fi
  done < <(feature_ids)
}

runtime_command_name() {
  runtime_manifest_string "$1" '.command'
}

runtime_command_path() {
  local runtime="$1"
  local command_name=""
  local candidate=""

  command_name="$(runtime_command_name "$runtime")" || return 1
  if command -v "$command_name" >/dev/null 2>&1; then
    command -v "$command_name"
    return 0
  fi
  for candidate in "$HOME/.local/bin/$command_name" "$HOME/bin/$command_name"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

runtime_install_method() {
  runtime_manifest_string "$1" '.install_method'
}

runtime_default_config_dir() {
  runtime_manifest_string "$1" '.default_config_dir'
}

runtime_auth_formats_json() {
  runtime_manifest_json "$1" '.auth_formats'
}

runtime_capabilities_json() {
  runtime_manifest_json "$1" '.capabilities'
}

runtime_commands_json() {
  runtime_manifest_json "$1" '.commands'
}

runtime_launch_configs_json() {
  local runtime="$1"
  local manifest

  manifest="$(runtime_manifest_path "$runtime")" || return 1
  jq -c '.launch_configs // {}' "$manifest"
}

feature_display_name() {
  feature_manifest_string "$1" '.display_name'
}

feature_install_method() {
  feature_manifest_string "$1" '.install_method'
}

feature_description() {
  feature_manifest_string "$1" '.description'
}

feature_capabilities_json() {
  feature_manifest_json "$1" '.capabilities'
}

feature_commands_json() {
  feature_manifest_json "$1" '.commands'
}

runtime_command_exists() {
  runtime_command_path "$1" >/dev/null 2>&1
}

runtime_installed_json() {
  local runtime="$1"
  if runtime_command_exists "$runtime"; then
    printf '%s\n' true
  else
    printf '%s\n' false
  fi
}

ensure_runtime_known() {
  local runtime="$1"
  runtime_known "$runtime" || die "unsupported runtime: $runtime"
}

ensure_feature_known() {
  local feature="$1"
  feature_known "$feature" || die "unsupported feature: $feature"
}

reset_runtime_hooks() {
  unset -f \
    agent_runtime_run \
    agent_runtime_install \
    agent_runtime_update \
    agent_runtime_reset_config \
    agent_runtime_state_paths \
    agent_runtime_auth_read \
    agent_runtime_auth_write \
    agent_runtime_auth_login \
    >/dev/null 2>&1 || true
}

reset_feature_hooks() {
  unset -f \
    agent_feature_installed \
    agent_feature_install \
    agent_feature_remove \
    agent_feature_update \
    >/dev/null 2>&1 || true
}

load_runtime_adapter() {
  local runtime="$1"
  local adapter

  ensure_runtime_known "$runtime"
  adapter="$(runtime_adapter_path "$runtime")" || die "missing runtime adapter: $runtime"
  reset_runtime_hooks
  # shellcheck source=/dev/null
  . "$adapter"
}

load_feature_adapter() {
  local feature="$1"
  local adapter

  ensure_feature_known "$feature"
  adapter="$(feature_adapter_path "$feature")" || die "missing feature adapter: $feature"
  reset_feature_hooks
  # shellcheck source=/dev/null
  . "$adapter"
}

ensure_runtime_installed() {
  local runtime="$1"
  ensure_runtime_known "$runtime"
  runtime_command_exists "$runtime" && return 0
  die "runtime not installed: $runtime (run: agent.sh runtime install $runtime)"
}

feature_installed_json() {
  local feature="$1"

  ensure_feature_known "$feature"
  load_feature_adapter "$feature"
  if agent_feature_installed "$feature"; then
    printf '%s\n' true
  else
    printf '%s\n' false
  fi
}

run_runtime() {
  local runtime="$1"
  shift

  ensure_runtime_installed "$runtime"
  load_runtime_adapter "$runtime"
  agent_runtime_run "$runtime" "$@"
}

runtime_config_json() {
  local config_json="$RUNTIME_CONFIG_JSON"

  if [ -z "$config_json" ]; then
    config_json='{}'
  fi

  printf '%s' "$config_json" | jq -c '
    if type == "object" then
      with_entries(.value |= if . == null then "" else tostring end)
    else
      error("runtime config must be an object")
    end
  ' 2>/dev/null || die "invalid runtime launch config JSON"
}

runtime_config_value() {
  local key="$1"
  local default_value="${2:-}"
  local value=""

  value="$(runtime_config_json | jq -er --arg key "$key" '.[$key] // empty' 2>/dev/null || true)"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' "$default_value"
}

runtime_config_enabled() {
  local key="$1"
  local value=""

  value="$(runtime_config_value "$key")"
  case "$value" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

ollama_detect_gateway() {
  local route_file="${AGENTCTL_OLLAMA_ROUTE_FILE:-/proc/net/route}"

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

ollama_resolve_base_url() {
  local gateway=""
  local api_url=""
  local ollama_port="11434"

  command -v curl >/dev/null 2>&1 || die "Missing curl required for local Ollama connectivity checks"
  gateway="$(ollama_detect_gateway)"
  [ -n "$gateway" ] || die "Unable to determine the container host gateway for local Ollama"
  api_url="http://${gateway}:${ollama_port}/api/version"
  if curl -fsS --max-time 3 "$api_url" >/dev/null 2>&1; then
    printf 'http://%s:%s\n' "$gateway" "$ollama_port"
    return 0
  fi

  die "Local Ollama is not reachable from the container.

Tried:
- Detected host gateway: $api_url

Expose or proxy Ollama onto the container network.
See README.md 'Local model connectivity'.

Host-side fixes:
- Start a second Ollama listener:
  OLLAMA_HOST=${gateway} ollama serve

- Proxy localhost with socat (needs \`brew install socat\`):
  socat TCP-LISTEN:${ollama_port},fork,bind=${gateway} TCP:127.0.0.1:${ollama_port}"
}

json_runtime_info() {
  local runtime="$1"
  local installed_json preferred_json commands_json capabilities_json launch_configs_json

  ensure_runtime_known "$runtime"
  installed_json="$(runtime_installed_json "$runtime")"
  commands_json="$(runtime_commands_json "$runtime")"
  capabilities_json="$(runtime_capabilities_json "$runtime")"
  launch_configs_json="$(runtime_launch_configs_json "$runtime")"
  if [ "$(runtime_preferred)" = "$runtime" ]; then
    preferred_json=true
  else
    preferred_json=false
  fi

  jq -n \
    --arg runtime "$runtime" \
    --arg image "$IMAGE_NAME" \
    --arg preferred "$(runtime_preferred)" \
    --arg launcher "/usr/local/bin/agent.sh run" \
    --arg command_name "$(runtime_command_name "$runtime")" \
    --arg install_method "$(runtime_install_method "$runtime")" \
    --arg config_dir "$(runtime_default_config_dir "$runtime")" \
    --argjson auth_formats "$(runtime_auth_formats_json "$runtime")" \
    --argjson capabilities "$capabilities_json" \
    --argjson commands "$commands_json" \
    --argjson launch_configs "$launch_configs_json" \
    --argjson installed "$installed_json" \
    --argjson selected "$preferred_json" \
    '{
      runtime: $runtime,
      image: $image,
      installed: $installed,
      preferred: $selected,
      preferred_runtime: $preferred,
      launcher: $launcher,
      command: $command_name,
      install_method: $install_method,
      auth_formats: $auth_formats,
      capabilities: $capabilities,
      commands: $commands,
      launch_configs: $launch_configs,
      default_config_dir: $config_dir,
      phase: 2
    }'
}

json_runtime_capabilities() {
  local runtime="$1"
  local capabilities_json launch_configs_json

  ensure_runtime_known "$runtime"
  capabilities_json="$(runtime_capabilities_json "$runtime")"
  launch_configs_json="$(runtime_launch_configs_json "$runtime")"
  jq -n \
    --arg runtime "$runtime" \
    --argjson auth_formats "$(runtime_auth_formats_json "$runtime")" \
    --argjson capabilities "$capabilities_json" \
    --argjson commands "$(runtime_commands_json "$runtime")" \
    --argjson launch_configs "$launch_configs_json" \
    '{
      runtime: $runtime,
      auth_formats: $auth_formats,
      capabilities: $capabilities,
      commands: $commands,
      launch_configs: $launch_configs
    }'
}

json_feature_info() {
  local feature="$1"
  local installed_json commands_json capabilities_json

  ensure_feature_known "$feature"
  installed_json="$(feature_installed_json "$feature")"
  commands_json="$(feature_commands_json "$feature")"
  capabilities_json="$(feature_capabilities_json "$feature")"

  jq -n \
    --arg feature "$feature" \
    --arg image "$IMAGE_NAME" \
    --arg display_name "$(feature_display_name "$feature")" \
    --arg install_method "$(feature_install_method "$feature")" \
    --arg description "$(feature_description "$feature")" \
    --argjson commands "$commands_json" \
    --argjson capabilities "$capabilities_json" \
    --argjson installed "$installed_json" \
    '{
      feature: $feature,
      image: $image,
      display_name: $display_name,
      installed: $installed,
      install_method: $install_method,
      description: $description,
      capabilities: $capabilities,
      commands: $commands
    }'
}

json_system_manifest() {
  local package_manager packages_json runtimes_json features_json default_runtime preferred_runtime

  if command -v apk >/dev/null 2>&1; then
    package_manager=apk
    packages_json="$(apk info -q 2>/dev/null | sort -u | jq -R . | jq -s .)"
  elif command -v dpkg-query >/dev/null 2>&1; then
    package_manager=dpkg
    packages_json="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort -u | jq -R . | jq -s .)"
  else
    package_manager=unknown
    packages_json='[]'
  fi
  runtimes_json="$(runtime_ids_installed | jq -R . | jq -s .)"
  features_json="$(feature_ids_installed | jq -R . | jq -s .)"
  default_runtime="$(runtime_default)"
  preferred_runtime="$(runtime_preferred)"

  jq -n \
    --arg package_manager "$package_manager" \
    --argjson packages "$packages_json" \
    --argjson installed_runtimes "$runtimes_json" \
    --argjson installed_features "$features_json" \
    --arg default_runtime "$default_runtime" \
    --arg preferred_runtime "$preferred_runtime" \
    '{
      package_manager: $package_manager,
      packages: $packages,
      installed_runtimes: $installed_runtimes,
      installed_features: $installed_features,
      default_runtime: $default_runtime,
      preferred_runtime: $preferred_runtime
    }'
}

state_unique_paths() {
  awk 'NF && !seen[$0]++'
}

state_runtime_paths() {
  local runtime="$1"

  ensure_runtime_known "$runtime"
  load_runtime_adapter "$runtime"
  if declare -F agent_runtime_state_paths >/dev/null 2>&1; then
    agent_runtime_state_paths "$runtime"
  fi
}

state_legacy_paths() {
  local codex_home_dir="${HOME}/.codex"
  local claude_home_dir="${HOME}/.claude"
  local claude_home_state_file="${HOME}/.claude.json"

  [ -e "$codex_home_dir" ] && printf '%s\n' ".codex"
  [ -e "$claude_home_dir" ] && printf '%s\n' ".claude"
  [ -e "$claude_home_state_file" ] && printf '%s\n' ".claude.json"
}

state_export_paths() {
  local installed_runtimes=""

  [ -e "$USER_CONFIG_DIR" ] && printf '%s\n' ".config/agentctl"
  installed_runtimes="$(runtime_ids_installed)"
  if [ -n "$installed_runtimes" ]; then
    printf '%s\n' "$installed_runtimes" | while IFS= read -r runtime; do
      [ -n "$runtime" ] || continue
      state_runtime_paths "$runtime"
    done
  else
    state_legacy_paths
  fi
}

state_import_paths() {
  local installed_runtimes=""

  printf '%s\n' ".config/agentctl"
  installed_runtimes="$(runtime_ids_installed)"
  if [ -n "$installed_runtimes" ]; then
    printf '%s\n' "$installed_runtimes" | while IFS= read -r runtime; do
      [ -n "$runtime" ] || continue
      state_runtime_paths "$runtime"
    done
  else
    printf '%s\n' ".codex" ".claude" ".claude.json"
  fi
}

state_export() {
  local -a paths=()
  local path=""

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    paths+=("$path")
  done < <(state_export_paths | state_unique_paths)

  if [ "${#paths[@]}" -eq 0 ]; then
    return 0
  fi

  tar -C "$HOME" -cf - "${paths[@]}"
}

state_import() {
  local import_file=""
  local path=""

  if [ -t 0 ]; then
    return 0
  fi

  import_file="$(mktemp)"
  cat >"$import_file"
  if [ ! -s "$import_file" ]; then
    rm -f "$import_file"
    return 0
  fi
  if ! tar -tf "$import_file" >/dev/null 2>&1; then
    rm -f "$import_file"
    die "invalid state import archive"
  fi

  mkdir -p "$HOME"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -rf "$HOME/$path"
  done < <(state_import_paths | state_unique_paths)
  tar -C "$HOME" -xf "$import_file"
  rm -f "$import_file"
}

auth_read() {
  local runtime="$1" key="$2"
  ensure_runtime_known "$runtime"
  load_runtime_adapter "$runtime"
  agent_runtime_auth_read "$runtime" "$key"
}

auth_write() {
  local runtime="$1" key="$2" value="${3:-}"
  ensure_runtime_known "$runtime"
  load_runtime_adapter "$runtime"
  agent_runtime_auth_write "$runtime" "$key" "$value"
}

auth_login() {
  local runtime="$1"
  ensure_runtime_installed "$runtime"
  load_runtime_adapter "$runtime"
  agent_runtime_auth_login "$runtime"
}

feature_list() {
  feature_ids
}

feature_install() {
  local feature="${1:-}"

  ensure_feature_known "$feature"
  load_feature_adapter "$feature"
  if ! printf '%s' "$(feature_capabilities_json "$feature")" | jq -e '(.install // false) == true' >/dev/null; then
    die "feature does not support install: $feature"
  fi
  agent_feature_install "$feature"
}

feature_remove() {
  local feature="${1:-}"

  ensure_feature_known "$feature"
  load_feature_adapter "$feature"
  if ! printf '%s' "$(feature_capabilities_json "$feature")" | jq -e '(.remove // false) == true' >/dev/null; then
    die "feature does not support remove: $feature"
  fi
  agent_feature_remove "$feature"
}

feature_update() {
  local feature="${1:-}"

  ensure_feature_known "$feature"
  load_feature_adapter "$feature"
  if ! printf '%s' "$(feature_capabilities_json "$feature")" | jq -e '(.update // false) == true' >/dev/null; then
    die "feature does not support update: $feature"
  fi
  agent_feature_update "$feature"
}

preferred_get() {
  runtime_preferred
}

preferred_set() {
  local runtime="${1:-}"
  ensure_runtime_installed "$runtime"
  ensure_user_config_dir
  printf '%s\n' "$runtime" >"$USER_RUNTIME_FILE"
  if [ "$(id -u)" -eq 0 ]; then
    chown "$(home_owner)" "$USER_RUNTIME_FILE"
  fi
}

runtime_list() {
  runtime_ids_installed
}

runtime_install() {
  local runtime="${1:-}"
  ensure_runtime_known "$runtime"
  load_runtime_adapter "$runtime"
  agent_runtime_install "$runtime"
}

runtime_update() {
  local runtime="${1:-}"
  ensure_runtime_known "$runtime"
  load_runtime_adapter "$runtime"
  agent_runtime_update "$runtime"
}

runtime_reset_config() {
  local runtime="${1:-}"
  ensure_runtime_known "$runtime"
  load_runtime_adapter "$runtime"
  agent_runtime_reset_config "$runtime" "$(runtime_default_config_dir "$runtime")"
}

refresh_agent() {
  jq -n \
    --arg preferred "$(runtime_preferred)" \
    --argjson runtimes "$(runtime_ids | jq -R . | jq -s .)" \
    '{status: "ok", preferred_runtime: $preferred, runtimes: $runtimes}'
}

usage() {
  cat <<'EOF'
Usage:
  agent.sh help
  agent.sh run [codex args...]
  agent.sh version
  agent.sh refresh
  agent.sh runtime list
  agent.sh feature list
  agent.sh preferred get
  agent.sh preferred set codex
  agent.sh runtime info codex
  agent.sh runtime capabilities codex
  agent.sh runtime install codex
  agent.sh runtime update codex
  agent.sh runtime reset-config codex
  agent.sh feature info office
  agent.sh feature install office
  agent.sh feature remove office
  agent.sh auth login codex
  agent.sh auth read codex json_refresh_token
  agent.sh auth write codex json_refresh_token [VALUE]
  agent.sh state export
  agent.sh state import
  agent.sh system manifest
EOF
}

main() {
  local command="${1:-help}"
  shift || true

  case "$command" in
    help|-h|--help)
      usage
      ;;
    run)
      run_runtime "$(runtime_preferred)" "$@"
      ;;
    version)
      printf '%s\n' "agent.sh phase2"
      ;;
    refresh)
      refresh_agent
      ;;
    runtime)
      case "${1:-}" in
        list)
          runtime_list
          ;;
        info)
          json_runtime_info "${2:-}"
          ;;
        capabilities)
          json_runtime_capabilities "${2:-}"
          ;;
        install)
          runtime_install "${2:-}"
          ;;
        update)
          runtime_update "${2:-}"
          ;;
        reset-config)
          runtime_reset_config "${2:-}"
          ;;
        *)
          die "unknown runtime command: ${1:-}"
          ;;
      esac
      ;;
    feature)
      case "${1:-}" in
        list)
          feature_list
          ;;
        info)
          json_feature_info "${2:-}"
          ;;
        install)
          feature_install "${2:-}"
          ;;
        remove)
          feature_remove "${2:-}"
          ;;
        update)
          feature_update "${2:-}"
          ;;
        *)
          die "unknown feature command: ${1:-}"
          ;;
      esac
      ;;
    preferred)
      case "${1:-}" in
        get)
          preferred_get
          ;;
        set)
          preferred_set "${2:-}"
          ;;
        *)
          die "unknown preferred command: ${1:-}"
          ;;
      esac
      ;;
    auth)
      case "${1:-}" in
        login)
          auth_login "${2:-}"
          ;;
        read)
          auth_read "${2:-}" "${3:-}"
          ;;
        write)
          auth_write "${2:-}" "${3:-}" "${4:-}"
          ;;
        *)
          die "unknown auth command: ${1:-}"
          ;;
      esac
      ;;
    state)
      case "${1:-}" in
        export)
          state_export
          ;;
        import)
          state_import
          ;;
        *)
          die "unknown state command: ${1:-}"
          ;;
      esac
      ;;
    system)
      case "${1:-}" in
        manifest)
          json_system_manifest
          ;;
        *)
          die "unknown system command: ${1:-}"
          ;;
      esac
      ;;
    *)
      die "unknown command: $command"
      ;;
  esac
}

main "$@"
