#!/bin/sh
# Empaquette klodymem-bar en .app de barre de menus (LSUIElement : pas d'icône
# dans le Dock), pour pouvoir l'ajouter aux ouvertures de session.
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/KlodyMem.app"
BIN="$ROOT/.build/release/klodymem-bar"

[ -x "$BIN" ] || {
    echo "compiler d'abord :  swift build --package-path $ROOT -c release"
    exit 1
}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/KlodyMem"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>KlodyMem</string>
  <key>CFBundleDisplayName</key><string>KlodyMem</string>
  <key>CFBundleIdentifier</key><string>com.klody.mem.bar</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>KlodyMem</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

echo "construit : $APP"
echo "lancer  :  open \"$APP\""
echo "session :  Réglages Système > Général > Ouverture > +  ->  $APP"
