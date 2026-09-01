#!/usr/bin/env bash
# Construye la imagen base del mini: un rootfs Debian minbase con los paquetes de
# packages.list + el overlay, empaquetado como squashfs booteable por live-boot

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="${DEBIAN_SUITE:-trixie}"
MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
WORK_DIR="${WORK_DIR:-${PROJECT_DIR}/work}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}"
ROOTFS="${WORK_DIR}/rootfs"

[ "$(id -u)" = 0 ] || { echo "Ejecuta como root" >&2; exit 1; }
for cmd in debootstrap chroot mksquashfs; do command -v "${cmd}" >/dev/null || { echo "Falta comando: ${cmd}" >&2; exit 1; }; done

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
# initrd con los hooks de live-boot (montar el squashfs + overlay al arrancar).
chroot "${ROOTFS}" update-initramfs -u
chroot "${ROOTFS}" apt-get clean

install -Dm0755 "${PROJECT_DIR}/overlay/usr/lib/mini-deploy/lan-fetch.sh" "${ROOTFS}/usr/lib/mini-deploy/lan-fetch.sh"
install -Dm0755 "${PROJECT_DIR}/overlay/usr/lib/mini-deploy/deploy-run.sh" "${ROOTFS}/usr/lib/mini-deploy/deploy-run.sh"
install -Dm0755 "${PROJECT_DIR}/overlay/sbin/init" "${ROOTFS}/sbin/init"
if [ -f "${PROJECT_DIR}/config.env" ]; then
    install -Dm0644 "${PROJECT_DIR}/config.env" "${ROOTFS}/etc/mini-deploy/config.env"
fi

# Kernel + initrd propios del mini para el arranque de la ISO.
cp "${ROOTFS}"/boot/vmlinuz-* "${OUTPUT_DIR}/vmlinuz"
cp "${ROOTFS}"/boot/initrd.img-* "${OUTPUT_DIR}/initrd.img"

mksquashfs "${ROOTFS}" "${OUTPUT_DIR}/filesystem.squashfs" -comp xz -b 1M -Xbcj x86 -noappend \
    -e boot proc sys run tmp var/cache/apt var/lib/apt/lists var/log
echo "Imagen base creada: ${OUTPUT_DIR}/filesystem.squashfs"
