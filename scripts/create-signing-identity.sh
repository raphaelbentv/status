#!/bin/zsh
# Crée une identité de signature locale auto-signée pour Status.
#
# Pourquoi : sans identité, package-app.sh signe en ad-hoc. Une signature ad-hoc change à chaque
# build, donc macOS considère chaque build comme une application différente — d'où des demandes
# répétées d'accès au Trousseau, et un SMAppService (lancement au démarrage) qui peut refuser de
# s'enregistrer. Une identité stable, même auto-signée, supprime ces frictions sur cette machine.
#
# Ce que ça ne fait PAS : distribuer l'app. Pour cela il faut un certificat Developer ID Apple.
#
# À lancer une seule fois. macOS demandera votre mot de passe pour faire confiance au certificat.
set -euo pipefail

NAME="Status Local Signing"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "L'identité « $NAME » existe déjà. Rien à faire."
  exit 0
fi

echo "Création d'un certificat de signature auto-signé « $NAME »…"
echo
echo "macOS ne permet pas de créer une identité de signature sans interaction."
echo "Suivez ces étapes une seule fois dans Trousseau d'accès :"
echo
echo "  1. Ouvrez « Trousseau d'accès » (Cmd+Espace → Trousseau)."
echo "  2. Menu « Trousseau d'accès » › Assistant de certification › Créer un certificat…"
echo "  3. Nom            : $NAME"
echo "  4. Type d'identité: Root auto-signée"
echo "  5. Type           : Signature de code"
echo "  6. Cochez « Remplacer les réglages par défaut », puis Continuer jusqu'à la fin."
echo "  7. Validité       : 3650 jours (facultatif, évite de recommencer chaque année)."
echo
echo "Ensuite, relancez ./scripts/package-app.sh : il détectera l'identité automatiquement."
echo
read -q "REPLY?Ouvrir Trousseau d'accès maintenant ? [o/N] " || true
echo
[[ "$REPLY" == "o" || "$REPLY" == "y" ]] && open -a "Keychain Access"
exit 0
