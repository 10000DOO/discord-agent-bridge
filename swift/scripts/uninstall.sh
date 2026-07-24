#!/bin/bash
# uninstall.sh — stop + unregister the launchd LaunchAgent, remove build artifacts.
# Preserves ~/.dab/env (your secrets) and ~/.dab/logs (history) on purpose.

set -euo pipefail

LABEL="com.discord-agent-bridge"
DAB_HOME="$HOME/.dab"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

log() { printf '%s\n' "$*"; }

launchctl unload -w "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "$DAB_HOME/bin"
rm -f "$DAB_HOME/run.sh"

log "uninstalled: stopped, unregistered, removed plist + $DAB_HOME/bin + run.sh."
log "kept: $DAB_HOME/env (secrets) and $DAB_HOME/logs (history)."
