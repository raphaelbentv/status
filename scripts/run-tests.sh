#!/bin/zsh
# Lance toute la suite de tests : logique native (StatusQuota) + collecteur Python.
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="${ROOT}/work"
mkdir -p "$BUILD"

echo "── Tests natifs (StatusQuota) ──"
clang -fobjc-arc -I "$ROOT/Native" -framework Foundation -framework IOKit -framework Cocoa \
  "$ROOT/Tests/native-tests.m" "$ROOT/Native/StatusQuota.m" "$ROOT/Native/StatusAwake.m" \
  "$ROOT/Native/StatusKeyboardLock.m" "$ROOT/Native/StatusSystemMonitor.m" \
  "$ROOT/Native/StatusWindowManager.m" "$ROOT/Native/StatusCost.m" "$ROOT/Native/StatusFx.m" \
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

echo "── Tests du bridge Claude (Python) ──"
if command -v python3 >/dev/null; then
  python3 -m unittest discover -s "$ROOT/Tests" -p 'test_*.py' -v 2>&1 | tail -5
  python_status=${PIPESTATUS[1]:-0}
else
  echo "python3 introuvable — ignoré"
  python_status=0
fi

exit $(( native_status + web_status + python_status ))
