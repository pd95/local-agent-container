#!/usr/bin/env bash
# Transparent adapter: no runtime behavior is mocked or substituted.
set -euo pipefail
: "${COMPAT_REAL_CONTAINER:?Missing real container executable}"
if [ "${1:-}" = create ]; then
  previous=""; generated=""; generator=""
  for argument in "$@"; do
    [ "$previous" != --name ] || generated="$argument"
    previous="$argument"
  done
  case "$generated" in
    agentctl-backup-validate-*|agentctl-system-manifest-*)
      # Production backup validation creates a temporary container internally.
      # Journal it too, so a killed test cannot lose ownership of that resource.
      listing="$(bash "$(dirname "$0")/supervise.sh" "${COMPAT_QUERY_TIMEOUT:-30}" "$COMPAT_REAL_CONTAINER" ls -a --quiet)"
      if printf '%s\n' "$listing" | grep -Fx "$generated" >/dev/null; then
        printf 'Backup validation name already exists: %s\n' "$generated" >&2; exit 1
      fi
      entry="$(mktemp "$COMPAT_JOURNAL/.pending.XXXXXXXX")"
      case "$generated" in
        agentctl-backup-validate-*) generator=validate_backup_image ;;
        agentctl-system-manifest-*) generator=image_system_manifest_json ;;
      esac
      jq -n --arg name "$generated" --arg test "$COMPAT_TEST_ID" --arg run "$COMPAT_RUN_ID" --arg generator "$generator" \
        '{type:"container",name:$name,test:$test,run:$run,generated_by:$generator}' >"$entry"
      mv "$entry" "$COMPAT_JOURNAL/resource.${entry##*.pending.}" ;;
  esac
fi
limit="${COMPAT_QUERY_TIMEOUT:-30}"
case "${1:-}" in
  create|run|start|stop|rm|delete|export) limit="${COMPAT_LIFECYCLE_TIMEOUT:-120}" ;;
  build) limit="${COMPAT_IMAGE_TIMEOUT:-600}" ;;
  image) case "${2:-}" in pull) limit="${COMPAT_IMAGE_TIMEOUT:-600}" ;; esac ;;
esac
exec bash "$(dirname "$0")/supervise.sh" "$limit" "$COMPAT_REAL_CONTAINER" "$@"
