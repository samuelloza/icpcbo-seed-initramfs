#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in build.sh build-iso.sh start.sh overlay/usr/lib/mini-deploy/deploy-run.sh overlay/usr/lib/mini-deploy/lan-fetch.sh; do bash -n "${root}/${f}"; done
test -x "${root}/start.sh"
case "$("${root}/start.sh" 2>&1 || true)" in *build-mini*run-mini*) ;; *) exit 1 ;; esac
grep -q 'build-iso.sh' "${root}/start.sh"
grep -q 'qemu-system-x86_64' "${root}/start.sh"
grep -q 'mksquashfs' "${root}/build.sh"
grep -q 'nmtui' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'tee /dev/ttyS0' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'Buscando particiones existentes' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'show_all_disks' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'stop_no_disk' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'USB YA PUEDE RETIRARSE' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
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
grep -q 'Preparación del equipo' "${root}/overlay/usr/lib/mini-deploy/deploy-run.sh"
grep -q 'firmware-realtek' "${root}/packages.list"
grep -q 'ntfs-3g' "${root}/packages.list"
grep -q '^ca-certificates$' "${root}/packages.list"
grep -q 'update-ca-certificates' "${root}/build.sh"
grep -q 'MINI_ARTIFACT_URL' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
grep -q 'ntfs|ntfs3' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"
if grep -Eq 'wipefs|parted|mkfs\.' "${root}/overlay/usr/lib/mini-deploy/lan-fetch.sh"; then
  echo 'El mini sistema contiene una operación destructiva' >&2; exit 1
fi
echo 'PASS: mini-deploy structure'
