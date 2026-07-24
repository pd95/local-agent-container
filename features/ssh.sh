#!/usr/bin/env bash

ssh_feature_state_dir() {
  printf '%s\n' "${AGENTCTL_FEATURE_STATE_DIR:-/var/lib/agentctl/features}/ssh"
}

ssh_feature_marker() {
  printf '%s/install-complete\n' "$(ssh_feature_state_dir)"
}

ssh_feature_require_root() {
  if [ "${AGENTCTL_FEATURE_SSH_SKIP_ROOT_CHECK:-0}" = "1" ]; then
    return 0
  fi
  [ "$(id -u)" = "0" ] || die "ssh feature install requires root (use: agentctl feature install ssh)"
}

ssh_feature_installed() {
  [ -f "$(ssh_feature_marker)" ] && command -v ssh >/dev/null 2>&1
}

ssh_feature_apk() {
  if [ -n "${AGENTCTL_FEATURE_SSH_APK_CMD:-}" ]; then
    "${AGENTCTL_FEATURE_SSH_APK_CMD}" "$@"
  else
    apk "$@"
  fi
}

ssh_feature_apt_get() {
  if [ -n "${AGENTCTL_FEATURE_SSH_APT_GET_CMD:-}" ]; then
    "${AGENTCTL_FEATURE_SSH_APT_GET_CMD}" "$@"
  else
    apt-get "$@"
  fi
}

agent_feature_installed() {
  ssh_feature_installed
}

agent_feature_install() {
  local feature="$1"
  local state_dir=""

  [ "$feature" = "ssh" ] || die "unsupported feature adapter: $feature"
  if ssh_feature_installed; then
    printf '%s\n' "feature already installed: ssh"
    return 0
  fi
  ssh_feature_require_root

  if command -v apk >/dev/null 2>&1 || [ -n "${AGENTCTL_FEATURE_SSH_APK_CMD:-}" ]; then
    ssh_feature_apk add --no-cache ca-certificates openssh-client
  elif command -v apt-get >/dev/null 2>&1 || [ -n "${AGENTCTL_FEATURE_SSH_APT_GET_CMD:-}" ]; then
    DEBIAN_FRONTEND=noninteractive ssh_feature_apt_get update
    DEBIAN_FRONTEND=noninteractive ssh_feature_apt_get install -y --no-install-recommends ca-certificates openssh-client
  else
    die "ssh feature requires Alpine apk or Debian/Ubuntu apt-get"
  fi

  command -v ssh >/dev/null 2>&1 || die "ssh feature installation completed but the ssh command is unavailable"
  state_dir="$(ssh_feature_state_dir)"
  mkdir -p "$state_dir"
  printf '%s\n' "ssh feature installed" >"$(ssh_feature_marker)"
}

agent_feature_remove() {
  local feature="$1"
  [ "$feature" = "ssh" ] || die "unsupported feature adapter: $feature"
  printf '%s\n' "feature not implemented yet: ssh" >&2
  return 1
}

agent_feature_update() {
  local feature="$1"
  [ "$feature" = "ssh" ] || die "unsupported feature adapter: $feature"
  printf '%s\n' "feature not implemented yet: ssh" >&2
  return 1
}
