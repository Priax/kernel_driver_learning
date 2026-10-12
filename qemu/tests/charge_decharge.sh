#!/bin/sh
for i in 1 2 3; do
    echo "--- cycle $i : insmod"
    insmod /modules/pilote.ko || echo "ECHEC insmod"
    sleep 1
    echo "--- cycle $i : rmmod"
    rmmod pilote || echo "ECHEC rmmod"
done
