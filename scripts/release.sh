#!/bin/zsh
# Construit une version distribuable de Status : signée Developer ID, notarisée par Apple, agrafée,
# dans un DMG lui-même notarisé. Gatekeeper l'ouvre sans avertissement sur n'importe quel Mac
# Apple Silicon sous macOS 14+.
#
#   ./scripts/release.sh
#
# Prérequis, une fois par Mac :
#   1. Un certificat « Developer ID Application » dans le trousseau (Xcode › Réglages › Comptes ›
#      Gérer les certificats › + › Developer ID Application).
#   2. Des identifiants de notarisation enregistrés sous le profil « status-notary » :
#        xcrun notarytool store-credentials status-notary --apple-id <email> --team-id <TEAMID>
#      (mot de passe d'app à générer sur account.apple.com › Connexion et sécurité).
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/outputs/Status.app"
DMG="$ROOT/outputs/Status.dmg"
STAGING="$ROOT/work/dmg-staging"
PROFILE="${STATUS_NOTARY_PROFILE:-status-notary}"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
[[ -n "$IDENTITY" ]] || { echo "Aucun certificat « Developer ID Application » dans le trousseau." >&2; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "Profil de notarisation « $PROFILE » absent : voir l'en-tête de ce script." >&2; exit 1; }

notarize() {  # $1 : fichier à soumettre (zip ou dmg)
  local out id
  out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --output-format json)
  id=$(print -r -- "$out" | plutil -extract id raw -o - -)
  if [[ "$(print -r -- "$out" | plutil -extract status raw -o - -)" != "Accepted" ]]; then
    echo "Notarisation refusée ($id) :" >&2
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    exit 1
  fi
  echo "notarisé : ${1:t} ($id)"
}

# 1. Build signé Developer ID (package-app.sh choisit cette identité d'office).
STATUS_SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/package-app.sh" >/dev/null
codesign --verify --deep --strict "$APP"
echo "signé : $IDENTITY"

# 2. Notariser l'app elle-même puis l'agrafer, pour qu'elle reste reconnue hors du DMG et hors ligne.
ZIP="$ROOT/work/Status-notarize.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
notarize "$ZIP"
xcrun stapler staple "$APP" >/dev/null
rm -f "$ZIP"

# 3. DMG glisser-déposer, signé, notarisé et agrafé.
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname Status -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG" >/dev/null

# 4. Vérification telle que Gatekeeper la fera chez l'utilisateur.
spctl --assess --type execute -vv "$APP"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
echo
echo "✓ Status $VERSION prêt : $DMG ($(du -h "$DMG" | cut -f1))"
