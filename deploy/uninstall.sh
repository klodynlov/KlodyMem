#!/bin/sh
# Retire l'agent et le binaire. Config et historique sont conservés.
set -e
LABEL="com.klody.mem"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BAR_LABEL="com.klody.mem.bar"
BAR_PLIST="$HOME/Library/LaunchAgents/$BAR_LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$BAR_LABEL" 2>/dev/null || true
rm -f "$PLIST" "$BAR_PLIST"
rm -f "$HOME/.local/bin/klodymem"
rm -rf "$HOME/Applications/KlodyMem.app"

# Un garde retiré pendant qu'il avait suspendu des apps les laisserait gelées.
pkill -CONT -u "$(id -u)" 2>/dev/null || true

echo "désinstallé. Config conservée dans ~/.config/klodymem/"
echo "Tous les process suspendus ont reçu SIGCONT."
