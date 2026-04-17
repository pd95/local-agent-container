#!/usr/bin/env bash

office_feature_state_dir() {
  printf '%s\n' "${AGENTCTL_FEATURE_STATE_DIR:-/var/lib/agentctl/features}/office"
}

office_feature_marker() {
  printf '%s/install-complete\n' "$(office_feature_state_dir)"
}

office_feature_venv_dir() {
  printf '%s\n' "${AGENTCTL_FEATURE_OFFICE_VENV_DIR:-${VIRTUAL_ENV:-/opt/venv}}"
}

office_feature_profile_dir() {
  printf '%s\n' "${AGENTCTL_FEATURE_OFFICE_PROFILE_DIR:-/etc/profile.d}"
}

office_feature_require_root() {
  if [ "${AGENTCTL_FEATURE_OFFICE_SKIP_ROOT_CHECK:-0}" = "1" ]; then
    return 0
  fi
  [ "$(id -u)" = "0" ] || die "office feature install requires root (use: agentctl feature install office)"
}

office_feature_require_python_base() {
  local venv_dir

  venv_dir="$(office_feature_venv_dir)"
  [ -x "$venv_dir/bin/pip" ] || die "office feature currently targets agent-python and expects a writable venv at $venv_dir"
}

office_apk() {
  if [ -n "${AGENTCTL_FEATURE_OFFICE_APK_CMD:-}" ]; then
    "${AGENTCTL_FEATURE_OFFICE_APK_CMD}" "$@"
  else
    apk "$@"
  fi
}

office_npm() {
  if [ -n "${AGENTCTL_FEATURE_OFFICE_NPM_CMD:-}" ]; then
    "${AGENTCTL_FEATURE_OFFICE_NPM_CMD}" "$@"
  else
    npm "$@"
  fi
}

office_chown() {
  if [ -n "${AGENTCTL_FEATURE_OFFICE_CHOWN_CMD:-}" ]; then
    "${AGENTCTL_FEATURE_OFFICE_CHOWN_CMD}" "$@"
  else
    chown "$@"
  fi
}

office_feature_installed() {
  [ -f "$(office_feature_marker)" ]
}

agent_feature_installed() {
  office_feature_installed
}

agent_feature_install() {
  local feature="$1"
  local venv_dir profile_dir state_dir

  [ "$feature" = "office" ] || die "unsupported feature adapter: $feature"
  if office_feature_installed; then
    printf '%s\n' "feature already installed: office"
    return 0
  fi

  office_feature_require_root
  office_feature_require_python_base

  venv_dir="$(office_feature_venv_dir)"
  profile_dir="$(office_feature_profile_dir)"
  state_dir="$(office_feature_state_dir)"

  office_apk add --no-cache \
    ca-certificates openssh-client \
    fd \
    build-base python3-dev musl-dev \
    fontconfig ttf-dejavu \
    freetype libpng jpeg zlib \
    py3-numpy py3-pandas py3-matplotlib py3-pytest \
    py3-pypdf py3-pdfminer py3-mupdf \
    py3-reportlab py3-pillow py3-openpyxl py3-xlsxwriter \
    poppler-utils tesseract-ocr qpdf ghostscript pandoc-cli

  office_npm install -g pptxgenjs \
    --omit=dev \
    --no-fund \
    --no-audit

  mkdir -p "$profile_dir"
  printf '%s\n' \
    'export NODE_PATH=/usr/lib/node_modules:/usr/local/lib/node_modules' \
    >"$profile_dir/node_path.sh"
  chmod 0644 "$profile_dir/node_path.sh"

  "$venv_dir/bin/pip" install --no-cache-dir \
    python-docx python-pptx xlrd pdfplumber

  office_chown -R coder:coder "$venv_dir"

  mkdir -p "$state_dir"
  printf '%s\n' "office feature installed" >"$(office_feature_marker)"
}

agent_feature_remove() {
  local feature="$1"

  [ "$feature" = "office" ] || die "unsupported feature adapter: $feature"
  printf '%s\n' "feature not implemented yet: office" >&2
  return 1
}

agent_feature_update() {
  local feature="$1"

  [ "$feature" = "office" ] || die "unsupported feature adapter: $feature"
  printf '%s\n' "feature not implemented yet: office" >&2
  return 1
}
