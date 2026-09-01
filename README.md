# Mini Deploy

Subproyecto autónomo para construir el sistema mínimo que arranca en RAM,
distribuye el runtime completo (USB, HTTP o LAN vía BitTorrent) y salta a él con
`kexec`.

No construye `filesystem.squashfs` del runtime, no instala un escritorio, no
inicia `systemd` y **nunca modifica particiones**. Su único destino persistente
es un folder propio (`/icpc_bo` por defecto) dentro de una partición existente y
montable.

El mini es autónomo: `build-mini` solo empaqueta su propia imagen base y no
consulta ningún runtime. Todo lo del runtime (manifest, `.torrent`, ficheros) lo
obtiene el equipo **al arrancar**, desde USB o `MINI_ARTIFACT_URL`.

## Construcción

```bash
sudo ./start.sh build-mini      # -> output/mini-deploy.iso
sudo ./start.sh run-mini        # arranca esa ISO en QEMU
```

`build-mini` hace `debootstrap --variant=minbase`, instala `packages.list` + el
overlay, y empaqueta un `filesystem.squashfs` booteable con `live-boot` usando el
kernel/initrd propios del mini. Reutiliza `apt-cacher-ng` en `127.0.0.1:3142` si
está activo. Sin entradas externas.

Configuración: copia `config.env.example` como `config.env` y ajústalo; `build.sh`
lo hornea en la ISO. `lan-fetch.sh` exige `CONTEST_DIR`, `MINI_MEDIA_DIR`,
`LAN_DIR` y `MINI_STAGING_MIB`; `MINI_ARTIFACT_URL` (origen HTTP del runtime y sus
metadatos) y `MINI_TRACKER_URL` (tracker BT de respaldo) son opcionales.

Salida:

```text
output/mini-deploy.iso
output/filesystem.squashfs   output/vmlinuz   output/initrd.img
```

La ISO configura `tty0` y `ttyS0` a 115200 baudios; en KVM se ve la misma salida
en la ventana gráfica y con `virsh console`.

## Firmware de red

`packages.list` trae firmware por chipset para que el kernel reconozca la
tarjeta WiFi/LAN del equipo al arrancar (nada de audio, gráficos ni GPU —
un laptop cualquiera de un concursante no necesita eso para desplegar):

| Paquete | Cubre |
|---|---|
| `firmware-iwlwifi` | WiFi Intel |
| `firmware-realtek` | WiFi y Ethernet Realtek (rtl8xxxu, rtw88/89, r8169…) |
| `firmware-atheros` | WiFi Qualcomm Atheros (ath3k, ath6kl, ath10k, ath11k) + Bluetooth |
| `firmware-ath9k-htc` | WiFi USB Atheros AR7010/AR9271 (dongles) |
| `firmware-brcm80211` | WiFi Broadcom/Cypress |
| `firmware-mediatek` | WiFi/red MediaTek y Ralink |
| `firmware-libertas` | WiFi Marvell (libertas/mwifiex) |
| `firmware-misc-nonfree` | resto de tarjetas de red sin paquete propio |

Es reconocimiento inicial de hardware, no el driver completo con todas sus
funciones (p. ej. sin firmware Bluetooth de audio ni de gráficos/GPU): lo
justo para que `iw`/`NetworkManager` vean la tarjeta y `deploy-run.sh` pueda
ofrecerla en el menú de red.

## Flujo en el equipo

1. **Red.** `deploy-run.sh` levanta DHCP; un menú (`whiptail`) permite WiFi o IP
   manual antes de continuar.
2. **Disco.** `lan-fetch.sh` recorre las particiones, prueba a montarlas y a
   **escribir** en ellas (descarta NTFS bloqueada por hibernación o Inicio
   rápido, solo-lectura, sin espacio) y elige la que tenga más libre por encima
   de `MINI_STAGING_MIB`. Admite ext4, ext3, xfs y NTFS/NTFS3.
3. **Metadatos.** `lan-fetch.sh` toma `manifest.json` + `contest-*.torrent` del
   USB o los baja de `MINI_ARTIFACT_URL`.
4. **Copia** del runtime a `<partición>/icpc_bo`, primera fuente disponible:
   USB → servidor HTTP → LAN (aria2c, BitTorrent). Escritura a `.tmp` + rename.
5. **Verificación** SHA-256 contra `manifest.json`.
6. **Siembra.** Venga de donde venga la copia, el equipo queda compartiendo el
   paquete por LAN (LPD, y tracker si se configuró), así los que arrancan más
   tarde descargan de todos los que ya terminaron, no solo del origen.
7. **Arranque.** Al pulsar ENTER se corta la siembra y se salta con `kexec` al
   `vmlinuz`/`initrd.img`/`filesystem.squashfs` ya copiados. Sin tocar
   particiones ni gestor de arranque.

Para un evento con arranques escalonados, mantén el servidor origen sembrando el
`.torrent` durante toda la ventana: es la fuente garantizada si un seed se va.

## Credenciales

El mini sistema no crea un usuario de escritorio ni habilita un login SSH. El
servicio de despliegue corre como `root`; la cuenta `root` permanece bloqueada
sin contraseña. La opción `shell` del menú abre una consola root local durante
la sesión de despliegue.

## Pruebas

```bash
tests/run.sh
```
