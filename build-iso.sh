#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:?ARTIFACTS_DIR debe apuntar al runtime completo}"
METADATA_DIR="${METADATA_DIR:-${ARTIFACTS_DIR}}"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/output}"
CONTEST_DIR="${CONTEST_DIR:-icpc_bo}"
STAGING="${WORK_DIR:-${PROJECT_DIR}/work}/iso"

command -v grub-mkrescue >/dev/null || { echo 'Falta grub-mkrescue' >&2; exit 1; }
for f in vmlinuz initrd.img; do
    [ -f "${ARTIFACTS_DIR}/${f}" ] || { echo "Falta: ${ARTIFACTS_DIR}/${f}" >&2; exit 1; }
done

ARTIFACTS_DIR="${ARTIFACTS_DIR}" METADATA_DIR="${METADATA_DIR}" OUTPUT_DIR="${OUTPUT_DIR}" "${PROJECT_DIR}/build.sh"
rm -rf "${STAGING}"
mkdir -p "${STAGING}/boot/grub" "${STAGING}/${CONTEST_DIR}"
cp -a "${ARTIFACTS_DIR}/vmlinuz" "${STAGING}/${CONTEST_DIR}/"
cp -a "${ARTIFACTS_DIR}/initrd.img" "${STAGING}/${CONTEST_DIR}/"
cp -a "${OUTPUT_DIR}/deploy.squashfs" "${STAGING}/${CONTEST_DIR}/"
cp -a "${OUTPUT_DIR}/${CONTEST_DIR}/." "${STAGING}/${CONTEST_DIR}/"
cat > "${STAGING}/boot/grub/grub.cfg" <<EOF
set timeout=0
set timeout_style=hidden
set default=0
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input console serial
terminal_output console serial
menuentry "Preparación del equipo ICPC Bolivia" {
    linux /${CONTEST_DIR}/vmlinuz contest.install_mode=deploy contest_dir=/${CONTEST_DIR} contest_root=filesystem.squashfs mini_deploy=1 console=tty0 console=ttyS0,115200n8
    initrd /${CONTEST_DIR}/initrd.img
}
EOF
grub-mkrescue -o "${OUTPUT_DIR}/mini-deploy.iso" "${STAGING}"
(cd "${OUTPUT_DIR}" && sha256sum mini-deploy.iso > mini-deploy.iso.sha256)
echo "ISO mini creada: ${OUTPUT_DIR}/mini-deploy.iso"
