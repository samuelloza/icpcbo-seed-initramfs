#!/usr/bin/env bash
# build-mini: construye la imagen base del mini (deploy.squashfs + ISO booteable).
# run-mini:   arranca esa ISO en QEMU para probarla.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}"
ISO="${OUTPUT_DIR}/mini-deploy.iso"

build_mini() {
    [ "$(id -u)" = 0 ] || { echo "Ejecuta como root: sudo ./start.sh build-mini" >&2; exit 1; }
    # Reutiliza apt-cacher-ng si está escuchando en 3142 (el internet en casa es lento).
    if [ -z "${APT_PROXY:-}" ] && (exec 3<>/dev/tcp/127.0.0.1/3142) 2>/dev/null; then
        export APT_PROXY="http://127.0.0.1:3142"
        echo "apt-cacher-ng detectado: APT_PROXY=${APT_PROXY}"
    fi
    exec "${PROJECT_DIR}/build-iso.sh"
}

run_mini() {
    [ -f "${ISO}" ] || { echo "No existe ${ISO}; corre primero: sudo ./start.sh build-mini" >&2; exit 1; }
    command -v qemu-system-x86_64 >/dev/null || { echo "Falta qemu-system-x86_64" >&2; exit 1; }
    local disk="${OUTPUT_DIR}/run-mini-scratch.img"
    [ -f "${disk}" ] || qemu-img create -f qcow2 "${disk}" "${RUN_MINI_DISK_GB:-8}G" >/dev/null
    local kvm=()
    [ -w /dev/kvm ] && kvm=(-enable-kvm -cpu host)
    echo "Serial en esta terminal. Ctrl-a x para salir de QEMU."
    exec qemu-system-x86_64 "${kvm[@]}" -m "${RUN_MINI_MEM_MIB:-2048}" \
        -cdrom "${ISO}" -drive file="${disk}",format=qcow2,if=virtio \
        -boot d -nographic -no-reboot
}

case "${1:-}" in
    build-mini) build_mini ;;
    run-mini)   run_mini ;;
    *) echo "Uso: sudo ./start.sh {build-mini|run-mini}" >&2; exit 1 ;;
esac
