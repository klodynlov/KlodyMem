#!/bin/sh
# Retire l'agent et le binaire. Config et historique sont conservés.
set -e
LABEL="com.klody.mem"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"
rm -f "$HOME/.local/bin/klodymem"

# Un garde retiré pendant qu'il avait suspendu des apps les laisserait gelées.
pkill -CONT -u "$(id -u)" 2>/dev/null || true

echo "désinstallé. Config conservée dans ~/.config/klodymem/"
echo "Tous les process suspendus ont reçu SIGCONT."
