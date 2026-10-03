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
  "$ROOT/Native/Status.m" "$ROOT/Native/StatusLidClient.m" "$ROOT/Native/StatusLidProtocol.m" "$ROOT/Native/StatusQuota.m" "$ROOT/Native/StatusAccounts.m" \
  "$ROOT/Native/StatusClaudeSession.m" "$ROOT/Native/StatusClaudeBridge.m" "$ROOT/Native/StatusAwake.m" \
  "$ROOT/Native/StatusSystemMonitor.m" "$ROOT/Native/StatusKeyboardLock.m" \
  "$ROOT/Native/StatusCodexServer.m" "$ROOT/Native/StatusWindowManager.m" "$ROOT/Native/StatusCost.m" \
  "$ROOT/Native/StatusFx.m" "$ROOT/Native/StatusDisplays.m" "$ROOT/Native/StatusMenuBarWidgets.m" -o "$BUILD"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/Contents/MacOS" "$OUTPUT/Contents/Resources/icons"
cp "$BUILD" "$OUTPUT/Contents/MacOS/Status"
cp "$ROOT/Resources/Info.plist" "$OUTPUT/Contents/Info.plist"
cp "$ROOT/Resources/StatusIcon.icns" "$OUTPUT/Contents/Resources/StatusIcon.icns"
cp "$ROOT/Resources/dashboard.html" "$OUTPUT/Contents/Resources/dashboard.html"
cp "$ROOT/Resources/menubar.html" "$OUTPUT/Contents/Resources/menubar.html"
cp "$ROOT/Resources/widget.html" "$OUTPUT/Contents/Resources/widget.html"
cp "$ROOT/Resources/picker.html" "$OUTPUT/Contents/Resources/picker.html"
cp "$ROOT/Resources/themes.css" "$OUTPUT/Contents/Resources/themes.css"
cp "$ROOT/Resources/icons/"*.png "$OUTPUT/Contents/Resources/icons/"

clang -fobjc-arc -O2 -I "$ROOT/Native" -framework Foundation \
  "$ROOT/Native/StatusClaudeCollector.m" "$ROOT/Native/StatusClaudeBridge.m" \
  "$ROOT/Native/StatusAccounts.m" "$ROOT/Native/StatusQuota.m" \
  -o "$OUTPUT/Contents/Resources/status-claude-collector"

mkdir -p "$OUTPUT/Contents/Library/LaunchDaemons" "$OUTPUT/Contents/Library/LaunchServices"
cp "$ROOT/Resources/LaunchDaemons/com.raphael.status.lid-helper.plist" "$OUTPUT/Contents/Library/LaunchDaemons/"
clang -fobjc-arc -O2 -I "$ROOT/Native" -framework Foundation -framework IOKit -framework Security   "$ROOT/Native/StatusLidHelper.m" "$ROOT/Native/StatusLidMode.m" "$ROOT/Native/StatusFanBoost.m" "$ROOT/Native/StatusLidProtocol.m"   -o "$OUTPUT/Contents/Library/LaunchServices/com.raphael.status.lid-helper"

xattr -cr "$OUTPUT"

# Signature : une identité stable évite que macOS voie chaque build comme une app différente
# (demandes d’accès Trousseau répétées). À défaut, on
# retombe sur l'ad-hoc, qui fonctionne mais change d'empreinte à chaque compilation.
# Voir ./scripts/create-signing-identity.sh
SIGN_IDENTITY="${STATUS_SIGN_IDENTITY:-Status Local Signing}"
# Sans -v, délibérément : « -v » ne liste que les identités approuvées comme racine de confiance.
# Une identité auto-signée locale ne l'est pas, et n'a pas à l'être — on ne cherche pas une chaîne
# vérifiable par des tiers (ce serait un Developer ID Apple), seulement une empreinte stable d'un
# build à l'autre, pour que macOS reconnaisse la même app et conserve ses autorisations.
# Les builds locaux utilisent un paquet approuvé par l’administrateur pour le service.
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  codesign --force --options runtime --identifier com.raphael.status.lid-helper --sign "$SIGN_IDENTITY" "$OUTPUT/Contents/Library/LaunchServices/com.raphael.status.lid-helper"
  echo "signé avec : $SIGN_IDENTITY"
else
  codesign --force --sign - "$OUTPUT/Contents/Library/LaunchServices/com.raphael.status.lid-helper"
  echo "signé en ad-hoc (aucune identité « $SIGN_IDENTITY » ; voir scripts/create-signing-identity.sh)"
fi

# Installation classique approuvée par l'administrateur, pour les builds locaux.
# Le payload contient uniquement le helper signé et sa déclaration launchd.
LID_PAYLOAD="$ROOT/work/lid-package"
rm -rf "$LID_PAYLOAD"
mkdir -p "$LID_PAYLOAD/Library/PrivilegedHelperTools" "$LID_PAYLOAD/Library/LaunchDaemons"
cp "$OUTPUT/Contents/Library/LaunchServices/com.raphael.status.lid-helper" "$LID_PAYLOAD/Library/PrivilegedHelperTools/"
# Label et nom Mach distincts de l'enregistrement SMAppService : smd recrée ce dernier
# après bootout, et le partage du label faisait échouer le bootstrap du paquet.
LID_PLIST="$LID_PAYLOAD/Library/LaunchDaemons/com.raphael.status.lid-service.plist"
cp "$ROOT/Resources/LaunchDaemons/com.raphael.status.lid-helper.plist" "$LID_PLIST"
plutil -replace Label -string com.raphael.status.lid-service "$LID_PLIST"
plutil -replace MachServices -json '{"com.raphael.status.lid-service":true}' "$LID_PLIST"
plutil -remove BundleProgram "$LID_PLIST"
plutil -insert Program -string /Library/PrivilegedHelperTools/com.raphael.status.lid-helper "$LID_PLIST"
plutil -replace ThrottleInterval -integer 30 "$LID_PLIST"
plutil -insert AssociatedBundleIdentifiers -json '["com.raphael.status"]' "$LID_PLIST"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
pkgbuild --root "$LID_PAYLOAD" --ownership recommended --install-location / \
  --scripts "$ROOT/scripts/lid-installer" --identifier com.raphael.status.lid-service \
  --version "$VERSION" "$OUTPUT/Contents/Resources/StatusLidService.pkg"

if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$OUTPUT"
else
  codesign --force --deep --sign - "$OUTPUT"
fi

rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$OUTPUT" "$ARCHIVE"
echo "$OUTPUT"
echo "$ARCHIVE"
