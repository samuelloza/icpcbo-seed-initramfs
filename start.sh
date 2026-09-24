#!/usr/bin/env bash
# build-mini: construye la imagen base del mini (deploy.squashfs + ISO booteable).
# run-mini:   arranca esa ISO en QEMU para probarla.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARENT_DIR="$(cd "${PROJECT_DIR}/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}"
ISO="${OUTPUT_DIR}/mini-deploy.iso"
# Discos de prueba para run-mini. Por defecto se toman del proyecto padre, donde
# viven los qcow2; RUN_MINI_TARGET_DISK / RUN_MINI_EXTRA_DISK los sustituyen.
DEFAULT_TARGET_DISK="${PARENT_DIR}/Windows10.qcow2"
DEFAULT_EXTRA_DISK="${PARENT_DIR}/tmp/libvirt/images/icpc-bolivia-debian-lab-hdd.qcow2"

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
    [ "$(id -u)" = 0 ] || { echo "Ejecuta como root: sudo ./start.sh run-mini" >&2; exit 1; }
    [ -f "${ISO}" ] || { echo "No existe ${ISO}; corre primero: sudo ./start.sh build-mini" >&2; exit 1; }
    command -v virt-install >/dev/null || { echo "Falta virt-install" >&2; exit 1; }
    command -v virsh >/dev/null || { echo "Falta virsh" >&2; exit 1; }
    local disk="${RUN_MINI_TARGET_DISK:-${DEFAULT_TARGET_DISK}}"
    # Sin ':' -> un RUN_MINI_EXTRA_DISK='' EXPLÍCITO significa "sin disco extra"
    # (test.sh lo pasa así); solo si la variable no está definida se usa el
    # qcow2 del proyecto padre.
    local extra_disk="${RUN_MINI_EXTRA_DISK-${DEFAULT_EXTRA_DISK}}"
    local vm_name="${MINI_VM_NAME:-mini-deploy}"
    # Windows XP fue instalado con IDE: debe ser el primer disco y conservar ese bus.
    local -a disk_args=(--disk "path=${disk},format=qcow2,bus=ide")
    [ -f "${disk}" ] || { echo "No existe disco destino: ${disk}" >&2; exit 1; }
    echo "Disco primario IDE: ${disk}"
    if [ -n "${extra_disk}" ]; then
        [ -f "${extra_disk}" ] || { echo "No existe RUN_MINI_EXTRA_DISK: ${extra_disk}" >&2; exit 1; }
        disk_args+=(--disk "path=${extra_disk},format=qcow2,bus=ide")
        echo "Disco adicional IDE: ${extra_disk}"
    fi
    if virsh --connect qemu:///system domstate "${vm_name}" >/dev/null 2>&1; then
        echo "La VM ${vm_name} ya existe; no se conecta el disco por segunda vez."
        echo "Consola serial: sudo virsh --connect qemu:///system console ${vm_name}"
        return
    fi
    virsh --connect qemu:///system net-info default >/dev/null || {
        echo "Falta la red NAT de libvirt: 'default'." >&2; exit 1;
    }
    if ! virsh --connect qemu:///system net-list --name | grep -Fxq default; then
        virsh --connect qemu:///system net-start default
    fi

    # RUN_MINI_HEADLESS=1: sin SPICE ni visor (para tests con sudo sin sesión X);
    # virt-install devuelve en cuanto la VM arranca.
    # RUN_MINI_SERIAL_LOG=<archivo>: libvirt vuelca la consola serie a ese
    # archivo (no requiere TTY; para capturar en scripts). Sin él, pty normal
    # que se sigue con 'virsh console'.
    local -a display_args=(--graphics spice --video vga --autoconsole graphical)
    local -a serial_args=(--serial pty,target.type=isa-serial --console pty,target.type=serial)
    if [ -n "${RUN_MINI_HEADLESS:-}" ]; then
        display_args=(--graphics none --noautoconsole)
    elif [ -n "${RUN_MINI_NOAUTOCONSOLE:-}" ]; then
        display_args=(--graphics spice --video vga --noautoconsole)
    fi
    if [ -n "${RUN_MINI_SERIAL_LOG:-}" ]; then
        : > "${RUN_MINI_SERIAL_LOG}"
        serial_args=(--serial "file,path=${RUN_MINI_SERIAL_LOG}"
                     --console pty,target.type=serial)
    fi

    virt-install \
        --connect qemu:///system \
        --virt-type "$(vm_accel)" \
        --name "${vm_name}" \
        --memory "${RUN_MINI_MEM_MIB:-3048}" \
        --vcpus "${RUN_MINI_VCPUS:-3}" \
        --machine pc \
        --os-variant winxp \
        --import \
        "${disk_args[@]}" \
        --cdrom "${ISO}" \
        --boot hd,cdrom,menu=on \
        --network network=default,model=e1000 \
        "${serial_args[@]}" \
        --transient \
        "${display_args[@]}"

    [ -n "${RUN_MINI_SERIAL_LOG:-}" ] && chmod 0644 "${RUN_MINI_SERIAL_LOG}" 2>/dev/null || true

    echo "Consola serial: sudo virsh --connect qemu:///system console ${vm_name}"
}

vm_accel() {
    [ -w /dev/kvm ] && echo kvm || echo qemu
}

case "${1:-}" in
    build-mini) build_mini ;;
    run-mini)   run_mini ;;
    test)       shift; exec "${PROJECT_DIR}/test.sh" "$@" ;;
    *) echo "Uso: sudo ./start.sh {build-mini|run-mini|test}" >&2; exit 1 ;;
esac
