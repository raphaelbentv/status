#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT="${ROOT}/outputs/Status.app"
ARCHIVE="${ROOT}/outputs/Status.zip"
BUILD="${ROOT}/work/Status"

cd "$ROOT"
mkdir -p "$ROOT/work" "$ROOT/outputs"
clang -fobjc-arc -O2 -I "$ROOT/Native" \
  -framework Cocoa -framework WebKit -framework Security \
  -framework ServiceManagement -framework UserNotifications -framework IOKit \
  "$ROOT/Native/Status.m" "$ROOT/Native/StatusQuota.m" "$ROOT/Native/StatusAwake.m" \
  "$ROOT/Native/StatusSystemMonitor.m" "$ROOT/Native/StatusKeyboardLock.m" \
  "$ROOT/Native/StatusCodexServer.m" -o "$BUILD"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources/scripts" "$OUTPUT/Contents/Resources/icons"
cp "$BUILD" "$OUTPUT/Contents/MacOS/Status"
cp "$ROOT/Resources/Info.plist" "$OUTPUT/Contents/Info.plist"
cp "$ROOT/Resources/StatusIcon.icns" "$OUTPUT/Contents/Resources/StatusIcon.icns"
cp "$ROOT/Resources/dashboard.html" "$OUTPUT/Contents/Resources/dashboard.html"
cp "$ROOT/Resources/menubar.html" "$OUTPUT/Contents/Resources/menubar.html"
cp "$ROOT/Resources/icons/"*.png "$OUTPUT/Contents/Resources/icons/"
cp "$ROOT/scripts/status-claude-bridge.py" "$OUTPUT/Contents/Resources/scripts/status-claude-bridge.py"
chmod 755 "$OUTPUT/Contents/Resources/scripts/status-claude-bridge.py"

xattr -cr "$OUTPUT"

# Signature : une identité stable évite que macOS voie chaque build comme une app différente
# (demandes d'accès Trousseau répétées, SMAppService qui refuse de s'enregistrer). À défaut, on
# retombe sur l'ad-hoc, qui fonctionne mais change d'empreinte à chaque compilation.
# Voir ./scripts/create-signing-identity.sh
SIGN_IDENTITY="${STATUS_SIGN_IDENTITY:-Status Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$OUTPUT"
  echo "signé avec : $SIGN_IDENTITY"
else
  codesign --force --deep --sign - "$OUTPUT"
  echo "signé en ad-hoc (aucune identité « $SIGN_IDENTITY » ; voir scripts/create-signing-identity.sh)"
fi

rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$OUTPUT" "$ARCHIVE"
echo "$OUTPUT"
echo "$ARCHIVE"
