#!/usr/bin/env bash
#
# lan-fetch.sh
# Se ejecuta justo después de deploy-run.sh, que ya dejó la red lista.
#
#   1. Carga y valida /etc/mini-deploy/config.env.
#   2. Localiza los metadatos del contest (manifest + paquete) en LAN_DIR.
#   3. Elige una partición del disco con espacio suficiente, o se detiene.
#   4. Copia el runtime a esa partición: primero por LAN (aria2c sobre el
#      .torrent, peers vía LPD); si en MINI_LAN_WAIT s no llega ni un byte,
#      respaldo por servidor HTTP (curl) -> USB. El primer equipo baja de
#      Internet una vez y el resto lo obtiene de él por LAN.
#   5. Verifica los SHA256 y, venga de donde venga la copia, el equipo queda
#      sembrando el paquete en la LAN para alimentar a las máquinas que
#      arranquen después.
#   6. Al pulsar ENTER: corta la siembra y salta (kexec) al runtime ya copiado
#      en el disco. No se toca ninguna partición ni gestor de arranque.

set -euo pipefail

# exec desde deploy-run.sh reemplaza el proceso y pierde su trap: se repite aquí.
# Ctrl+C / apagado no debe dejar el NTFS montado ni sucio. ARIA_PID se mata
# primero para que aria2 suelte los ficheros y umount no falle por "busy".
ARIA_PID=''
cleanup() {
    local rc=$?
    trap - EXIT
    if [ -n "${ARIA_PID}" ]; then
        kill "${ARIA_PID}" 2>/dev/null || true
        wait "${ARIA_PID}" 2>/dev/null || true
    fi
    [ -n "${CURRENT_TMP:-}" ] && rm -f "${CURRENT_TMP}" || true
    if mountpoint -q /mnt/mini-deploy; then
        sync || true
        umount /mnt/mini-deploy 2>/dev/null || {
            sleep 1; sync || true
            umount -l /mnt/mini-deploy 2>/dev/null || true   # perezoso: se cierra al soltarse
        }
        sync || true
    fi
    exit "${rc}"
}

# Vuelca logs + estado de red/aria2 a un disco legible luego (Windows/Linux), ya
# que el mini no deja rastro al reiniciar. Best-effort en subshell con set +e:
# nunca aborta el flujo aunque algo dentro falle.
dump_diag() { ( set +e; _dump_diag "$@" ); return 0; }
_dump_diag() {
    local dest='' i
    if [ -n "${STAGING_ROOT:-}" ] && mountpoint -q "${STAGING_ROOT}" 2>/dev/null; then
        dest="${STAGING_ROOT}${CONTEST_DIR}/mini-deploy-logs"
    elif [ -n "${MEDIA:-}" ] && mountpoint -q "${MEDIA}" 2>/dev/null; then
        dest="${MEDIA}/mini-deploy-logs"
    else
        return 0
    fi
    mkdir -p "${dest}" 2>/dev/null || return 0
    {
        echo "=== mini-deploy diag $(date -u '+%F %T UTC') ==="
        echo; echo '--- ip -4 a ---';      ip -4 a 2>&1
        echo; echo '--- ip route ---';     ip route 2>&1
        echo; echo '--- nmcli device ---'; LC_ALL=C nmcli -t -f DEVICE,TYPE,STATE device 2>&1
        for i in /sys/class/net/*; do
            i="${i##*/}"; [ "${i}" = lo ] && continue
            echo; echo "--- ${i} ---"
            ethtool "${i}" 2>&1 | grep -E 'Speed|Duplex|Link detected' || true
            ethtool -i "${i}" 2>&1 | grep -E 'driver|bus-info' || true
        done
        echo; echo '--- NIC hardware ---'
        lspci -nn 2>/dev/null | grep -iE 'ethernet|network' || true
        lsusb 2>/dev/null | grep -iE 'ether|wlan|wireless|network' || true
        echo; echo '--- dmesg (firmware/red/enlace) ---'
        dmesg 2>/dev/null | grep -iE 'firmware|link is|eth[0-9]|r815|igb|e1000|carrier' | tail -n 40 || true
        echo; echo '--- SHA256 payload vs manifest ---'
        ( cd "${payload:-/nonexistent}" 2>/dev/null && sha256sum -c SHA256SUMS 2>&1 ) || true
        echo; echo '--- aria2 (¿seed completo? peers, velocidades) ---'
        aria2_report 2>&1 || true
    } > "${dest}/diag.txt" 2>&1
    for i in session.log seed.log download.log; do
        [ -f "/run/mini-deploy/${i}" ] && cp "/run/mini-deploy/${i}" "${dest}/${i}" 2>/dev/null || true
    done
    sync 2>/dev/null || true
    echo "  Diagnóstico guardado en: ${dest}/  (léelo desde Windows/Linux tras reiniciar)"
}

# Dump legible del estado del torrent activo vía RPC de aria2.
aria2_report() {
    python3 - <<'PY' 2>/dev/null || true
import json, urllib.request
def rpc(m, p=[]):
    b = json.dumps({"jsonrpc":"2.0","id":"d","method":m,"params":p}).encode()
    r = urllib.request.Request("http://127.0.0.1:6800/jsonrpc", data=b,
                               headers={"Content-Type":"application/json"})
    return json.load(urllib.request.urlopen(r, timeout=2)).get("result")
try:
    for it in rpc("aria2.tellActive") or []:
        c, t = int(it.get("completedLength",0)), int(it.get("totalLength",0))
        pct = (100*c/t) if t else 0
        state = "COMPLETO" if t and c >= t else "sin verificación adicional (SHA-256 ya validado)"
        print(f"descarga: {c}/{t} bytes ({pct:.1f}%)  {state}")
        print(f"  conexiones={it.get('connections')} subida={int(it.get('uploadSpeed',0))/1048576:.2f} MiB/s "
              f"bajada={int(it.get('downloadSpeed',0))/1048576:.2f} MiB/s errores={it.get('errorCode')}")
        for p in rpc("aria2.getPeers", [it["gid"]]) or []:
            print(f"  peer {p.get('ip')}:{p.get('port')} seeder={p.get('seeder')} "
                  f"up={int(p.get('uploadSpeed',0))/1024:.0f}KiB/s down={int(p.get('downloadSpeed',0))/1024:.0f}KiB/s")
    print("stat:", rpc("aria2.getGlobalStat"))
except Exception as e:
    print("aria2 RPC no disponible:", e)
PY
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# Con set -e cualquier comando que falle aborta sin decir cuál; esto nombra la
# causa y deja el diagnóstico en disco antes de salir.
trap 'rc=$?; [ "${PROGRESS_OPEN:-0}" = 1 ] && printf "\n"; echo "  CAUSA: ${BASH_SOURCE[0]##*/}:${LINENO}: fallo \`${BASH_COMMAND}\` (código ${rc})" >&2; dump_diag || true; exit ${rc}' ERR

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
# Segundos sin recibir un solo byte por LAN antes de caer al respaldo
# (Internet/USB). Arranque escalonado de un lab grande: subir si el switch
# tarda en propagar el multicast LPD. Sin respaldo la espera es indefinida.
MINI_LAN_WAIT="${MINI_LAN_WAIT:-60}"
case "${MINI_LAN_WAIT}" in ''|*[!0-9]*) MINI_LAN_WAIT=60 ;; esac
# Un lab grande puede tener más de 55 equipos (tope BT por defecto) en el enjambre.
BT_MAX_PEERS="${MINI_BT_MAX_PEERS:-100}"
STAGING_ROOT=''   # lo fija find_staging_root con la partición elegida
STAGING_DEV=''
CURRENT_TMP=''

RUNTIME_FILES=(filesystem.squashfs vmlinuz initrd.img grub-entry.cfg)
# No dejar el disco montado indefinidamente si la red queda congelada.
CURL_OPTS=(--fail --location --progress-bar --retry 3 --connect-timeout 15 --speed-limit 1 --speed-time 120)

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

# Aviso llamativo justo antes de entrar en modo seed: sin esto, un operador
# desprevenido deja el equipo sirviendo indefinidamente sin saber que ENTER
# lo arranca. Colores ANSI, no requiere figlet/toilet ni otra dependencia.
show_seed_banner() {
    local reset='\033[0m' bar='\033[1;33m' box='\033[1;97;44m'
    printf "${bar}"
    printf '  %s\n' '################################################################'
    printf "${reset}${box}"
    printf '  %-62s  \n' ''
    printf '  %-62s  \n' '        >>>  PRESIONE ENTER PARA INICIAR EL SISTEMA  <<<'
    printf '  %-62s  \n' '           (si no, el equipo queda en MODO SEED)'
    printf '  %-62s  \n' ''
    printf "${reset}${bar}"
    printf '  %s\n' '################################################################'
    printf "${reset}\n"
}

# El latido LPD y el estado del enjambre son python; sin estos módulos el
# descubrimiento LAN se degrada al intervalo nativo de aria2 (~5 min).
python3 -c 'import json, socket, hashlib, urllib.request' 2>/dev/null || {
    echo "  ADVERTENCIA: python3 incompleto (¿python3-minimal?). El descubrimiento" >&2
    echo "               LPD y el estado del enjambre quedarán degradados." >&2
}

# Tracker BT opcional (se suma a LPD y a los del .torrent). Respaldo si el
# switch filtra el multicast de LPD. Levantar en el origen, p. ej. opentracker.
BT_TRACKER=()
[ -n "${MINI_TRACKER_URL:-}" ] && BT_TRACKER=(--bt-tracker="${MINI_TRACKER_URL}")

# La ruta por defecto puede ser WiFi/Internet aunque la LAN esté por cable.
# MINI_LAN_INTERFACE permite forzarla cuando el equipo tenga varias LAN.
LPD_INTERFACE="${MINI_LAN_INTERFACE:-$(LC_ALL=C nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null \
    | awk -F: '$2 == "ethernet" && $3 == "connected" { print $1; exit }')}"
[ -n "${LPD_INTERFACE}" ] || LPD_INTERFACE="$(ip -4 route show default 2>/dev/null \
    | awk '{ for (i=1; i<NF; i++) if ($i == "dev") { print $(i+1); exit } }')"
LOCAL_IP="$(ip -4 -o addr show dev "${LPD_INTERFACE}" scope global 2>/dev/null \
    | awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }')"
if [ -z "${LOCAL_IP}" ] && [ -z "${MINI_LAN_INTERFACE:-}" ]; then
    read -r LPD_INTERFACE LOCAL_IP < <(ip -4 -o addr show scope global 2>/dev/null \
        | awk '$2 != "lo" { sub(/\/.*/, "", $4); print $2, $4; exit }') || true
fi
[ -n "${LOCAL_IP}" ] || { echo "LPD requiere IPv4 en ${LPD_INTERFACE:-una interfaz de red}." >&2; exit 1; }
BT_LAN=(--bt-enable-lpd=true --bt-lpd-interface="${LPD_INTERFACE}" --listen-port=6881)
echo "  LPD activo en ${LPD_INTERFACE} (${LOCAL_IP}): multicast UDP 239.192.152.143:6771, peers TCP 6881."
LINK_SPEED="$(cat "/sys/class/net/${LPD_INTERFACE}/speed" 2>/dev/null || true)"
case "${LINK_SPEED}" in
    ''|*[!0-9]*) ;;
    *)
        echo "  Enlace ${LPD_INTERFACE}: ${LINK_SPEED} Mbit/s negociados."
        [ "${LINK_SPEED}" -gt 100 ] || echo '  ADVERTENCIA: enlace de 100 Mbit/s; ~94 Mbit/s es su máximo real.'
        ;;
esac

# aria2 solo anuncia LPD cada ~5 min; una ventana LAN de MINI_LAN_WAIT s no
# alcanza a verlo. Este latido:
#   * calcula el infohash del .torrent LOCALMENTE (no depende del RPC de aria2,
#     así funciona desde el primer segundo aunque el RPC tarde en levantar),
#   * emite BT-SEARCH al grupo multicast cada MINI_LPD_INTERVAL s,
#   * re-hace el JOIN del grupo cada ~30 s: en switches con IGMP snooping SIN
#     querier, eso mantiene viva la entrada y evita que el switch pode el
#     multicast (síntoma: el cliente no ve al seed y cae a Internet).
lpd_heartbeat() {
    python3 - "$1" "${MINI_LPD_INTERVAL:-2}" "${LOCAL_IP}" "${bundle}" <<'PY' 2>/dev/null
import hashlib, os, socket, sys, time

aria_pid = int(sys.argv[1])
interval = float(sys.argv[2])
local_ip = sys.argv[3]
torrent_path = sys.argv[4]
GROUP = "239.192.152.143"

def _skip(b, i):
    c = b[i:i+1]
    if c == b"i":
        return b.index(b"e", i) + 1
    if c == b"l":
        i += 1
        while b[i:i+1] != b"e":
            i = _skip(b, i)
        return i + 1
    if c == b"d":
        i += 1
        while b[i:i+1] != b"e":
            i = _skip(b, i)          # clave
            i = _skip(b, i)          # valor
        return i + 1
    j = b.index(b":", i)             # cadena
    return j + 1 + int(b[i:j])

def infohash(path):
    b = open(path, "rb").read()
    i = 1                            # tras la 'd' inicial
    while b[i:i+1] != b"e":
        ks = i; i = _skip(b, i)
        key = b[ks:i].split(b":", 1)[1]
        vs = i; i = _skip(b, i)
        if key == b"info":
            return hashlib.sha1(b[vs:i]).hexdigest()
    return None

try:
    info_hash = infohash(torrent_path)
except Exception:
    info_hash = None

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(local_ip))
sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
mreq = socket.inet_aton(GROUP) + socket.inet_aton(local_ip)

def rejoin():
    for opt in (socket.IP_DROP_MEMBERSHIP, socket.IP_ADD_MEMBERSHIP):
        try:
            sock.setsockopt(socket.IPPROTO_IP, opt, mreq)
        except OSError:
            pass

rejoin()
tick = 0
msg = None
if info_hash:
    msg = (f"BT-SEARCH * HTTP/1.1\r\nHost: {GROUP}:6771\r\n"
           f"Port: 6881\r\nInfohash: {info_hash}\r\n\r\n\r\n").encode()

while os.path.exists(f"/proc/{aria_pid}"):
    if msg:
        try:
            sock.sendto(msg, (GROUP, 6771))
        except OSError:
            pass
    tick += 1
    if tick % max(1, int(30 / interval)) == 0:
        rejoin()
    time.sleep(interval)
PY
}

# Sin esto, cada actualización imprimía líneas nuevas que empujaban hacia
# arriba (y perdían de vista) la información previa del arranque. show()
# repinta SIEMPRE la misma línea con \r + borrado hasta fin de línea (sin
# \n), como una barra de progreso. progress_break (más abajo) inserta el
# único salto de línea real cuando hay que dejar esa línea fija y seguir
# con mensajes normales.
PROGRESS_OPEN=0
progress_break() {
    if [ "${PROGRESS_OPEN}" = 1 ]; then
        printf '\n'
        PROGRESS_OPEN=0
    fi
}

show_swarm_status() {
    python3 - "$1" "${LOCAL_IP}" <<'PY' 2>/dev/null || true
import json, os, sys, urllib.request

mode, local_ip = sys.argv[1:]

def show(text):
    sys.stdout.write('\r' + text + '\x1b[K')
    sys.stdout.flush()

def rpc(method, params=[]):
    body = json.dumps({"jsonrpc": "2.0", "id": "x", "method": method, "params": params}).encode()
    req = urllib.request.Request('http://127.0.0.1:6800/jsonrpc', data=body,
                                 headers={'Content-Type': 'application/json'})
    return json.load(urllib.request.urlopen(req, timeout=2)).get('result')

def mib(value):
    return int(value or 0) / 1048576

def mbit(value):
    return int(value or 0) * 8 / 1_000_000

def size(value):
    value = int(value or 0)
    for unit in ('B', 'KiB', 'MiB', 'GiB'):
        if value < 1024 or unit == 'GiB':
            return f'{value:.1f} {unit}'
        value /= 1024

def eta(remaining, speed):
    speed = int(speed or 0)
    if not speed:
        return 'calculando...'
    seconds = int(remaining / speed)
    hours, seconds = divmod(seconds, 3600)
    minutes, seconds = divmod(seconds, 60)
    return f'{hours}h {minutes:02d}m' if hours else f'{minutes}m {seconds:02d}s'

try:
    active = rpc('aria2.tellActive') or []
    if mode == 'download' and not active:
        stopped = rpc('aria2.tellStopped', [0, 10]) or []
        finished = next((item for item in stopped if item.get('status') == 'complete'), None)
        failed = next((item for item in stopped if item.get('status') in ('error', 'removed')), None)
        if finished:
            open('/run/mini-deploy/download-complete', 'w').close()
            show(f"  Descarga completa; verificando archivos...")
        elif failed:
            open('/run/mini-deploy/download-error', 'w').close()
            show(f"  aria2 terminó con error {failed.get('errorCode', '?')}.")
        else:
            show(f"  Esta máquina {local_ip} | buscando peers LPD...")
        raise SystemExit
    peers = [peer for item in active for peer in (rpc('aria2.getPeers', [item['gid']]) or [])]
    ips = sorted({peer['ip'] for peer in peers})
    seeds = sorted({peer['ip'] for peer in peers if peer.get('seeder') == 'true'})
    stat = rpc('aria2.getGlobalStat') or {}
    if mode == 'seed':
        up = stat.get('uploadSpeed')
        show(f"  Seed {local_ip} | equipos servidos: {len(ips)} ({', '.join(ips) or '-'})"
              f" | red: {mib(up):.1f} MiB/s ({mbit(up):.0f} Mbit/s)")
    else:
        completed = sum(int(item.get('completedLength', 0)) for item in active)
        total = sum(int(item.get('totalLength', 0)) for item in active)
        remaining = max(0, total - completed)
        pct = 100 * completed / total if total else 0
        files = [file for item in active for file in item.get('files', [])]
        pending = [file for file in files
                   if int(file.get('completedLength', 0)) < int(file.get('length', 0))]
        current = max(pending,
                      key=lambda file: int(file['length']) - int(file.get('completedLength', 0)),
                      default=None)
        with open('/run/mini-deploy/download-progress', 'w') as progress:
            progress.write(str(completed))
        with open('/run/mini-deploy/download-seeds', 'w') as seed_count:
            seed_count.write(str(len(seeds)))
        down = stat.get('downloadSpeed')
        parts = [f"Esta máquina {local_ip} | seeds: {len(seeds)} ({', '.join(seeds) or '-'})"
              f" | peers: {len(ips)} ({', '.join(ips) or '-'})"
              f" | red: {mib(down):.1f} MiB/s ({mbit(down):.0f} Mbit/s)",
              f"Descarga: {pct:.1f}% | {size(completed)} de {size(total)}"
              f" | faltan {size(remaining)} | tiempo estimado: {eta(remaining, down)}"]
        if current:
            file_done, file_total = int(current.get('completedLength', 0)), int(current['length'])
            parts.append(f"Archivo: {os.path.basename(current['path'])}"
                  f" ({100 * file_done / file_total if file_total else 0:.1f}%)")
        show('  ' + '  ||  '.join(parts))
except Exception:
    show(f"  Esta máquina {local_ip} | actualizando estado; la descarga continúa...")
PY
    PROGRESS_OPEN=1
}

# $1 = segundos sin progreso (ni un peer, ni un byte nuevo) antes de rendirse
# (0 = espera indefinida, sin respaldo).
run_lpd_download() {
    local stall_max="$1"; shift
    local pid rc bytes last_bytes=-1 last_progress=${SECONDS}
    rm -f /run/mini-deploy/download-progress /run/mini-deploy/download-seeds \
        /run/mini-deploy/download-complete /run/mini-deploy/download-error
    aria2c --enable-rpc --rpc-listen-port=6800 "${BT_LAN[@]}" \
        --bt-max-peers="${BT_MAX_PEERS}" "$@" \
        >/run/mini-deploy/download.log 2>&1 &
    pid=$!
    ARIA_PID="${pid}"
    lpd_heartbeat "${pid}" &
    while kill -0 "${pid}" 2>/dev/null; do
        show_swarm_status download
        if [ -e /run/mini-deploy/download-complete ]; then
            progress_break
            kill "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
            ARIA_PID=''
            return 0
        fi
        if [ -e /run/mini-deploy/download-error ]; then
            progress_break
            kill "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
            ARIA_PID=''
            return 1
        fi
        bytes="$(cat /run/mini-deploy/download-progress 2>/dev/null || echo 0)"
        case "${bytes}" in ''|*[!0-9]*) bytes=0 ;; esac
        [ "${bytes}" != "${last_bytes}" ] && last_progress=${SECONDS}
        last_bytes="${bytes}"
        if [ "${stall_max}" -gt 0 ] && [ "$((SECONDS - last_progress))" -ge "${stall_max}" ]; then
            progress_break
            echo "  Sin progreso (ni peers ni bytes nuevos) durante ${stall_max} s; se usa el respaldo (Internet/USB)."
            # Congela el estado (peers, %, si el seed era completo) antes de matar aria2.
            { echo "=== estado al agotar la ventana LAN ($(date -u '+%T')) ==="; aria2_report; } \
                >> /run/mini-deploy/download.log 2>&1 || true
            kill "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
            return 124
        fi
        sleep 2
    done
    progress_break
    wait "${pid}" || {
        rc=$?
        tail -n 10 /run/mini-deploy/download.log >&2 || true
        ARIA_PID=''
        return "${rc}"
    }
    ARIA_PID=''
}

# ---------------------------------------------------------------------------
# Metadatos del contest (manifest.json + contest-*.torrent)
# ---------------------------------------------------------------------------
# No vienen en la imagen mini: se toman del USB si está, o se bajan del origen
# (MINI_METADATA_URL). manifest.json trae la versión; con ella se arma el nombre
# del .torrent, necesario tanto para la copia por LAN como para sembrar luego.

mkdir -p "${LAN_DIR}" 2>/dev/null || { LAN_DIR=/run/mini-deploy/lan; mkdir -p "${LAN_DIR}"; }
META_URL="${MINI_METADATA_URL:-}"

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
[ -n "${meta_src}" ] || { echo 'Sin metadatos: no hay USB ni MINI_METADATA_URL' >&2; exit 1; }

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

# El USB puede desmontarse antes de descargar o sembrar; conserva los dos
# metadatos que aria2 y artifact_url siguen necesitando.
cp "${manifest}" /run/mini-deploy/manifest.json
cp "${bundle}" /run/mini-deploy/contest.torrent
manifest=/run/mini-deploy/manifest.json
bundle=/run/mini-deploy/contest.torrent

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
    echo "  Copiando ${file}..."
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

# Salta al runtime copiado cuando el operador sale del modo seed.
boot_runtime() {
    local runtime="$1" append media_uuid

    # NetworkManager guarda los perfiles (WiFi, IP fija) solo en la RAM del
    # mini. Se copian al medio para que el initramfs del runtime los reponga en
    # cada arranque: sin esto un equipo sin cable se queda sin red tras el kexec.
    if ls /etc/NetworkManager/system-connections/* >/dev/null 2>&1; then
        mkdir -p "${runtime}/network"
        cp /etc/NetworkManager/system-connections/* "${runtime}/network/" || true
        chmod 600 "${runtime}"/network/* 2>/dev/null || true
        echo "  Perfiles de red copiados a ${runtime}/network para el runtime."
    fi

    append="$(awk '/^[[:space:]]*linux[[:space:]]/ { $1=""; $2=""; sub(/^[[:space:]]+/, ""); print; exit }' \
        "${runtime}/grub-entry.cfg" 2>/dev/null)"
    [ -n "${append}" ] || append="pcie_aspm=off contest_dir=${CONTEST_DIR} contest_root=filesystem.squashfs contest_persist=auto contest.boot_source=hdd contest.persist_scope=home console=tty0"
    media_uuid="$(blkid -o value -s UUID "${STAGING_DEV}" 2>/dev/null || true)"
    [ -n "${media_uuid}" ] && append="${append} contest.media_uuid=${media_uuid}"

    echo "  Arrancando el sistema desde ${runtime} ..."
    if kexec --load "${runtime}/vmlinuz" --initrd="${runtime}/initrd.img" --append="${append}"; then
        sync
        umount -l "${STAGING_ROOT}" 2>/dev/null || true
        # kexec no pasa por el BIOS/POST: si el wifi Intel queda a mitad de
        # inicializar, el kernel del runtime hereda esos registros y iwlwifi
        # falla el probe (-110) sin importar qué haga después. Se descarga el
        # driver antes de saltar para que quede en un estado limpio conocido.
        # ponytail: solo cubre iwlwifi (caso visto); sumar otros drivers wifi
        # a esta lista si aparece el mismo síntoma con otro chipset.
        modprobe -r iwlwifi 2>/dev/null || true
        kexec --exec || true
    fi
    kexec --unload 2>/dev/null || true
    return 1
}

# Recorre cada partición una sola vez: busca un runtime válido y, si no existe,
# se queda con la partición escribible que tenga más espacio libre.
find_staging_root() {
    local part fs mount_fs free_kb candidate probe mount_error write_error
    local best_free=0 best_part='' best_fs=''

    echo
    echo '  Buscando un runtime o una partición apta para /icpc_bo...'
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

        candidate="/mnt/mini-deploy${CONTEST_DIR}"
        if cmp -s "${candidate}/SHA256SUMS" "${EXPECTED_SUMS}"; then
            echo "  VERIFICANDO IMAGEN en ${part}; puede tardar varios minutos..."
            if (cd "${candidate}" && sha256sum -c "${EXPECTED_SUMS}" >/dev/null 2>&1); then
                STAGING_ROOT=/mnt/mini-deploy
                STAGING_DEV="${part}"
                payload="${candidate}"
                RUNTIME_FOUND=true
                echo "  Runtime validado en ${part}; no se descargará nuevamente."
                return 0
            fi
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

RUNTIME_FOUND=false
find_staging_root || stop_no_disk
if [ "${RUNTIME_FOUND}" = true ]; then
    release_usb 'El runtime ya estaba validado en el disco.'
else
    payload="${STAGING_ROOT}${CONTEST_DIR}"
    mkdir -p "${payload}"
    cp "${EXPECTED_SUMS}" "${payload}/SHA256SUMS"

    # Ventana LAN de MINI_LAN_WAIT s para hallar un seed por LPD antes de tirar
    # del respaldo. Al descubrir uno se conserva la conexión hasta completar.
    usb="${MEDIA}${CONTEST_DIR}"
    usb_released=false
    copied_from_lan=false
    if [ -n "${META_URL}" ] || [ -f "${usb}/filesystem.squashfs" ]; then
        echo "  Buscando un seed en la red local (hasta ${MINI_LAN_WAIT} s) antes de usar el respaldo..."
        if run_lpd_download "${MINI_LAN_WAIT}" --enable-dht=false --bt-exclude-tracker='*' \
            --check-integrity=true --seed-time=0 --summary-interval=1 \
            --human-readable=true --show-console-readout=true --console-log-level=notice \
            --dir="${STAGING_ROOT}" "${bundle}" \
            && (cd "${payload}" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
            copied_from_lan=true
        fi
    fi

    if [ "${copied_from_lan}" = false ] && [ -n "${META_URL}" ]; then
        # Guarda por qué falló la LAN (peers vistos, %, velocidades) antes de
        # borrar los parciales y tirar de Internet.
        dump_diag
        for f in "${RUNTIME_FILES[@]}"; do
            artifact_valid "${f}" || rm -f "${payload}/${f}" "${payload}/${f}.aria2"
        done
        release_usb 'No se halló un seed LAN; el runtime se descargará de Internet.'
        usb_released=true
        echo "  Descargando runtime desde ${META_URL}"
        for f in "${RUNTIME_FILES[@]}"; do
            copy_runtime_file "${f}" "$(artifact_url "${f}")" http
        done
    elif [ "${copied_from_lan}" = false ] && [ -f "${usb}/filesystem.squashfs" ]; then
        for f in "${RUNTIME_FILES[@]}"; do
            copy_runtime_file "${f}" "${usb}/${f}" usb
        done
    elif [ "${copied_from_lan}" = false ]; then
        # Sin Internet ni USB: la LAN es la única fuente. Se espera
        # indefinidamente (stall_max=0) a que aparezca un seed; el orden de
        # arranque de los equipos deja de importar.
        echo '  Sin Internet ni USB: esperando un seed en la red local...'
        run_lpd_download 0 --enable-dht=false --check-integrity=true --seed-time=0 \
            --summary-interval=1 --human-readable=true --show-console-readout=true --console-log-level=notice \
            "${BT_TRACKER[@]}" --dir="${STAGING_ROOT}" "${bundle}" \
            || { echo '  aria2c terminó con error; revise /run/mini-deploy/download.log.' >&2; exit 1; }
    fi

    # Falla (y aborta por set -e) si algún archivo no coincide con su sha256.
    (cd "${payload}" && sha256sum -c SHA256SUMS)
    printf 'INSTALLED_FROM=mini-deploy\n' > "${payload}/.contest-installed"
    [ "${usb_released}" = true ] || release_usb 'El runtime fue copiado y validado en el disco.'
fi

# ---------------------------------------------------------------------------
# Compartir con el resto de equipos
# ---------------------------------------------------------------------------

# El intento LAN cancelado deja <raíz-del-torrent>.aria2 marcando las piezas
# como incompletas. Los SHA-256 de arriba ya validaron todo; se elimina ese
# estado obsoleto para que --bt-seed-unverified anuncie un seed real.
rm -f "${payload}.aria2" "${payload}"/*.aria2

# El mini queda EN MODO SEED por defecto: sirve el runtime al resto de equipos
# y espera a que el operador pulse ENTER para salir y arrancar. MINI_SEED_WAIT
# (segundos) fuerza un arranque automatico; vacio/0 = espera indefinida.
SEED_WAIT="${MINI_SEED_WAIT:-0}"
SEED_PID=''

wait_seed_exit() {
    local ans=''
    echo
    if [ "${SEED_WAIT}" -gt 0 ] 2>/dev/null; then
        echo "  Modo seed activo. ENTER = arrancar   q + ENTER = cerrar NTFS y apagar   (o espera ${SEED_WAIT} s)."
        read -r -t "${SEED_WAIT}" ans || true
    else
        echo '  Modo seed activo. ENTER = arrancar   q + ENTER = cerrar NTFS y apagar.'
        read -r ans || true
    fi
    [ -n "${SEED_PID}" ] && { kill "${SEED_PID}" 2>/dev/null || true; wait "${SEED_PID}" 2>/dev/null || true; }
    case "${ans}" in q|Q) exit 130 ;; esac
}

show_seed_banner

aria2c --enable-rpc --rpc-listen-port=6800 \
        "${BT_LAN[@]}" --enable-dht=false --bt-max-peers="${BT_MAX_PEERS}" \
        --check-integrity=false --bt-seed-unverified=true \
        --seed-time=525600 --seed-ratio=0.0 --summary-interval=0 \
        "${BT_TRACKER[@]}" --dir="${STAGING_ROOT}" "${bundle}" \
        >/run/mini-deploy/seed.log 2>&1 &
    share_pid=$!
    ARIA_PID="${share_pid}"     # cleanup lo mata para soltar el NTFS antes de umount
    lpd_heartbeat "${share_pid}" &
    SEED_PID="${share_pid}"
    echo "  Sembrando el runtime desde ${LOCAL_IP}:6881; anuncio LPD cada ${MINI_LPD_INTERVAL:-2} s."
    echo '  Teclas (tecla + ENTER):  d = guardar diagnóstico en disco   q = cerrar NTFS y apagar   ENTER = salir y arrancar'

    stopped_by_enter=0
    while kill -0 "${share_pid}" 2>/dev/null; do
        show_swarm_status seed
        if read -r -t 2 key; then
            case "${key}" in
                d|D) progress_break; dump_diag ;;
                q|Q) progress_break; dump_diag; exit 130 ;;   # trap EXIT: cierra NTFS; init -> apaga
                *)   stopped_by_enter=1; break ;;
            esac
        fi
    done
    progress_break

    # Si aria2c murió solo, muestra la causa y espera ENTER.
    if ! kill -0 "${share_pid}" 2>/dev/null; then
        echo '  El proceso seed se detuvo. Detalle:' >&2
        tail -n 10 /run/mini-deploy/seed.log >&2 || true
    fi
    [ "${stopped_by_enter}" = 1 ] || wait_seed_exit
    kill "${share_pid}" 2>/dev/null || true
    wait "${share_pid}" 2>/dev/null || true
    ARIA_PID=''

# ---------------------------------------------------------------------------
# Arrancar el runtime ya copiado en el disco
# ---------------------------------------------------------------------------

boot_runtime "${payload}" && exit 0

# Si llegamos aquí, kexec falló. No dejamos morir a PID 1: alto controlado.
echo '  ERROR: el runtime está copiado y verificado en el disco, pero el' >&2
echo '         arranque automático (kexec) falló.' >&2
echo '         Causa más común en equipos UEFI: Secure Boot activo (bloquea' >&2
echo '         kexec de un kernel sin firmar). Desactívalo en la BIOS y vuelve' >&2
echo '         a arrancar el mini: detectará el runtime ya validado en disco,' >&2
echo '         no descargará nada y hará kexec de nuevo.' >&2
tail -n 5 /run/mini-deploy/session.log 2>/dev/null >&2 || true
exit 1
