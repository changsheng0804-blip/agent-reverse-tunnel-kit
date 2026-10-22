#!/bin/bash
# Agent-side one-time setup. Run as root on the agent's machine (Linux).
# Creates: dedicated low-privilege user, REVSSH_DIR with host key,
# and (Variant B) a private venv with paramiko.
# Usage: sudo bash setup.sh [LOGIN_USER] [REVSSH_DIR]
set -euo pipefail
LOGIN_USER="${1:-revtest}"
REVSSH_DIR="${2:-$HOME/revssh}"
export REVSSH_USER="$LOGIN_USER" REVSSH_DIR

if ! id "$LOGIN_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$LOGIN_USER"
  echo "created user $LOGIN_USER"
fi
# '*' = no password login possible, but account not "locked" for pubkey checks.
usermod -p '*' "$LOGIN_USER"

mkdir -p "$REVSSH_DIR"
chmod 700 "$REVSSH_DIR"
if [ ! -f "$REVSSH_DIR/host_ed25519" ]; then
  ssh-keygen -t ed25519 -N '' -f "$REVSSH_DIR/host_ed25519" >/dev/null
  echo "host key generated"
fi
touch "$REVSSH_DIR/authorized_keys"
chmod 600 "$REVSSH_DIR/authorized_keys"
echo "host key fingerprint (give this to the local side for verification):"
ssh-keygen -lf "$REVSSH_DIR/host_ed25519"

# Variant B dependency: paramiko in a venv inside REVSSH_DIR (self-contained).
if [ ! -x "$REVSSH_DIR/venv/bin/python" ]; then
  python3 -m venv "$REVSSH_DIR/venv"
  "$REVSSH_DIR/venv/bin/pip" install -q paramiko
  echo "paramiko installed into $REVSSH_DIR/venv"
fi
echo "setup done. Next: put the LOCAL side public key into $REVSSH_DIR/authorized_keys (one line), then run start_server.sh"
