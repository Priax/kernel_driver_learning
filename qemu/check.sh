#!/bin/sh
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=${1:-$HERE/tests/charge_decharge.sh}
shift 2>/dev/null
LOG=$HERE/build/$(basename "$SCRIPT" .sh).log
TIMEOUT=${TIMEOUT:-120}

mkdir -p "$HERE/build"
echo "## $(basename "$SCRIPT") (noyau ${KVER:-$(uname -r)})"
timeout "$TIMEOUT" "$HERE/run.sh" -e -t "$SCRIPT" "$@" </dev/null >"$LOG" 2>&1

PROBLEMES='out of bounds|clamping DMA|failed with error|BUG:|WARNING:|Oops|Call Trace|nobody cared|ECHEC|scheduling while atomic|suspected memory leak|unreferenced object|UBSAN|DMA-API'
# Un test peut déclarer les messages qu'il provoque volontairement avec une ligne
# « # ATTENDU: regex »
ATTENDU=$(sed -n 's/^# ATTENDU: //p' "$SCRIPT")

problemes() {
    if [ -n "$ATTENDU" ]; then
        grep -E "$PROBLEMES" "$LOG" | grep -vE "$ATTENDU"
    else
        grep -E "$PROBLEMES" "$LOG"
    fi
}

# VERBOSE=1 pour voir aussi tous les messages du pilote
if [ -n "$VERBOSE" ]; then
    ETAPES="EDU|qemu_edu|edu détecté|^---|IGNORÉ"
else
    ETAPES="^---|IGNORÉ"
fi
echo "== Étapes"
grep -E "$ETAPES" "$LOG" | grep -vE "$PROBLEMES" | sed 's/^/   /'
echo "== Problèmes détectés"
P=$(problemes)
if [ -n "$P" ]; then
    echo "$P" | sed 's/^/   /'
    echo "== ECHEC (log complet : $LOG)"; exit 1
fi
grep -q "=== FIN DU TEST" "$LOG" || { echo "   la VM ne s'est pas terminée normalement"; echo "== ECHEC (log complet : $LOG)"; exit 1; }
echo "   aucun"
echo "== OK (log complet : $LOG)"
