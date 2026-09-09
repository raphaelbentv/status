#!/bin/zsh
# Lance toute la suite de tests : logique native (StatusQuota, StatusAccounts) + surfaces web.
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="${ROOT}/work"
mkdir -p "$BUILD"

echo "── Tests natifs (StatusQuota) ──"
clang -fobjc-arc -I "$ROOT/Native" -framework Foundation -framework IOKit -framework Cocoa \
  "$ROOT/Tests/native-tests.m" "$ROOT/Native/StatusQuota.m" "$ROOT/Native/StatusAccounts.m" \
  "$ROOT/Native/StatusAwake.m" \
  "$ROOT/Native/StatusKeyboardLock.m" "$ROOT/Native/StatusSystemMonitor.m" \
  "$ROOT/Native/StatusWindowManager.m" "$ROOT/Native/StatusCost.m" "$ROOT/Native/StatusFx.m" \
  "$ROOT/Native/StatusDisplays.m" "$ROOT/Native/StatusMenuBarWidgets.m" \
  -o "$BUILD/native-tests"
"$BUILD/native-tests"
native_status=$?

echo "── Tests des surfaces web (JavaScript) ──"
if command -v node >/dev/null; then
  node "$ROOT/Tests/web-tests.mjs"
  web_status=$?
else
  echo "node introuvable — ignoré"
  web_status=0
fi

python3 -m unittest discover -s "$ROOT/Tests" -p "test_claude_bridge.py"

exit $(( native_status + web_status ))
