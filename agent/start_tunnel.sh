#!/bin/bash
# Start the tunnel keeper detached (survives the launching session).
set -euo pipefail
cd "$(dirname "$0")"
if pgrep -f "tunnel-keep.sh" >/dev/null; then
  echo "keeper already running"; exit 0
fi
setsid nohup bash ./tunnel-keep.sh >/dev/null 2>&1 < /dev/null &
sleep 6
pgrep -f "tunnel-keep.sh" >/dev/null && echo "keeper up (see tunnel-keep.log)"
