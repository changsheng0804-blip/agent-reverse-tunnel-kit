#!/bin/bash
# Local side verification: one-shot remote command through the tunnel.
# Proves the whole chain: your machine -> tunnel mouth (localhost:REMOTE_PORT)
# -> agent machine -> SSH service -> command runs as the low-priv user.
# Usage: bash verify.sh [keyname] [remote_port] [user]
set -uo pipefail
KEYNAME="${1:-agent-door}"
REMOTE_PORT="${2:-2222}"
LOGIN_USER="${3:-revtest}"
ssh -i "$HOME/.ssh/$KEYNAME" -p "$REMOTE_PORT" \
  -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 \
  "$LOGIN_USER@127.0.0.1" \
  'echo REVERSE_LOGIN_OK; id; hostname; pwd; head -1 /etc/os-release'
