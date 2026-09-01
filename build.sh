#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:?ARTIFACTS_DIR debe apuntar al runtime completo}"
METADATA_DIR="${METADATA_DIR:-${ARTIFACTS_DIR}}"
SUITE="${DEBIAN_SUITE:-trixie}"
MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
CONTEST_DIR="${CONTEST_DIR:-icpc_bo}"
WORK_DIR="${WORK_DIR:-${PROJECT_DIR}/work}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}"
ROOTFS="${WORK_DIR}/rootfs"

require_file() { [ -f "$1" ] || { echo "Falta: $1" >&2; exit 1; }; }
[ "$(id -u)" = 0 ] || { echo "Ejecuta como root" >&2; exit 1; }
for cmd in debootstrap chroot mksquashfs; do command -v "${cmd}" >/dev/null || { echo "Falta comando: ${cmd}" >&2; exit 1; }; done
for f in filesystem.squashfs vmlinuz initrd.img grub-entry.cfg; do require_file "${ARTIFACTS_DIR}/${f}"; done
require_file "${METADATA_DIR}/manifest.json"
compgen -G "${METADATA_DIR}/contest-*.torrent" >/dev/null || { echo "Falta contest-*.torrent" >&2; exit 1; }

rm -rf "${WORK_DIR}"
mkdir -p "${ROOTFS}" "${OUTPUT_DIR}"
debootstrap_env=()
if [ -n "${APT_PROXY:-}" ]; then debootstrap_env=(env http_proxy="${APT_PROXY}" https_proxy="${APT_PROXY}"); fi
"${debootstrap_env[@]}" debootstrap --variant=minbase "${SUITE}" "${ROOTFS}" "${MIRROR}"
printf 'deb %s %s main contrib non-free non-free-firmware\n' "${MIRROR}" "${SUITE}" > "${ROOTFS}/etc/apt/sources.list"
if [ -n "${APT_PROXY:-}" ]; then
    mkdir -p "${ROOTFS}/etc/apt/apt.conf.d"
    printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "DIRECT";\n' "${APT_PROXY}" > "${ROOTFS}/etc/apt/apt.conf.d/01proxy"
fi
cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf"
mount --bind /dev "${ROOTFS}/dev"
mount -t proc proc "${ROOTFS}/proc"
mount -t sysfs sys "${ROOTFS}/sys"
cleanup() { umount "${ROOTFS}/sys" "${ROOTFS}/proc" "${ROOTFS}/dev" 2>/dev/null || true; }
trap cleanup EXIT
chroot "${ROOTFS}" apt-get update
chroot "${ROOTFS}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $(grep -vE '^($|#)' "${PROJECT_DIR}/packages.list")
chroot "${ROOTFS}" update-ca-certificates
chroot "${ROOTFS}" apt-get clean

install -Dm0755 "${PROJECT_DIR}/overlay/usr/lib/mini-deploy/lan-fetch.sh" "${ROOTFS}/usr/lib/mini-deploy/lan-fetch.sh"
install -Dm0755 "${PROJECT_DIR}/overlay/usr/lib/mini-deploy/deploy-run.sh" "${ROOTFS}/usr/lib/mini-deploy/deploy-run.sh"
install -Dm0755 "${PROJECT_DIR}/overlay/sbin/init" "${ROOTFS}/sbin/init"
if [ -f "${PROJECT_DIR}/config.env" ]; then
    install -Dm0644 "${PROJECT_DIR}/config.env" "${ROOTFS}/etc/mini-deploy/config.env"
fi
mkdir -p "${ROOTFS}/usr/lib/mini-deploy/lan"
cp -a "${METADATA_DIR}/manifest.json" "${ROOTFS}/usr/lib/mini-deploy/lan/"
cp -a "${METADATA_DIR}"/contest-*.torrent "${ROOTFS}/usr/lib/mini-deploy/lan/"

mksquashfs "${ROOTFS}" "${OUTPUT_DIR}/deploy.squashfs" -comp zstd -Xcompression-level 15 -e boot proc sys run tmp var/cache/apt var/lib/apt/lists var/log
mkdir -p "${OUTPUT_DIR}/${CONTEST_DIR}"
cp -a "${METADATA_DIR}/manifest.json" "${METADATA_DIR}"/contest-*.torrent "${OUTPUT_DIR}/${CONTEST_DIR}/"
echo "Mini deploy creado: ${OUTPUT_DIR}/deploy.squashfs"
