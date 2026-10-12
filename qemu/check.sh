#!/bin/sh
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${1:-$HERE/tests/charge_decharge.sh}
shift 2>/dev/null
LOG=$HERE/build/check.log

mkdir -p "$HERE/build"
timeout 120 "$HERE/run.sh" -e -t "$SCRIPT" "$@" </dev/null >"$LOG" 2>&1

PROBLEMES='out of bounds|clamping DMA|failed with error|BUG:|WARNING:|Oops|Call Trace|nobody cared|ECHEC|scheduling while atomic|leak'
echo "== Messages du pilote"
grep -E "EDU|qemu_edu|edu détecté" "$LOG" | grep -vE "$PROBLEMES" | sed 's/^/   /'
echo "== Problèmes détectés"
if grep -qE "$PROBLEMES" "$LOG"; then
    grep -E "$PROBLEMES" "$LOG" | sed 's/^/   /'
    echo "== ECHEC (log complet : $LOG)"; exit 1
fi
grep -q "=== FIN DU TEST" "$LOG" || { echo "   la VM ne s'est pas terminée normalement"; echo "== ECHEC (log complet : $LOG)"; exit 1; }
echo "   aucun"
echo "== OK (log complet : $LOG)"
