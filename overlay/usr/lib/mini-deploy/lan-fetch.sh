#!/usr/bin/env bash
#
# lan-fetch.sh
# Se ejecuta justo después de deploy-run.sh, que ya dejó la red lista.
#
#   1. Carga y valida /etc/mini-deploy/config.env.
#   2. Localiza los metadatos del contest (manifest + paquete) en LAN_DIR.
#   3. Elige una partición del disco con espacio suficiente, o se detiene.
#   4. Copia el runtime a esa partición desde la primera fuente disponible:
#        servidor HTTP  ->  USB  ->  distribución por LAN (aria2c).
#   5. Verifica los SHA256 y, venga de donde venga la copia, el equipo queda
#      sembrando el paquete en la LAN para alimentar a las máquinas que
#      arranquen después.
#   6. Al pulsar ENTER: corta la siembra y salta (kexec) al runtime ya copiado
#      en el disco. No se toca ninguna partición ni gestor de arranque.

set -euo pipefail

# exec desde deploy-run.sh reemplaza el proceso y pierde su trap: se repite aquí.
# Un fallo de descarga o SHA no debe dejar NTFS montado si el operador apaga.
cleanup() {
    local rc=$?
    trap - EXIT
    [ -n "${CURRENT_TMP:-}" ] && rm -f "${CURRENT_TMP}" || true
    if mountpoint -q /mnt/mini-deploy; then
        sync || true
        umount /mnt/mini-deploy || true
    fi
    exit "${rc}"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# Con set -e cualquier comando que falle aborta sin decir cuál; esto nombra la causa.
trap 'rc=$?; echo "  CAUSA: ${BASH_SOURCE[0]##*/}:${LINENO}: fallo \`${BASH_COMMAND}\` (código ${rc})" >&2; exit ${rc}' ERR

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
STAGING_DEV=''
CURRENT_TMP=''

RUNTIME_FILES=(filesystem.squashfs vmlinuz initrd.img grub-entry.cfg)
# No dejar el disco montado indefinidamente si la red queda congelada.
CURL_OPTS=(--fail --location --retry 3 --connect-timeout 15 --speed-limit 1 --speed-time 120)

release_usb() {
    sync
    if mountpoint -q "${MEDIA}"; then
        umount "${MEDIA}"
    fi

    clear || true
    cat <<EOF
  ==================================================
       USB YA PUEDE RETIRARSE CON SEGURIDAD
  ==================================================
  $1

EOF
}

# Tracker BT opcional (se suma a LPD y a los del .torrent). Respaldo si el
# switch filtra el multicast de LPD. Levantar en el origen, p. ej. opentracker.
BT_TRACKER=()
[ -n "${MINI_TRACKER_URL:-}" ] && BT_TRACKER=(--bt-tracker="${MINI_TRACKER_URL}")

# Inventario temprano para que el operador vea qué discos hay antes de usar la
# red. Las particiones se montan solo lectura únicamente para medir espacio.
show_partition_inventory() {
    local part size fs uuid mount_fs free_kb state probe_rc

    echo
    echo '  Discos y particiones detectados (solo lectura):'
    printf '  %-14s %-9s %-9s %-9s %-14s %s\n' 'DISPOSITIVO' 'TOTAL' 'LIBRE' 'FORMATO' 'ESTADO' 'UUID'
    printf '  %-14s %-9s %-9s %-9s %-14s %s\n' '--------------' '---------' '---------' '---------' '--------------' '----'
    while read -r part size; do
        fs="$(blkid -o value -s TYPE "${part}" 2>/dev/null || true)"
        uuid="$(blkid -o value -s UUID "${part}" 2>/dev/null || true)"
        free_kb=''
        state='NO COMPATIBLE'
        case "${fs}" in
            ext4|ext3|xfs|ntfs|ntfs3)
                state='OK'
                mount_fs="${fs}"
                [ "${mount_fs}" = ntfs ] && mount_fs=ntfs3
                if [ "${fs}" = ntfs ] && command -v ntfs-3g.probe >/dev/null 2>&1; then
                    ntfs-3g.probe --readwrite "${part}" >/dev/null 2>&1 || {
                        probe_rc=$?
                        case "${probe_rc}" in
                            14) state='BLOQ-WINDOWS' ;; # NTFS hibernado.
                            15) state='NTFS-SUCIO' ;;
                            16) state='EN USO' ;;
                            *)  state="NTFS-ERR-${probe_rc}" ;;
                        esac
                    }
                fi
                mkdir -p /mnt/mini-inventory
                if mount -t "${mount_fs}" -o ro "${part}" /mnt/mini-inventory 2>/dev/null; then
                    free_kb="$(df -k /mnt/mini-inventory | awk 'NR == 2 { print $4 }')"
                    umount /mnt/mini-inventory 2>/dev/null || true
                else
                    state='NO MONTABLE'
                fi ;;
        esac
        printf '  %-14s %-9s %-9s %-9s %-14s %s\n' "${part}" "${size}" \
            "${free_kb:+$((free_kb / 1024))MiB}" "${fs:--}" "${state}" "${uuid:--}"
    done < <(lsblk -pnro NAME,SIZE,TYPE | awk '$3 == "part" { print $1, $2 }')
}

show_partition_inventory

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
    if ! curl "${CURL_OPTS[@]}" -o "${LAN_DIR}/manifest.json" "${META_URL%/}/manifest.json"; then
        echo "  No se pudo descargar manifest.json desde ${META_URL%/}." >&2
        echo '  Verifique la red, la IP/puerto del servidor o conecte el USB con los metadatos.' >&2
        exit 1
    fi
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
    curl "${CURL_OPTS[@]}" -o "${bundle}" "${META_URL%/}/contest-${VERSION}.torrent"
fi

[ -f "${manifest}" ] && [ -f "${bundle}" ] || {
    echo 'Metadatos incompletos' >&2
    exit 1
}

# El manifest es la fuente de verdad tanto para una descarga nueva como para
# reutilizar un runtime ya presente en cualquier disco.
EXPECTED_SUMS=/run/mini-deploy/expected-sha256sums
python3 - "${manifest}" > "${EXPECTED_SUMS}" <<'PY'
import json, os, sys
for item in json.load(open(sys.argv[1]))['artifacts'].values():
    print(f"{item['sha256']}  {os.path.basename(item['url'])}")
PY

artifact_url() {
    python3 - "${manifest}" "$1" "${META_URL%/}/" <<'PY'
import json, os, sys
from urllib.parse import urljoin
for item in json.load(open(sys.argv[1]))['artifacts'].values():
    if os.path.basename(item['url']) == sys.argv[2]:
        print(urljoin(sys.argv[3], item['url']))
        break
else:
    raise SystemExit(f"El manifest no contiene {sys.argv[2]}")
PY
}

# Conserva únicamente artefactos completos: tras una interrupción se reutiliza
# cada archivo cuyo hash coincide y se vuelve a copiar solo el resto.
artifact_valid() {
    local file="$1" expected actual

    [ -f "${payload}/${file}" ] || return 1
    expected="$(awk -v file="${file}" '$2 == file { print $1; exit }' "${payload}/SHA256SUMS")"
    [ -n "${expected}" ] || return 1
    actual="$(sha256sum "${payload}/${file}" | awk '{ print $1 }')"
    [ "${actual}" = "${expected}" ]
}

copy_runtime_file() {
    local file="$1" source="$2" method="$3"

    if artifact_valid "${file}"; then
        echo "  Reutilizando ${file} ya verificado."
        return 0
    fi

    CURRENT_TMP="${payload}/${file}.tmp"
    rm -f "${CURRENT_TMP}"
    if [ "${method}" = http ]; then
        curl "${CURL_OPTS[@]}" --output "${CURRENT_TMP}" "${source}"
    else
        cp "${source}" "${CURRENT_TMP}"
    fi
    mv "${CURRENT_TMP}" "${payload}/${file}"
    CURRENT_TMP=''

    if ! artifact_valid "${file}"; then
        echo "  SHA-256 inválido en ${file}; se descartará y volverá a descargar." >&2
        rm -f "${payload}/${file}"
        return 1
    fi
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

# Intenta arrancar un runtime ya validado. Si kexec falla, continúa buscando en
# las otras particiones antes de descargar o escribir nada.
boot_runtime() {
    local runtime="$1" append media_uuid

    append="$(awk '/^[[:space:]]*linux[[:space:]]/ { $1=""; $2=""; sub(/^[[:space:]]+/, ""); print; exit }' \
        "${runtime}/grub-entry.cfg" 2>/dev/null)"
    [ -n "${append}" ] || append="contest_dir=${CONTEST_DIR} contest_root=filesystem.squashfs contest_persist=auto contest.boot_source=hdd contest.persist_scope=home console=tty0"
    media_uuid="$(blkid -o value -s UUID "${STAGING_DEV}" 2>/dev/null || true)"
    [ -n "${media_uuid}" ] && append="${append} contest.media_uuid=${media_uuid}"

    echo "  Arrancando el sistema desde ${runtime} ..."
    if kexec --load "${runtime}/vmlinuz" --initrd="${runtime}/initrd.img" --append="${append}"; then
        sync
        umount -l "${STAGING_ROOT}" 2>/dev/null || true
        kexec --exec || true
    fi
    kexec --unload 2>/dev/null || true
    return 1
}

boot_existing_runtimes() {
    local part fs mount_fs candidate probe

    echo '  Buscando un runtime ya validado en los discos...'
    for part in $(lsblk -pnro NAME,TYPE | awk '$2 == "part" { print $1 }'); do
        fs="$(blkid -o value -s TYPE "${part}" 2>/dev/null || true)"
        case "${fs}" in
            ext4|ext3|xfs|ntfs|ntfs3) ;;
            *) continue ;;
        esac

        mount_fs="${fs}"
        [ "${mount_fs}" = ntfs ] && mount_fs=ntfs3
        mkdir -p /mnt/mini-deploy
        mount -t "${mount_fs}" -o rw "${part}" /mnt/mini-deploy 2>/dev/null || continue
        candidate="/mnt/mini-deploy${CONTEST_DIR}"
        probe="${candidate}/.mini-deploy-write-probe"
        if [ ! -d "${candidate}" ] || ! { : > "${probe}" && rm -f "${probe}"; } 2>/dev/null; then
            echo "  Runtime en ${part} omitido: disco sin escritura segura."
            umount /mnt/mini-deploy 2>/dev/null || true
            continue
        fi
        if [ -d "${candidate}" ] && (cd "${candidate}" && sha256sum -c "${EXPECTED_SUMS}" >/dev/null 2>&1); then
            STAGING_ROOT=/mnt/mini-deploy
            STAGING_DEV="${part}"
            echo "  Runtime validado en ${part}; se intenta arrancar sin descargar."
            boot_runtime "${candidate}" || echo "  No se pudo arrancar ${part}; probando otro disco."
        fi
        umount /mnt/mini-deploy 2>/dev/null || true
    done
    return 1
}

# Recorre cada partición, prueba a montarla, mide el espacio libre y se queda
# con la que más tenga (si supera el mínimo). Deja STAGING_ROOT apuntando a la
# partición ya montada, o devuelve 1 si ninguna sirve.
find_staging_root() {
    local part fs mount_fs free_kb probe mount_error write_error
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
        if ! mount_error="$(mount -t "${mount_fs}" -o rw "${part}" /mnt/mini-deploy 2>&1)"; then
            printf '  %-18s %-8s %10s  %s\n' "${part}" "${fs}" '-' 'BLOQUEADA/NO MONTABLE'
            printf '    Detalle %s: %s\n' "${part}" "${mount_error:-sin detalle del driver}"
            continue
        fi

        # "Montada rw" no garantiza escritura: NTFS con hibernación o Fast
        # Startup, remontajes de solo-lectura por errores de disco, permisos...
        # Se comprueba de verdad creando la carpeta destino y un archivo dentro.
        probe="/mnt/mini-deploy${CONTEST_DIR}"
        if ! write_error="$({ mkdir -p "${probe}" && : > "${probe}/.escritura" && rm -f "${probe}/.escritura"; } 2>&1)"; then
            printf '  %-18s %-8s %10s  %s\n' "${part}" "${fs}" '-' 'SOLO LECTURA'
            printf '    Detalle %s: %s\n' "${part}" "${write_error:-no se pudo crear el archivo de prueba}"
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
    STAGING_DEV="${best_part}"
    echo "  Usando ${best_part}: ${best_free} KiB libres."
}

# Si alguno arranca, kexec no regresa. Si todos fallan, recién se descarga.
boot_existing_runtimes || true

find_staging_root || stop_no_disk
payload="${STAGING_ROOT}${CONTEST_DIR}"
mkdir -p "${payload}"
cp "${EXPECTED_SUMS}" "${payload}/SHA256SUMS"

# Se prueba cada fuente en orden y se usa la primera disponible. Siempre se
# escribe a un .tmp y se renombra, para que un corte a media copia no deje un
# archivo incompleto con el nombre definitivo.
usb="${MEDIA}${CONTEST_DIR}"
usb_released=false
if [ -n "${MINI_ARTIFACT_URL:-}" ]; then
    release_usb 'El runtime se descargará por red; puede usar el USB en otro equipo.'
    usb_released=true
    echo "  Descargando runtime desde ${MINI_ARTIFACT_URL}"
    for f in "${RUNTIME_FILES[@]}"; do
        copy_runtime_file "${f}" "$(artifact_url "${f}")" http
    done

elif [ -f "${usb}/filesystem.squashfs" ]; then
    for f in "${RUNTIME_FILES[@]}"; do
        copy_runtime_file "${f}" "${usb}/${f}" usb
    done

else
    aria2c --bt-enable-lpd=true --enable-dht=false --check-integrity=true --seed-time=0 \
        --summary-interval=2 --human-readable=true --console-log-level=notice \
        "${BT_TRACKER[@]}" --dir="${STAGING_ROOT}" "${bundle}"
fi

# Falla (y aborta por set -e) si algún archivo no coincide con su sha256.
# Sin --status para que se vea qué archivo falló la verificación.
(cd "${payload}" && sha256sum -c SHA256SUMS)
printf 'INSTALLED_FROM=mini-deploy\n' > "${payload}/.contest-installed"
[ "${usb_released}" = true ] || release_usb 'El runtime fue copiado y validado en el disco.'

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

boot_runtime "${payload}" && exit 0

# Si llegamos aquí, kexec falló. No dejamos morir a PID 1: alto controlado.
echo '  ERROR: el runtime está copiado y verificado en el disco, pero el' >&2
echo '         arranque automático (kexec) falló. Reinicia el equipo a mano.' >&2
while :; do sleep 3600; done
