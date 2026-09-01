#!/usr/bin/env bash
#
# lan-fetch.sh
# Se ejecuta justo después de deploy-run.sh, que ya dejó la red lista.
#
#   1. Carga y valida /etc/mini-deploy/config.env.
#   2. Localiza los metadatos del contest (manifest + paquete) en LAN_DIR.
#   3. Elige una partición del disco con espacio suficiente, o se detiene.
#   4. Copia el runtime a esa partición desde la primera fuente disponible:
#        USB  ->  servidor HTTP  ->  distribución por LAN (aria2c).
#   5. Verifica los SHA256 y, venga de donde venga la copia, el equipo queda
#      sembrando el paquete en la LAN para alimentar a las máquinas que
#      arranquen después.
#   6. Al pulsar ENTER: corta la siembra y salta (kexec) al runtime ya copiado
#      en el disco. No se toca ninguna partición ni gestor de arranque.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

# Aborta listando de una vez todas las variables que faltan (vacías = faltan).
require_env() {
    local missing=() name
    for name in "$@"; do
        [ -n "${!name:-}" ] || missing+=("${name}")
    done
    [ "${#missing[@]}" -eq 0 ] || {
        echo "config.env incompleto, faltan: ${missing[*]}" >&2
        exit 1
    }
}

CONFIG=/etc/mini-deploy/config.env
[ -r "${CONFIG}" ] || { echo "Falta ${CONFIG}" >&2; exit 1; }
. "${CONFIG}"

require_env CONTEST_DIR MINI_MEDIA_DIR LAN_DIR MINI_STAGING_MIB

MEDIA="${MINI_MEDIA_DIR}"
MIN_FREE_MIB="${MINI_STAGING_MIB}"
STAGING_ROOT=''   # lo fija find_staging_root con la partición elegida

RUNTIME_FILES=(filesystem.squashfs vmlinuz initrd.img grub-entry.cfg)

# Tracker BT opcional (se suma a LPD y a los del .torrent). Respaldo si el
# switch filtra el multicast de LPD. Levantar en el origen, p. ej. opentracker.
BT_TRACKER=()
[ -n "${MINI_TRACKER_URL:-}" ] && BT_TRACKER=(--bt-tracker="${MINI_TRACKER_URL}")

# ---------------------------------------------------------------------------
# Metadatos del contest (manifest.json + contest-*.torrent)
# ---------------------------------------------------------------------------
# No vienen en la imagen mini: se toman del USB si está, o se bajan del origen
# (MINI_ARTIFACT_URL). manifest.json trae la versión; con ella se arma el nombre
# del .torrent, necesario tanto para la copia por LAN como para sembrar luego.

mkdir -p "${LAN_DIR}" 2>/dev/null || { LAN_DIR=/run/mini-deploy/lan; mkdir -p "${LAN_DIR}"; }
META_URL="${MINI_METADATA_URL:-${MINI_ARTIFACT_URL:+${MINI_ARTIFACT_URL%/artifacts/*}}}"

meta_src=''
for cand in "${LAN_DIR}" "${MINI_MEDIA_DIR}${CONTEST_DIR}"; do
    [ -f "${cand}/manifest.json" ] && { meta_src="${cand}"; break; }
done
if [ -z "${meta_src}" ] && [ -n "${META_URL}" ]; then
    echo "  Descargando metadatos desde ${META_URL}"
    curl --fail --location --retry 3 -o "${LAN_DIR}/manifest.json" "${META_URL%/}/manifest.json"
    meta_src="${LAN_DIR}"
fi
[ -n "${meta_src}" ] || { echo 'Sin metadatos: no hay USB ni MINI_ARTIFACT_URL' >&2; exit 1; }

manifest="${meta_src}/manifest.json"
VERSION="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' \
    "${manifest}" 2>/dev/null || true)"

bundle="${meta_src}/contest-${VERSION}.torrent"
[ -f "${bundle}" ] || bundle="$(find "${meta_src}" -maxdepth 1 -name 'contest-*.torrent' -print -quit)"
if [ -z "${bundle}" ] && [ -n "${META_URL}" ] && [ -n "${VERSION}" ]; then
    bundle="${LAN_DIR}/contest-${VERSION}.torrent"
    curl --fail --location --retry 3 -o "${bundle}" "${META_URL%/}/contest-${VERSION}.torrent"
fi

[ -f "${manifest}" ] && [ -f "${bundle}" ] || {
    echo 'Metadatos incompletos' >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Selección de disco
# ---------------------------------------------------------------------------

# Lista todos los discos, solo para que el operador vea qué hay conectado.
show_all_disks() {
    echo
    echo '  Discos detectados (solo informativo; ninguno sera modificado):'
    lsblk -dpnro NAME,SIZE,MODEL,RM,TYPE 2>/dev/null \
        | awk '{ printf "  %-14s %-10s %-28s removible=%s tipo=%s\n", $1, $2, $3, $4, $5 }' \
        || true
}

# Sin partición apta no se puede seguir: se informa y se deja el equipo
# detenido a propósito, sin haber tocado ningún disco.
stop_no_disk() {
    clear || true
    cat <<'EOF'

  ==================================================
    ERROR: NO HAY PARTICION APTA PARA EL DESPLIEGUE
  ==================================================
EOF
    show_all_disks
    cat <<EOF

  Se necesita una particion ext4, ext3, xfs o NTFS con al menos ${MIN_FREE_MIB} MiB libres.
  El sistema queda detenido; no se modifico ningun disco.
  Corrige el disco y reinicia la ISO mini.

EOF
    while :; do sleep 3600; done
}

# Recorre cada partición, prueba a montarla, mide el espacio libre y se queda
# con la que más tenga (si supera el mínimo). Deja STAGING_ROOT apuntando a la
# partición ya montada, o devuelve 1 si ninguna sirve.
find_staging_root() {
    local part fs mount_fs free_kb probe
    local best_free=0 best_part='' best_fs=''

    echo
    echo '  Buscando particiones existentes para el folder /icpc_bo...'
    printf '  %-18s %-8s %10s  %s\n' 'PARTICIÓN' 'FORMATO' 'LIBRE' 'ESTADO'
    printf '  %-18s %-8s %10s  %s\n' '------------------' '--------' '----------' '----------------'

    for part in $(lsblk -pnro NAME,TYPE | awk '$2 == "part" { print $1 }'); do
        fs="$(blkid -o value -s TYPE "${part}" 2>/dev/null || true)"

        # Solo sistemas de archivos que sabemos montar en lectura/escritura.
        case "${fs}" in
            ext4|ext3|xfs|ntfs|ntfs3) ;;
            *)
                printf '  %-18s %-8s %10s  %s\n' "${part}" "${fs:--}" '-' 'NO COMPATIBLE'
                continue ;;
        esac

        # En este sistema el driver de NTFS se llama ntfs3.
        mount_fs="${fs}"
        [ "${mount_fs}" = ntfs ] && mount_fs=ntfs3

        mkdir -p /mnt/mini-deploy
        if ! mount -t "${mount_fs}" -o rw "${part}" /mnt/mini-deploy 2>/dev/null; then
            printf '  %-18s %-8s %10s  %s\n' "${part}" "${fs}" '-' 'BLOQUEADA/NO MONTABLE'
            continue
        fi

        # "Montada rw" no garantiza escritura: NTFS con hibernación o Fast
        # Startup, remontajes de solo-lectura por errores de disco, permisos...
        # Se comprueba de verdad creando la carpeta destino y un archivo dentro.
        probe="/mnt/mini-deploy${CONTEST_DIR}"
        if ! { mkdir -p "${probe}" && : > "${probe}/.escritura" && rm -f "${probe}/.escritura"; } 2>/dev/null; then
            printf '  %-18s %-8s %10s  %s\n' "${part}" "${fs}" '-' 'SOLO LECTURA'
            umount /mnt/mini-deploy 2>/dev/null || true
            continue
        fi

        # Columna "Available" de df, en KiB. Se desmonta enseguida: solo medimos.
        free_kb="$(df -k /mnt/mini-deploy | awk 'NR == 2 { print $4 }')"
        umount /mnt/mini-deploy 2>/dev/null || true

        if [ "${free_kb:-0}" -ge "$((MIN_FREE_MIB * 1024))" ]; then
            printf '  %-18s %-8s %7s MiB  %s\n' "${part}" "${fs}" "$((free_kb / 1024))" 'APTA'
            if [ "${free_kb}" -gt "${best_free}" ]; then
                best_free="${free_kb}"
                best_part="${part}"
                best_fs="${fs}"
            fi
        else
            printf '  %-18s %-8s %7s MiB  %s\n' "${part}" "${fs}" "$((free_kb / 1024))" 'SIN ESPACIO'
        fi
    done

    if [ -z "${best_part}" ]; then
        show_all_disks
        return 1
    fi

    [ "${best_fs}" = ntfs ] && best_fs=ntfs3
    mount -t "${best_fs}" -o rw "${best_part}" /mnt/mini-deploy || return 1
    STAGING_ROOT=/mnt/mini-deploy
    echo "  Usando ${best_part}: ${best_free} KiB libres."
}

# Elige la partición donde irá el folder del contest. Si ninguna sirve, alto.
find_staging_root || stop_no_disk

# Carpeta destino dentro de la partición elegida, p. ej. /mnt/mini-deploy/icpc_bo.
payload="${STAGING_ROOT}${CONTEST_DIR}"
mkdir -p "${payload}"

# ---------------------------------------------------------------------------
# Copia del runtime
# ---------------------------------------------------------------------------

# Arma el archivo de sumas a partir del manifest, en el formato que espera
# sha256sum -c:  "<sha256>  <nombre-de-archivo>" por línea.
python3 - "${manifest}" "${payload}" > "${payload}/SHA256SUMS" <<'PY'
import json, os, sys
for item in json.load(open(sys.argv[1]))['artifacts'].values():
    print(f"{item['sha256']}  {os.path.basename(item['url'])}")
PY

# Se prueba cada fuente en orden y se usa la primera disponible. Siempre se
# escribe a un .tmp y se renombra, para que un corte a media copia no deje un
# archivo incompleto con el nombre definitivo.
usb="${MEDIA}${CONTEST_DIR}"
if [ -f "${usb}/filesystem.squashfs" ]; then
    for f in "${RUNTIME_FILES[@]}"; do
        cp "${usb}/${f}" "${payload}/${f}.tmp"
        mv "${payload}/${f}.tmp" "${payload}/${f}"
    done

elif [ -n "${MINI_ARTIFACT_URL:-}" ]; then
    echo "  Sin USB: descargando runtime desde ${MINI_ARTIFACT_URL}"
    for f in "${RUNTIME_FILES[@]}"; do
        curl --fail --location --retry 3 --output "${payload}/${f}.tmp" "${MINI_ARTIFACT_URL%/}/${f}"
        mv "${payload}/${f}.tmp" "${payload}/${f}"
    done

else
    aria2c --bt-enable-lpd=true --enable-dht=false --check-integrity=true --seed-time=0 \
        --summary-interval=2 --human-readable=true --console-log-level=notice \
        "${BT_TRACKER[@]}" --dir="${STAGING_ROOT}" "${bundle}"
fi

# Falla (y aborta por set -e) si algún archivo no coincide con su sha256.
(cd "${payload}" && sha256sum -c --status SHA256SUMS)
printf 'INSTALLED_FROM=mini-deploy\n' > "${payload}/.contest-installed"
umount -l "${MEDIA}" 2>/dev/null || true

clear || true
cat <<'EOF'
  ==================================================
       USB YA PUEDE RETIRARSE CON SEGURIDAD
  ==================================================
  El runtime fue copiado y validado en el disco.

EOF

# ---------------------------------------------------------------------------
# Compartir con el resto de equipos
# ---------------------------------------------------------------------------

echo '  Compartiendo con el resto de equipos. Pulsa ENTER para terminar.'
aria2c --enable-rpc --rpc-listen-port=6800 --bt-enable-lpd=true --enable-dht=false \
    --check-integrity=true --seed-time=525600 --seed-ratio=0.0 --summary-interval=0 \
    "${BT_TRACKER[@]}" --dir="${STAGING_ROOT}" "${bundle}" >/dev/null 2>&1 &
share_pid=$!
trap 'kill "${share_pid}" 2>/dev/null || true' EXIT

while kill -0 "${share_pid}" 2>/dev/null; do
    python3 - <<'PY' 2>/dev/null || true
import json, urllib.request

def rpc(method):
    body = json.dumps({"jsonrpc": "2.0", "id": "x", "method": method, "params": []}).encode()
    req = urllib.request.Request(
        'http://127.0.0.1:6800/jsonrpc', data=body,
        headers={'Content-Type': 'application/json'})
    return json.load(urllib.request.urlopen(req, timeout=1)).get('result')

def mib(v):
    return int(v or 0) / 1048576

try:
    stat = rpc('aria2.getGlobalStat') or {}
    active = rpc('aria2.tellActive') or []
    peers = sum(int(x.get('numPeers', x.get('connections', 0)) or 0) for x in active)
    received = sum(int(x.get('completedLength', 0) or 0) for x in active)
    sent = sum(int(x.get('uploadLength', 0) or 0) for x in active)
    print(f"  Compartiendo: recibidos={mib(received):.1f} MiB | "
          f"enviados={mib(sent):.1f} MiB | equipos conectados={peers} | "
          f"{mib(stat.get('uploadSpeed')):.1f} MiB/s subida")
except Exception:
    print('  Compartiendo: esperando conexiones...')
PY
    read -r -t 2 _ && break || true
done

trap - EXIT
kill "${share_pid}" 2>/dev/null || true
wait "${share_pid}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Arrancar el runtime ya copiado en el disco
# ---------------------------------------------------------------------------

append="$(awk '/^[[:space:]]*linux[[:space:]]/ { $1=""; $2=""; sub(/^[[:space:]]+/, ""); print; exit }' \
    "${payload}/grub-entry.cfg" 2>/dev/null)"
[ -n "${append}" ] || append="contest_dir=${CONTEST_DIR} contest_root=filesystem.squashfs contest_persist=auto contest.boot_source=hdd contest.persist_scope=home console=tty0"

echo "  Arrancando el sistema nuevo desde ${payload} ..."
if kexec --load "${payload}/vmlinuz" --initrd="${payload}/initrd.img" --append="${append}"; then
    sync
    umount -l "${STAGING_ROOT}" 2>/dev/null || true
    kexec --exec || true               # no retorna: el equipo salta al runtime
fi

# Si llegamos aquí, kexec falló. No dejamos morir a PID 1: alto controlado.
echo '  ERROR: el runtime está copiado y verificado en el disco, pero el' >&2
echo '         arranque automático (kexec) falló. Reinicia el equipo a mano.' >&2
while :; do sleep 3600; done
