#!/bin/zsh
# Construit Status et l'installe dans /Applications.
#
# Pourquoi /Applications plutôt que le dossier de build : SMAppService (lancement au démarrage)
# enregistre un chemin. Depuis outputs/, l'enregistrement casse dès que le dossier bouge ou est
# reconstruit, et macOS refuse souvent une app hors emplacement standard.
#
#   ./scripts/install-app.sh            installe
#   ./scripts/install-app.sh --login    installe et active le lancement au démarrage
set -euo pipefail

ROOT="${0:A:h:h}"
DEST="/Applications/Status.app"

"$ROOT/scripts/package-app.sh" >/dev/null

# Quitte l'instance en cours, d'où qu'elle vienne : deux Status en même temps donnent deux icônes
# dans la barre des menus, et on ne peut pas remplacer un bundle en cours d'exécution.
pkill -f "Status.app/Contents/MacOS/Status" 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R "$ROOT/outputs/Status.app" "$DEST"
echo "installé : $DEST"

if [[ "${1:-}" == "--login" ]]; then
  "$DEST/Contents/MacOS/Status" --register-login-item
fi

open "$DEST"
echo "lancé depuis /Applications"
