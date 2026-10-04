#!/usr/bin/env bash
# Read-only process ancestry lookup, shared with the local safety regression test.
compat_descendants() {
  {
    if [ "$(uname -s)" = Darwin ]; then ps -axo pid=,ppid=
    else ps -o pid=,ppid=; fi
  } | awk -v root="$1" '
    { parent[$1]=$2 }
    END {
      selected[root]=1
      for (pass=0; pass<100; pass++) {
        changed=0
        for (pid in parent) if (!selected[pid] && selected[parent[pid]]) { selected[pid]=1; changed=1 }
        if (!changed) break
      }
      # Reading an absent awk array entry inserts a zero-valued key. Only
      # explicitly selected descendants may be emitted, never those keys.
      for (pid in parent) if (selected[pid] && pid != root) print pid
    }'
}
