#!/bin/bash
# Full teardown of the agent side: keeper loop + its tunnel ssh, the SSH
# service, the base dir, and (with --user) the dedicated login user.
set -uo pipefail
REVSSH_DIR="${REVSSH_DIR:-$HOME/revssh}"
REVSSH_PORT="${REVSSH_PORT:-2223}"
LOGIN_USER="${REVSSH_USER:-revtest}"
for kp in $(pgrep -f "tunnel-keep.sh" || true); do
  pkill -P "$kp" 2>/dev/null || true   # the tunnel ssh child
  kill "$kp" 2>/dev/null || true
  echo "keeper $kp stopped"
done
pid=$(ss -tlnp 2>/dev/null | grep "127.0.0.1:$REVSSH_PORT" | grep -oP 'pid=\K[0-9]+' | head -1 || true)
if [ -n "${pid:-}" ]; then kill "$pid" 2>/dev/null && echo "ssh service (pid $pid) stopped"; fi
sleep 1
rm -rf "$REVSSH_DIR"
echo "removed $REVSSH_DIR"
if [ "${1:-}" = "--user" ]; then
  userdel -r "$LOGIN_USER" 2>/dev/null && echo "user $LOGIN_USER removed" || true
fi
echo "teardown done"
