# 🏛 Instalador del Templo

Instala **el Templo** (el portal de gestión de una logia) en un contenedor LXC de **Proxmox VE** con una sola orden.

El núcleo y el tema de la logia están en repositorios **privados**. Este repositorio es público solo para poder lanzar el script directamente: no lleva nada del Templo ni de ninguna logia.

## Instalar

En la **consola del host de Proxmox** (Datacenter → tu nodo → Shell), como root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hombrelobo2/templo-instalador/main/proxmox/templo.sh)"
```

Pulsa Intro para aceptar lo que va entre corchetes. El script:

1. Te pregunta el contenedor (número, nombre, disco, memoria, red), los repositorios, la web, los datos de la logia si no hay tema, y el usuario de administración.
2. Descarga la plantilla **Debian 13** (o la 12 si no está la 13).
3. Crea el contenedor sin privilegios: 2 núcleos, 2 GB de RAM, 16 GB de disco y arranque automático.
4. Le pone la zona horaria del host (Europe/Madrid si el host está en UTC).
5. Crea **una llave de solo lectura para el núcleo** y, si hay tema, **otra para el tema**, y te las enseña con el enlace a la página de GitHub donde se pegan.
6. Espera a que GitHub las acepte. Lo comprueba solo cada 10 segundos; no hay que pulsar nada.
7. Descarga el núcleo e instala la **última versión publicada**, el tema y el actualizador.
8. Crea tu usuario de administración y te enseña la dirección y las contraseñas.

### Las llaves en GitHub

Para cada llave que te enseñe, abre el enlace (`…/settings/keys`) y pulsa **Add deploy key**:
- **Title:** el que te sugiere, por ejemplo `Templo templo (131)`.
- **Key:** la línea que empieza por `ssh-ed25519`.
- **No** marques «Allow write access».

GitHub no deja usar la misma llave en dos repositorios. Por eso hay dos: la del núcleo va en el repositorio del núcleo y la del tema en el del tema.

## Añadir o cambiar el tema

Si instalaste sin tema, o la logia cambia de tema (en el ejemplo, el contenedor 131):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hombrelobo2/templo-instalador/main/proxmox/templo.sh)" -- tema 131
```

Te pide el repositorio del tema, te enseña su llave y lo instala.

Las líneas `LOGIA_*` del `.env` mandan sobre los datos del tema. Si al instalar sin tema pusiste los datos de la logia, bórralas para que se usen los del tema.

## Actualizar

Lo normal es actualizar desde la web: **Administración → Estado → Actualizaciones**. Desde el host también se puede:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hombrelobo2/templo-instalador/main/proxmox/templo.sh)" -- actualizar 131
```

## Instalación sin preguntas

```bash
SIN_PREGUNTAS=1 CT_ID=131 CT_IP=192.168.1.30/24 CT_GW=192.168.1.1 \
TEMPLO_TEMA=https://github.com/USUARIO/templo-tema-milogia TEMPLO_WEB=https://milogia.org \
TEMPLO_ADMIN=admin TEMPLO_ADMIN_PASS='una-contraseña-larga' \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hombrelobo2/templo-instalador/main/proxmox/templo.sh)"
```

Aun así, se para a enseñarte las llaves y espera a que las pegues en GitHub (30 minutos como mucho). Todas las variables están explicadas al principio de [`proxmox/templo.sh`](proxmox/templo.sh).

Sin tema, pon los datos de la logia: `LOGIA_NOMBRE`, `LOGIA_NUMERO`, `LOGIA_ORIENTE`, `LOGIA_OBEDIENCIA` y `LOGIA_CARACTER`. Para «solo Templo» (la logia ya tiene su web): `TEMPLO_WEB_PUBLICA=n` y, si quieres el enlace a la web de la logia, `TEMPLO_WEB_EXTERNA=https://…`.

## Después de instalar

- **Publicarlo:** en Nginx Proxy Manager, un *Proxy Host* hacia `http://IP-DEL-CONTENEDOR:8000`, con certificado de Let's Encrypt y «Force SSL». Con Cloudflare, SSL/TLS en «Completo (estricto)».
- **Doble verificación:** entra con tu usuario y actívala en *Mi perfil*.
- **Copias en el NAS:** en Proxmox, añade al contenedor un punto de montaje con la carpeta del NAS (*Resources → Add → Mount Point*, por ejemplo `/mnt/nas/templo`). Después, en el contenedor (`pct enter 131`), pon `BACKUP_DIR=/mnt/nas/templo` y `BACKUP_REQUIRE_MOUNT=1` en `/opt/luzdelnorte/.env`, reinicia con `systemctl restart luzdelnorte` y prueba con `luzdelnorte-cli copia`.
- **Copia cifrada en la nube:** `luzdelnorte-nube-conectar` (mira `NUBE.md` del núcleo).
- **Correo de Secretaría:** las líneas `SOGO_*` del `.env` (mira `CORREO.md` del núcleo).
- **Telegram:** `TELEGRAM_BOT_TOKEN` en el `.env` y después *Administración → Telegram*.
- **Avisos al móvil:** en *Mi perfil*, activa las notificaciones. En *Administración → Ajustes*, pon tu usuario en «Quién recibe el aviso».

## Si algo falla

- **Se queda esperando las llaves:** comprueba que cada una está en las *Deploy keys* de **su** repositorio. Desde el host: `pct exec 131 -- ssh -i /root/.ssh/templo_nucleo -p 443 -T git@ssh.github.com` debe saludar con el nombre del repositorio (con la del tema, `templo_tema`).
- **La web no arranca:** `pct exec 131 -- journalctl -u luzdelnorte -n 50`.
- **Volver a empezar:** `pct stop 131 && pct destroy 131` y repetir. Borra también sus llaves en GitHub.
