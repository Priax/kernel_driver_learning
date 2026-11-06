#!/bin/sh
# Fait échouer, une par une, chaque allocation mémoire faite pendant le probe
# (fail-nth : la N-ième allocation de ce processus échoue) pour exécuter tous
# les chemins d'erreur, puis vérifie que chacun a bien tout nettoyé.
# Nécessite CONFIG_FAULT_INJECTION (noyau +debug).
# ATTENDU: probe with driver .* failed with error
. /lib.sh

if [ ! -e /proc/self/fail-nth ] || [ ! -d $DBG/failslab ]; then
    echo "IGNORÉ : noyau sans injection de fautes (lancer avec le noyau +debug)"
    exit 0
fi

# Par défaut, les allocations GFP_KERNEL et les pages seules (ordre 0) ne
# peuvent pas échouer : ce sont justement celles du probe
for f in failslab fail_page_alloc; do
    echo N > $DBG/$f/ignore-gfp-wait
    echo 1 > $DBG/$f/verbose # Message sans pile d'appel
done
echo 0 > $DBG/fail_page_alloc/min-order

kmemleak_debut
insmod /modules/pilote.ko || echo "ECHEC insmod"

# On ne met en échec que les allocations appelées depuis le code du module
# (adresse au-dessus du début de son .text, aucun autre module n'est chargé),
# sinon on teste surtout les centaines d'allocations internes à l'ACPI
# (cat et non read : ce fichier refuse d'être lu octet par octet)
texte=$(cat /sys/module/pilote/sections/.text)
for f in failslab fail_page_alloc; do
    echo $texte > $DBG/$f/require-start
    echo 12 > $DBG/$f/stacktrace-depth
done
echo $EDU > $DRV/unbind

n=1
while [ $n -le 200 ]; do
    exec 3>$DRV/bind
    echo $n > /proc/self/fail-nth
    echo $EDU >&3 2>/dev/null
    # fail-nth vaut 0 si la faute a été injectée pendant le bind. Sinon le
    # probe fait moins de n allocations : tout a été couvert.
    if ! read reste < /proc/self/fail-nth || [ "$reste" != 0 ]; then
        echo 0 > /proc/self/fail-nth 2>/dev/null
        exec 3>&-
        break
    fi
    exec 3>&-
    [ -e $DRV/$EDU ] && echo $EDU > $DRV/unbind
    verifier_propre "faute n°$n"
    n=$((n + 1))
done
echo "--- $((n - 1)) allocation(s) mises en échec"

[ -e $DRV/$EDU ] || echo "ECHEC : le probe sans faute n'a pas abouti"
rmmod pilote || echo "ECHEC rmmod"
verifier_propre "rmmod"
kmemleak_fin
dma_api_fin
