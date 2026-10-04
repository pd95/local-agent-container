#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
COMPAT_WORK_DIR="$(compat_tmpdir work)"
export COMPAT_WORK_DIR
compat_load_agentctl
. "$COMPAT_DIR/cases.sh"
trap compat_worker_cleanup EXIT
trap 'exit 130' INT TERM HUP
case " $COMPAT_CASES " in *" $1 "*) "compat_test_$1" ;; *) compat_fail "Unknown test: $1" ;; esac
