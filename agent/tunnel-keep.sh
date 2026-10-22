#!/bin/bash
# Tunnel keeper: maintains the reverse SSH tunnel to the landing machine.
# WHY A LOOP: a single-shot tunnel started from a short-lived agent session
# tends to die with that session (measured: ~46s in the reference setup,
# where outbound connections ride a per-session proxy). A supervisor loop
# that reconnects forever is what makes the door persistent.
# Run detached:  setsid nohup ./tunnel-keep.sh >/dev/null 2>&1 < /dev/null &
set -uo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
source ./tunnel.env
: "${JUMP_USER:?}" "${JUMP_HOST:?}" "${JUMP_KEY:?}"
REMOTE_PORT="${REMOTE_PORT:-2222}"
LOCAL_PORT="${LOCAL_PORT:-2223}"
while true; do
  echo "$(date '+%F %T') starting tunnel -> $JUMP_HOST:$REMOTE_PORT" >> tunnel-keep.log
  ssh -i "$JUMP_KEY" -o IdentitiesOnly=yes \
    ${PROXY_COMMAND:+-o ProxyCommand="$PROXY_COMMAND"} \
    -o ConnectTimeout=25 -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
    -N -R "$REMOTE_PORT:127.0.0.1:$LOCAL_PORT" \
    "$JUMP_USER@$JUMP_HOST" >> tunnel-keep.log 2>&1
  echo "$(date '+%F %T') tunnel exited rc=$?, retry in 5s" >> tunnel-keep.log
  sleep 5
done
