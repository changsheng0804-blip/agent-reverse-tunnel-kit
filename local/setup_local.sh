#!/bin/bash
# Local side (your own PC/Mac): create the DEDICATED keypair for this door.
# One door, one key. The private key never leaves this machine.
# Usage: bash setup_local.sh [keyname]   (default: agent-door)
set -euo pipefail
KEYNAME="${1:-agent-door}"
KEY="$HOME/.ssh/$KEYNAME"
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -N '' -C "$KEYNAME-$(date +%F)" -f "$KEY" >/dev/null
  echo "key created: $KEY"
else
  echo "key already exists: $KEY"
fi
echo
echo "== Give this ONE public line to the agent side (into its authorized_keys) =="
cat "$KEY.pub"
echo "== Connect (after the tunnel is up), assuming REMOTE_PORT=2222, user=revtest =="
echo "ssh -i $KEY -p 2222 revtest@127.0.0.1"
echo "First connect will ask you to confirm the host fingerprint."
echo "It MUST match the fingerprint the agent side printed during its setup."
