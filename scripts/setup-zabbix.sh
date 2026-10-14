#!/usr/bin/env bash
# Auto-réparation CRLF (copier-coller depuis Windows) : lancer avec "sudo bash <script>"
grep -q $'\r' "$0" 2>/dev/null && { sed -i 's/\r$//' "$0" && exec bash "$0" "$@"; } #
# =============================================================================
# setup-zabbix.sh : Zabbix (PostgreSQL + serveur + interface web) en Docker
#
# Architecture :
#   - reseau_zabbix (10.30.30.0/24, NAT Docker classique) : db + server + web
#   - zabbix-server est AUSSI rattaché à reseau_ubuntu avec l'IP 10.20.20.20
#       => ubuntu-cible (10.20.20.10) le joint directement, sans routage
#   - L'interface web est publiée uniquement sur la Debian :
#       http://127.0.0.1:8080  (non exposée au réseau extérieur)
#
# Prérequis : labo créé avec setup-lab.sh (reseau_ubuntu doit exister).
#
# Usage : sudo ./setup-zabbix.sh [--version 7.0] [--port 8080] [--remove]
#   --version : version Zabbix des images (défaut 7.0, LTS)
#   --port    : port local de l'interface web (défaut 8080)
#   --remove  : supprime Zabbix (conteneurs, volume de données, réseau, mot de passe)
# Idempotent : relançable sans risque (le mot de passe de la base est conservé).
# =============================================================================
set -euo pipefail

# ---------------------------- Paramètres -------------------------------------
ZBX_VERSION="7.0"
WEB_PORT="8080"
TZ_PHP="Europe/Paris"
PG_IMAGE="postgres:16-alpine"

NET_ZBX="reseau_zabbix"; BR_ZBX="br-zabbix"; SUBNET_ZBX="10.30.30.0/24"; GW_ZBX="10.30.30.1"
NET_UBUNTU="reseau_ubuntu"; IP_ZBX_UBUNTU="10.20.20.20"
CT_UBUNTU="ubuntu-cible"

CT_DB="zabbix-db"; CT_SRV="zabbix-server"; CT_WEB="zabbix-web"
VOL_DB="zabbix-db-data"
DB_NAME="zabbix"; DB_USER="zabbix"

WORKDIR="/opt/zabbix-lab"
ENV_FILE="$WORKDIR/.env"

# ---------------------------- Utilitaires ------------------------------------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

REMOVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) shift; ZBX_VERSION="${1:-}"; [ -n "$ZBX_VERSION" ] || die "--version : valeur manquante" ;;
    --port)    shift; WEB_PORT="${1:-}"; [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || die "--port : nombre attendu" ;;
    --remove)  REMOVE=1 ;;
    -h|--help) sed -n '4,21p' "$0"; exit 0 ;;
    *) die "Option inconnue : $1" ;;
  esac
  shift
done

ZBX_TAG="alpine-${ZBX_VERSION}-latest"
IMG_SRV="zabbix/zabbix-server-pgsql:${ZBX_TAG}"
IMG_WEB="zabbix/zabbix-web-nginx-pgsql:${ZBX_TAG}"

[ "$(id -u)" -eq 0 ] || die "Lancez ce script avec sudo / en root."
command -v docker >/dev/null || die "Docker n'est pas installé."
docker info >/dev/null 2>&1   || die "Le démon Docker ne répond pas."

# ---------------------------- Désinstallation --------------------------------
if [ "$REMOVE" -eq 1 ]; then
  log "Suppression de Zabbix"
  docker rm -f "$CT_WEB" "$CT_SRV" "$CT_DB" >/dev/null 2>&1 || true
  docker volume rm "$VOL_DB" >/dev/null 2>&1 || true
  docker network rm "$NET_ZBX" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
  ok "Zabbix supprimé (conteneurs, volume, réseau, fichier de mot de passe)."
  exit 0
fi

# ---------------------------- 1. Prérequis -----------------------------------
log "Vérification des prérequis"
docker network inspect "$NET_UBUNTU" >/dev/null 2>&1 \
  || die "Le réseau $NET_UBUNTU n'existe pas : lancez d'abord setup-lab.sh."

# Le port web doit être libre (sauf s'il est déjà utilisé par notre conteneur)
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${WEB_PORT}$"; then
  if ! docker port "$CT_WEB" 2>/dev/null | grep -q ":${WEB_PORT}$"; then
    die "Le port $WEB_PORT est déjà utilisé sur la Debian. Relancez avec --port <autre port>."
  fi
fi

# L'IP 10.20.20.20 ne doit pas être prise par un autre conteneur
used_by="$(docker network inspect -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}' "$NET_UBUNTU" \
           | awk -v ip="$IP_ZBX_UBUNTU/" 'index($2, ip)==1 {print $1}')"
if [ -n "$used_by" ] && [ "$used_by" != "$CT_SRV" ]; then
  die "L'IP $IP_ZBX_UBUNTU est déjà utilisée par '$used_by' sur $NET_UBUNTU."
fi
ok "Prérequis OK"

# ---------------------------- 2. Mot de passe de la base ---------------------
mkdir -p "$WORKDIR"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  ok "Mot de passe de la base réutilisé ($ENV_FILE)"
else
  DB_PASSWORD="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  umask 077
  printf 'DB_PASSWORD=%s\n' "$DB_PASSWORD" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Mot de passe de la base généré ($ENV_FILE)"
fi

# ---------------------------- 3. Images --------------------------------------
log "Téléchargement des images (peut prendre quelques minutes)"
for img in "$PG_IMAGE" "$IMG_SRV" "$IMG_WEB"; do
  docker pull -q "$img" >/dev/null || die "Impossible de télécharger $img (Internet ? version valide ?)"
done
ok "Images prêtes"

# ---------------------------- 4. Réseau Zabbix -------------------------------
if docker network inspect "$NET_ZBX" >/dev/null 2>&1; then
  ok "Réseau $NET_ZBX déjà présent"
else
  docker network create --driver bridge \
    --subnet "$SUBNET_ZBX" --gateway "$GW_ZBX" \
    -o "com.docker.network.bridge.name=$BR_ZBX" \
    "$NET_ZBX" >/dev/null
  ok "Réseau $NET_ZBX créé ($BR_ZBX, $SUBNET_ZBX)"
fi

# ---------------------------- 5. Conteneurs ----------------------------------
exists()  { docker inspect "$1" >/dev/null 2>&1; }
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

# --- Base de données
docker volume create "$VOL_DB" >/dev/null
if exists "$CT_DB"; then
  running "$CT_DB" || docker start "$CT_DB" >/dev/null
  ok "$CT_DB déjà présent"
else
  docker run -d --name "$CT_DB" --hostname "$CT_DB" \
    --restart unless-stopped --network "$NET_ZBX" \
    -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB="$DB_NAME" \
    -v "$VOL_DB":/var/lib/postgresql/data \
    "$PG_IMAGE" >/dev/null
  ok "$CT_DB créé"
fi

log "Attente de PostgreSQL"
for _ in $(seq 1 60); do
  docker exec "$CT_DB" pg_isready -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1 && break
  sleep 2
done
docker exec "$CT_DB" pg_isready -h 127.0.0.1 -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1 \
  || die "PostgreSQL ne répond pas (docker logs $CT_DB)."
ok "PostgreSQL prêt"

# --- Serveur Zabbix (2 réseaux : reseau_zabbix + reseau_ubuntu)
if ! exists "$CT_SRV"; then
  docker create --name "$CT_SRV" --hostname "$CT_SRV" \
    --restart unless-stopped --network "$NET_ZBX" \
    -e DB_SERVER_HOST="$CT_DB" \
    -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB="$DB_NAME" \
    "$IMG_SRV" >/dev/null
  ok "$CT_SRV créé"
fi
if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "$CT_SRV" | grep -q "\"$NET_UBUNTU\""; then
  docker network connect --ip "$IP_ZBX_UBUNTU" "$NET_UBUNTU" "$CT_SRV"
  ok "$CT_SRV rattaché à $NET_UBUNTU ($IP_ZBX_UBUNTU)"
fi
running "$CT_SRV" || docker start "$CT_SRV" >/dev/null

# --- Interface web (publiée uniquement sur 127.0.0.1 de la Debian)
if exists "$CT_WEB"; then
  running "$CT_WEB" || docker start "$CT_WEB" >/dev/null
  ok "$CT_WEB déjà présent"
else
  docker run -d --name "$CT_WEB" --hostname "$CT_WEB" \
    --restart unless-stopped --network "$NET_ZBX" \
    -p "127.0.0.1:${WEB_PORT}:8080" \
    -e ZBX_SERVER_HOST="$CT_SRV" -e ZBX_SERVER_NAME="Lab-Zabbix" \
    -e DB_SERVER_HOST="$CT_DB" \
    -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB="$DB_NAME" \
    -e PHP_TZ="$TZ_PHP" \
    "$IMG_WEB" >/dev/null
  ok "$CT_WEB créé"
fi

# ---------------------------- 6. Vérifications -------------------------------
log "Vérifications (le premier démarrage importe le schéma : 1 à 3 minutes)"
FAIL=0

# Interface web
if command -v curl >/dev/null; then
  code="000"
  for _ in $(seq 1 90); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB_PORT}/" || true)"
    [[ "$code" =~ ^(200|301|302)$ ]] && break
    sleep 2
  done
  if [[ "$code" =~ ^(200|301|302)$ ]]; then ok "Interface web : http://127.0.0.1:${WEB_PORT} (HTTP $code)"
  else warn "ÉCHEC : interface web (HTTP $code). Voir : docker logs $CT_WEB"; FAIL=1; fi
else
  warn "curl absent sur la Debian : test de l'interface web ignoré."
fi

# Joignabilité du serveur depuis Ubuntu (port 10051)
if exists "$CT_UBUNTU" && running "$CT_UBUNTU"; then
  reach=0
  for _ in $(seq 1 60); do
    if docker exec "$CT_UBUNTU" bash -c "timeout 3 bash -c 'echo > /dev/tcp/${IP_ZBX_UBUNTU}/10051'" >/dev/null 2>&1; then
      reach=1; break
    fi
    sleep 2
  done
  if [ "$reach" -eq 1 ]; then ok "$CT_UBUNTU joint le serveur Zabbix sur ${IP_ZBX_UBUNTU}:10051"
  else warn "ÉCHEC : $CT_UBUNTU ne joint pas ${IP_ZBX_UBUNTU}:10051 (docker logs $CT_SRV)"; FAIL=1; fi
else
  warn "Conteneur $CT_UBUNTU absent ou arrêté : test de joignabilité ignoré."
fi

echo
if [ "$FAIL" -eq 0 ]; then
  ok "Zabbix opérationnel."
else
  warn "Des vérifications ont échoué (voir ci-dessus)."
fi

cat <<EOF

Interface web (navigateur de la Debian) :
  http://127.0.0.1:${WEB_PORT}
  Identifiants par défaut : Admin / zabbix   (à changer dès la première connexion)

Configuration de l'agent Zabbix sur ${CT_UBUNTU} (plus tard) :
  Server=${IP_ZBX_UBUNTU}
  ServerActive=${IP_ZBX_UBUNTU}
  Hostname=${CT_UBUNTU}
  Dans l'interface : Collecte de données > Hôtes > Créer un hôte, interface agent = 10.20.20.10:10050

Mot de passe PostgreSQL : $ENV_FILE
Suppression complète    : sudo $0 --remove
EOF

[ "$FAIL" -eq 0 ] || exit 1
