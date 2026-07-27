#!/bin/bash
# uninstall-linux.sh — stop + unregister the systemd --user unit, remove build artifacts.
# Preserves ~/.dab/env (your secrets) and ~/.dab/logs (history) on purpose.

set -euo pipefail

SERVICE_NAME="discord-agent-bridge"
DAB_HOME="$HOME/.dab"
UNIT_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"

log() { printf '%s\n' "$*"; }

systemctl --user disable --now "$SERVICE_NAME" 2>/dev/null || true
rm -f "$UNIT_FILE"
systemctl --user daemon-reload 2>/dev/null || true
rm -rf "$DAB_HOME/bin"
rm -f "$DAB_HOME/run.sh"

log "uninstalled: stopped, unregistered, removed unit + $DAB_HOME/bin + run.sh."
log "kept: $DAB_HOME/env (secrets) and $DAB_HOME/logs (history)."
