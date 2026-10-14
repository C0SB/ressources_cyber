#!/usr/bin/env bash
# =============================================================================
# setup-lab.sh : labo Docker Kali <-> Debian (routeur) <-> Ubuntu
#
#   Kali 10.10.10.10 -- br-kali (10.10.10.1) -- [Debian] -- br-ubuntu (10.20.20.1) -- Ubuntu 10.20.20.10
#
# - Idempotent : peut être relancé sans risque.
# - Conserve les conteneurs existants (ils sont détachés/rattachés, jamais supprimés).
# - Pas de NAT entre les deux réseaux : les vraies IP sont visibles (Suricata).
# - NAT (MASQUERADE) uniquement vers Internet.
# - Règles persistantes via un service systemd.
#
# Usage : sudo ./setup-lab.sh [--no-packages] [--mode routed|trusted]
#   --no-packages : n'installe pas les outils réseau dans les conteneurs
#   --mode        : force la méthode de contournement de la protection Docker 28+
#                   (par défaut : "routed", bascule auto sur "trusted" si nécessaire)
# =============================================================================
set -euo pipefail

# ---------------------------- Paramètres -------------------------------------
NET_KALI="reseau_kali";     BR_KALI="br-kali";     SUBNET_KALI="10.10.10.0/24"; GW_KALI="10.10.10.1"; IP_KALI="10.10.10.10"
NET_UBUNTU="reseau_ubuntu"; BR_UBUNTU="br-ubuntu"; SUBNET_UBUNTU="10.20.20.0/24"; GW_UBUNTU="10.20.20.1"; IP_UBUNTU="10.20.20.10"
CT_KALI="kali";             IMG_KALI="kalilinux/kali-rolling"
CT_UBUNTU="ubuntu-cible";   IMG_UBUNTU="ubuntu:24.04"

RULES_SCRIPT="/usr/local/sbin/lab-net-rules.sh"
SERVICE_FILE="/etc/systemd/system/lab-network.service"
SYSCTL_FILE="/etc/sysctl.d/99-lab.conf"

MODE="routed"; FORCE_MODE=0; INSTALL_PACKAGES=1

# ---------------------------- Utilitaires ------------------------------------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-packages) INSTALL_PACKAGES=0 ;;
    --mode) shift; MODE="${1:-}"; FORCE_MODE=1
            [[ "$MODE" == "routed" || "$MODE" == "trusted" ]] || die "--mode : routed ou trusted" ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "Option inconnue : $1" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "Lancez ce script avec sudo / en root."

# ---------------------------- 1. Prérequis -----------------------------------
log "Vérification des prérequis"
command -v docker   >/dev/null || die "Docker n'est pas installé."
command -v iptables >/dev/null || die "iptables n'est pas installé (apt install iptables)."
docker info >/dev/null 2>&1   || die "Le démon Docker ne répond pas."
DOCKER_VER="$(docker version --format '{{.Server.Version}}')"
ok "Docker $DOCKER_VER"

iptables -nL DOCKER-USER >/dev/null 2>&1 \
  || die "Chaîne DOCKER-USER absente : Docker n'utilise pas le backend iptables ?"

# ---------------------------- 2. Routage IPv4 --------------------------------
log "Activation du routage IPv4 (persistant)"
echo "net.ipv4.ip_forward=1" > "$SYSCTL_FILE"
sysctl -q -w net.ipv4.ip_forward=1
sysctl -q --system >/dev/null 2>&1 || true
ok "net.ipv4.ip_forward=1"

# ---------------------------- 3. Nettoyage ancienne chaîne LAB-FORWARD -------
if iptables -S 2>/dev/null | grep -q 'LAB-FORWARD'; then
  log "Nettoyage de l'ancienne chaîne LAB-FORWARD"
  while read -r rule; do
    # transforme "-A FORWARD ..." en "-D FORWARD ..."
    # shellcheck disable=SC2086
    iptables ${rule/-A/-D} 2>/dev/null || true
  done < <(iptables -S | grep -E '^-A .* -j LAB-FORWARD')
  iptables -F LAB-FORWARD 2>/dev/null || true
  iptables -X LAB-FORWARD 2>/dev/null || true
  ok "LAB-FORWARD supprimée"
fi

# ---------------------------- 4. Réseaux Docker ------------------------------
# Options selon le mode choisi
net_opts() {  # $1 = bridge, $2 = bridge du pair
  if [ "$MODE" = "routed" ]; then
    echo "-o com.docker.network.bridge.gateway_mode_ipv4=routed"
  else
    echo "-o com.docker.network.bridge.enable_ip_masquerade=false -o com.docker.network.bridge.trusted_host_interfaces=$2"
  fi
}

# Retourne 0 si le réseau existe déjà avec la bonne configuration
net_is_current() {  # $1 = nom, $2 = subnet, $3 = mode
  docker network inspect "$1" >/dev/null 2>&1 || return 1
  local sub lbl
  sub="$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$1")"
  lbl="$(docker network inspect -f '{{index .Labels "lab.mode"}}' "$1")"
  [ "$sub" = "$2" ] && [ "$lbl" = "$3" ]
}

ensure_network() {  # $1 nom, $2 bridge, $3 subnet, $4 gateway, $5 bridge du pair
  local name="$1" br="$2" subnet="$3" gw="$4" peer="$5"
  if net_is_current "$name" "$subnet" "$MODE"; then
    ok "Réseau $name déjà conforme (mode $MODE)"
    return
  fi

  # Sauvegarde des conteneurs rattachés (nom + IP) pour les rattacher ensuite
  local saved=()
  if docker network inspect "$name" >/dev/null 2>&1; then
    log "Réseau $name à recréer : migration des conteneurs rattachés"
    while read -r cname cip; do
      [ -n "$cname" ] || continue
      saved+=("$cname ${cip%/*}")
      docker network disconnect -f "$name" "$cname"
    done < <(docker network inspect -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}' "$name")
    docker network rm "$name" >/dev/null
  fi

  # shellcheck disable=SC2046
  docker network create --driver bridge \
    --subnet "$subnet" --gateway "$gw" \
    -o "com.docker.network.bridge.name=$br" \
    $(net_opts "$br" "$peer") \
    --label "lab.mode=$MODE" \
    "$name" >/dev/null
  ok "Réseau $name créé ($br, $subnet, mode $MODE)"

  for entry in "${saved[@]:-}"; do
    [ -n "$entry" ] || continue
    docker network connect --ip "${entry#* }" "$name" "${entry%% *}"
    ok "Conteneur ${entry%% *} rattaché à $name avec l'IP ${entry#* }"
  done
}

build_networks() {
  log "Réseaux Docker (mode $MODE)"
  ensure_network "$NET_KALI"   "$BR_KALI"   "$SUBNET_KALI"   "$GW_KALI"   "$BR_UBUNTU"
  ensure_network "$NET_UBUNTU" "$BR_UBUNTU" "$SUBNET_UBUNTU" "$GW_UBUNTU" "$BR_KALI"
}

# Détecte les DROP "raw" de Docker 28+ qui bloquent le routage inter-bridges
raw_drops_present() {
  iptables -t raw -S PREROUTING 2>/dev/null \
    | grep -E -- "-d ($IP_KALI|$IP_UBUNTU)/32 ! -i br-[a-z]+ -j DROP" >/dev/null
}

build_networks

# Les règles raw sont (re)créées quand un conteneur démarre : on le vérifiera plus bas.

# ---------------------------- 5. Conteneurs ----------------------------------
ensure_container() {  # $1 nom, $2 image, $3 réseau, $4 ip
  local name="$1" image="$2" net="$3" ip="$4"
  if docker inspect "$name" >/dev/null 2>&1; then
    log "Conteneur $name existant : conservé"
    if ! docker inspect -f '{{json .NetworkSettings.Networks}}' "$name" | grep -q "\"$net\""; then
      docker network connect --ip "$ip" "$net" "$name"
      ok "$name rattaché à $net ($ip)"
    fi
    docker update --restart unless-stopped "$name" >/dev/null
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = "true" ] || docker start "$name" >/dev/null
  else
    docker run -dit --name "$name" --hostname "$name" \
      --restart unless-stopped \
      --network "$net" --ip "$ip" \
      "$image" sleep infinity >/dev/null
    ok "Conteneur $name créé ($ip)"
  fi
}

log "Conteneurs"
ensure_container "$CT_KALI"   "$IMG_KALI"   "$NET_KALI"   "$IP_KALI"
ensure_container "$CT_UBUNTU" "$IMG_UBUNTU" "$NET_UBUNTU" "$IP_UBUNTU"

# Bascule automatique vers "trusted" si la protection Docker bloque encore le routage
if [ "$MODE" = "routed" ] && [ "$FORCE_MODE" -eq 0 ] && raw_drops_present; then
  warn "Des règles raw DROP subsistent en mode routed : bascule en mode trusted"
  MODE="trusted"
  build_networks
  docker restart "$CT_KALI" "$CT_UBUNTU" >/dev/null
fi
if raw_drops_present && [ "$MODE" = "routed" ]; then
  warn "Des règles raw DROP sont toujours présentes (relancez avec --mode trusted)."
fi

# ---------------------------- 6. Règles iptables persistantes ----------------
log "Installation des règles de routage/NAT persistantes"

# En-tête avec les valeurs (expansées maintenant)
cat > "$RULES_SCRIPT" <<EOF
#!/usr/bin/env bash
# Généré par setup-lab.sh : règles du labo Kali/Ubuntu
BR_KALI="$BR_KALI"
BR_UBUNTU="$BR_UBUNTU"
SUBNET_KALI="$SUBNET_KALI"
SUBNET_UBUNTU="$SUBNET_UBUNTU"
EOF

# Corps (non expansé)
cat >> "$RULES_SCRIPT" <<'EOF'
set -euo pipefail

# Attendre que Docker ait créé la chaîne DOCKER-USER
for _ in $(seq 1 30); do
  iptables -nL DOCKER-USER >/dev/null 2>&1 && break
  sleep 1
done
iptables -nL DOCKER-USER >/dev/null 2>&1 || { echo "DOCKER-USER introuvable" >&2; exit 1; }

sysctl -q -w net.ipv4.ip_forward=1

# Interface de sortie Internet (WAN)
WAN="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
[ -n "$WAN" ] || { echo "Interface WAN introuvable" >&2; exit 1; }

# Ajout idempotent (-C teste l'existence avant d'ajouter)
ensure() {  # ensure <table> <action -I|-A> <chaîne> <règle...>
  local table="$1" action="$2" chain="$3"; shift 3
  iptables -t "$table" -C "$chain" "$@" 2>/dev/null || {
    if [ "$action" = "-I" ]; then iptables -t "$table" -I "$chain" 1 "$@"
    else iptables -t "$table" -A "$chain" "$@"; fi
  }
}

# Trafic inter-réseaux autorisé dans les deux sens (aucun NAT)
ensure filter -I DOCKER-USER -i "$BR_KALI"   -o "$BR_UBUNTU" -j ACCEPT
ensure filter -I DOCKER-USER -i "$BR_UBUNTU" -o "$BR_KALI"   -j ACCEPT

# NAT uniquement vers Internet
ensure nat -A POSTROUTING -s "$SUBNET_KALI"   -o "$WAN" -j MASQUERADE
ensure nat -A POSTROUTING -s "$SUBNET_UBUNTU" -o "$WAN" -j MASQUERADE

echo "Règles lab appliquées (WAN=$WAN)"
EOF
chmod 755 "$RULES_SCRIPT"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Règles réseau du labo Kali/Ubuntu (routage + NAT)
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$RULES_SCRIPT

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable lab-network.service >/dev/null 2>&1
systemctl restart lab-network.service
ok "Service lab-network.service actif (réappliqué après chaque démarrage de Docker)"

# ---------------------------- 7. Paquets dans les conteneurs -----------------
if [ "$INSTALL_PACKAGES" -eq 1 ]; then
  log "Installation des outils réseau dans les conteneurs (nécessite Internet)"
  BASE_PKGS="iproute2 iputils-ping net-tools traceroute tcpdump dnsutils curl wget netcat-openbsd"
  docker exec "$CT_KALI" bash -c \
    "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $BASE_PKGS nmap" >/dev/null \
    && ok "Outils installés dans $CT_KALI" || warn "Échec d'installation dans $CT_KALI (Internet ?)"
  docker exec "$CT_UBUNTU" bash -c \
    "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $BASE_PKGS procps openssh-server" >/dev/null \
    && ok "Outils installés dans $CT_UBUNTU" || warn "Échec d'installation dans $CT_UBUNTU (Internet ?)"
fi

# ---------------------------- 8. Vérifications -------------------------------
log "Vérifications"
FAIL=0
check() {  # $1 description, $2... commande
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else warn "ÉCHEC : $desc"; FAIL=1; fi
}

check "ip_forward = 1"                       test "$(sysctl -n net.ipv4.ip_forward)" = "1"
check "Ubuntu -> Kali ($IP_KALI)"            docker exec "$CT_UBUNTU" ping -c2 -W2 "$IP_KALI"
check "Kali -> Ubuntu ($IP_UBUNTU)"          docker exec "$CT_KALI"   ping -c2 -W2 "$IP_UBUNTU"
check "Internet depuis Kali"                 docker exec "$CT_KALI"   ping -c2 -W3 1.1.1.1
check "Internet depuis Ubuntu"               docker exec "$CT_UBUNTU" ping -c2 -W3 1.1.1.1
check "DNS depuis Kali"                      docker exec "$CT_KALI"   getent hosts example.com
check "DNS depuis Ubuntu"                    docker exec "$CT_UBUNTU" getent hosts example.com

echo
if [ "$FAIL" -eq 0 ]; then
  ok "Architecture opérationnelle."
  cat <<EOF

Pour Suricata (plus tard) : une seule interface, br-ubuntu (ou br-kali).
Contrôle visuel :
  sudo tcpdump -ni $BR_UBUNTU host $IP_KALI and host $IP_UBUNTU
EOF
else
  warn "Certains tests ont échoué. Diagnostic :"
  echo "  sudo iptables -t raw -S PREROUTING"
  echo "  sudo iptables -nvL FORWARD --line-numbers"
  echo "  sudo iptables -nvL DOCKER-USER --line-numbers"
  echo "  sudo iptables -t nat -S POSTROUTING"
  echo "  (si les ping inter-conteneurs échouent : relancer avec --mode trusted)"
  echo "  (si seuls les tests ping échouent : paquets 'ping' absents avec --no-packages)"
  exit 1
fi
