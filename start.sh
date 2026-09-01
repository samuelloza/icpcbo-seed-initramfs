#!/usr/bin/env bash
# Envoltura local: build-mini construye la ISO, run-mini la arranca en QEMU.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}"
ISO="${OUTPUT_DIR}/mini-deploy.iso"
UPDATES_DIR="${UPDATES_DIR:-$(cd "${PROJECT_DIR}/.." && pwd)/tmp/updates}"
[ -f "${PROJECT_DIR}/config.env" ] && set -a && . "${PROJECT_DIR}/config.env" && set +a

PARENT_DIR="$(cd "${PROJECT_DIR}/.." && pwd)"

# Busca el runtime en tmp/updates/artifacts/<version>/ del proyecto padre.
find_artifacts() {
    if [ -n "${ARTIFACTS_DIR:-}" ] && [ -f "${ARTIFACTS_DIR}/vmlinuz" ]; then return 0; fi
    local v
    v="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
         "${UPDATES_DIR}/manifest.json" 2>/dev/null || true)"
    [ -n "${v}" ] && [ -f "${UPDATES_DIR}/artifacts/${v}/vmlinuz" ] || return 1
    export ARTIFACTS_DIR="${UPDATES_DIR}/artifacts/${v}"
    export METADATA_DIR="${METADATA_DIR:-${UPDATES_DIR}}"
}

# build-mini construye TODO: si falta el runtime, lo genera con el proyecto padre
# (publish-lan = debootstrap + squashfs + manifest + torrent, sin firma) y sigue.
resolve_artifacts() {
    find_artifacts && { echo "runtime: ${ARTIFACTS_DIR}"; return; }
    [ "${AUTO_BUILD_RUNTIME:-1}" = 1 ] || {
        echo "ERROR: no hay runtime y AUTO_BUILD_RUNTIME=0. Pon ARTIFACTS_DIR en config.env." >&2; exit 1; }
    echo ">> No hay runtime; construyéndolo: scripts/build.sh publish-lan"
    ( cd "${PARENT_DIR}" && ./scripts/build.sh publish-lan )
    find_artifacts || { echo "ERROR: publish-lan terminó pero no encuentro el runtime." >&2; exit 1; }
    echo "runtime: ${ARTIFACTS_DIR}"
}

build_mini() {
    [ "$(id -u)" = 0 ] || { echo "Ejecuta como root: sudo ./start.sh build-mini" >&2; exit 1; }
    resolve_artifacts
    # Reutiliza apt-cacher-ng del proyecto principal si está escuchando en 3142.
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
