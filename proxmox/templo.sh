#!/usr/bin/env bash
# El Templo — crea un contenedor LXC en Proxmox VE y deja el Templo funcionando (núcleo y, si hay, el tema de la logia).
#
# Ejecútalo en la consola del host de Proxmox (como root):
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/hombrelobo2/templo-instalador/main/proxmox/templo.sh)"
#
# Añadir o cambiar el tema de un contenedor ya creado (p. ej. el 130):
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/hombrelobo2/templo-instalador/main/proxmox/templo.sh)" -- tema 130
#
# Actualizar el núcleo y el tema de un contenedor ya creado:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/hombrelobo2/templo-instalador/main/proxmox/templo.sh)" -- actualizar 130
#
# El núcleo y el tema son repositorios privados: el script crea en el contenedor una llave de solo lectura para cada uno,
# te las enseña para que las pegues en GitHub (Settings → Deploy keys) y sigue solo en cuanto GitHub las acepta.
#
# Sin preguntas (todo con variables):
#   CT_ID, CT_HOSTNAME, CT_CORES, CT_RAM, CT_SWAP, CT_DISCO (GB), CT_ALMACEN, CT_PUENTE, CT_IP (dhcp o 192.168.1.30/24),
#   CT_GW, CT_DNS, CT_VLAN, CT_CLAVE_ROOT, CT_DEBIAN (13 o 12),
#   TEMPLO_NUCLEO (repositorio del núcleo), TEMPLO_TEMA (repositorio del tema; vacío = sin tema), TEMPLO_WEB (https://…),
#   TEMPLO_WEB_PUBLICA (s/n), TEMPLO_WEB_EXTERNA, TEMPLO_ADMIN, TEMPLO_ADMIN_NOMBRE, TEMPLO_ADMIN_PASS,
#   LOGIA_NOMBRE, LOGIA_NUMERO, LOGIA_ORIENTE, LOGIA_OBEDIENCIA, LOGIA_CARACTER (solo sin tema),
#   y SIN_PREGUNTAS=1
set -Eeuo pipefail

NUCLEO_DEF="git@github.com:hombrelobo2/templo-nucleo.git"
SRC=/opt/luzdelnorte-src
LLAVE_NUCLEO=/root/.ssh/templo_nucleo
LLAVE_TEMA=/root/.ssh/templo_tema
ESPERA_LLAVES=${ESPERA_LLAVES:-1800}     # segundos esperando a que GitHub acepte las llaves

# ---------- Presentación ----------
if [ -t 1 ]; then
  V=$'\e[32m'; A=$'\e[33m'; R=$'\e[31m'; N=$'\e[1m'; C=$'\e[36m'; X=$'\e[0m'
else
  V=""; A=""; R=""; N=""; C=""; X=""
fi
ok()   { echo "${V}✔${X} $*"; }
info() { echo "${A}•${X} $*"; }
fallo(){ echo "${R}✘ $*${X}" >&2; exit 1; }
trap 'fallo "Algo ha fallado en la línea $LINENO. Revisa los mensajes de arriba."' ERR

preguntar() {   # preguntar VARIABLE "Texto" "por defecto"
  local var=$1 texto=$2 defecto=${3:-} resp
  if [ -n "${!var:-}" ]; then return; fi
  if [ "${SIN_PREGUNTAS:-0}" = "1" ]; then printf -v "$var" '%s' "$defecto"; return; fi
  read -r -p "  $texto [${defecto}]: " resp </dev/tty || true
  printf -v "$var" '%s' "${resp:-$defecto}"
}

preguntar_secreto() {   # preguntar_secreto VARIABLE "Texto" (vacío = se inventa)
  local var=$1 texto=$2 c1 c2
  if [ -n "${!var:-}" ] || [ "${SIN_PREGUNTAS:-0}" = "1" ]; then return; fi
  while true; do
    read -r -s -p "  $texto (Enter = inventar una): " c1 </dev/tty || true; echo
    [ -z "$c1" ] && return
    read -r -s -p "  Repítela: " c2 </dev/tty || true; echo
    if [ "$c1" = "$c2" ] && [ ${#c1} -ge 8 ]; then printf -v "$var" '%s' "$c1"; return; fi
    echo "  No coinciden o tiene menos de 8 caracteres."
  done
}

inventar_clave() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16 || true; }

repo_ssh() {    # https://github.com/u/r(.git) o git@github.com:u/r(.git) → git@github.com:u/r.git
  local u=$1
  u=${u%/}
  if [[ "$u" == https://github.com/* ]]; then u="git@github.com:${u#https://github.com/}"; fi
  [[ "$u" == *.git ]] || u="$u.git"
  printf '%s' "$u"
}
repo_nombre() { local u=${1#git@github.com:}; printf '%s' "${u%.git}"; }   # → usuario/repositorio

# «pct exec» no siempre trae /usr/local/bin en el PATH (ahí están luzdelnorte-cli y luzdelnorte-actualizar)
CT_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
en_ct() { pct exec "$CT_ID" -- env PATH=$CT_PATH LANG=C.UTF-8 LC_ALL=C.UTF-8 DEBIAN_FRONTEND=noninteractive bash -c "$1"; }

crear_llave() {   # crear_llave RUTA COMENTARIO
  en_ct "mkdir -p /root/.ssh && chmod 700 /root/.ssh; [ -f $1 ] || ssh-keygen -q -t ed25519 -N '' -C '$2' -f $1"
}

llave_vale() {    # llave_vale RUTA usuario/repositorio → ¿GitHub acepta esa llave para ese repositorio?
  local out
  out=$(pct exec "$CT_ID" -- ssh -i "$1" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
        -o ConnectTimeout=15 -p 443 -T git@ssh.github.com 2>&1 || true)
  [[ "$out" == *"successfully authenticated"* && "${out,,}" == *"${2,,}"* ]]
}

ensenar_llave() {  # ensenar_llave RUTA usuario/repositorio "qué es"
  echo
  echo "${N}Llave del $3${X} → en GitHub: ${C}https://github.com/$2/settings/keys${X} → «Add deploy key»"
  echo "   Title: ${N}Templo $CT_HOSTNAME ($CT_ID)${X}    Key: la línea de abajo    ${R}NO${X} marques «Allow write access»"
  echo
  pct exec "$CT_ID" -- cat "$1.pub"
}

esperar_llaves() {  # esperar_llaves RUTA1 REPO1 [RUTA2 REPO2] → espera a que GitHub acepte todas
  local fin=$((SECONDS + ESPERA_LLAVES)) pend
  echo
  info "Esperando a que pegues las llaves en GitHub (lo compruebo solo cada 10 s; Ctrl+C para cancelar)…"
  while true; do
    pend=""
    llave_vale "$1" "$2" || pend="$2"
    if [ $# -ge 4 ]; then llave_vale "$3" "$4" || pend="$pend $4"; fi
    [ -z "$pend" ] && break
    [ $SECONDS -ge $fin ] && fallo "GitHub no acepta todavía la llave de:$pend. Revisa las Deploy keys y vuelve a lanzar el script."
    sleep 10
  done
  ok "GitHub acepta las llaves"
}

# ---------- Comprobaciones ----------
[ "$(id -u)" -eq 0 ] || fallo "Ejecuta este script como root en el host de Proxmox."
command -v pct >/dev/null && command -v pveam >/dev/null || fallo "Este script se ejecuta en el host de Proxmox VE (no se encuentra 'pct')."
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# ---------- Modo actualizar ----------
if [ "${1:-}" = "actualizar" ]; then
  CT_ID="${2:-}"
  [ -n "$CT_ID" ] || fallo "Indica el número del contenedor: … actualizar 130"
  pct status "$CT_ID" >/dev/null 2>&1 || fallo "No existe el contenedor $CT_ID."
  info "Actualizando el Templo en el contenedor $CT_ID"
  en_ct "if command -v luzdelnorte-actualizar >/dev/null; then luzdelnorte-actualizar; else bash /opt/luzdelnorte/deploy/luzdelnorte-actualizar; fi"
  ok "Hecho."
  exit 0
fi

# ---------- Modo tema ----------
if [ "${1:-}" = "tema" ]; then
  CT_ID="${2:-}"; TEMPLO_TEMA="${3:-${TEMPLO_TEMA:-}}"
  [ -n "$CT_ID" ] || fallo "Indica el número del contenedor: … tema 130"
  pct status "$CT_ID" >/dev/null 2>&1 || fallo "No existe el contenedor $CT_ID."
  en_ct "test -f /opt/luzdelnorte/.env" || fallo "En el contenedor $CT_ID no está instalado el Templo."
  CT_HOSTNAME=$(pct exec "$CT_ID" -- hostname)
  preguntar TEMPLO_TEMA "Repositorio del tema (p. ej. https://github.com/USUARIO/templo-tema-milogia)" ""
  [ -n "$TEMPLO_TEMA" ] || fallo "Hace falta el repositorio del tema."
  TEMA=$(repo_ssh "$TEMPLO_TEMA"); TEMA_NOMBRE=$(repo_nombre "$TEMA")
  # Una deploy key solo vale para un repositorio: si el tema cambia, llave nueva
  ANTES=$(pct exec "$CT_ID" -- bash -c "grep -E '^TEMA_REPO=' /etc/luzdelnorte/actualizar.conf 2>/dev/null | cut -d= -f2-" || true)
  if [ -n "$ANTES" ] && [ "$ANTES" != "$TEMA" ]; then
    en_ct "mv -f $LLAVE_TEMA $LLAVE_TEMA.anterior 2>/dev/null; mv -f $LLAVE_TEMA.pub $LLAVE_TEMA.anterior.pub 2>/dev/null; true"
    info "El tema anterior era $ANTES: su llave queda como $LLAVE_TEMA.anterior"
  fi
  crear_llave "$LLAVE_TEMA" "templo-$CT_HOSTNAME-tema-solo-lectura"
  en_ct "luzdelnorte-actualizar configurar-tema '$TEMA' >/dev/null"
  if ! llave_vale "$LLAVE_TEMA" "$TEMA_NOMBRE"; then
    ensenar_llave "$LLAVE_TEMA" "$TEMA_NOMBRE" "TEMA ($TEMA_NOMBRE)"
    esperar_llaves "$LLAVE_TEMA" "$TEMA_NOMBRE"
  fi
  info "Instalando el tema"
  en_ct "luzdelnorte-actualizar"
  if en_ct "grep -qE '^LOGIA_' /opt/luzdelnorte/.env"; then
    info "Ojo: el .env tiene líneas LOGIA_*, que mandan sobre los datos del tema. Si quieres los del tema, bórralas"
    info "(pct enter $CT_ID → nano /opt/luzdelnorte/.env) y reinicia con: systemctl restart luzdelnorte"
  fi
  ok "Tema instalado."
  exit 0
fi

echo
echo "${N}🏛  El Templo — nuevo contenedor LXC para Proxmox${X}"
echo "   Debian · Python · SQLite. Pulsa Enter para aceptar lo que va entre corchetes."
echo

# ---------- Valores ----------
SIG_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo 200)
ALMACENES=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}' || true)
ALMACEN_DEF=""
for a in local-lvm local-zfs; do
  if echo "$ALMACENES" | grep -qx "$a"; then ALMACEN_DEF=$a; break; fi
done
[ -n "$ALMACEN_DEF" ] || ALMACEN_DEF=$(echo "$ALMACENES" | head -n1)
ALMACEN_DEF=${ALMACEN_DEF:-local-lvm}
PLANTILLAS=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
PLANTILLAS=${PLANTILLAS:-local}

echo "${N}Contenedor${X}"
preguntar CT_ID       "Número del contenedor" "$SIG_ID"
preguntar CT_HOSTNAME "Nombre" "templo"
preguntar CT_ALMACEN  "Almacenamiento del disco" "$ALMACEN_DEF"
preguntar CT_DISCO    "Disco en GB (la biblioteca, las fotos y la música pueden ir luego en el NAS)" "16"
preguntar CT_CORES    "Núcleos" "2"
preguntar CT_RAM      "Memoria en MB" "2048"
preguntar CT_SWAP     "Swap en MB" "512"
echo "${N}Red${X}"
preguntar CT_PUENTE   "Puente de red" "vmbr0"
preguntar CT_IP       "IP: 'dhcp' o fija con máscara, p. ej. 192.168.1.30/24" "dhcp"
if [ "$CT_IP" != "dhcp" ]; then
  GW_DEF=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}' || true)
  preguntar CT_GW     "Puerta de enlace" "${GW_DEF:-192.168.1.1}"
fi
preguntar CT_DNS      "Servidor DNS (vacío = el del host)" ""
preguntar CT_VLAN     "VLAN (vacío = ninguna)" ""
echo "${N}Repositorios${X}"
preguntar TEMPLO_NUCLEO "Repositorio del núcleo" "$NUCLEO_DEF"
preguntar TEMPLO_TEMA   "Repositorio del tema de la logia (vacío = diseño por defecto)" ""
echo "${N}La web${X}"
preguntar TEMPLO_WEB        "Dirección pública con https:// (vacío si aún no hay)" ""
preguntar TEMPLO_WEB_PUBLICA "¿Web pública en el Templo? (s/n; n = «solo Templo», la logia ya tiene su web)" "s"
if [ "${TEMPLO_WEB_PUBLICA,,}" = "n" ]; then
  preguntar TEMPLO_WEB_EXTERNA "Dirección de la web propia de la logia (vacío = sin enlace)" ""
fi
if [ -z "$TEMPLO_TEMA" ]; then
  echo "${N}La logia${X} (se puede cambiar luego en el .env, líneas LOGIA_*)"
  preguntar LOGIA_NOMBRE     "Nombre (sin «R∴L∴»)" ""
  preguntar LOGIA_NUMERO     "Número" ""
  preguntar LOGIA_ORIENTE    "Oriente (ciudad)" ""
  preguntar LOGIA_OBEDIENCIA "Obediencia (vacío si no se quiere poner)" ""
  preguntar LOGIA_CARACTER   "Carácter, p. ej. «mixta, liberal y adogmática» (vacío si no)" ""
fi
echo "${N}Administración${X}"
preguntar TEMPLO_ADMIN        "Usuario de administración" "admin"
preguntar TEMPLO_ADMIN_NOMBRE "Nombre que se verá" "Administración"
preguntar_secreto TEMPLO_ADMIN_PASS "Su contraseña"
preguntar_secreto CT_CLAVE_ROOT     "Contraseña de root del contenedor"

CT_CLAVE_ROOT=${CT_CLAVE_ROOT:-$(inventar_clave)}
TEMPLO_ADMIN_PASS=${TEMPLO_ADMIN_PASS:-$(inventar_clave)}
CT_GW=${CT_GW:-}
CT_DEBIAN=${CT_DEBIAN:-13}
TEMPLO_WEB_EXTERNA=${TEMPLO_WEB_EXTERNA:-}
for v in LOGIA_NOMBRE LOGIA_NUMERO LOGIA_ORIENTE LOGIA_OBEDIENCIA LOGIA_CARACTER; do printf -v "$v" '%s' "${!v:-}"; done

[[ "$CT_ID" =~ ^[0-9]+$ ]] || fallo "El número del contenedor tiene que ser un número."
pct status "$CT_ID" >/dev/null 2>&1 && fallo "Ya existe un contenedor con el número $CT_ID."
NUCLEO=$(repo_ssh "$TEMPLO_NUCLEO"); NUCLEO_NOMBRE=$(repo_nombre "$NUCLEO")
TEMA=""; TEMA_NOMBRE=""
if [ -n "$TEMPLO_TEMA" ]; then TEMA=$(repo_ssh "$TEMPLO_TEMA"); TEMA_NOMBRE=$(repo_nombre "$TEMA"); fi

# ---------- Plantilla Debian ----------
info "Buscando la plantilla de Debian $CT_DEBIAN"
pveam update >/dev/null 2>&1 || info "No se ha podido actualizar la lista de plantillas; sigo con la que haya."
PLANTILLA=""
for d in "$CT_DEBIAN" 13 12; do
  PLANTILLA=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E "^debian-$d-standard_.*_amd64\.tar\.(zst|gz|xz)$" | sort -V | tail -n1 || true)
  [ -n "$PLANTILLA" ] || PLANTILLA=$(pveam list "$PLANTILLAS" 2>/dev/null | awk '{print $1}' | sed 's|.*/||' | grep -E "^debian-$d-standard" | sort -V | tail -n1 || true)
  [ -n "$PLANTILLA" ] && break
done
[ -n "$PLANTILLA" ] || fallo "No encuentro la plantilla debian-13-standard ni la 12. Descárgala en la web de Proxmox (local → Plantillas CT)."
if ! pveam list "$PLANTILLAS" 2>/dev/null | grep -q "$PLANTILLA"; then
  info "Descargando $PLANTILLA"
  pveam download "$PLANTILLAS" "$PLANTILLA" >/dev/null
fi
ok "Plantilla: $PLANTILLA"

# ---------- Crear el contenedor ----------
RED="name=eth0,bridge=$CT_PUENTE,ip=$CT_IP"
[ -n "$CT_GW" ] && RED="$RED,gw=$CT_GW"
[ -n "$CT_VLAN" ] && RED="$RED,tag=$CT_VLAN"
OPC=()
[ -n "$CT_DNS" ] && OPC+=(--nameserver "$CT_DNS")

info "Creando el contenedor $CT_ID ($CT_HOSTNAME)"
pct create "$CT_ID" "$PLANTILLAS:vztmpl/$PLANTILLA" \
  --hostname "$CT_HOSTNAME" --cores "$CT_CORES" --memory "$CT_RAM" --swap "$CT_SWAP" \
  --rootfs "$CT_ALMACEN:$CT_DISCO" --net0 "$RED" "${OPC[@]}" \
  --unprivileged 1 --features nesting=1 --onboot 1 --ostype debian \
  --password "$CT_CLAVE_ROOT" --tags templo \
  --description "El Templo — https://github.com/hombrelobo2/templo-instalador" >/dev/null
ok "Contenedor creado"

pct start "$CT_ID"
info "Esperando a que tenga red"
for _ in $(seq 1 60); do
  if pct exec "$CT_ID" -- getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  sleep 2
done
pct exec "$CT_ID" -- getent hosts deb.debian.org >/dev/null 2>&1 \
  || fallo "El contenedor no llega a internet. Revisa la IP, la puerta de enlace y el DNS (pct config $CT_ID)."
ok "Red lista"

ZONA=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "Europe/Madrid")
case "$ZONA" in ""|UTC|Etc/UTC) ZONA="Europe/Madrid" ;; esac   # un host en UTC no da la hora de la logia
preguntar T_ZONA_CT "Zona horaria" "$ZONA"; ZONA=$T_ZONA_CT

info "Preparando el sistema"
en_ct "apt-get update -qq && apt-get install -y -qq git openssh-client ca-certificates locales >/dev/null
  sed -i 's/^# *es_ES.UTF-8/es_ES.UTF-8/' /etc/locale.gen && locale-gen >/dev/null 2>&1 || true"
ok "Sistema listo"

# ---------- Llaves para GitHub ----------
crear_llave "$LLAVE_NUCLEO" "templo-$CT_HOSTNAME-solo-lectura"
[ -n "$TEMA" ] && crear_llave "$LLAVE_TEMA" "templo-$CT_HOSTNAME-tema-solo-lectura"
echo
if [ -n "$TEMA" ]; then
  echo "${N}Ahora, en GitHub${X}: el núcleo y el tema son privados y el contenedor necesita permiso para leerlos."
  echo "GitHub no deja usar la misma llave en dos repositorios: son dos llaves distintas, cada una en el suyo."
else
  echo "${N}Ahora, en GitHub${X}: el núcleo es privado y el contenedor necesita permiso para leerlo."
fi
ensenar_llave "$LLAVE_NUCLEO" "$NUCLEO_NOMBRE" "NÚCLEO ($NUCLEO_NOMBRE)"
if [ -n "$TEMA" ]; then
  ensenar_llave "$LLAVE_TEMA" "$TEMA_NOMBRE" "TEMA ($TEMA_NOMBRE)"
  esperar_llaves "$LLAVE_NUCLEO" "$NUCLEO_NOMBRE" "$LLAVE_TEMA" "$TEMA_NOMBRE"
else
  esperar_llaves "$LLAVE_NUCLEO" "$NUCLEO_NOMBRE"
fi

# ---------- Instalar el Templo ----------
info "Descargando el núcleo"
en_ct "GIT_SSH_COMMAND='ssh -i $LLAVE_NUCLEO -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o HostName=ssh.github.com -o Port=443' \
  git clone --quiet '$NUCLEO' $SRC"
ok "Núcleo descargado"

info "Instalando el Templo (tarda unos minutos)"
TMPENV=$(mktemp); chmod 600 "$TMPENV"
{
  printf 'export %s=%q\n' T_ZONA "$ZONA" T_WEB "$TEMPLO_WEB" T_WEB_PUBLICA "$TEMPLO_WEB_PUBLICA" \
    T_WEB_EXTERNA "$TEMPLO_WEB_EXTERNA" T_TEMA "$TEMA" \
    T_LOGIA_NOMBRE "$LOGIA_NOMBRE" T_LOGIA_NUMERO "$LOGIA_NUMERO" T_LOGIA_ORIENTE "$LOGIA_ORIENTE" \
    T_LOGIA_OBEDIENCIA "$LOGIA_OBEDIENCIA" T_LOGIA_CARACTER "$LOGIA_CARACTER" \
    T_ADMIN "$TEMPLO_ADMIN" T_ADMIN_NOMBRE "$TEMPLO_ADMIN_NOMBRE" T_ADMIN_PASS "$TEMPLO_ADMIN_PASS"
} > "$TMPENV"
pct push "$CT_ID" "$TMPENV" /root/.templo-instalar.env --perms 600
rm -f "$TMPENV"
# El instalador cambia el núcleo a la última versión publicada: se ejecuta una copia, no el archivo que cambia
en_ct "cp $SRC/deploy/instalar-desde-github.sh /root/.templo-instalar.sh || exit 1
  . /root/.templo-instalar.env; rm -f /root/.templo-instalar.env
  bash /root/.templo-instalar.sh </dev/null; r=\$?
  rm -f /root/.templo-instalar.sh; exit \$r" || fallo "La instalación dentro del contenedor ha fallado (mira los mensajes de arriba). El contenedor $CT_ID se queda para revisarlo: pct enter $CT_ID"
ok "Templo instalado"

IP=$(pct exec "$CT_ID" -- ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
IP=${IP:-IP-DEL-CONTENEDOR}
echo
echo "${N}🎉 Listo${X}"
echo "   El Templo:             http://$IP:8000/acceso"
echo "   Acceso de emergencia:  http://$IP:8001   (solo red local)"
echo "   Usuario:               $TEMPLO_ADMIN"
echo "   Contraseña:            $TEMPLO_ADMIN_PASS"
echo "   Root del LXC:          $CT_CLAVE_ROOT   (entra con: pct enter $CT_ID)"
echo
echo "   Apunta las contraseñas: no se vuelven a mostrar. Activa la doble verificación en «Mi perfil»."
echo "   Siguiente paso: publícalo con HTTPS (Nginx Proxy Manager → http://$IP:8000)${TEMPLO_WEB:+ como $TEMPLO_WEB}."
echo "   Lo demás (NAS, nube, correo, Telegram): https://github.com/hombrelobo2/templo-instalador#después-de-instalar"
