#!/usr/bin/env bash
set -euo pipefail

# Serial para que KVM/virsh
if [ -c /dev/ttyS0 ] && [ -w /dev/ttyS0 ]; then
    exec > >(tee /dev/ttyS0) 2>&1
fi

ethernet_device() {
    nmcli -t -f DEVICE,TYPE device 2>/dev/null \
        | awk -F: '$2 == "ethernet" { print $1; exit }'
}

# Una línea por interfaz con IP global ("enp1s0  192.168.1.20/24"),
network_status() {
    ip -4 -brief addr show scope global 2>/dev/null | awk '
        $1 != "lo" { print $1 "  " $3; found = 1 }
        END        { if (!found) print "SIN CONEXIÓN" }
    '
}

# Enciende la red e intenta conectar la interfaz cableada por DHCP.
try_dhcp() {
    nmcli -w 20 networking on >/dev/null 2>&1 || true
    local device
    device="$(ethernet_device)"
    [ -z "${device}" ] || nmcli -w 25 device connect "${device}" >/dev/null 2>&1 || true
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

clear
echo '  ICPC Bolivia - Preparación del equipo'
echo '  Preparando red por DHCP...'
try_dhcp
echo "  Red: $(network_status | tr '\n' ' ')"
echo '  Pulse una tecla en 10 segundos para configurar IP o WiFi.'
if read -r -n 1 -t 10 _; then network_menu; fi

exec /usr/lib/mini-deploy/lan-fetch.sh
