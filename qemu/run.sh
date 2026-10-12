#!/bin/sh
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/..
KVER=${KVER:-$(uname -r)}
WORK=$HERE/build
BUSYBOX=$(command -v busybox)

MEM=512M
QEMU_EXTRA=""
KARGS=""
AUTORUN=""

usage() {
    cat <<USAGE
Usage: $0 [options]
  -e          erreurs du device côté QEMU (-d guest_errors) : DMA hors limites, adresses tronquées
  -m TAILLE   RAM de la VM (défaut 512M), ex. -m 2G pour tester le masque DMA
  -t SCRIPT   exécute SCRIPT dans la VM puis l'éteint (mode non interactif)
  -g          attend gdb sur le port 1234 (-s -S) et désactive KASLR
  -k ARGS     arguments noyau en plus, ex. -k "panic_on_warn=1"
  -h          cette aide
Variable : KVER=<version> pour démarrer un autre noyau installé (ex. le noyau +debug)
USAGE
}

while getopts "em:t:gk:h" opt; do
    case $opt in
        e) QEMU_EXTRA="$QEMU_EXTRA -d guest_errors" ;;
        m) MEM=$OPTARG ;;
        t) AUTORUN=$(realpath "$OPTARG") ;;
        g) QEMU_EXTRA="$QEMU_EXTRA -s -S"; KARGS="$KARGS nokaslr"
           echo ">> gdb : gdb /usr/src/kernels/$KVER/vmlinux -ex 'target remote :1234'" ;;
        k) KARGS="$KARGS $OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

make -C "/lib/modules/$KVER/build" M="$(realpath "$SRC")" MO="$(realpath "$SRC")/build" modules

rm -rf "$WORK/root"
mkdir -p "$WORK/root"/bin "$WORK/root"/proc "$WORK/root"/sys "$WORK/root"/dev "$WORK/root"/modules "$WORK/root"/tmp
cp "$BUSYBOX" "$WORK/root/bin/busybox"
cp "$HERE/init" "$WORK/root/init"
chmod +x "$WORK/root/init"
cp "$SRC"/build/*.ko "$WORK/root/modules/" 2>/dev/null || true
[ -d "$SRC/user" ] && cp "$SRC"/user/* "$WORK/root/bin/" 2>/dev/null || true
[ -n "$AUTORUN" ] && cp "$AUTORUN" "$WORK/root/autorun.sh" && chmod +x "$WORK/root/autorun.sh"
(cd "$WORK/root" && find . | cpio -o -H newc --quiet | gzip) > "$WORK/initramfs.cpio.gz"

exec qemu-system-x86_64 \
    -enable-kvm -cpu host -m "$MEM" -smp 2 \
    -kernel /boot/vmlinuz-$KVER \
    -initrd "$WORK/initramfs.cpio.gz" \
    -append "console=ttyS0 quiet$KARGS" \
    -device edu \
    -nographic -no-reboot $QEMU_EXTRA
