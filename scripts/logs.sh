#!/bin/bash
# AltTab unified-log helper.
#   ./scripts/logs.sh           — live stream (incl. debug-level), Ctrl-C to stop
#   ./scripts/logs.sh 10m       — dump the last 10 minutes (any `log show --last` syntax: 30s, 2h, 1d)
#                                 to /tmp/alttab-<timestamp>.log and print the path
# Note: debug-level events are memory-only — they appear in the live stream but may be missing
# from a dump. Everything logged at default/error level IS persisted and survives in dumps.
# /usr/bin/log is absolute on purpose: the user's zsh profile defines a `log` function that shadows it.
set -euo pipefail
PRED='subsystem == "dev.fusy.alttab"'
if [[ $# -ge 1 ]]; then
  out="/tmp/alttab-$(date +%Y%m%d-%H%M%S).log"
  /usr/bin/log show --last "$1" --info --debug --predicate "$PRED" > "$out"
  echo "$out"
else
  exec /usr/bin/log stream --level debug --predicate "$PRED"
fi
