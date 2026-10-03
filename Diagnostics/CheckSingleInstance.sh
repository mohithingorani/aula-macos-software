#!/bin/sh
# Opt-in UI check: launch the installed app and try opening the dist copy.
# Stop Music Sync and close other AULA copies before running this check.
set -eu
first="${1:-/Applications/AULA F75.app}"
second="${2:-dist/AULA F75.app}"
open "$first"
sleep 2
before="$(pgrep -u "$(id -u)" -f '/Contents/MacOS/AulaF75Mac$')"
test "$(printf '%s\n' "$before" | wc -l | tr -d ' ')" = 1
open -n "$second" || true # Launch Services may reject the second launch itself.
sleep 2
after="$(pgrep -u "$(id -u)" -f '/Contents/MacOS/AulaF75Mac$')"
test "$before" = "$after"
echo 'PASS: opening the second app copy leaves the original as the only receiver client.'
