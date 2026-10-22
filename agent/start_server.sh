#!/bin/bash
# Start the Variant B SSH service (localhost only), detached so it survives
# the launching shell/session. Re-running is safe: it exits if already up.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REVSSH_DIR="${REVSSH_DIR:-$HOME/revssh}"
REVSSH_PORT="${REVSSH_PORT:-2223}"
export REVSSH_DIR REVSSH_PORT
export REVSSH_USER="${REVSSH_USER:-revtest}"
if ss -tln 2>/dev/null | grep -q "127.0.0.1:$REVSSH_PORT"; then
  echo "already listening on 127.0.0.1:$REVSSH_PORT"; exit 0
fi
setsid nohup "$REVSSH_DIR/venv/bin/python" "$SCRIPT_DIR/ssh_server.py" \
  >"$REVSSH_DIR/server.err" 2>&1 < /dev/null &
sleep 2
if ss -tln | grep -q "127.0.0.1:$REVSSH_PORT"; then
  echo "server up on 127.0.0.1:$REVSSH_PORT"
else
  echo "FAILED to start; last errors:"; tail -5 "$REVSSH_DIR/server.err"; exit 1
fi
