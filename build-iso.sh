#!/usr/bin/env bash
# Empaqueta la imagen base (build.sh) en una ISO booteable con GRUB + live-boot.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}"
WORK_DIR="${WORK_DIR:-${PROJECT_DIR}/work}"
STAGING="${WORK_DIR}/iso"

command -v grub-mkrescue >/dev/null || { echo 'Falta grub-mkrescue' >&2; exit 1; }

OUTPUT_DIR="${OUTPUT_DIR}" WORK_DIR="${WORK_DIR}" "${PROJECT_DIR}/build.sh"

rm -rf "${STAGING}"
mkdir -p "${STAGING}/boot/grub" "${STAGING}/live"
cp -a "${OUTPUT_DIR}/vmlinuz" "${STAGING}/live/vmlinuz"
cp -a "${OUTPUT_DIR}/initrd.img" "${STAGING}/live/initrd.img"
cp -a "${OUTPUT_DIR}/filesystem.squashfs" "${STAGING}/live/filesystem.squashfs"

cat > "${STAGING}/boot/grub/grub.cfg" <<'EOF'
set timeout=0
set timeout_style=hidden
set default=0
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input console serial
terminal_output console serial
menuentry "Preparación del equipo ICPC Bolivia" {
    linux /live/vmlinuz boot=live components noeject init=/sbin/init console=tty0 console=ttyS0,115200n8
    initrd /live/initrd.img
}
EOF

grub-mkrescue -o "${OUTPUT_DIR}/mini-deploy.iso" "${STAGING}"
(cd "${OUTPUT_DIR}" && sha256sum mini-deploy.iso > mini-deploy.iso.sha256)
echo "ISO mini creada: ${OUTPUT_DIR}/mini-deploy.iso"
