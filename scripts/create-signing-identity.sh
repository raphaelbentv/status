#!/bin/zsh
# Crée une identité de signature locale auto-signée pour Status.
#
# Pourquoi : sans identité, package-app.sh signe en ad-hoc. Une signature ad-hoc change à chaque
# build, donc macOS considère chaque build comme une application différente — d'où des demandes
# répétées d'accès au Trousseau, une autorisation d'Accessibilité révoquée (verrou clavier,
# raccourci global), et un SMAppService qui peut refuser de s'enregistrer. Une identité stable,
# même auto-signée, supprime ces frictions sur cette machine.
#
# Ce que ça ne fait PAS : distribuer l'app. Pour cela il faut un certificat Developer ID Apple.
#
# Pourquoi pas en ligne de commande : importer une clé privée utilisable par codesign exige
# `security set-key-partition-list`, qui réclame le mot de passe de session. L'assistant graphique
# est le seul chemin qui n'oblige pas à le taper dans un terminal.
set -euo pipefail

NAME="Status Local Signing"

existing=$(security find-certificate -a -c "$NAME" 2>/dev/null | grep -c "labl" || true)

if [[ "$existing" -gt 0 ]]; then
  echo "⚠  $existing certificat(s) « $NAME » déjà présent(s)."
  if security find-certificate -c "$NAME" -p 2>/dev/null > /tmp/status-cert-check.pem && [[ -s /tmp/status-cert-check.pem ]]; then
    echo "   Expiration : $(openssl x509 -in /tmp/status-cert-check.pem -noout -enddate 2>/dev/null | cut -d= -f2)"
    rm -f /tmp/status-cert-check.pem
  fi
  echo
  echo "   Deux certificats du même nom rendraient codesign ambigu : il refuserait de signer."
  echo "   Pour en recréer un, supprimez D'ABORD l'ancien :"
  echo
  echo "     1. Trousseau d'accès › catégorie « Mes certificats »"
  echo "     2. Clic droit sur « $NAME » › Supprimer"
  echo "        (supprime le certificat ET sa clé privée)"
  echo
  REPLY=""
  read -q "REPLY?Continuer quand même vers la création ? [o/N] " || true
  echo
  [[ "$REPLY" == "o" || "$REPLY" == "y" ]] || exit 0
  echo
fi

cat <<'GUIDE'
Création d'un certificat de signature auto-signé.

macOS ne permet pas de créer une identité de signature sans interaction. Dans Trousseau d'accès :

  1. Menu « Trousseau d'accès » › Assistant de certification › Créer un certificat…
  2. Nom             : Status Local Signing
  3. Type d'identité : Racine auto-signée
  4. Type            : Signature de code
  5. COCHEZ « Remplacer les réglages par défaut » — sans cette case, l'assistant impose
     365 jours en silence et il faudra tout recommencer dans un an.
  6. Écran « Validité » : remplacez 365 par 3650 jours.
  7. Continuez jusqu'à la fin (les écrans suivants n'ont rien à changer).

Ensuite, relancez ce script : il vérifiera le résultat.
GUIDE

echo
REPLY=""
read -q "REPLY?Ouvrir Trousseau d'accès maintenant ? [o/N] " || true
echo
[[ "$REPLY" == "o" || "$REPLY" == "y" ]] && open -a "Keychain Access"

cat <<'CHECK'

Une fois créé, vérifiez avec :

  security find-identity -p codesigning | grep "Status Local Signing"
  ./scripts/package-app.sh            # doit afficher « signé avec : Status Local Signing »

Le statut CSSMERR_TP_NOT_TRUSTED est normal et sans effet : une racine auto-signée n'est pas
approuvée par défaut, et codesign l'accepte quand même. Voir README § Signature stable.
CHECK
