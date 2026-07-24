#!/bin/zsh
# Construit Status et l'empaquette dans un .dmg glisser-déposer, pour l'installer sur d'autres Mac.
#
#   ./scripts/make-dmg.sh
#
# Produit outputs/Status.dmg : une image contenant Status.app et un raccourci vers /Applications,
# l'utilisateur n'a qu'à glisser l'app dans le dossier.
#
# LIMITES ASSUMÉES :
#   — Apple Silicon uniquement (binaire arm64, API DDC/SMC propres à Apple Silicon), macOS 14+.
#   — App auto-signée, NON notarisée par Apple (pas de certificat Developer ID). Sur un autre Mac,
#     Gatekeeper bloquera le premier lancement. Contournement, une fois par Mac, après avoir copié
#     l'app dans Applications :
#         xattr -dr com.apple.quarantine /Applications/Status.app
#     (ou clic droit sur l'app › Ouvrir). Le script rappelle cette étape à la fin.
set -euo pipefail

ROOT="${0:A:h:h}"
APP="${ROOT}/outputs/Status.app"
DMG="${ROOT}/outputs/Status.dmg"
STAGING="${ROOT}/work/dmg-staging"
VOLNAME="Status"

# 1. Build + signature frais (réutilise le pipeline existant : compilation, ressources, signature).
"${ROOT}/scripts/package-app.sh" >/dev/null
echo "app construite : $APP"

# 2. Dossier de montage : l'app + un lien vers /Applications pour le glisser-déposer.
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 3. Image compressée (UDZO). -ov écrase une image précédente.
rm -f "$DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

# 4. Signer l'image elle-même avec la même identité que l'app, quand elle existe (cohérence ;
#    sans effet sur Gatekeeper côté distribution, mais évite un avertissement « image non signée »).
SIGN_IDENTITY="${STATUS_SIGN_IDENTITY:-Status Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  codesign --force --sign "$SIGN_IDENTITY" "$DMG" 2>/dev/null || true
fi

rm -rf "$STAGING"
SIZE=$(du -h "$DMG" | cut -f1)

echo
echo "✓ DMG prêt : $DMG  (${SIZE})"
echo
echo "Sur chaque AUTRE Mac (Apple Silicon, macOS 14+) :"
echo "  1. Ouvrir Status.dmg, glisser Status.app dans Applications."
echo "  2. Lever la mise en quarantaine (app non notarisée) :"
echo "       xattr -dr com.apple.quarantine /Applications/Status.app"
echo "  3. Lancer Status. Accorder l'Accessibilité si vous voulez le verrou clavier,"
echo "     le gestionnaire de fenêtres et le pilotage de luminosité au clavier."
