#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${TEST_DIR:-${ROOT}/output/test-vms}"
SCENARIO="${1:-static}"
VIRSH="virsh --connect qemu:///system"

# Escenarios VM automáticos con ventana gráfica por defecto. Ajustables:
#   TEST_HEADLESS=1        no abre ventanas (CI)
#   REBUILD_ISO=1          fuerza reconstruir la ISO (por defecto se reutiliza)
#   SEED_TIMEOUT=900       s máx. a que el seed llegue a "Sembrando el runtime"
#   CLIENT_TIMEOUT=600     s máx. a que el cliente copie por LAN
#   TEST_DISK_SIZE=8G      tamaño de cada disco qcow2 desechable
SEED_TIMEOUT="${SEED_TIMEOUT:-900}"
CLIENT_TIMEOUT="${CLIENT_TIMEOUT:-600}"

VMS=()
KEEP_VMS=0

usage() {
    cat <<'EOF'
Uso:
  ./test.sh                 pruebas rápidas estáticas, sin VM
  sudo ./test.sh fallback   una VM visible sin seed -> respaldo HTTP
  sudo ./test.sh lan        dos VMs visibles, cliente copia del seed por LAN
  sudo ./test.sh run-seed   inicia solo el seed y conserva su disco
  sudo ./test.sh run-client inicia solo el cliente y conserva su disco
  sudo ./test.sh stop       apaga las VMs; conserva sus discos
  sudo ./test.sh all        estáticas + fallback + lan

Los escenarios VM abren ventanas y además capturan la consola serie para
verificar mensajes solos. Use TEST_HEADLESS=1 en CI. Necesitan libvirt/KVM y
la red NAT 'default'. ISO y discos se reutilizan; RESET_TEST_DISKS=1 recrea
el disco de la máquina que se inicia.
EOF
}

cleanup() {
    local vm
    [ "${KEEP_VMS}" = 0 ] || return 0
    for vm in ${VMS[@]+"${VMS[@]}"}; do ${VIRSH} destroy "${vm}" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT INT TERM

require_vm_tools() {
    [ "$(id -u)" = 0 ] || { echo "Ejecuta este escenario con sudo." >&2; exit 1; }
    local c
    for c in qemu-img virt-format virsh virt-install; do
        command -v "${c}" >/dev/null || { echo "Falta ${c}." >&2; exit 1; }
    done
    if [ "${TEST_HEADLESS:-0}" != 1 ]; then
        command -v virt-viewer >/dev/null || { echo 'Falta virt-viewer (o use TEST_HEADLESS=1).' >&2; exit 1; }
    fi
    ${VIRSH} net-info default >/dev/null 2>&1 || { echo "Falta la red NAT de libvirt 'default'." >&2; exit 1; }
    ${VIRSH} net-list --name | grep -Fxq default || ${VIRSH} net-start default
    # Sin esto el bridge de libvirt puede tragarse el multicast LPD entre guests.
    local b=/sys/class/net/virbr0/bridge/multicast_snooping
    if [ -w "${b}" ]; then echo 0 > "${b}"; fi
}

build_iso() {
    local iso="${ROOT}/output/mini-deploy.iso" stale=0 file
    if [ -f "${iso}" ]; then
        for file in build.sh build-iso.sh packages.list config.env; do
            [ "${ROOT}/${file}" -nt "${iso}" ] && stale=1
        done
        find "${ROOT}/overlay" -type f -newer "${iso}" -print -quit | grep -q . && stale=1
    fi
    if [ "${REBUILD_ISO:-0}" = 1 ] || [ ! -f "${iso}" ] || [ "${stale}" = 1 ]; then
        echo "== Construyendo ISO (faltante, forzada o desactualizada) =="
        "${ROOT}/start.sh" build-mini
    else
        echo "== Reutilizando ${iso} (está actualizada) =="
    fi
}

new_disk() {
    local disk="${TEST_DIR}/$1.qcow2"
    ${VIRSH} destroy "$1" >/dev/null 2>&1 || true
    mkdir -p "${TEST_DIR}"
    [ "${RESET_TEST_DISKS:-0}" = 1 ] && rm -f "${disk}"
    if [ -f "${disk}" ]; then
        echo "Reutilizando disco: ${disk}" >&2
        printf '%s\n' "${disk}"
        return
    fi
    qemu-img create -q -f qcow2 "${disk}" "${TEST_DISK_SIZE:-8G}" >&2
    virt-format --format=qcow2 --filesystem=ext4 -a "${disk}" >&2
    printf '%s\n' "${disk}"
}

# boot_vm <name> <disk> <logfile>: abre la VM y conserva su consola en el log.
boot_vm() {
    local name="$1" disk="$2" log="$3"
    local -a run_env=(RUN_MINI_SERIAL_LOG="${log}" MINI_VM_NAME="${name}"
                      RUN_MINI_TARGET_DISK="${disk}" RUN_MINI_EXTRA_DISK='')
    VMS+=("${name}")
    ${VIRSH} destroy "${name}" >/dev/null 2>&1 || true
    if [ "${TEST_HEADLESS:-0}" = 1 ]; then
        run_env+=(RUN_MINI_HEADLESS=1)
    else
        run_env+=(RUN_MINI_NOAUTOCONSOLE=1)
    fi
    env "${run_env[@]}" "${ROOT}/start.sh" run-mini
    local tries=0
    until ${VIRSH} domstate "${name}" 2>/dev/null | grep -q running; do
        sleep 1; tries=$((tries + 1))
        [ "${tries}" -lt 30 ] || { echo "FAIL: la VM ${name} no llegó a 'running'." >&2; return 1; }
    done
    if [ "${TEST_HEADLESS:-0}" != 1 ]; then
        virt-viewer --connect qemu:///system "${name}" >/dev/null 2>&1 &
    fi
}

run_one() {
    local role="$1" name="mini-$1" disk log
    disk="$(new_disk "${name}")"
    log="${TEST_DIR}/${role}.log"
    KEEP_VMS=1
    boot_vm "${name}" "${disk}" "${log}"
    echo "VM ${name} activa; disco persistente: ${disk}"
    echo "Log: ${log}"
}

stop_vms() {
    local vm
    for vm in mini-seed mini-client mini-fallback; do
        ${VIRSH} destroy "${vm}" >/dev/null 2>&1 || true
    done
    echo 'VMs detenidas; los discos se conservaron.'
}

# wait_for_log <logfile> <ERE> <timeout_s> <label>
wait_for_log() {
    local log="$1" pat="$2" timeout="$3" label="$4" waited=0
    while ! grep -Eq "${pat}" "${log}" 2>/dev/null; do
        sleep 3; waited=$((waited + 3))
        if [ "$((waited % 30))" = 0 ]; then echo "  ... esperando '${label}' (${waited}s/${timeout}s)"; fi
        if [ "${waited}" -ge "${timeout}" ]; then
            echo "FAIL: timeout ${timeout}s esperando '${label}'." >&2
            echo "----- últimas líneas de ${log} -----" >&2
            tail -n 30 "${log}" >&2
            return 1
        fi
    done
    echo "  OK: '${label}' (${waited}s)"
}

test_fallback() {
    local disk log="${TEST_DIR}/fallback.log"
    stop_vms
    disk="$(new_disk mini-fallback)"
    echo "== fallback: 1 VM, sin seed en la LAN =="
    boot_vm mini-fallback "${disk}" "${log}"
    wait_for_log "${log}" 'Buscando un seed en la red local' 300 'inicio de la ventana LAN'
    wait_for_log "${log}" 'Sin progreso \(ni peers ni bytes nuevos\) durante [0-9]+ s' 300 'watchdog LAN agotado'
    wait_for_log "${log}" 'Descargando runtime desde ' 60 'salto al respaldo HTTP'
    echo "PASS: fallback  |  sin seed -> respaldo HTTP como se espera"
}

test_lan() {
    local seed_disk client_disk
    local seed_log="${TEST_DIR}/seed.log" client_log="${TEST_DIR}/client.log"
    stop_vms
    seed_disk="$(new_disk mini-seed)"
    client_disk="$(new_disk mini-client)"

    echo "== lan: VM seed (baja de Internet y siembra) =="
    boot_vm mini-seed "${seed_disk}" "${seed_log}"
    wait_for_log "${seed_log}" 'Sembrando el runtime desde ' "${SEED_TIMEOUT}" \
        'el seed llega a modo semilla'

    echo "== lan: VM cliente (debe copiar del seed por LAN) =="
    boot_vm mini-client "${client_disk}" "${client_log}"
    wait_for_log "${client_log}" 'Sembrando el runtime desde |El runtime fue copiado y validado' \
        "${CLIENT_TIMEOUT}" 'el cliente completa la copia'

    if grep -Eq 'Descargando runtime desde |el runtime se descargará de Internet' "${client_log}"; then
        echo "FAIL: el cliente cayó al respaldo HTTP; NO copió del seed LAN." >&2
        grep -nE 'seed|LAN|Descargando|Sembrando|descarga:' "${client_log}" | tail -n 20 >&2
        return 1
    fi

    echo "----- resumen del enjambre (cliente) -----"
    grep -E 'Esta máquina .*seeds: [1-9]|descarga: ' "${client_log}" | tail -n 5 || true
    echo "PASS: lan  |  el cliente copió el runtime del seed por LAN (sin tocar HTTP)"
}

case "${SCENARIO}" in
    static) "${ROOT}/tests/run.sh" ;;
    fallback) require_vm_tools; build_iso; test_fallback ;;
    lan)      require_vm_tools; build_iso; test_lan ;;
    run-seed) require_vm_tools; build_iso; run_one seed ;;
    run-client) require_vm_tools; build_iso; run_one client ;;
    stop)
        [ "$(id -u)" = 0 ] || { echo 'Ejecuta este escenario con sudo.' >&2; exit 1; }
        command -v virsh >/dev/null || { echo 'Falta virsh.' >&2; exit 1; }
        KEEP_VMS=1; stop_vms ;;
    all)
        "${ROOT}/tests/run.sh"
        require_vm_tools; build_iso
        test_fallback
        test_lan ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 1 ;;
esac
