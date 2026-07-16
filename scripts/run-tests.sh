#!/bin/zsh
# Lance toute la suite de tests : logique native (StatusQuota) + collecteur Python.
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="${ROOT}/work"
mkdir -p "$BUILD"

echo "── Tests natifs (StatusQuota) ──"
clang -fobjc-arc -I "$ROOT/Native" -framework Foundation \
  "$ROOT/Tests/native-tests.m" "$ROOT/Native/StatusQuota.m" \
  -o "$BUILD/native-tests"
"$BUILD/native-tests"
native_status=$?

echo "── Tests du bridge Claude (Python) ──"
if command -v python3 >/dev/null; then
  python3 -m unittest discover -s "$ROOT/Tests" -p 'test_*.py' -v 2>&1 | tail -5
  python_status=${PIPESTATUS[1]:-0}
else
  echo "python3 introuvable — ignoré"
  python_status=0
fi

exit $(( native_status + python_status ))
