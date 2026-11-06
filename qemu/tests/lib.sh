#!/bin/sh
# Fonctions communes aux tests, copiées dans la VM en /lib.sh

DRV=/sys/bus/pci/drivers/qemu_edu_driver
DBG=/sys/kernel/debug

for d in /sys/bus/pci/devices/*; do
    [ "$(cat $d/vendor):$(cat $d/device)" = "0x1234:0x11e8" ] && EDU=${d##*/}
done

# Vérifie que le pilote n'a rien laissé derrière lui une fois détaché de la carte
verifier_propre() {
    grep -q qemu_edu_driver /proc/interrupts && echo "ECHEC $1: IRQ toujours enregistrée"
    grep -q qemu_edu_driver /proc/iomem && echo "ECHEC $1: BAR toujours réservée"
    # Octet 4 de l'espace de configuration PCI = registre Command, bit 2 = Bus Master
    cmd=$(od -An -tu1 -j4 -N1 /sys/bus/pci/devices/$EDU/config | tr -d ' ')
    [ $((cmd & 4)) -ne 0 ] && echo "ECHEC $1 : Bus Master encore actif"
    return 0
}

# Oublie les fuites déjà présentes au démarrage (celles du noyau lui-même)
kmemleak_debut() {
    [ -w $DBG/kmemleak ] && echo clear > $DBG/kmemleak
    return 0
}

# Les rapports kmemleak contiennent "unreferenced object", repéré par check.sh
kmemleak_fin() {
    [ -w $DBG/kmemleak ] || return 0
    sleep 6 # kmemleak ignore les objets de moins de 5 s
    echo scan > $DBG/kmemleak
    echo scan > $DBG/kmemleak
    cat $DBG/kmemleak
}

# Erreurs relevées par CONFIG_DMA_API_DEBUG (mauvais usage de l'API DMA)
dma_api_fin() {
    [ -r $DBG/dma-api/error_count ] || return 0
    n=$(cat $DBG/dma-api/error_count)
    [ "$n" -ne 0 ] && echo "ECHEC DMA-API : $n erreur(s)"
    return 0
}
