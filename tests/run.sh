#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in build.sh build-iso.sh start.sh overlay/sbin/init overlay/usr/lib/mini-deploy/deploy-run.sh overlay/usr/lib/mini-deploy/lan-fetch.sh; do bash -n "${root}/${f}"; done
test -x "${root}/start.sh"
case "$("${root}/start.sh" 2>&1 || true)" in *build-mini*run-mini*) ;; *) exit 1 ;; esac
grep -q 'build-iso.sh' "${root}/start.sh"
grep -q 'virt-install' "${root}/start.sh"
grep -q 'RUN_MINI_TARGET_DISK' "${root}/start.sh"
grep -q 'RUN_MINI_EXTRA_DISK' "${root}/start.sh"
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
grep -q 'nmtui' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'session.log' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'tee "${LOG}" /dev/tty0 /dev/ttyS0 >/dev/null' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q "awk -F: '\$2 == \"ethernet\" { print \$1; exit }' || true" "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'has_ipv4' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'DHCP sin respuesta' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'Solicitando DHCP por' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'Esperando adaptador de red (10 segundos más)' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'Gateway:' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
if grep -qx 'clear' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"; then
  echo 'el instalador no debe borrar el detalle del error' >&2; exit 1
fi
grep -q 'Buscando particiones existentes' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'trap cleanup EXIT' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q "trap 'exit 143' TERM" "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Discos y particiones detectados (solo lectura)' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'show_partition_inventory' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'BLOQ-WINDOWS' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Buscando un runtime ya validado en los discos' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Runtime validado en' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Runtime en .* omitido: disco sin escritura segura' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'contest.media_uuid' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'show_all_disks' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'stop_no_disk' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Detalle %s' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'write_error' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
if sed -n '/^stop_no_disk()/,/^}/p' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh" | grep -qx '    clear || true'; then
  echo 'el error de particiones no debe borrarse antes de mostrarse' >&2; exit 1
fi
grep -q 'USB YA PUEDE RETIRARSE' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
awk '/USB YA PUEDE RETIRARSE/ { usb = NR } /Descargando runtime desde/ { http = NR } END { exit !(usb && http && usb < http) }' \
  "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'Compartiendo: recibidos' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
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
grep -q '^ca-certificates$' "${root}/packages.list"
grep -q 'update-ca-certificates' "${root}/build.sh"
grep -q 'update-initramfs' "${root}/build.sh"
# La imagen mini arranca sola con live-boot; su propio kernel
grep -q '^live-boot$' "${root}/packages.list"
grep -q 'boot=live' "${root}/build-iso.sh"
grep -q 'boot/vmlinuz-' "${root}/build.sh"

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
grep -q -- '--connect-timeout 15' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q -- '--speed-time 120' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'ntfs|ntfs3' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
if grep -Eq 'wipefs|parted|mkfs\.' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"; then
  echo 'El mini sistema contiene una operación destructiva' >&2; exit 1
fi
echo 'PASS: mini-deploy structure'
