#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=tests/testlib.sh
. "$SCRIPT_DIR/testlib.sh"

trap cleanup EXIT

load_codexctl_functions() {
  local harness

  harness="$(mktemp "${TMPDIR:-/tmp}/codexctl-unit.XXXXXX")"
  register_dir_cleanup "$harness"

  sed -e "s#^SCRIPT_DIR=.*#SCRIPT_DIR=\"$TEST_ROOT\"#" \
    -e '/^cmd="${1:-}"/,$d' \
    "$CODEXCTL" >"$harness"
  # shellcheck source=/dev/null
  . "$harness"
}

test_run_profile_wires_selected_profile() {
  begin_test "run_cmd wires --profile into the launched runtime contract"

  load_codexctl_functions

  local captured_pre_exec=""
  local captured_cmd=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  run_container() {
    captured_pre_exec="$9"
    shift 12
    captured_cmd="$(printf '%s\n' "$*")"
  }

  run_cmd --name unit-test-container --workdir "$workdir" --profile gemma

  [ "$captured_pre_exec" = "local_model_pre_exec" ] || fail "Expected local_model_pre_exec, got: $captured_pre_exec"
  printf '%s\n' "$captured_cmd" | grep -Fxq '__agentctl_default_runtime__ local gemma' || fail "Expected runtime contract command to include local mode and profile gemma, got: $captured_cmd"
}

test_run_skips_local_model_preflight_for_non_local_runtime() {
  begin_test "run without --cmd skips local-model preflight when runtime does not support it"

  load_codexctl_functions

  local captured_pre_exec=""
  local captured_cmd=""
  local workdir

  workdir="$(new_workdir)"

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  container_has_agent_contract() { return 0; }
  container_supports_capability() { return 1; }
  run_container() {
    captured_pre_exec="$9"
    shift 12
    captured_cmd="$(printf '%s\n' "$*")"
  }

  run_cmd --name unit-test-container --workdir "$workdir"

  [ -z "$captured_pre_exec" ] || fail "Expected no pre-exec hook for unsupported local-model mode, got: $captured_pre_exec"
  printf '%s\n' "$captured_cmd" | grep -Fxq '__agentctl_default_runtime__ local gpt-oss' || fail "Expected runtime contract command for default profile, got: $captured_cmd"
}

test_run_rejects_default_container_creation_when_legacy_container_exists() {
  begin_test "run fails fast when only the legacy default container exists for the workdir"

  load_codexctl_functions

  local workdir
  local status=0
  local out_file
  workdir="$(new_workdir)"

  require_container() { return 0; }
  container_exists() {
    [ "$1" = "codex-$(basename "$workdir")" ]
  }

  out_file="$(mktemp "${TMPDIR:-/tmp}/codexctl-legacy-default.XXXXXX")"
  if (run_cmd --workdir "$workdir" >"$out_file" 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || fail "Expected run_cmd to fail when only legacy default exists, got status $status"
  RUN_OUTPUT="$(cat "$out_file" 2>/dev/null || printf '')"
  rm -f "$out_file"
  assert_contains "Found legacy container codex-$(basename "$workdir") for this workdir"
  assert_contains "migrate --name codex-$(basename "$workdir")"
}

test_local_model_preflight_info_defaults_missing_defaults_dir_arg() {
  begin_test "local_model_preflight_info tolerates callers that omit defaults_dir"

  load_codexctl_functions

  CONTAINER_CMD=container
  container() {
    [ "$1" = "exec" ] || fail "Unexpected container invocation: $*"
    shift
    [ "$1" = "-i" ] || fail "Expected exec -i invocation, got: $*"
    shift
    [ "$1" = "unit-test-container" ] || fail "Expected unit-test-container, got: $1"
    shift
    while [ "$#" -gt 0 ] && [[ "$1" == setpriv* || "$1" == --* ]]; do
      shift
    done
    [ "$1" = "sh" ] || fail "Expected shell invocation, got: $*"
    cat >/dev/null
  }

  local status=0
  if (local_model_preflight_info unit-test-container gpt-oss /home/coder/.codex >/dev/null 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 0 ] || fail "Expected omitted defaults_dir arg to be tolerated, got status $status"
}

test_run_openai_rejected_for_non_openai_runtime() {
  begin_test "run --openai fails for runtimes without openai-mode support"

  load_codexctl_functions

  local status=0
  local out
  local out_file

  require_container() { return 0; }
  container_has_agent_contract() { return 0; }
  container_supports_capability() { return 1; }

  out_file="$(mktemp "${TMPDIR:-/tmp}/codexctl-openai-runtime.XXXXXX")"
  if (openai_pre_exec unit-test-container >"$out_file" 2>&1); then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 1 ] || fail "Expected --openai command to fail, got status $status"
  out="$(cat "$out_file" 2>/dev/null || printf '')"
  rm -f "$out_file"
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | grep -Fq "Selected runtime does not support --openai mode" \
      || fail "Expected unsupported openai-mode error, got: $out"
  fi
}

test_run_help_reports_profile_default() {
  begin_test "run help reports the actual default profile"

  run_capture "$CODEXCTL" run --help
  assert_status 0
  assert_contains "--profile NAME  Codex profile to use (default: gpt-oss)"
}

test_agentctl_wrapper_usage_banner() {
  begin_test "agentctl wrapper prints its own command name"

  run_capture "$TEST_ROOT/agentctl" --help
  assert_status 0
  assert_contains "Usage: agentctl <command> [options]"
}

test_agent_env_metadata_helpers() {
  begin_test "agent metadata helpers read values from agent.env"

  load_codexctl_functions

  CONTAINER_CMD=container
container() {
        case "$1" in
      exec)
        shift
        if [ "$1" = "unit-test-container" ]; then
          shift
        fi
        while [ "$#" -gt 0 ] && [[ "$1" == setpriv* || "$1" == --* ]]; do
          shift
        done
        case "$1" in
          test)
            return 0
            ;;
          cat)
            cat <<'EOF'
AGENT_HOME_DIR=/home/coder/.codex
AGENT_CONFIG_DIR=/home/coder/.codex
AGENT_AUTH_PATH=/home/coder/.codex/auth.json
AGENT_IMAGE_DEFAULTS_DIR=/etc/agentctl/defaults
AGENT_KEYCHAIN_SERVICE=agent-openai-auth
AGENT_KEYCHAIN_ACCOUNT=device-auth-openAI
AGENT_SUPPORTS_OPENAI_MODE=1
EOF
            ;;
          *)
            fail "Unexpected container exec: $*"
            ;;
        esac
        ;;
      ls)
        cat <<'EOF'
ID IMAGE
unit-test-container codex:latest
EOF
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  [ "$(container_agent_home_dir unit-test-container)" = "/home/coder/.codex" ] || fail "Expected AGENT_HOME_DIR metadata"
  [ "$(container_agent_defaults_dir unit-test-container)" = "/etc/agentctl/defaults" ] || fail "Expected AGENT_IMAGE_DEFAULTS_DIR metadata"
  [ "$(container_agent_keychain_service unit-test-container)" = "agent-openai-auth" ] || fail "Expected AGENT_KEYCHAIN_SERVICE metadata"
  container_supports_capability unit-test-container openai-mode || fail "Expected openai-mode capability"
}

test_runtime_contract_switches_metadata_paths_and_capabilities() {
  begin_test "runtime contract switches image metadata path and capability lookups"

  load_codexctl_functions

  CONTAINER_CMD=container
  local contract_present=1
  container() {
    case "$1" in
      exec)
        shift
        if [ "$1" = "unit-test-container" ]; then
          shift
        fi
        while [ "$#" -gt 0 ] && [[ "$1" == setpriv* || "$1" == --* ]]; do
          shift
        done
        case "$1" in
          test)
            [ "$contract_present" -eq 1 ]
            ;;
          cat)
            cat <<'EOF'
AGENT_IMAGE_DEFAULTS_DIR=/etc/agentctl/defaults
AGENT_SUPPORTS_OPENAI_MODE=1
AGENT_SUPPORTS_UPDATE=0
EOF
            ;;
          *)
            fail "Unexpected container exec: $*"
            ;;
        esac
        ;;
      ls)
        cat <<'EOF'
ID IMAGE
unit-test-container agent-codex:latest
EOF
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  [ "$(container_agent_image_md_path unit-test-container)" = "/etc/agentctl/image.md" ] || fail "Expected contract image metadata path"
  container_supports_capability unit-test-container openai-mode || fail "Expected contract capability lookup for openai-mode"
  if container_supports_capability unit-test-container update; then
    fail "Expected disabled update capability from contract metadata"
  fi

  contract_present=0
  [ "$(container_agent_image_md_path unit-test-container)" = "$DEFAULT_AGENT_IMAGE_MD_PATH" ] || fail "Expected legacy image metadata fallback without contract"
}

test_container_auth_format_helpers() {
  begin_test "agent auth metadata helpers support AGENT_AUTH_FORMAT"

  load_codexctl_functions

  local current_format=""
  container_agent_env_value() {
    local _name="$1"
    local key="$2"
    local fallback="$3"
    if [ "$key" = "AGENT_AUTH_FORMAT" ] && [ -n "$current_format" ]; then
      printf '%s\n' "$current_format"
      return 0
    fi
    printf '%s\n' "$fallback"
  }

  current_format=""
  [ "$(container_auth_format unit-test-container)" = "json_refresh_token" ] || fail "Expected default auth format fallback"
  current_format="directory_tarball"
  [ "$(container_auth_format unit-test-container)" = "directory_tarball" ] || fail "Expected explicit AGENT_AUTH_FORMAT"
}

test_image_family_aliases_support_legacy_and_tagged_names() {
  begin_test "image family helpers handle legacy names and tags"

  load_codexctl_functions

  [ "$(image_family_preferred codex)" = "agent-codex" ] || fail "Expected codex base family to map to agent-codex"
  [ "$(image_family_preferred codex-python)" = "agent-python" ] || fail "Expected codex-python to map to agent-python"
  [ "$(image_family_preferred codex-python:20260313-154500)" = "agent-python:20260313-154500" ] || fail "Expected tagged codex-python to map to tagged agent-python"
  [ "$(image_family_preferred agent)" = "agent-codex" ] || fail "Expected agent shorthand to map to agent-codex"
  [ "$(image_family_legacy_codex agent-python)" = "codex-python" ] || fail "Expected agent-python to map to codex-python legacy"
  [ "$(image_family_legacy_codex agent-python:20260313-154500)" = "codex-python:20260313-154500" ] || fail "Expected tagged agent-python to map to tagged codex legacy"

  image_exists() {
    [ "$1" = "agent-python:20260313-154500" ] || return 1
    return 0
  }
  [ "$(image_family_for_runtime codex-python:20260313-154500)" = "agent-python:20260313-154500" ] || fail "Expected runtime resolver to prefer tagged agent image"
  image_exists() {
    [ "$1" = "codex-python:20260313-154500" ] || return 1
    return 0
  }
  [ "$(image_family_for_runtime codex-python:20260313-154500)" = "codex-python:20260313-154500" ] || fail "Expected runtime resolver to fallback to legacy tagged family"
}

test_matrix_runtime_image_helpers() {
  begin_test "matrix images resolve to runtime variants and their dockerfiles"

  load_codexctl_functions

  [ "$(image_family_preferred agent-python-claude)" = "agent-python-claude" ] || fail "Expected agent-python-claude to map to itself"
  [ "$(image_family_preferred agent-office-claude:20260313-154500)" = "agent-office-claude:20260313-154500" ] || fail "Expected tagged matrix preferred family to preserve tag"
  [ "$(image_family_legacy_codex agent-swift-claude)" = "codex-swift-claude" ] || fail "Expected legacy conversion for matrix name to keep toolchain+runtime"
  [ "$(image_family_legacy_codex agent-swift-claude:20260313-154500)" = "codex-swift-claude:20260313-154500" ] || fail "Expected tagged legacy matrix conversion"

  image_exists() { [ "$1" = "agent-python-claude:20260313-154500" ] || return 1; }
  [ "$(image_family_for_runtime agent-python-claude:20260313-154500)" = "agent-python-claude:20260313-154500" ] || fail "Expected runtime resolver to pick matrix image when available"

  image_exists() { [ "$1" = "codex-python-claude:20260313-154500" ] || return 1; }
  [ "$(image_family_for_runtime agent-python-claude:20260313-154500)" = "codex-python-claude:20260313-154500" ] || fail "Expected matrix runtime resolver to fall back to legacy codex image"
}

test_legacy_migration_target_mapping() {
  begin_test "migrate maps legacy codex images to matching agent targets"

  load_codexctl_functions

  [ "$(legacy_migration_target_image codex)" = "agent-codex" ] || fail "Expected codex to migrate to agent-codex"
  [ "$(legacy_migration_target_image codex-python:latest)" = "agent-python" ] || fail "Expected codex-python to migrate to agent-python"
  [ "$(legacy_migration_target_image codex-office)" = "agent-office" ] || fail "Expected codex-office to migrate to agent-office"
  [ "$(legacy_migration_target_image codex-swift)" = "agent-swift" ] || fail "Expected codex-swift to migrate to agent-swift"
  [ "$(legacy_migration_target_name codex-local-codex-container)" = "agent-local-codex-container" ] || fail "Expected codex-* name to migrate to matching agent-* name"

  if legacy_migration_target_image agent-codex >/dev/null 2>&1; then
    fail "Expected agent-codex to be rejected for migrate"
  fi
}

test_matrix_dockerfiles_publish_runtime_metadata() {
  begin_test "matrix dockerfiles publish agentctl metadata and runtime-specific AGENTS paths"

  grep -Fq 'ln -sf /etc/codexctl/image.md /etc/agentctl/image.md' "$TEST_ROOT/DockerFile.python" \
    || fail "Expected DockerFile.python to publish /etc/agentctl/image.md"
  grep -Fq 'claude) mkdir -p /home/coder/.claude \' "$TEST_ROOT/DockerFile.python" \
    || fail "Expected DockerFile.python to initialize Claude config directory"
  grep -Fq 'ln -sf /etc/agentctl/image.md /home/coder/.claude/AGENTS.md ;;' "$TEST_ROOT/DockerFile.python" \
    || fail "Expected DockerFile.python to link Claude AGENTS.md into /home/coder/.claude"

  grep -Fq 'ln -sf /etc/codexctl/image.md /etc/agentctl/image.md' "$TEST_ROOT/DockerFile.office" \
    || fail "Expected DockerFile.office to publish /etc/agentctl/image.md"
  grep -Fq 'claude) mkdir -p /home/coder/.claude \' "$TEST_ROOT/DockerFile.office" \
    || fail "Expected DockerFile.office to initialize Claude config directory"
  grep -Fq 'ln -sf /etc/agentctl/image.md /home/coder/.claude/AGENTS.md ;;' "$TEST_ROOT/DockerFile.office" \
    || fail "Expected DockerFile.office to link Claude AGENTS.md into /home/coder/.claude"

  grep -Fq 'ln -sf /etc/codexctl/image.md /etc/agentctl/image.md' "$TEST_ROOT/DockerFile.swift" \
    || fail "Expected DockerFile.swift to publish /etc/agentctl/image.md"
  grep -Fq 'ln -sf /etc/agentctl/image.md /home/coder/.claude/AGENTS.md ;;' "$TEST_ROOT/DockerFile.swift" \
    || fail "Expected DockerFile.swift to link Claude AGENTS.md into /home/coder/.claude"
}

test_claude_images_publish_default_onboarding_state() {
  begin_test "Claude-capable images publish default claude.json state"

  grep -Fq 'COPY --chown=coder:coder claude.json /home/coder/.claude/settings.json' "$TEST_ROOT/DockerFile.claude" \
    || fail "Expected DockerFile.claude to bake in /home/coder/.claude/settings.json"
  grep -Fq 'cp /home/coder/.claude/settings.json /etc/agentctl/defaults/claude.json' "$TEST_ROOT/DockerFile.claude" \
    || fail "Expected DockerFile.claude to publish claude.json defaults"

  grep -Fq 'COPY --chown=root:root claude.json /tmp/claude.json' "$TEST_ROOT/DockerFile.swift" \
    || fail "Expected DockerFile.swift to stage claude.json for Claude runtime builds"
  grep -Fq 'cp /tmp/claude.json /home/coder/.claude/settings.json' "$TEST_ROOT/DockerFile.swift" \
    || fail "Expected DockerFile.swift to install claude.json into /home/coder/.claude/settings.json for Claude runtime builds"
  grep -Fq 'cp /tmp/claude.json /etc/agentctl/defaults/claude.json' "$TEST_ROOT/DockerFile.swift" \
    || fail "Expected DockerFile.swift to publish claude.json defaults for Claude runtime builds"
}

test_migrate_cmd_plans_backup_and_forces_overwrite_config() {
  begin_test "migrate plans host backup and upgrade --overwrite-config"

  load_codexctl_functions

  local temp_dir
  local old_pwd
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-migrate.XXXXXX")"
  register_dir_cleanup "$temp_dir"
  old_pwd="$PWD"
  cd "$temp_dir"

  require_container() { return 0; }
  container_exists() { [ "$1" = "codex-legacy-container" ]; }
  image_exists() { [ "$1" = "agent-python" ]; }
  container_upgrade_info() {
    printf 'codex-python:latest\t%s\trw\t8\t8192 MB\n' "$temp_dir"
  }
  CONTAINER_CMD=container
  container() {
    case "$1" in
      inspect)
        cat <<EOF
ignored
EOF
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }

  run_capture migrate_cmd --name codex-legacy-container --dry-run
  cd "$old_pwd"

  assert_status 0
  assert_contains "Migration plan for codex-legacy-container"
  assert_contains "target name:   agent-legacy-container"
  assert_contains "current image: codex-python:latest"
  assert_contains "target image:  agent-python"
  assert_contains "host backup:   "
  assert_contains "/codex-backup/codex-legacy-container-codex-home.tar"
  assert_contains "migrate mode:  restore ~/.codex, then overwrite config defaults"
}

test_openai_auth_sync_opaque_format() {
  begin_test "openai auth sync path uses checksums for opaque auth formats"

  load_codexctl_functions

  local test_auth_format="opaque_blob"
  local container_payload="token-v1"
  local keychain_payload="token-v1"
  local load_calls=0
  local store_calls=0

  ensure_keychain() { return 0; }
  auth_signature() {
    cat | sha256sum | awk '{print $1}'
  }

  container_agent_env_value() {
    local key="$2"
    local fallback="$3"
    case "$key" in
      AGENT_AUTH_FORMAT) printf '%s\n' "${test_auth_format}" ;;
      AGENT_AUTH_PATH) printf '%s\n' "/home/coder/.codex/auth.json" ;;
      AGENT_KEYCHAIN_SERVICE) printf '%s\n' "${fallback}" ;;
      AGENT_KEYCHAIN_ACCOUNT) printf '%s\n' "${fallback}" ;;
      *) printf '%s\n' "$fallback" ;;
    esac
  }
  CONTAINER_CMD=container
  container() {
    if [ "$1" != "exec" ]; then
      fail "Unexpected container invocation: $*"
    fi
    shift
    if [ "$1" = "unit-test-container" ]; then
      shift
    fi
    while [ "$#" -gt 0 ] && [[ "$1" == setpriv* || "$1" == --* ]]; do
      shift
    done
    case "$1" in
      test)
        return 0
        ;;
      cat)
        printf '%s' "$container_payload"
        ;;
      *)
        fail "Unexpected container exec payload: $*"
        ;;
    esac
  }
  keychain_script_run() {
    local cmd="$3"
    case "$cmd" in
      read)
        printf '%s' "$keychain_payload"
        ;;
      load-to-container)
        load_calls=$((load_calls + 1))
        ;;
      store-from-container)
        store_calls=$((store_calls + 1))
        ;;
      verify)
        return 0
        ;;
      *)
        fail "Unexpected keychain action: $cmd"
        ;;
    esac
  }

  sync_openai_auth_to_container unit-test-container
  sync_openai_auth_from_container unit-test-container
  [ "$load_calls" -eq 0 ] || fail "Expected no container load with matching signatures, got: $load_calls"
  [ "$store_calls" -eq 0 ] || fail "Expected no keychain store with matching signatures, got: $store_calls"

  container_payload="token-v2"
  sync_openai_auth_to_container unit-test-container
  sync_openai_auth_from_container unit-test-container
  [ "$load_calls" -eq 1 ] || fail "Expected one container load after mismatch, got: $load_calls"
  [ "$store_calls" -eq 1 ] || fail "Expected one keychain store after mismatch, got: $store_calls"
}

test_codex_auth_wrapper_execs_generic_script() {
  begin_test "codex-auth-keychain wrapper delegates to the generic script"

  run_capture bash -c 'SCRIPT_DIR="$(pwd)"; PATH="$SCRIPT_DIR:$PATH"; export KEYCHAIN_SERVICE_NAME=test KEYCHAIN_ACCOUNT_NAME=test; sed -n "1,5p" codex-auth-keychain.sh | grep -F "agent-auth-keychain.sh"'
  assert_status 0
  assert_contains "agent-auth-keychain.sh"
}

test_ls_filters_non_codex_containers() {
  begin_test "ls_cmd hides non-agent runtime containers"

  load_codexctl_functions

  require_container() { return 0; }
  container_list_all() {
    cat <<'EOF'
ID                               IMAGE                                                OS     ARCH   STATE    ADDR              CPUS  MEMORY   STARTED
converter                        docker.io/library/debian:latest                      linux  amd64  stopped                    4     1024 MB
buildkit                         ghcr.io/apple/container-builder-shim/builder:0.11.0  linux  arm64  running  192.168.64.10/24  2     2048 MB  2026-04-06T10:40:58Z
agent-codex                      agent-codex:latest                                  linux  arm64  stopped                    4     1024 MB
agent-python                     agent-python:latest                                  linux  arm64  stopped                    4     1024 MB
codex-python                     codex-python:latest                                  linux  arm64  stopped                    4     1024 MB
codex-local-codex-container      codex:latest                                         linux  arm64  running  192.168.64.12/24  4     1024 MB  2026-04-06T10:59:42Z
codex-custom                     my-team/codex-custom:latest                          linux  arm64  stopped                    4     1024 MB
EOF
  }

  run_capture ls_cmd
  assert_status 0
  assert_contains "ID                               IMAGE"
  assert_contains "agent-codex                      agent-codex:latest"
  assert_contains "agent-python                     agent-python:latest"
  assert_contains "codex-python                     codex-python:latest"
  assert_contains "codex-local-codex-container      codex:latest"
  assert_contains "codex-custom                     my-team/codex-custom:latest"
  assert_not_contains "buildkit"
  assert_not_contains "converter"
}

test_upgrade_backup_support_check() {
  begin_test "upgrade backup support check requires export support"

  load_codexctl_functions

  local fake_dir
  local fake_container
  local old_path

  fake_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-fake-container.XXXXXX")"
  register_dir_cleanup "$fake_dir"
  fake_container="$fake_dir/container"
  old_path="$PATH"

  cat >"$fake_container" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = "export" ] && [ "${2:-}" = "--help" ]; then
  cat <<'OUT'
OVERVIEW: Export a container's filesystem as a tar archive
OPTIONS:
  -o, --output <output>   Pathname for the saved container filesystem
OUT
  exit 0
fi

exit 0
EOF
  chmod +x "$fake_container"

  PATH="$fake_dir:$old_path"
  CONTAINER_CMD=container

  run_capture require_container_backup_support
  assert_status 0
}

test_run_rejects_resource_flags_for_existing_container() {
  begin_test "run rejects --cpu/--mem for existing containers"

  local fake_dir
  local fake_container
  local old_path

  fake_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-fake-container.XXXXXX")"
  register_dir_cleanup "$fake_dir"
  fake_container="$fake_dir/container"
  old_path="$PATH"

  cat >"$fake_container" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "ls" ] && [ "${2:-}" = "-a" ]; then
  cat <<'OUT'
ID                               IMAGE
unit-test-container              codex:latest
OUT
  exit 0
fi

exit 0
EOF
  chmod +x "$fake_container"

  PATH="$fake_dir:$old_path"

  run_capture "$CODEXCTL" run --name unit-test-container --workdir "$TEST_ROOT" --cpu 4 --mem 8G --cmd true
  assert_status 1
  assert_contains "Error: --cpu and --mem only apply when creating a new container."
  assert_contains "codexctl upgrade --name unit-test-container --image $DEFAULT_IMAGE --cpu 4 --mem 8G"
}

test_upgrade_uses_explicit_resource_overrides() {
  begin_test "upgrade prefers explicit --cpu/--mem over inspected values"

  load_codexctl_functions

  local create_args=""
  local start_calls=0
  local stop_calls=0
  local rm_calls=0

  require_container() { return 0; }
  default_name() { printf 'unit-test-container\n'; }
  require_container_backup_support() { return 0; }
  container_exists() { [ "$1" = "unit-test-container" ]; }
  container_running() { return 1; }
  image_exists() { return 0; }
  codex_agents_state() { printf 'missing\n'; }
  backup_codex_config() { :; }
  restore_codex_config() { :; }
  sanitize_image_name() { printf '%s\n' "$1"; }
  build_backup_image_from_export() { :; }
  date() { printf '20260406120000\n'; }
  trap() { :; }

  CONTAINER_CMD=container
  container() {
    case "$1" in
      inspect)
        printf 'placeholder\n'
        ;;
      create)
        shift
        create_args="$(printf '%s\n' "$*")"
        ;;
      start)
        start_calls=$((start_calls + 1))
        ;;
      stop)
        stop_calls=$((stop_calls + 1))
        ;;
      rm)
        rm_calls=$((rm_calls + 1))
        ;;
      export)
        fail "export should not be called for --no-backup"
        ;;
      *)
        fail "Unexpected container invocation: $*"
        ;;
    esac
  }
  container_upgrade_info() {
    printf 'codex\t%s\trw\t2\t4G\n' "$TEST_ROOT"
  }

  run_capture upgrade_cmd --name unit-test-container --cpu 6 --mem 12G --no-backup
  assert_status 0
  assert_contains "Upgrade complete: unit-test-container (backup skipped)"
  printf '%s\n' "$create_args" | grep -F -- "-c 6" >/dev/null || fail "Expected create args to include overridden cpu, got: $create_args"
  printf '%s\n' "$create_args" | grep -F -- "-m 12G" >/dev/null || fail "Expected create args to include overridden mem, got: $create_args"
  printf '%s\n' "$create_args" | grep -F -- "--name unit-test-container" >/dev/null || fail "Expected create args to include container name, got: $create_args"
  [ "$start_calls" -eq 2 ] || fail "Expected 2 start calls, got: $start_calls"
  [ "$stop_calls" -eq 2 ] || fail "Expected 2 stop calls, got: $stop_calls"
  [ "$rm_calls" -eq 1 ] || fail "Expected 1 rm call, got: $rm_calls"
}

test_cleanup_temp_dir_handles_read_only_trees() {
  begin_test "cleanup_temp_dir removes read-only extracted trees"

  load_codexctl_functions

  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexctl-cleanup.XXXXXX")"
  register_dir_cleanup "$temp_dir"

  mkdir -p "$temp_dir/rootfs/pkg"
  : >"$temp_dir/rootfs/pkg/file.txt"
  chmod 500 "$temp_dir/rootfs" "$temp_dir/rootfs/pkg"
  chmod 400 "$temp_dir/rootfs/pkg/file.txt"

  cleanup_temp_dir "$temp_dir"

  [ ! -e "$temp_dir" ] || fail "Expected cleanup_temp_dir to remove $temp_dir"
}

main() {
  log "Using codexctl at $CODEXCTL"

  test_run_profile_wires_selected_profile
  test_run_skips_local_model_preflight_for_non_local_runtime
  test_run_rejects_default_container_creation_when_legacy_container_exists
  test_local_model_preflight_info_defaults_missing_defaults_dir_arg
  test_run_openai_rejected_for_non_openai_runtime
  test_run_help_reports_profile_default
  test_agentctl_wrapper_usage_banner
  test_agent_env_metadata_helpers
  test_runtime_contract_switches_metadata_paths_and_capabilities
  test_container_auth_format_helpers
  test_image_family_aliases_support_legacy_and_tagged_names
  test_matrix_runtime_image_helpers
  test_legacy_migration_target_mapping
  test_matrix_dockerfiles_publish_runtime_metadata
  test_claude_images_publish_default_onboarding_state
  test_migrate_cmd_plans_backup_and_forces_overwrite_config
  test_openai_auth_sync_opaque_format
  test_codex_auth_wrapper_execs_generic_script
  test_ls_filters_non_codex_containers
  test_upgrade_backup_support_check
  test_run_rejects_resource_flags_for_existing_container
  test_upgrade_uses_explicit_resource_overrides
  test_cleanup_temp_dir_handles_read_only_trees

  log "PASS: all shell unit tests completed"
}

main "$@"
