#!/usr/bin/env bash
# Isolate production functions that may call die/exit or replace traps.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
compat_load_agentctl
case "$1" in
  refresh_container_file|refresh_container_tree) function_name="$1"; shift; "$function_name" "$@" ;;
  *) compat_fail 'Unsupported function invocation' ;;
esac
