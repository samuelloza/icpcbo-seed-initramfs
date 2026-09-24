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

# init (PID1) hereda stdin de la consola del kernel, que con
# "console=tty0 console=ttyS0" es la SERIAL: ENTER en la ventana gráfica no
# llegaba. Se fija stdin a tty0 (la ventana que ve el operador).
# CONSOLE_DEV lo usa whiptail, que necesita una terminal real en 0/1/2 y no
# sirve contra el 'tee' de la salida general.
CONSOLE_DEV=/dev/console
if [ -c /dev/tty0 ] && [ -r /dev/tty0 ]; then
    CONSOLE_DEV=/dev/tty0
    exec 0</dev/tty0
fi

# Con set -e cualquier comando que falle aborta sin decir cuál: este trap
# imprime la causa (script, línea, comando, código) antes de salir.
trap 'rc=$?; echo "  CAUSA: ${BASH_SOURCE[0]##*/}:${LINENO}: fallo \`${BASH_COMMAND}\` (código ${rc})" >&2; exit ${rc}' ERR

ethernet_device() {
    nmcli -t -f DEVICE,TYPE device 2>/dev/null \
        | awk -F: '$2 == "ethernet" { print $1; exit }' || true
}

# Todas las NIC cableadas: una máquina puede traer placa onboard + tarjeta PCI,
# o doble puerto, con el cable en cualquiera de ellas.
ethernet_devices() {
    nmcli -t -f DEVICE,TYPE device 2>/dev/null \
        | awk -F: '$2 == "ethernet" { print $1 }' || true
}

wifi_device() {
    nmcli -t -f DEVICE,TYPE device 2>/dev/null \
        | awk -F: '$2 == "wifi" { print $1; exit }' || true
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

# Enciende la red e intenta DHCP en CADA interfaz cableada hasta que una dé IP.
try_dhcp() {
    echo "  Interfaces: $(ip -brief link 2>/dev/null | tr '\n' ' ')"
    nmcli networking on || true
    local device found=0
    for device in $(ethernet_devices); do
        found=1
        echo "  Solicitando DHCP por ${device}..."
        nmcli -w 8 device connect "${device}" || true
        has_ipv4 && return 0
    done
    [ "${found}" = 1 ] || echo '  NetworkManager no detecta una interfaz Ethernet.'
}

# Vuelca las NIC del equipo y el firmware que el kernel reclama; sirve para
# diagnosticar in situ una tarjeta que no levanta en un equipo desconocido.
show_nic_hardware() {
    echo '  Controladoras de red detectadas:'
    { lspci -nn 2>/dev/null | grep -iE 'ethernet|network'; \
      lsusb 2>/dev/null | grep -iE 'ethernet|wireless|wi-?fi|802\.11|network'; } \
        | sed 's/^/    /' || true
    if dmesg 2>/dev/null | grep -i firmware | grep -iqE 'fail|missing|error'; then
        echo '  Firmware que el kernel no encontró (falta el paquete):'
        dmesg 2>/dev/null | grep -i firmware | grep -iE 'fail|missing|error' \
            | sed 's/^/    /' | tail -n 10
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

# Formulario de IP (DHCP automático o manual) reusado por cable y WiFi:
# misma secuencia de diálogos whiptail + nmcli, sólo cambian device/connection/title.
edit_ip_config() {
    local device="$1" connection="$2" title="$3"
    local mode ip gw dns cur_ip cur_gw cur_dns err

    mode="$(whiptail --title "${title}" --notags --menu \
        'Modo de dirección IP (ESC vuelve al menú anterior):' 12 64 2 \
        auto   'DHCP automático' \
        manual 'IP fija (manual)' \
        3>&1 1>&2 2>&3)" || return

    if [ "${mode}" = auto ]; then
        nmcli connection modify "${connection}" \
            ipv4.method auto ipv4.addresses '' ipv4.gateway '' ipv4.dns '' >/dev/null 2>&1
    else
        cur_ip="$(nmcli -g IP4.ADDRESS device show "${device}" 2>/dev/null | head -n1)"
        cur_gw="$(nmcli -g IP4.GATEWAY device show "${device}" 2>/dev/null | head -n1)"
        cur_dns="$(nmcli -g IP4.DNS device show "${device}" 2>/dev/null | paste -sd, - 2>/dev/null)"
        ip="$(whiptail --title "${title}" --inputbox \
            'Dirección IP con máscara CIDR, p. ej. 192.168.5.50/24:' 9 66 "${cur_ip}" \
            3>&1 1>&2 2>&3)" || return
        gw="$(whiptail --title "${title}" --inputbox \
            'Puerta de enlace (gateway), p. ej. 192.168.5.1:' 9 66 "${cur_gw}" \
            3>&1 1>&2 2>&3)" || return
        dns="$(whiptail --title "${title}" --inputbox \
            'DNS (uno o varios separados por coma):' 9 66 "${cur_dns:-${gw}}" \
            3>&1 1>&2 2>&3)" || return
        if ! err="$(nmcli connection modify "${connection}" \
            ipv4.method manual ipv4.addresses "${ip}" \
            ipv4.gateway "${gw}" ipv4.dns "${dns}" 2>&1)"; then
            whiptail --title "${title}" --msgbox \
                "Datos inválidos:\n${err}" 12 66
            return
        fi
    fi

    if err="$(nmcli -w 20 connection up uuid "${connection}" ifname "${device}" 2>&1)"; then
        echo; echo "  ${title}: configuración de IP aplicada."; network_summary
        whiptail --title "${title}" --msgbox \
            "$(network_summary)" 11 60
    else
        whiptail --title "${title}" --msgbox \
            "No se pudo activar la conexión:\n${err}" 12 66
    fi
}

# Configura el cable con formularios whiptail + nmcli (nmtui necesita un
# terminfo/terminal que el mini no siempre tiene: se cerraba y volvía al menú).
edit_ethernet() {
    local device connection
    device="$(ethernet_device)"
    if [ -z "${device}" ]; then
        whiptail --title 'Red cableada' --msgbox \
            'NetworkManager no detecta una interfaz Ethernet.' 8 60
        return
    fi

    connection="$(nmcli -t -f UUID,TYPE connection show 2>/dev/null \
        | awk -F: '$2 == "802-3-ethernet" { print $1; exit }')"
    if [ -z "${connection}" ]; then
        if ! nmcli connection add type ethernet ifname "${device}" \
            con-name "Cable ${device}" >/dev/null 2>&1; then
            whiptail --title 'Red cableada' --msgbox \
                'No se pudo crear la configuración Ethernet.' 8 60
            return
        fi
        connection="$(nmcli -g connection.uuid connection show "Cable ${device}")"
    fi

    edit_ip_config "${device}" "${connection}" "Cable: ${device}"
}

# Edita la IP de la conexión WiFi activa (o, si ninguna está activa, la
# guardada más reciente) reusando el mismo formulario que el cable.
edit_wifi_ip() {
    local device connection ssid
    device="$(wifi_device)"
    if [ -z "${device}" ]; then
        whiptail --title 'WiFi' --msgbox \
            'Linux/NetworkManager no detecta un adaptador WiFi.' 8 60
        return
    fi

    connection="$(nmcli -t -f DEVICE,UUID,TYPE connection show --active 2>/dev/null \
        | awk -F: -v d="${device}" '$1 == d { print $2; exit }')"
    if [ -z "${connection}" ]; then
        connection="$(nmcli -t -f UUID,TYPE,TIMESTAMP connection show 2>/dev/null \
            | awk -F: '$2 == "802-11-wireless"' | sort -t: -k3 -rn | head -n1 | cut -d: -f1)"
    fi
    if [ -z "${connection}" ]; then
        whiptail --title 'WiFi' --msgbox \
            'Conéctese primero a una red WiFi ("Ver redes WiFi y conectar").' 9 68
        return
    fi

    ssid="$(nmcli -g connection.id connection show "${connection}" 2>/dev/null)"
    edit_ip_config "${device}" "${connection}" "WiFi: ${ssid:-${connection}}"
}

configure_wifi() {
    local device choice password security ssid line
    local -a networks securities options connect_args
    nmcli radio wifi on || true
    device="$(wifi_device)"
    if [ -z "${device}" ]; then
        whiptail --title 'WiFi' --msgbox \
            'Linux/NetworkManager no detecta un adaptador WiFi. Revise /var/log/mini-network.log para identificar el driver o firmware faltante.' 9 68
        return 1
    fi
    nmcli device set "${device}" managed yes || true
    nmcli device wifi rescan ifname "${device}" || true

    while IFS= read -r line; do
        security="${line%%:*}"
        ssid="${line#*:}"
        [ -n "${ssid}" ] || continue
        networks+=("${ssid}")
        securities+=("${security}")
        options+=("${#networks[@]}" "${ssid}  [${security:---}]")
    done < <(nmcli -t --escape no -f SECURITY,SSID device wifi list ifname "${device}")

    options+=(oculta 'Red oculta (SSID no visible en el escaneo)...')

    choice="$(whiptail --title 'Redes WiFi' --menu \
        'Seleccione una red (ESC vuelve al menú anterior):' 20 72 12 \
        "${options[@]}" 3>&1 1>&2 2>&3)" || return

    if [ "${choice}" = oculta ]; then
        ssid="$(whiptail --title 'Red oculta' --inputbox \
            'SSID de la red oculta:' 9 66 3>&1 1>&2 2>&3)" || return
        [ -n "${ssid}" ] || return
        security=oculta
        connect_args=(device wifi connect "${ssid}" ifname "${device}" hidden yes)
    else
        ssid="${networks[choice - 1]}"
        security="${securities[choice - 1]}"
        connect_args=(device wifi connect "${ssid}" ifname "${device}")
    fi

    if [ -n "${security}" ] && [ "${security}" != '--' ]; then
        password="$(whiptail --title "WiFi: ${ssid}" --passwordbox \
            'Contraseña (déjela vacía para usar una conexión ya guardada):' \
            9 68 3>&1 1>&2 2>&3)" || return
        [ -z "${password}" ] || connect_args+=(password "${password}")
    fi

    if nmcli -w 30 "${connect_args[@]}"; then
        echo
        echo "  Conectado a ${ssid}. Conexión WiFi por DHCP lista."
        network_summary
        return 0
    else
        whiptail --title 'WiFi' --msgbox \
            "No se pudo conectar a ${ssid}. Revise la contraseña e intente otra vez." 9 68
        return 1
    fi
}

# Con IP ya asignada por DHCP, el gateway es más útil que invitar a reintentar.
dhcp_menu_label() {
    local gw
    if has_ipv4; then
        gw="$(ip -4 route show default 2>/dev/null | awk 'NR == 1 { print $3 }')"
        [ -z "${gw}" ] || { printf 'Puerta de enlace: %s' "${gw}"; return; }
    fi
    printf 'Reintentar DHCP'
}

# whiptail es TUI: necesita una terminal real en 0/1/2. La salida general va por
# un 'tee' (una tuberia, no una tty), asi que se ejecuta con las tres
# descripciones apuntadas a la consola (tty0).
_network_menu_ui() {
    while :; do
        local choice
        choice="$(whiptail --title 'Preparación del equipo: red' --notags \
            --menu "$(network_status)" 18 70 6 \
            continue 'Continuar al despliegue' \
            dhcp     "$(dhcp_menu_label)" \
            ethernet 'Editar cable Ethernet (IP, gateway, DNS)' \
            wifi     'Ver redes WiFi y conectar' \
            wifi-ip  'Editar IP de la red WiFi actual' \
            3>&1 1>&2 2>&3)" || return 0

        case "${choice}" in
            continue) return 0 ;;
            dhcp)     try_dhcp ;;
            ethernet) edit_ethernet ;;
            wifi)     configure_wifi && return 0 ;;
            wifi-ip)  edit_wifi_ip ;;
        esac
    done
}

network_menu() {
    if [ -c "${CONSOLE_DEV}" ]; then
        _network_menu_ui <"${CONSOLE_DEV}" >"${CONSOLE_DEV}" 2>"${CONSOLE_DEV}"
    else
        _network_menu_ui
    fi
}

printf '    _\n  >( )_\n   (___)\n\n'
echo '  ICPC Bolivia - Preparación del equipo'
if grep -qw toram /proc/cmdline 2>/dev/null \
    && awk '$2 == "/run/live/medium" && $3 == "tmpfs" { found=1 } END { exit !found }' /proc/mounts; then
    cat <<'EOF'

  ==================================================
     ISO EN RAM: RETIRE EL USB CON SEGURIDAD
  ==================================================

EOF
fi
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
    echo '  No hay red. Conecte el cable Ethernet o configure WiFi.'
    show_nic_hardware
fi
network_menu

exec /usr/lib/mini-deploy/lan-fetch.sh
