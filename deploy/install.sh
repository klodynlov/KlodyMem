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
BAR_LABEL="com.klody.mem.bar"
BAR_PLIST="$HOME/Library/LaunchAgents/$BAR_LABEL.plist"
BAR_SRC="$ROOT/KlodyMem.app"
BAR_DST="$HOME/Applications/KlodyMem.app"

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

# La barre de menus est optionnelle : elle n'est installée que si le bundle a
# été construit (./deploy/make-bar-app.sh).
if [ -d "$BAR_SRC" ]; then
    echo "==> barre  -> $BAR_DST"
    mkdir -p "$HOME/Applications"
    # Même piège que pour le binaire : écraser un bundle signé invalide sa
    # signature et macOS tue l'app au lancement.
    rm -rf "$BAR_DST"
    cp -R "$BAR_SRC" "$BAR_DST"
    codesign -f -s - --deep "$BAR_DST" >/dev/null 2>&1 || true

    echo "==> session-> $BAR_PLIST"
    sed -e "s|__APP__|$BAR_DST|g" -e "s|__STATE__|$STATE|g" \
        "$ROOT/deploy/com.klody.mem.bar.plist" > "$BAR_PLIST"

    # Fermer l'instance lancée à la main, sinon deux icônes dans la barre.
    pkill -f "KlodyMem.app/Contents/MacOS/KlodyMem" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/$BAR_LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$BAR_PLIST"
else
    echo "==> barre  -> non construite, ignorée (./deploy/make-bar-app.sh)"
fi

echo
echo "installé. Vérifier :"
echo "  $BIN_DST doctor"
echo "  tail -f $STATE/guard.log"
echo
echo "Par défaut le garde NE FAIT QUE NOTIFIER."
echo "Pour l'autoriser à agir, éditer $CFG :"
echo "  \"manageable\": [\"Google Chrome\"]   liste blanche des cibles"
echo "  \"actions\": { \"suspendAtHigh\": true }"
