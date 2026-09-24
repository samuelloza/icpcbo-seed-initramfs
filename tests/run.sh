#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in build.sh build-iso.sh start.sh test.sh overlay/sbin/init overlay/usr/lib/mini-deploy/deploy-run.sh overlay/usr/lib/mini-deploy/lan-fetch.sh; do bash -n "${root}/${f}"; done
test -x "${root}/test.sh"
grep -q 'run-seed)' "${root}/test.sh"
grep -q 'run-client)' "${root}/test.sh"
grep -q 'RESET_TEST_DISKS:-0' "${root}/test.sh"
grep -q 'Reutilizando disco:' "${root}/test.sh"
# build_iso reutiliza la ISO por defecto (REBUILD_ISO=1 para forzar); nunca
# reconstruye a ciegas, pero tampoco ejecuta código más nuevo sobre una ISO vieja.
# El perfil WiFi vive en la RAM del mini: si no se copia al medio, el runtime
# arranca sin red tras el kexec (el runtime lo repone desde <CONTEST_DIR>/network).
grep -q '"${runtime}/network"' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q '/etc/NetworkManager/system-connections' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'REBUILD_ISO:-0' "${root}/test.sh"
grep -q 'overlay.*-newer.*iso' "${root}/test.sh"
grep -q 'desactualizada' "${root}/test.sh"
# Los escenarios VM son visibles por defecto; CI puede pedir headless.
grep -q 'TEST_HEADLESS:-0' "${root}/test.sh"
grep -q 'run_env+=(RUN_MINI_HEADLESS=1)' "${root}/test.sh"
grep -q 'virt-viewer --connect qemu:///system' "${root}/test.sh"
grep -q 'RUN_MINI_NOAUTOCONSOLE' "${root}/start.sh"
grep -q 'RUN_MINI_HEADLESS' "${root}/start.sh"
# libvirt vuelca la consola serie a un archivo (sin 'virsh console', que exige TTY).
grep -q 'RUN_MINI_SERIAL_LOG' "${root}/test.sh"
grep -q 'serial "file,path=' "${root}/start.sh"
grep -q 'chmod 0644 "${RUN_MINI_SERIAL_LOG}"' "${root}/start.sh"
if grep -q 'console --force' "${root}/test.sh"; then
  echo 'virsh console --force exige TTY; usa RUN_MINI_SERIAL_LOG' >&2; exit 1
fi
test -x "${root}/start.sh"
case "$("${root}/start.sh" 2>&1 || true)" in *build-mini*run-mini*) ;; *) exit 1 ;; esac
grep -q 'build-iso.sh' "${root}/start.sh"
grep -q 'virt-install' "${root}/start.sh"
grep -q 'RUN_MINI_TARGET_DISK' "${root}/start.sh"
grep -q 'RUN_MINI_EXTRA_DISK' "${root}/start.sh"
# RUN_MINI_EXTRA_DISK='' explícito = sin disco extra (test.sh lo pasa así):
# debe usar ${VAR-default}, no ${VAR:-default}.
grep -q 'RUN_MINI_EXTRA_DISK-' "${root}/start.sh"
if grep -q 'RUN_MINI_EXTRA_DISK:-' "${root}/start.sh"; then
  echo 'start.sh ignora un RUN_MINI_EXTRA_DISK vacío por usar :-' >&2; exit 1
fi
grep -q 'bus=ide' "${root}/start.sh"
grep -q -- '--network network=default,model=e1000' "${root}/start.sh"
grep -q -- '--boot hd,cdrom,menu=on' "${root}/start.sh"
grep -q -- '--machine pc' "${root}/start.sh"
grep -q -- '--os-variant winxp' "${root}/start.sh"
grep -q -- '--autoconsole graphical' "${root}/start.sh"
grep -q -- '--console pty,target.type=serial' "${root}/start.sh"
grep -q 'vm_accel' "${root}/start.sh"
grep -q 'domstate' "${root}/start.sh"
grep -q 'mksquashfs' "${root}/build.sh"
grep -q -- '-wildcards' "${root}/build.sh"
if grep -q -- '-e boot proc sys run tmp' "${root}/build.sh"; then
  echo 'el squashfs debe conservar los puntos de montaje vacíos' >&2; exit 1
fi
grep -q "ethernet 'Editar cable Ethernet (IP, gateway, DNS)'" "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q "wifi     'Ver redes WiFi y conectar'" "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
# La config de IP del cable usa formularios whiptail + nmcli, NO nmtui (nmtui
# se cerraba y volvía al menú por falta de terminfo/terminal).
if grep -vE '^[[:space:]]*#' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh" | grep -q 'nmtui'; then
  echo 'nmtui no es fiable en el mini; usa whiptail + nmcli' >&2; exit 1
fi
grep -q 'ipv4.method manual ipv4.addresses' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'ipv4.method auto' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q "IP fija (manual)" "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'connection up uuid "${connection}" ifname "${device}"' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'nmcli radio wifi on' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'nmcli device wifi rescan ifname "${device}"' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q -- "--menu.*Seleccione una red" "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh" || \
  grep -q "Seleccione una red (ESC vuelve al menú anterior)" "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'device wifi connect "${ssid}" ifname "${device}"' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'Conexión WiFi por DHCP lista.' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'wifi)     configure_wifi && return 0' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'Linux/NetworkManager no detecta un adaptador WiFi.' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'session.log' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'tee "${LOG}" /dev/tty0 /dev/ttyS0 >/dev/null' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'ISO EN RAM: RETIRE EL USB CON SEGURIDAD' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q "awk -F: '\$2 == \"ethernet\" { print \$1; exit }' || true" "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'has_ipv4' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'DHCP sin respuesta' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'Solicitando DHCP por' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'Esperando adaptador de red (10 segundos más)' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'Gateway:' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
if grep -qx 'clear' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"; then
  echo 'el instalador no debe borrar el detalle del error' >&2; exit 1
fi
grep -q 'trap cleanup EXIT' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q "trap 'exit 143' TERM" "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Buscando un runtime o una partición apta' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'cmp -s.*SHA256SUMS.*EXPECTED_SUMS' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'VERIFICANDO IMAGEN en ${part}; puede tardar varios minutos' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Runtime validado en' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'runtime ya estaba validado en el disco' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Buscando un seed en la red local' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'MINI_LAN_WAIT:-60' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q -- "--bt-exclude-tracker='\*'" "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q "download-seeds" "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Sin progreso (ni peers ni bytes nuevos) durante ${stall_max} s' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
# stall_max=0 => sin Internet/USB la espera de un seed es indefinida, no aborta.
grep -q 'run_lpd_download 0 ' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q -- '--bt-max-peers="${BT_MAX_PEERS}"' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
# read que puede quedar vacío no debe disparar el trap ERR con set -e.
grep -q "print \$2, \$4; exit }') || true" "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q "case \"\${bytes}\" in ''|\*\[!0-9\]\*) bytes=0 ;; esac" "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
# El trap del modo seed debe encadenar cleanup (umount de NTFS si se apaga),
# cleanup mata aria2 (ARIA_PID) para soltar el NTFS y hace umount perezoso si
# sigue "busy" -> Ctrl+C / q dejan el disco limpio.
grep -q 'ARIA_PID' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'kill "${ARIA_PID}"' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'umount -l /mnt/mini-deploy' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'q|Q) progress_break; dump_diag; exit 130' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
test "$(grep -c 'trap - EXIT' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh")" -eq 1
# Ctrl+C del teclado (tty0) requiere que tty0 sea el terminal de control.
grep -q 'setsid -c /usr/lib/mini-deploy/deploy-run.sh' "${root}/overlay/sbin/init"
grep -q -- '--bt-lpd-interface="${LPD_INTERFACE}"' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q -- '--listen-port=6881' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q '239.192.152.143:6771' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'MINI_LAN_INTERFACE' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'MINI_LPD_INTERVAL:-2' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
# El latido LPD calcula el infohash del .torrent localmente (no depende del RPC)
# y re-hace el JOIN del grupo para switches con IGMP snooping sin querier.
grep -q 'hashlib.sha1(b\[vs:i\])' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'BT-SEARCH \* HTTP/1.1' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'IP_ADD_MEMBERSHIP' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'ADVERTENCIA: python3 incompleto' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
test "$(grep -c 'lpd_heartbeat .*&' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh")" -eq 2
# python3 COMPLETO: python3-minimal no trae urllib.request y el latido moría.
grep -qx 'python3' "${root}/packages.list"
if grep -qx 'python3-minimal' "${root}/packages.list"; then
  echo 'python3-minimal no trae urllib.request; usa python3' >&2; exit 1
fi
grep -q '/run/mini-deploy/seed.log' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
awk '/Buscando un seed en la red local/ { lan = NR } /Descargando runtime desde/ { http = NR } END { exit !(lan && http && lan < http) }' \
  "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'contest.media_uuid' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'show_all_disks' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'stop_no_disk' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
# Diagnóstico persistente en disco (máquina física sin forma de extraer logs).
grep -q 'dump_diag()' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'aria2_report()' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'mini-deploy-logs' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'dump_diag || true; exit ${rc}' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
# El seed ya fue validado con SHA-256; no anunciar un falso fallo por omitir el
# segundo hash BitTorrent.
grep -q 'sin verificación adicional (SHA-256 ya validado)' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
if grep -q 'El seed NO tiene el runtime completo' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"; then
  echo 'bt-seed-unverified no debe generar una alerta falsa de runtime incompleto' >&2; exit 1
fi
grep -q 'd|D) progress_break; dump_diag' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Detalle %s' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'write_error' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
if sed -n '/^stop_no_disk()/,/^}/p' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh" | grep -qx '    clear || true'; then
  echo 'el error de particiones no debe borrarse antes de mostrarse' >&2; exit 1
fi
grep -q 'USB YA PUEDE RETIRARSE' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
awk '/USB YA PUEDE RETIRARSE/ { usb = NR } /Descargando runtime desde/ { http = NR } END { exit !(usb && http && usb < http) }' \
  "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
# El modo seed muestra cuántas máquinas sirve y la velocidad de red.
grep -q 'Seed.*equipos servidos: {len(ips)}' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'red: {mib(up):.1f} MiB/s ({mbit(up):.0f} Mbit/s)' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'red: {mib(down):.1f} MiB/s ({mbit(down):.0f} Mbit/s)' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Descarga: {pct:.1f}%' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'faltan {size(remaining)}' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'tiempo estimado: {eta(remaining, down)}' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q "Archivo: {os.path.basename(current\['path'\])}" "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q "aria2.tellStopped" "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q "download-complete" "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q "Descarga completa; verificando archivos" "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'actualizando estado; la descarga continúa' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
if grep -q 'iniciando aria2/LPD' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"; then
  echo 'un timeout RPC no debe anunciar falsamente que aria2 reinició' >&2; exit 1
fi
grep -q 'Enlace ${LPD_INTERFACE}: ${LINK_SPEED} Mbit/s negociados' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'enlace de 100 Mbit/s; ~94 Mbit/s es su máximo real' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'def mbit(value)' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Sembrando el runtime desde.*LOCAL_IP.*:6881' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q -- '--check-integrity=false --bt-seed-unverified=true' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'rm -f "${payload}.aria2" "${payload}"/\*.aria2' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
awk '/rm -f "\${payload}\.aria2"/ { clean = NR } /--bt-seed-unverified=true/ { seed = NR } END { exit !(clean && seed && clean < seed) }' \
  "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Esta máquina {local_ip} | seeds: {len(seeds)}' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'peers: {len(ips)}' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q "aria2.getPeers" "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'getGlobalStat' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'tellActive' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'kexec --load' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'grub-entry.cfg' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
test -x "${root}/overlay/sbin/init"
grep -q 'no inicia systemd' "${root}/overlay/sbin/init"
if grep -q 'systemctl enable mini-deploy.service' "${root}/build.sh"; then exit 1; fi
grep -q 'console=ttyS0' "${root}/build-iso.sh"
grep -q 'set timeout=0' "${root}/build-iso.sh"
grep -q 'show_error' "${root}/overlay/sbin/init"
grep -q 'tail -n 30 /run/mini-deploy/session.log' "${root}/overlay/sbin/init"
grep -q '\[ "${rc}" -eq 130 \] && poweroff_now' "${root}/overlay/sbin/init"
grep -q 'busybox poweroff -f' "${root}/overlay/sbin/init"
grep -q 'trap safe_shutdown INT TERM' "${root}/overlay/sbin/init"
grep -q 'echo 0 > /proc/sys/kernel/ctrl-alt-del' "${root}/overlay/sbin/init"
grep -q 'kill -TERM "-${deploy_pid}"' "${root}/overlay/sbin/init"
grep -q 'date -u +%s.*build-epoch' "${root}/build.sh"
grep -q 'date -u -s "@${build_epoch}"' "${root}/overlay/sbin/init"
grep -q 'mkdir -p /run/dbus' "${root}/overlay/sbin/init"
grep -q 'mini-dbus.log' "${root}/overlay/sbin/init"
grep -q 'nmcli -t -f RUNNING general' "${root}/overlay/sbin/init"
grep -q 'NetworkManager no quedó listo; registro:' "${root}/overlay/sbin/init"
grep -q 'tee /var/log/mini-network.log >/dev/ttyS0' "${root}/overlay/sbin/init"
grep -q 'Preparación del equipo' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'firmware-realtek' "${root}/packages.list"
grep -q 'firmware-ath9k-htc' "${root}/packages.list"
if grep -q '^firmware-ralink' "${root}/packages.list"; then
  echo 'firmware-ralink no es un paquete real, usa firmware-mediatek' >&2; exit 1
fi
grep -q 'ntfs-3g' "${root}/packages.list"
# busybox: /sbin/init lo necesita para 'poweroff -f' (minbase no trae poweroff).
grep -qx 'busybox' "${root}/packages.list"
grep -qx 'pciutils' "${root}/packages.list"
grep -qx 'usbutils' "${root}/packages.list"
# try_dhcp recorre TODAS las NIC cableadas, no solo la primera.
grep -q 'for device in $(ethernet_devices)' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'show_nic_hardware' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'Secure Boot activo' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q '^ca-certificates$' "${root}/packages.list"
grep -q 'update-ca-certificates' "${root}/build.sh"
grep -q 'update-initramfs' "${root}/build.sh"
# La imagen mini arranca sola con live-boot; su propio kernel
grep -q '^live-boot$' "${root}/packages.list"
grep -q 'boot=live' "${root}/build-iso.sh"
grep -q 'boot=live components toram' "${root}/build-iso.sh"
grep -q 'quiet splash i915.enable_guc=0' "${root}/build-iso.sh"
grep -q 'grub/i386-pc' "${root}/build-iso.sh"
grep -q 'grub/x86_64-efi' "${root}/build-iso.sh"
grep -q 'boot/vmlinuz-' "${root}/build.sh"
grep -q '^udev$' "${root}/packages.list"
grep -q 'systemd-udevd --daemon' "${root}/overlay/sbin/init"
grep -q 'udevadm trigger --type=devices' "${root}/overlay/sbin/init"
grep -q '_network_menu_ui <"${CONSOLE_DEV}"' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
tail -n 3 "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh" | grep -q '^network_menu$'

# La selección WiFi debe llegar a nmcli; solo ESC vuelve al menú anterior.
wifi_log="${TMPDIR:-/tmp}/mini-deploy-wifi-test.$$"
wifi_output="$(
  eval "$(sed -n '/^configure_wifi()/,/^}/p' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh")"
  wifi_device() { echo wlan0; }
  network_summary() { printf '  IP: 192.0.2.2/24\n  Gateway: 192.0.2.1\n  DNS: 192.0.2.1\n'; }
  nmcli() {
    printf '<%s>' "$@" >>"${wifi_log}"; echo >>"${wifi_log}"
    [[ " $* " != *' -f SECURITY,SSID '* ]] || printf 'WPA2:Red de prueba\n'
  }
  whiptail() {
    [[ " $* " != *' --menu '* ]] || { printf '1' >&2; return; }
    [[ " $* " != *' --passwordbox '* ]] || printf 'secreto' >&2
  }
  configure_wifi
)"
grep -q '<device><wifi><connect><Red de prueba><ifname><wlan0><password><secreto>' "${wifi_log}"
grep -q 'Conexión WiFi por DHCP lista.' <<<"${wifi_output}"
grep -q 'IP: 192.0.2.2/24' <<<"${wifi_output}"
rm -f "${wifi_log}"

# Cable y WiFi comparten el mismo formulario de IP manual (edit_ip_config);
# tanto edit_ethernet como edit_wifi_ip deben delegar en él, no duplicarlo.
grep -q 'edit_ip_config "${device}" "${connection}" "Cable: ${device}"' \
  "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'edit_ip_config "${device}" "${connection}" "WiFi: ${ssid:-${connection}}"' \
  "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q "wifi-ip  'Editar IP de la red WiFi actual'" \
  "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'wifi-ip)  edit_wifi_ip ;;' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"

# edit_ip_config en modo manual: debe llegar a nmcli con la IP/gateway/DNS
# tecleados y luego activar la conexión por uuid en el device correcto.
ip_log="${TMPDIR:-/tmp}/mini-deploy-ip-test.$$"
ip_output="$(
  eval "$(sed -n '/^edit_ip_config()/,/^}/p' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh")"
  network_summary() { printf '  IP: 192.0.2.9/24\n  Gateway: 192.0.2.1\n  DNS: 192.0.2.1\n'; }
  nmcli() {
    printf '<%s>' "$@" >>"${ip_log}"; echo >>"${ip_log}"
    return 0
  }
  whiptail() {
    [[ " $* " != *' --notags --menu '* ]] || { printf 'manual' >&2; return; }
    [[ " $* " != *' --inputbox '* ]] || {
      case " $* " in
        *'Dirección IP'*)      printf '192.0.2.9/24' >&2 ;;
        *'Puerta de enlace'*)  printf '192.0.2.1' >&2 ;;
        *'DNS'*)               printf '192.0.2.1' >&2 ;;
      esac
    }
  }
  edit_ip_config wlan0 test-uuid 'WiFi: Red de prueba'
)"
grep -q '<connection><modify><test-uuid><ipv4.method><manual><ipv4.addresses><192.0.2.9/24><ipv4.gateway><192.0.2.1><ipv4.dns><192.0.2.1>' "${ip_log}"
grep -q '<connection><up><uuid><test-uuid><ifname><wlan0>' "${ip_log}"
grep -q 'IP: 192.0.2.9/24' <<<"${ip_output}"
rm -f "${ip_log}"

if grep -Eq 'scripts/build\.sh|tmp/updates|publish-lan' \
    "${root}/start.sh" "${root}/build.sh" "${root}/build-iso.sh"; then
  echo 'el build del mini no debe referirse al proyecto padre' >&2; exit 1
fi

grep -q 'Descargando metadatos' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'No se pudo descargar manifest.json' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'MINI_ARTIFACT_URL' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'artifact_url' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'urljoin' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'artifact_valid' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'copy_runtime_file' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q -- '--progress-bar' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q -- '--summary-interval=1.*--show-console-readout=true' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q -- '--connect-timeout 15' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q -- '--speed-time 120' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'ntfs|ntfs3' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
if grep -Eq 'wipefs|parted|mkfs\.' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"; then
  echo 'El mini sistema contiene una operación destructiva' >&2; exit 1
fi
echo 'PASS: mini-deploy structure'
