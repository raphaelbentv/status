#!/bin/zsh
# Télécharge Sparkle (mises à jour automatiques) dans vendor/Sparkle, une version figée et
# vérifiée par empreinte SHA-256 (celle publiée par GitHub pour l'asset de la release).
#
#   ./scripts/fetch-sparkle.sh
#
# vendor/ n'est pas versionné : le framework pèse une dizaine de Mo et se récupère à l'identique.
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION="2.10.0"
SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
DEST="$ROOT/vendor/Sparkle"

if [[ -d "$DEST/Sparkle.framework" && "$(cat "$DEST/VERSION" 2>/dev/null)" == "$VERSION" ]]; then
  echo "Sparkle $VERSION déjà présent."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$TMP/sparkle.tar.xz"
ACTUAL=$(shasum -a 256 "$TMP/sparkle.tar.xz" | cut -d' ' -f1)
[[ "$ACTUAL" == "$SHA256" ]] || { echo "Empreinte inattendue pour Sparkle $VERSION : $ACTUAL" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST" "$TMP/x"
tar -xf "$TMP/sparkle.tar.xz" -C "$TMP/x"
cp -R "$TMP/x/Sparkle.framework" "$DEST/"
cp -R "$TMP/x/bin" "$DEST/bin"
echo "$VERSION" > "$DEST/VERSION"
echo "Sparkle $VERSION installé dans vendor/Sparkle"
