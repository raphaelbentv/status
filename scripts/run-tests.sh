#!/bin/zsh
# Lance toute la suite de tests : logique native (StatusQuota, StatusAccounts) + surfaces web.
set -euo pipefail

ROOT="${0:A:h:h}"
# Les tests natifs et web comparent des textes français : on fige la langue, quelle que soit celle du Mac.
export STATUS_LANGUAGE=fr
export STATUS_I18N_DIR="$ROOT/Resources/i18n"
BUILD="${ROOT}/work"
mkdir -p "$BUILD"

echo "── Tests natifs (StatusQuota) ──"
clang -fobjc-arc -I "$ROOT/Native" -framework Foundation -framework IOKit -framework Cocoa \
  "$ROOT/Tests/native-tests.m" "$ROOT/Native/StatusQuota.m" "$ROOT/Native/StatusAccounts.m" \
  "$ROOT/Native/StatusAwake.m" \
  "$ROOT/Native/StatusKeyboardLock.m" "$ROOT/Native/StatusSystemMonitor.m" \
  "$ROOT/Native/StatusCost.m" "$ROOT/Native/StatusFx.m" \
  "$ROOT/Native/StatusDisplays.m" "$ROOT/Native/StatusMenuBarWidgets.m" "$ROOT/Native/StatusCodexServer.m" \
  "$ROOT/Native/StatusI18n.m" \
  -o "$BUILD/native-tests"
"$BUILD/native-tests"
native_status=$?

echo "── Mode capot fermé (simulé, sans modifier la veille) ──"
clang -fobjc-arc -I "$ROOT/Native" -framework Foundation -framework Security -framework IOKit \
  "$ROOT/Tests/lid-mode-tests.m" "$ROOT/Native/StatusLidMode.m" "$ROOT/Native/StatusLidProtocol.m" \
  -o "$BUILD/lid-mode-tests"
"$BUILD/lid-mode-tests"

echo "── Tests des surfaces web (JavaScript) ──"
clang -fobjc-arc -I "$ROOT/Native" -framework Foundation -framework IOKit \
  "$ROOT/Tests/fan-boost-tests.m" "$ROOT/Native/StatusFanBoost.m" -o "$BUILD/fan-boost-tests"
"$BUILD/fan-boost-tests"
if command -v node >/dev/null; then
  node "$ROOT/Tests/web-tests.mjs"
  web_status=$?
  echo "── Traductions (dictionnaires, clés, rendu par langue) ──"
  node "$ROOT/Tests/i18n-tests.mjs"
  web_status=$(( web_status + $? ))
else
  echo "node introuvable — ignoré"
  web_status=0
fi

python3 -m unittest discover -s "$ROOT/Tests" -p "test_claude_bridge.py"

exit $(( native_status + web_status ))
