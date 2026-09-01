# Mini Deploy

Subproyecto autónomo para construir el sistema mínimo que arranca en RAM,
distribuye el runtime completo (USB, HTTP o LAN vía BitTorrent) y salta a él con
`kexec`.

No construye `filesystem.squashfs`, no instala un escritorio, no inicia
`systemd` y **nunca modifica particiones**. Su único destino persistente es un
folder propio (`/icpc_bo` por defecto) dentro de una partición existente y
montable.

## Contrato de entrada

El directorio indicado por `ARTIFACTS_DIR` debe contener:

- `filesystem.squashfs`
- `vmlinuz`
- `initrd.img`
- `grub-entry.cfg`
- `manifest.json`
- `contest-*.torrent`

`manifest.json` define los SHA-256 obligatorios. El torrent interno debe tener
como nombre `icpc_bo`, igual que `CONTEST_DIR` sin `/`.

## Construcción

```bash
sudo ARTIFACTS_DIR=/ruta/a/runtime ./build.sh
```

Desde `start.sh build-mini` se reutiliza automáticamente el servicio
`apt-cacher-ng` del proyecto principal cuando está disponible.

Configuración: copia `config.env.example` como `config.env` y ajústalo. `build.sh`
lo incluye en la ISO si existe. `lan-fetch.sh` exige `CONTEST_DIR`,
`MINI_MEDIA_DIR`, `LAN_DIR` y `MINI_STAGING_MIB`; `MINI_ARTIFACT_URL` (fallback
HTTP) y `MINI_TRACKER_URL` (tracker BT de respaldo) son opcionales.

Salida:

```text
output/deploy.squashfs
output/icpc_bo/{manifest.json,contest-*.torrent}
```

El empaquetado de ISO es responsabilidad de una capa posterior: este proyecto
solo entrega el rootfs RAM y los metadatos que esa ISO debe acompañar.

La ISO generada configura `tty0` y `ttyS0` a 115200 baudios; en KVM se puede
ver la misma salida en la ventana gráfica y con `virsh console`.

## Flujo en el equipo

1. **Red.** `deploy-run.sh` levanta DHCP; un menú (`whiptail`) permite WiFi o IP
   manual antes de continuar.
2. **Disco.** `lan-fetch.sh` recorre las particiones, prueba a montarlas y a
   **escribir** en ellas (descarta NTFS bloqueada por hibernación o Inicio
   rápido, solo-lectura, sin espacio) y elige la que tenga más libre por encima
   de `MINI_STAGING_MIB`. Admite ext4, ext3, xfs y NTFS/NTFS3.
3. **Copia** del runtime a `<partición>/icpc_bo`, primera fuente disponible:
   USB → servidor HTTP → LAN (aria2c, BitTorrent). Escritura a `.tmp` + rename.
4. **Verificación** SHA-256 contra `manifest.json`.
5. **Siembra.** Venga de donde venga la copia, el equipo queda compartiendo el
   paquete por LAN (LPD, y tracker si se configuró), así los que arrancan más
   tarde descargan de todos los que ya terminaron, no solo del origen.
6. **Arranque.** Al pulsar ENTER se corta la siembra y se salta con `kexec` al
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
