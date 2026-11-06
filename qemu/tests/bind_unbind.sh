#!/bin/sh
# Enchaîne remove/probe sans décharger le module
. /lib.sh
kmemleak_debut
insmod /modules/pilote.ko || echo "ECHEC insmod"
for i in $(seq 20); do
    echo $EDU > $DRV/unbind || echo "ECHEC unbind $i"
    verifier_propre "unbind $i"
    echo $EDU > $DRV/bind || echo "ECHEC bind $i"
done
rmmod pilote || echo "ECHEC rmmod"
verifier_propre "rmmod"
kmemleak_fin
dma_api_fin
