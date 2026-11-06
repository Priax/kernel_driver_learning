#!/bin/sh
. /lib.sh
kmemleak_debut
for i in 1 2 3; do
    echo "--- cycle $i : insmod"
    insmod /modules/pilote.ko || echo "ECHEC insmod"
    sleep 1
    echo "--- cycle $i : rmmod"
    rmmod pilote || echo "ECHEC rmmod"
    verifier_propre "cycle $i"
done
kmemleak_fin
dma_api_fin
