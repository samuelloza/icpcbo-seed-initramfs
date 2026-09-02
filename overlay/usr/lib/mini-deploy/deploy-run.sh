#!/usr/bin/env bash
set -euo pipefail

LOG=/run/mini-deploy/session.log
mkdir -p "${LOG%/*}"
: > "${LOG}"

# En QEMU, tty0 es la UI gráfica y ttyS0 es la consola serial.
if [ -w /dev/tty0 ] && [ -w /dev/ttyS0 ]; then
    exec > >(tee "${LOG}" /dev/tty0 /dev/ttyS0 >/dev/null) 2>&1
elif [ -w /dev/console ]; then
    exec > >(tee "${LOG}" >/dev/console) 2>&1
fi

# Con set -e cualquier comando que falle aborta sin decir cuál: este trap
# imprime la causa (script, línea, comando, código) antes de salir.
trap 'rc=$?; echo "  CAUSA: ${BASH_SOURCE[0]##*/}:${LINENO}: fallo \`${BASH_COMMAND}\` (código ${rc})" >&2; exit ${rc}' ERR

ethernet_device() {
    nmcli -t -f DEVICE,TYPE device 2>/dev/null \
        | awk -F: '$2 == "ethernet" { print $1; exit }' || true
}

# Una línea por interfaz con IP global ("enp1s0  192.168.1.20/24"),
network_status() {
    ip -4 -brief addr show scope global 2>/dev/null | awk '
        $1 != "lo" { print $1 "  " $3; found = 1 }
        END        { if (!found) print "SIN RED" }
    '
}

network_summary() {
    local address gateway dns
    address="$(ip -4 -o addr show scope global 2>/dev/null | awk '$2 != "lo" { print $4; exit }')"
    gateway="$(ip -4 route show default 2>/dev/null | awk 'NR == 1 { print $3 }')"
    dns="$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf 2>/dev/null)"
    printf '  IP: %s\n  Gateway: %s\n  DNS: %s\n' \
        "${address:-SIN IP}" "${gateway:--}" "${dns:--}"
}

has_ipv4() {
    ip -4 -o addr show scope global 2>/dev/null | grep -q .
}

# Enciende la red e intenta conectar la interfaz cableada por DHCP.
try_dhcp() {
    echo "  Interfaces: $(ip -brief link 2>/dev/null | tr '\n' ' ')"
    nmcli networking on || true
    local device
    device="$(ethernet_device)"
    if [ -z "${device}" ]; then
        echo '  NetworkManager no detecta una interfaz Ethernet.'
    else
        echo "  Solicitando DHCP por ${device}..."
        nmcli -w 8 device connect "${device}" || true
    fi
}

wait_for_network() {
    local attempt
    for attempt in 1 2 3 4 5; do
        try_dhcp
        has_ipv4 && return 0
        echo "  DHCP sin respuesta (${attempt}/5). Conecte el cable de red..."
        [ "${attempt}" = 5 ] || sleep 4
    done
    return 1
}

network_menu() {
    while :; do
        local choice
        choice="$(whiptail --title 'Preparación del equipo: red' --notags \
            --menu "$(network_status)" 18 70 6 \
            continue 'Continuar al despliegue' \
            dhcp     'Reintentar DHCP' \
            wifi     'Configurar WiFi o IP manual (nmtui)' \
            3>&1 1>&2 2>&3)" || return 0

        case "${choice}" in
            continue) return 0 ;;
            dhcp)     try_dhcp ;;
            wifi)     nmtui ;;
        esac
    done
}

echo '  ICPC Bolivia - Preparación del equipo'
echo '  Preparando red por DHCP...'
wait_for_network || true
if ! has_ipv4; then
    echo '  Esperando adaptador de red (10 segundos más)...'
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        try_dhcp
        has_ipv4 && break
        sleep 1
    done
fi
echo '  Resumen de red:'
network_summary
if ! has_ipv4; then
    echo '  No hay red. Conecte el cable Ethernet o configure WiFi/IP manual.'
    network_menu
fi

exec /usr/lib/mini-deploy/lan-fetch.sh
