#!/bin/sh
# Installe klodymem : binaire, config par défaut, agent launchd utilisateur.
# Aucun sudo — l'agent tourne sous l'utilisateur et n'agit que sur ses process.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_SRC="$ROOT/.build/release/klodymem"
BIN_DST="$HOME/.local/bin/klodymem"
STATE="$HOME/.local/state/klodymem"
CFG="$HOME/.config/klodymem/config.json"
LABEL="com.klody.mem"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -x "$BIN_SRC" ] || {
    echo "compiler d'abord :  swift build --package-path $ROOT -c release"
    exit 1
}

echo "==> binaire -> $BIN_DST"
mkdir -p "$(dirname "$BIN_DST")" "$STATE"
# Écraser un Mach-O signé en place invalide sa signature : macOS tue alors le
# process au lancement (code 137). Il faut retirer l'ancien puis resigner.
rm -f "$BIN_DST"
cp "$BIN_SRC" "$BIN_DST"
codesign -f -s - "$BIN_DST" >/dev/null 2>&1 || true

echo "==> config  -> $CFG"
if [ -f "$CFG" ]; then
    echo "    (déjà présente, conservée)"
else
    "$BIN_DST" config init
fi

echo "==> agent   -> $PLIST"
mkdir -p "$(dirname "$PLIST")"
sed -e "s|__BIN__|$BIN_DST|g" -e "s|__STATE__|$STATE|g" \
    "$ROOT/deploy/com.klody.mem.plist" > "$PLIST"

# Recharger un plist se fait en bootout + bootstrap. `kickstart` relance le
# process mais ne relit pas le fichier : une modification passerait inaperçue.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "installé. Vérifier :"
echo "  $BIN_DST doctor"
echo "  tail -f $STATE/guard.log"
echo
echo "Par défaut le garde NE FAIT QUE NOTIFIER."
echo "Pour l'autoriser à agir, éditer $CFG :"
echo "  \"manageable\": [\"Google Chrome\"]   liste blanche des cibles"
echo "  \"actions\": { \"suspendAtHigh\": true }"
