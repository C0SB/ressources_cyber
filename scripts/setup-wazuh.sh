#!/usr/bin/env bash
# Auto-réparation CRLF (copier-coller depuis Windows) : lancer avec "sudo bash <script>"
grep -q $'\r' "$0" 2>/dev/null && { sed -i 's/\r$//' "$0" && exec bash "$0" "$@"; } #
# =============================================================================
# setup-wazuh.sh : Wazuh (manager + indexer + dashboard) en Docker, avec
#                  collecte des logs Suricata et des alertes Zabbix.
#
# Architecture :
#   - Stack officielle wazuh-docker (single-node) sur son propre réseau Docker
#   - wazuh.manager est AUSSI rattaché à reseau_ubuntu avec l'IP 10.20.20.30
#       => les agents Wazuh d'ubuntu-cible (10.20.20.10) le joignent directement
#          (ports 1514 = événements, 1515 = enregistrement)
#   - Dashboard publié uniquement sur la Debian : https://127.0.0.1:8443
#   - Suricata : le manager lit /var/log/suricata/eve.json (dossier de la Debian
#     monté en lecture seule). Les règles Suricata sont déjà incluses dans Wazuh.
#   - Zabbix   : un script d'alerte Zabbix écrit chaque alerte en JSON dans
#     /var/log/zabbix-wazuh/alerts.json, lu par le manager (règles 100200+).
#
# Prérequis : setup-lab.sh exécuté (reseau_ubuntu) ; Zabbix recommandé
#             (setup-zabbix.sh) ; ~4 Go de RAM disponibles.
#
# Usage : sudo bash setup-wazuh.sh [--version 4.14.5] [--port 8443] [--remove]
#   --version : version Wazuh (tag du dépôt wazuh-docker), défaut 4.14.5
#   --port    : port local du dashboard (défaut 8443)
#   --remove  : supprime Wazuh (conteneurs, volumes, certificats, dépôt cloné)
# Idempotent : relançable sans risque.
# =============================================================================
set -euo pipefail
umask 022

# ---------------------------- Paramètres -------------------------------------
WAZUH_VERSION="4.14.5"
DASH_PORT="8443"
PROJECT="wazuh-lab"

NET_UBUNTU="reseau_ubuntu"; IP_WAZUH_UBUNTU="10.20.20.30"
CT_UBUNTU="ubuntu-cible"

# Zabbix (valeurs de setup-zabbix.sh)
CT_ZBX="zabbix-server"; CT_ZBX_DB="zabbix-db"; NET_ZBX="reseau_zabbix"; IP_ZBX_UBUNTU="10.20.20.20"
ZBX_DIR="/opt/zabbix-lab"
ZBX_ALERT_DIR="$ZBX_DIR/alertscripts"
ZBX_LOG_DIR="/var/log/zabbix-wazuh"
ZBX_ALERT_FILE="$ZBX_LOG_DIR/alerts.json"

SURICATA_DIR="/var/log/suricata"

WORKDIR="/opt/wazuh-lab"
REPO_DIR="$WORKDIR/wazuh-docker"
SN_DIR="$REPO_DIR/single-node"
OVERRIDE="$SN_DIR/docker-compose.lab.yml"
RULES_FILE="$WORKDIR/lab_rules.xml"
SYSCTL_FILE="/etc/sysctl.d/99-wazuh.conf"

# ---------------------------- Utilitaires ------------------------------------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

REMOVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) shift; WAZUH_VERSION="${1:-}"; [ -n "$WAZUH_VERSION" ] || die "--version : valeur manquante" ;;
    --port)    shift; DASH_PORT="${1:-}"; [[ "$DASH_PORT" =~ ^[0-9]+$ ]] || die "--port : nombre attendu" ;;
    --remove)  REMOVE=1 ;;
    -h|--help) awk 'NR>=4{print} NR>4 && /^# =+$/{exit}' "$0"; exit 0 ;;
    *) die "Option inconnue : $1" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "Lancez ce script avec sudo / en root."
command -v docker >/dev/null || die "Docker n'est pas installé."
docker info >/dev/null 2>&1   || die "Le démon Docker ne répond pas."

# Commande docker compose pour le projet Wazuh (stack officielle + surcharge du labo)
dc() { docker compose -p "$PROJECT" --project-directory "$SN_DIR" \
         -f "$SN_DIR/docker-compose.yml" -f "$OVERRIDE" "$@"; }

wait_for() {  # wait_for <timeout_s> <fonction/commande...>
  local t="$1" i=0; shift
  while [ "$i" -lt "$t" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 3; i=$((i + 3))
  done
  return 1
}

# ---------------------------- Désinstallation --------------------------------
if [ "$REMOVE" -eq 1 ]; then
  log "Suppression de Wazuh"
  docker compose -p "$PROJECT" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
  rm -f "$SYSCTL_FILE"
  ok "Wazuh supprimé (conteneurs, volumes, certificats, dépôt)."
  ok "Conservés : $SURICATA_DIR, $ZBX_LOG_DIR et le script d'alerte Zabbix."
  exit 0
fi

# ---------------------------- 1. Prérequis -----------------------------------
log "Vérification des prérequis"

docker network inspect "$NET_UBUNTU" >/dev/null 2>&1 \
  || die "Le réseau $NET_UBUNTU n'existe pas : lancez d'abord setup-lab.sh."

CV="$(docker compose version --short 2>/dev/null | sed 's/^v//' || true)"
[ -n "$CV" ] || die "Plugin 'docker compose' absent (apt install docker-compose-plugin)."
[ "$(printf '%s\n2.24.4\n' "$CV" | sort -V | head -n1)" = "2.24.4" ] \
  || die "docker compose $CV trop ancien (>= 2.24.4 requis pour la surcharge). Mettez à jour docker-compose-plugin."
ok "docker compose $CV"

if ! command -v git >/dev/null; then
  log "Installation de git"
  apt-get update -qq && apt-get install -y -qq git >/dev/null
fi
command -v curl >/dev/null || { apt-get update -qq && apt-get install -y -qq curl >/dev/null; }

mem_mb="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)"
if [ "$mem_mb" -lt 3500 ]; then
  warn "Seulement ${mem_mb} Mo de RAM disponibles : Wazuh (indexer ~1 Go de heap) risque d'être instable."
  warn "Arrêtez des conteneurs inutiles ou augmentez la RAM de la VM."
else
  ok "RAM disponible : ${mem_mb} Mo"
fi

# IP 10.20.20.30 libre ?
used_by="$(docker network inspect -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}' "$NET_UBUNTU" \
           | awk -v ip="$IP_WAZUH_UBUNTU/" 'index($2, ip)==1 {print $1}')"
if [ -n "$used_by" ] && [[ "$used_by" != "${PROJECT}-wazuh.manager-"* ]]; then
  die "L'IP $IP_WAZUH_UBUNTU est déjà utilisée par '$used_by' sur $NET_UBUNTU."
fi

# Port du dashboard libre ? (sauf si c'est déjà notre stack)
if ! docker ps -q --filter "label=com.docker.compose.project=$PROJECT" | grep . >/dev/null; then
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -E "[:.]${DASH_PORT}$" >/dev/null; then
    die "Le port $DASH_PORT est déjà utilisé sur la Debian. Relancez avec --port <autre port>."
  fi
fi
ok "Prérequis OK"

# ---------------------------- 2. Paramètre noyau (indexer) -------------------
log "vm.max_map_count=262144 (requis par l'indexer, persistant)"
echo "vm.max_map_count=262144" > "$SYSCTL_FILE"
sysctl -q -w vm.max_map_count=262144
ok "vm.max_map_count configuré"

# ---------------------------- 3. Intégration Zabbix (côté fichiers) ----------
log "Préparation de l'intégration Zabbix -> Wazuh"
mkdir -p "$ZBX_ALERT_DIR" "$ZBX_LOG_DIR" "$SURICATA_DIR"
chmod 755 "$ZBX_DIR" "$ZBX_ALERT_DIR"
chmod 777 "$ZBX_LOG_DIR"                      # écrit par l'utilisateur 'zabbix' du conteneur
touch "$ZBX_ALERT_FILE"; chmod 666 "$ZBX_ALERT_FILE"

cat > "$ZBX_ALERT_DIR/wazuh-alert.sh" <<'ZBX_SCRIPT_EOF'
#!/bin/sh
# Script d'alerte Zabbix : écrit l'alerte en JSON (1 ligne) pour Wazuh.
# Paramètres du type de média : 1={ALERT.SUBJECT} 2={ALERT.MESSAGE} 3={EVENT.SEVERITY}
OUT="${WAZUH_ALERT_FILE:-/var/log/zabbix-wazuh/alerts.json}"

esc() {  # échappe pour JSON, aplatit retours à la ligne et tabulations
  printf '%s' "$1" | tr '\r\n\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

SUBJECT="$(esc "${1:-}")"
MESSAGE="$(esc "${2:-}")"
SEVERITY="$(esc "${3:-Not classified}")"

case "${1:-}" in
  Resolved*|OK*) STATUS="RESOLVED" ;;
  *)             STATUS="PROBLEM" ;;
esac

printf '{"integration":"zabbix","status":"%s","severity":"%s","subject":"%s","message":"%s"}\n' \
  "$STATUS" "$SEVERITY" "$SUBJECT" "$MESSAGE" >> "$OUT"
ZBX_SCRIPT_EOF
chmod 755 "$ZBX_ALERT_DIR/wazuh-alert.sh"
ok "Script d'alerte : $ZBX_ALERT_DIR/wazuh-alert.sh"

# Le serveur Zabbix doit voir ces deux dossiers : on le recrée si nécessaire
ZBX_RECREATED=0
if docker inspect "$CT_ZBX" >/dev/null 2>&1; then
  if docker inspect -f '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' "$CT_ZBX" | grep -x "$ZBX_LOG_DIR" >/dev/null; then
    ok "$CT_ZBX voit déjà les dossiers d'intégration"
  else
    log "Recréation de $CT_ZBX avec les dossiers d'intégration (données conservées dans la base)"
    [ -f "$ZBX_DIR/.env" ] || die "$ZBX_DIR/.env introuvable : impossible de recréer $CT_ZBX."
    # shellcheck disable=SC1091
    . "$ZBX_DIR/.env"
    zbx_img="$(docker inspect -f '{{.Config.Image}}' "$CT_ZBX")"
    docker rm -f "$CT_ZBX" >/dev/null
    docker create --name "$CT_ZBX" --hostname "$CT_ZBX" \
      --restart unless-stopped --network "$NET_ZBX" \
      -e DB_SERVER_HOST="$CT_ZBX_DB" \
      -e POSTGRES_USER=zabbix -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=zabbix \
      -v "$ZBX_ALERT_DIR":/usr/lib/zabbix/alertscripts:ro \
      -v "$ZBX_LOG_DIR":"$ZBX_LOG_DIR" \
      "$zbx_img" >/dev/null
    docker network connect --ip "$IP_ZBX_UBUNTU" "$NET_UBUNTU" "$CT_ZBX"
    docker start "$CT_ZBX" >/dev/null
    ZBX_RECREATED=1
    ok "$CT_ZBX recréé (réseaux $NET_ZBX + $NET_UBUNTU, IP $IP_ZBX_UBUNTU)"
  fi
else
  warn "Conteneur $CT_ZBX absent : installez Zabbix (setup-zabbix.sh) puis relancez ce script."
fi

# ---------------------------- 4. Dépôt wazuh-docker + configuration ----------
log "Dépôt officiel wazuh-docker v$WAZUH_VERSION"
mkdir -p "$WORKDIR"
if [ -d "$SN_DIR" ]; then
  ok "Dépôt déjà présent ($REPO_DIR)"
else
  git clone -q --depth 1 -b "v$WAZUH_VERSION" https://github.com/wazuh/wazuh-docker.git "$REPO_DIR" \
    || die "Clonage impossible (Internet ? tag v$WAZUH_VERSION inexistant ? essayez --version)."
  ok "Dépôt cloné"
fi
[ -f "$SN_DIR/docker-compose.yml" ] || die "$SN_DIR/docker-compose.yml introuvable (structure du dépôt différente ?)."

MANAGER_CONF="$SN_DIR/config/wazuh_cluster/wazuh_manager.conf"
[ -f "$MANAGER_CONF" ] || die "$MANAGER_CONF introuvable : cette version a une structure différente."

# Sources de logs lues par le manager
if grep -q 'LAB-INTEGRATIONS' "$MANAGER_CONF"; then
  ok "Sources de logs Suricata/Zabbix déjà déclarées"
else
  printf '\n' >> "$MANAGER_CONF"
  cat >> "$MANAGER_CONF" <<LOGCOLL_EOF
<ossec_config>
  <!-- LAB-INTEGRATIONS (setup-wazuh.sh) -->
  <localfile>
    <log_format>json</log_format>
    <location>${SURICATA_DIR}/eve.json</location>
  </localfile>
  <localfile>
    <log_format>json</log_format>
    <location>${ZBX_ALERT_FILE}</location>
  </localfile>
</ossec_config>
LOGCOLL_EOF
  ok "Sources de logs ajoutées (eve.json Suricata, alertes Zabbix)"
fi

# Surcharge de la stack officielle : réseau du labo, ports restreints, dossiers de logs
cat > "$OVERRIDE" <<OVERRIDE_EOF
# Généré par setup-wazuh.sh : adaptations pour le labo
services:
  wazuh.manager:
    ports: !reset []
    networks:
      default: {}
      lab_ubuntu:
        ipv4_address: ${IP_WAZUH_UBUNTU}
    volumes:
      - ${SURICATA_DIR}:${SURICATA_DIR}:ro
      - ${ZBX_LOG_DIR}:${ZBX_LOG_DIR}:ro
  wazuh.indexer:
    ports: !reset []
  wazuh.dashboard:
    ports: !override
      - "127.0.0.1:${DASH_PORT}:5601"
networks:
  lab_ubuntu:
    external: true
    name: ${NET_UBUNTU}
OVERRIDE_EOF

dc config --services >/dev/null 2>&1 \
  || { dc config 2>&1 | tail -n 15; die "Configuration compose invalide (voir ci-dessus)."; }
ok "Configuration compose valide"

# Règles Wazuh pour les alertes Zabbix (installées après le premier démarrage)
cat > "$RULES_FILE" <<'RULES_EOF'
<group name="lab,zabbix,">

  <rule id="100200" level="3">
    <decoded_as>json</decoded_as>
    <field name="integration">^zabbix$</field>
    <description>Zabbix : $(subject)</description>
  </rule>

  <rule id="100201" level="3">
    <if_sid>100200</if_sid>
    <field name="status">^RESOLVED$</field>
    <description>Zabbix : probleme resolu - $(subject)</description>
  </rule>

  <rule id="100202" level="6">
    <if_sid>100200</if_sid>
    <field name="status">^PROBLEM$</field>
    <description>Zabbix : probleme - $(subject)</description>
  </rule>

  <rule id="100203" level="8">
    <if_sid>100202</if_sid>
    <field name="severity">^Average$</field>
    <description>Zabbix : probleme (Average) - $(subject)</description>
  </rule>

  <rule id="100204" level="10">
    <if_sid>100202</if_sid>
    <field name="severity">^High$</field>
    <description>Zabbix : probleme (High) - $(subject)</description>
  </rule>

  <rule id="100205" level="12">
    <if_sid>100202</if_sid>
    <field name="severity">^Disaster$</field>
    <description>Zabbix : probleme (Disaster) - $(subject)</description>
  </rule>

</group>
RULES_EOF

# Certificats (générés une seule fois)
if [ -f "$SN_DIR/config/wazuh_indexer_ssl_certs/wazuh.manager.pem" ]; then
  ok "Certificats déjà générés"
else
  log "Génération des certificats"
  ( cd "$SN_DIR" && docker compose -f generate-indexer-certs.yml run --rm generator >/dev/null ) \
    || die "Échec de la génération des certificats."
  ok "Certificats générés"
fi

# ---------------------------- 5. Démarrage -----------------------------------
log "Téléchargement des images Wazuh (plusieurs Go, peut être long)"
dc pull -q || die "Échec du téléchargement des images."
ok "Images prêtes"

log "Démarrage de la stack"
dc up -d
ok "Conteneurs lancés"

# ---------------------------- 6. Règles Zabbix dans le manager ---------------
log "Attente du manager Wazuh"
manager_ready() { dc exec -T wazuh.manager /var/ossec/bin/wazuh-control status 2>/dev/null | grep 'wazuh-analysisd is running' >/dev/null; }
wait_for 300 manager_ready || die "Le manager ne démarre pas (voir : cd $SN_DIR && docker compose -p $PROJECT logs wazuh.manager)."
ok "Manager démarré"

RULES_CHANGED=0
if dc exec -T wazuh.manager cat /var/ossec/etc/rules/lab_rules.xml 2>/dev/null | cmp -s - "$RULES_FILE"; then
  ok "Règles Zabbix déjà installées"
else
  dc exec -T wazuh.manager sh -c \
    'cat > /var/ossec/etc/rules/lab_rules.xml && chown wazuh:wazuh /var/ossec/etc/rules/lab_rules.xml && chmod 660 /var/ossec/etc/rules/lab_rules.xml' \
    < "$RULES_FILE"
  if dc exec -T wazuh.manager /var/ossec/bin/wazuh-analysisd -t >/dev/null 2>&1; then
    RULES_CHANGED=1
    ok "Règles Zabbix installées (100200-100205)"
  else
    dc exec -T wazuh.manager rm -f /var/ossec/etc/rules/lab_rules.xml
    warn "Les règles Zabbix ont été rejetées par Wazuh (retirées). Le reste fonctionne."
  fi
fi

if [ "$RULES_CHANGED" -eq 1 ]; then
  log "Redémarrage du manager pour charger les règles"
  dc restart wazuh.manager >/dev/null
  wait_for 300 manager_ready || die "Le manager ne redémarre pas."
  ok "Manager redémarré"
fi

# ---------------------------- 7. Vérifications -------------------------------
log "Vérifications"
FAIL=0

# Ubuntu -> manager (1514 événements, 1515 enregistrement)
tcp_from_ubuntu() { docker exec "$CT_UBUNTU" bash -c "timeout 3 bash -c 'echo > /dev/tcp/${IP_WAZUH_UBUNTU}/$1'"; }
if docker inspect -f '{{.State.Running}}' "$CT_UBUNTU" 2>/dev/null | grep true >/dev/null; then
  for p in 1514 1515; do
    if wait_for 90 tcp_from_ubuntu "$p"; then ok "$CT_UBUNTU joint le manager sur ${IP_WAZUH_UBUNTU}:$p"
    else warn "ÉCHEC : $CT_UBUNTU ne joint pas ${IP_WAZUH_UBUNTU}:$p"; FAIL=1; fi
  done
else
  warn "Conteneur $CT_UBUNTU arrêté ou absent : test de joignabilité ignoré."
fi

# Chaîne Zabbix -> fichier -> Wazuh (test de bout en bout)
zbx_alert_seen() { dc exec -T wazuh.manager grep -q 'TEST setup-wazuh' /var/ossec/logs/alerts/alerts.json; }
if docker inspect -f '{{.State.Running}}' "$CT_ZBX" 2>/dev/null | grep true >/dev/null; then
  if docker exec "$CT_ZBX" /usr/lib/zabbix/alertscripts/wazuh-alert.sh \
       "Problem: TEST setup-wazuh" "Evenement de test genere par setup-wazuh.sh" "High"; then
    if wait_for 60 zbx_alert_seen; then ok "Alerte Zabbix de test reçue et classée par Wazuh"
    else warn "ÉCHEC : l'alerte de test Zabbix n'apparaît pas dans les alertes Wazuh"; FAIL=1; fi
  else
    warn "ÉCHEC : exécution du script d'alerte dans $CT_ZBX"; FAIL=1
  fi
fi

# Suricata
if [ -f "$SURICATA_DIR/eve.json" ]; then ok "Suricata : $SURICATA_DIR/eve.json présent"
else warn "Suricata pas encore installé/actif ($SURICATA_DIR/eve.json absent) : normal pour l'instant."; fi

# Dashboard (peut être long : l'indexer doit finir son initialisation)
dash_up() {
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:${DASH_PORT}/" || true)"
  [[ "$code" =~ ^(200|301|302)$ ]]
}
log "Attente du dashboard (jusqu'à ~5 min)"
if wait_for 300 dash_up; then ok "Dashboard : https://127.0.0.1:${DASH_PORT}"
else warn "Dashboard pas encore prêt : patientez 1-2 min puis ouvrez https://127.0.0.1:${DASH_PORT} (docker compose -p $PROJECT logs wazuh.dashboard)"; fi

echo
if [ "$FAIL" -eq 0 ]; then ok "Wazuh opérationnel."; else warn "Certaines vérifications ont échoué (voir ci-dessus)."; fi

cat <<SUMMARY_EOF

Dashboard (navigateur de la Debian, certificat auto-signé à accepter) :
  https://127.0.0.1:${DASH_PORT}
  Identifiants par défaut de la stack : admin / SecretPassword
  (valables pour un labo isolé ; non joignable depuis l'extérieur de la Debian)

Agents Wazuh (ex. ubuntu-cible) : Manager = ${IP_WAZUH_UBUNTU}
  Ports : 1514 (événements), 1515 (enregistrement)

Suricata -> Wazuh : automatique. Le manager lit ${SURICATA_DIR}/eve.json
  (activez eve-log dans Suricata ; les règles Suricata sont incluses dans Wazuh).

Zabbix -> Wazuh : dernière étape manuelle dans l'interface Zabbix (http://127.0.0.1:8080) :
  1. Alertes > Types de média > Créer : Nom "Wazuh", Type "Script",
     Nom du script "wazuh-alert.sh", paramètres dans cet ordre :
         {ALERT.SUBJECT}   {ALERT.MESSAGE}   {EVENT.SEVERITY}
  2. Utilisateurs > Admin > onglet Média > Ajouter : type "Wazuh", Envoyer à "wazuh".
  3. Alertes > Actions > Actions de déclencheur : activez (ou créez) une action dont
     l'opération envoie le message à l'utilisateur Admin via le média "Wazuh".
  Les alertes arrivent dans Wazuh avec les règles 100200-100205 (groupe "zabbix").

Suppression complète : sudo bash $0 --remove
SUMMARY_EOF

[ "$FAIL" -eq 0 ] || exit 1
