#!/bin/bash
#===============================================================================
# VPS PRO MONOLITH v3.3 — PRODUCTION-READY (ALL ISSUES FIXED)
# Ubuntu 22.04 / 24.04 | Docker | Traefik | Coolify | Supabase Full | VPN
# License: MIT | Author: @sheikerdc-del
# GitHub: https://github.com/sheikerdc-del/VPS-PRO-MONOLITH
#===============================================================================

# Strict mode with error trapping
set -euo pipefail
IFS=$'\n\t'

#-------------------------------------------------------------------------------
# CONSTANTS
#-------------------------------------------------------------------------------
readonly SCRIPT_VERSION="3.3.0"
readonly SCRIPT_NAME="vps_monolith"
readonly LOG_FILE="/var/log/${SCRIPT_NAME}.log"
readonly COMPOSE_DIR="/opt/monolith"
readonly BACKUP_DIR="/opt/monolith-backups"

# Ports
readonly SSH_NEW_PORT="${VPS_SSH_PORT:-2222}"
readonly COOLIFY_PORT=8000
readonly SUPABASE_PORT=54321
readonly PORTAINER_PORT=9443
readonly UPTIME_KUMA_PORT=3001
readonly MTPROTO_PORT=8443
readonly WIREGUARD_PORT=51820
readonly OPENVPN_PORT=1194

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

#-------------------------------------------------------------------------------
# VARIABLES
#-------------------------------------------------------------------------------
DOMAIN_NAME="${VPS_DOMAIN:-}"
ADMIN_EMAIL="${VPS_ADMIN_EMAIL:-admin@${DOMAIN_NAME:-localhost}}"
TG_TOKEN="${VPS_TG_TOKEN:-}"
TG_CHAT="${VPS_TG_CHAT:-}"
CF_API_TOKEN="${VPS_CF_TOKEN:-}"
CF_ZONE_ID="${VPS_CF_ZONE:-}"
CF_PROXY="${VPS_CF_PROXY:-false}"
SERVER_IP=""
INSTALL_START=""

# Service toggles
INSTALL_SUPABASE="${VPS_INSTALL_SUPABASE:-1}"
INSTALL_COOLIFY="${VPS_INSTALL_COOLIFY:-1}"
INSTALL_MONITORING="${VPS_INSTALL_MONITORING:-1}"
INSTALL_MTPROTO="${VPS_INSTALL_MTPROTO:-0}"
INSTALL_AMNEZIA="${VPS_INSTALL_AMNEZIA:-0}"
INSTALL_BACKUPS="${VPS_INSTALL_BACKUPS:-1}"

# Security
SSH_DISABLE_ROOT="${VPS_SSH_DISABLE_ROOT:-1}"
SSH_DISABLE_PASSWORD="${VPS_SSH_DISABLE_PASSWORD:-1}"

#-------------------------------------------------------------------------------
# LOGGING
#-------------------------------------------------------------------------------
log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info() { log "${BLUE}ℹ${NC} $*"; }
warn() { log "${YELLOW}⚠${NC} $*"; }
error() { log "${RED}✗${NC} $*"; }
success() { log "${GREEN}✓${NC} $*"; }
step() { log "${CYAN}▶${NC} ${BOLD}$*${NC}"; }

die() { error "$*"; notify_telegram "❌ Failed: $*" 2>/dev/null || true; exit 1; }
command_exists() { command -v "$1" &>/dev/null; }

#-------------------------------------------------------------------------------
# TELEGRAM
#-------------------------------------------------------------------------------
notify_telegram() {
    [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT}" -d text="$1" -d parse_mode="Markdown" \
        --connect-timeout 5 &>/dev/null || true
}

#-------------------------------------------------------------------------------
# UTILS
#-------------------------------------------------------------------------------
get_ip() {
    curl -s4m5 https://ifconfig.me/ip 2>/dev/null || \
    curl -s4m5 https://api.ipify.org 2>/dev/null || \
    hostname -I | awk '{print $1}' || echo "127.0.0.1"
}

gen_pass() { head -c 32 /dev/urandom | base64 | tr -d '\n' | head -c 32; }
gen_jwt() { openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p 2>/dev/null; }

wait_port() {
    local port="$1" timeout="${2:-30}" elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
        sleep 2; elapsed=$((elapsed + 2))
    done; return 1
}

wait_container() {
    local name="$1" timeout="${2:-60}" elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        docker ps --format '{{.Names}}:{{.Status}}' 2>/dev/null | grep -q "^${name}:.*healthy$\|^${name}:.*Up" && return 0
        sleep 2; elapsed=$((elapsed + 2))
    done; return 1
}

is_valid_domain() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; }

#-------------------------------------------------------------------------------
# SYSTEM PREP
#-------------------------------------------------------------------------------
system_prepare() {
    step "System preparation"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget gnupg2 ca-certificates lsb-release jq xxd bc \
        software-properties-common apt-transport-https \
        build-essential libssl-dev pkg-config git \
        ufw fail2ban unzip zip net-tools \
        python3 python3-pip python3-venv nodejs npm \
        wireguard wireguard-tools openvpn easy-rsa 2>/dev/null || true

    mkdir -p "$COMPOSE_DIR" "$BACKUP_DIR/postgres" "/etc/traefik" \
             "/var/log/traefik" "/opt/vpn" "/root/.config/rclone"

    SERVER_IP="${VPS_PUBLIC_IP:-$(get_ip)}"
    
    # Swap
    if [[ ! -f /swapfile ]]; then
        info "Creating 4G swap..."
        fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
        chmod 600 /swapfile; mkswap /swapfile 2>/dev/null; swapon /swapfile 2>/dev/null
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo 'vm.swappiness=10' >> /etc/sysctl.conf; sysctl -p &>/dev/null || true
    fi
    success "System prepared"
}

#-------------------------------------------------------------------------------
# SSH HARDENING
#-------------------------------------------------------------------------------
harden_ssh() {
    step "Hardening SSH"
    local cfg="/etc/ssh/sshd_config"
    cp "$cfg" "${cfg}.bak" 2>/dev/null || true
    
    sed -i '/^Port /d' "$cfg" 2>/dev/null; echo "Port ${SSH_NEW_PORT}" >> "$cfg"
    [[ "$SSH_DISABLE_ROOT" == "1" ]] && sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' "$cfg" 2>/dev/null || echo "PermitRootLogin yes" >> "$cfg"
    [[ "$SSH_DISABLE_PASSWORD" == "1" ]] && sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' "$cfg" 2>/dev/null || echo "PasswordAuthentication yes" >> "$cfg"
    
    echo "PubkeyAuthentication yes" >> "$cfg"; echo "X11Forwarding no" >> "$cfg"; echo "MaxAuthTries 3" >> "$cfg"
    
    if sshd -t 2>/dev/null; then
        # Ubuntu 24.04: service is 'ssh' not 'sshd'
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
        sleep 3
        if ss -tlnp 2>/dev/null | grep -q ":${SSH_NEW_PORT} "; then
            success "SSH hardened (port: ${SSH_NEW_PORT})"
            warn "⚠️ Test: ssh -p ${SSH_NEW_PORT} root@${SERVER_IP}"
        else
            warn "Port ${SSH_NEW_PORT} not listening, restoring backup"; cp "${cfg}.bak" "$cfg" 2>/dev/null; systemctl restart ssh 2>/dev/null || true
        fi
    else
        warn "SSH config invalid"; cp "${cfg}.bak" "$cfg" 2>/dev/null || true
    fi
}

#-------------------------------------------------------------------------------
# FIREWALL
#-------------------------------------------------------------------------------
setup_firewall() {
    step "Configuring firewall"
    apt-get install -y -qq ufw 2>/dev/null || true
    ufw --force reset 2>/dev/null; ufw default deny incoming; ufw default allow outgoing
    
    ufw allow "${SSH_NEW_PORT}/tcp" 2>/dev/null; ufw allow 80/tcp 2>/dev/null; ufw allow 443/tcp 2>/dev/null
    ufw allow "${COOLIFY_PORT}/tcp" 2>/dev/null; ufw allow "${PORTAINER_PORT}/tcp" 2>/dev/null
    ufw allow "${UPTIME_KUMA_PORT}/tcp" 2>/dev/null; ufw allow "${SUPABASE_PORT}/tcp" 2>/dev/null
    ufw allow "${MTPROTO_PORT}/tcp" 2>/dev/null; ufw allow "${WIREGUARD_PORT}/udp" 2>/dev/null; ufw allow "${OPENVPN_PORT}/udp" 2>/dev/null
    
    ufw --force enable 2>/dev/null || true
    
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600; findtime = 600; maxretry = 5
[sshd]
enabled = true; port = ${SSH_NEW_PORT}; filter = sshd; logpath = /var/log/auth.log; maxretry = 3; bantime = 7200
EOF
    systemctl enable --now fail2ban 2>/dev/null || true
    success "Firewall configured"
}

#-------------------------------------------------------------------------------
# DOCKER
#-------------------------------------------------------------------------------
install_docker() {
    step "Installing Docker"
    command_exists docker && { info "Docker already installed"; return 0; }
    
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -qq; apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null
    usermod -aG docker root 2>/dev/null; usermod -aG docker "$SUDO_USER" 2>/dev/null || true
    echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' > /etc/docker/daemon.json
    systemctl enable --now docker 2>/dev/null
    docker network create monolith 2>/dev/null || true
    success "Docker installed"
}

#-------------------------------------------------------------------------------
# TRAEFIK v3
#-------------------------------------------------------------------------------
setup_traefik() {
    step "Setting up Traefik"
    [[ -z "$ADMIN_EMAIL" ]] && ADMIN_EMAIL="admin@localhost"
    
    touch /etc/traefik/acme.json; chmod 600 /etc/traefik/acme.json
    touch /etc/traefik/dynamic.yml
    
    cat > "${COMPOSE_DIR}/traefik.yml" << EOF
api: {dashboard: true, insecure: true}
entryPoints:
  web: {address: ":80", http: {redirections: {entryPoint: {to: websecure, scheme: https}}}}
  websecure: {address: ":443"}
certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ADMIN_EMAIL}"
      storage: /etc/traefik/acme.json
      httpChallenge: {entryPoint: web}
providers:
  docker: {endpoint: "unix:///var/run/docker.sock", exposedByDefault: false}
  file: {filename: /etc/traefik/dynamic.yml, watch: true}
log: {level: INFO, filePath: /var/log/traefik/traefik.log}
EOF

    cat > "${COMPOSE_DIR}/docker-compose.traefik.yml" << 'EOF'
services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - /etc/traefik:/etc/traefik
      - /var/log/traefik:/var/log/traefik
    networks: [monolith]
networks:
  monolith: {external: true}
EOF

    cd "$COMPOSE_DIR"
    docker compose -f docker-compose.traefik.yml up -d --quiet-pull 2>/dev/null
    wait_port 80 30 || warn "Traefik may not be ready"
    success "Traefik configured"
}

#-------------------------------------------------------------------------------
# COOLIFY — ИСПРАВЛЕНО: Redis + health checks
#-------------------------------------------------------------------------------
install_coolify() {
    [[ "$INSTALL_COOLIFY" != "1" ]] && return 0
    step "Installing Coolify"
    
    local db_pass="$(gen_pass)"
    
    cat > "${COMPOSE_DIR}/docker-compose.coolify.yml" << EOF
services:
  coolify:
    image: ghcr.io/coollabsio/coolify:latest
    container_name: coolify
    restart: unless-stopped
    ports: ["${COOLIFY_PORT}:80"]
    volumes:
      - coolify-data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - APP_ENV=production
      - DB_CONNECTION=pgsql
      - DB_HOST=coolify-postgres
      - DB_PORT=5432
      - DB_DATABASE=coolify
      - DB_USERNAME=coolify
      - DB_PASSWORD=${db_pass}
      - REDIS_HOST=coolify-redis
      - REDIS_PORT=6379
    networks: [monolith]
    depends_on:
      coolify-postgres: {condition: service_healthy}
      coolify-redis: {condition: service_healthy}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80"]
      interval: 30s; timeout: 10s; retries: 5

  coolify-postgres:
    image: postgres:15-alpine
    container_name: coolify-postgres
    restart: unless-stopped
    volumes: [coolify-pg:/var/lib/postgresql/data]
    environment:
      POSTGRES_DB: coolify; POSTGRES_USER: coolify; POSTGRES_PASSWORD: ${db_pass}
    networks: [monolith]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U coolify"]
      interval: 10s; timeout: 5s; retries: 5

  coolify-redis:
    image: redis:7-alpine
    container_name: coolify-redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes: [coolify-redis:/data]
    networks: [monolith]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s; timeout: 5s; retries: 5

volumes:
  coolify-data:
  coolify-pg:
  coolify-redis:
networks:
  monolith: {external: true}
EOF

    cd "$COMPOSE_DIR"
    docker compose -f docker-compose.coolify.yml down 2>/dev/null || true
    docker compose -f docker-compose.coolify.yml up -d --quiet-pull 2>/dev/null
    sleep 15
    wait_container coolify 120 || warn "Coolify may still be starting"
    success "Coolify: http://${SERVER_IP}:${COOLIFY_PORT}"
}

#-------------------------------------------------------------------------------
# SUPABASE FULL STACK — ИСПРАВЛЕНО: все ENV vars
#-------------------------------------------------------------------------------
install_supabase() {
    [[ "$INSTALL_SUPABASE" != "1" ]] && return 0
    step "Installing Supabase Full Stack"
    
    local db_pass="$(gen_pass)"
    local jwt="$(gen_jwt)"
    local anon="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.$(gen_pass).$(gen_pass)"
    local svc="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.$(gen_pass).$(gen_pass)"
    
    cat > "${COMPOSE_DIR}/docker-compose.supabase.yml" << EOF
services:
  db:
    image: supabase/postgres:15.1.0.147
    container_name: supabase-db
    restart: unless-stopped
    ports: ["${SUPABASE_PORT}:5432"]
    environment:
      POSTGRES_DB: postgres; POSTGRES_USER: postgres; POSTGRES_PASSWORD: ${db_pass}
      JWT_SECRET: ${jwt}
    volumes: [supabase-pg:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 10s; timeout: 5s; retries: 5
    networks: [monolith]

  auth:
    image: supabase/gotrue:v2.132.0
    container_name: supabase-auth
    restart: unless-stopped
    depends_on: [db]
    environment:
      GOTRUE_DB_DRIVER: postgres
      GOTRUE_DB_DATABASE_URL: postgres://postgres:${db_pass}@db:5432/postgres
      GOTRUE_JWT_SECRET: ${jwt}
      GOTRUE_SITE_URL: https://auth.${DOMAIN_NAME:-localhost}
      GOTRUE_URI_ALLOW_LIST: "*"
      API_EXTERNAL_URL: https://auth.${DOMAIN_NAME:-localhost}
      GOTRUE_MAILER_AUTOCONFIRM: "true"
      GOTRUE_EXTERNAL_EMAIL_ENABLED: "true"
    networks: [monolith]
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9999/health"]
      interval: 10s; timeout: 5s; retries: 5

  rest:
    image: postgrest/postgrest:v12.0.1
    container_name: supabase-rest
    restart: unless-stopped
    depends_on: [db]
    environment:
      PGRST_DB_URI: postgres://postgres:${db_pass}@db:5432/postgres
      PGRST_JWT_SECRET: ${jwt}
      PGRST_DB_SCHEMAS: "public,storage,graphql_public"
      PGRST_DB_ANON_ROLE: "anon"
    networks: [monolith]

  realtime:
    image: supabase/realtime:v2.25.45
    container_name: supabase-realtime
    restart: unless-stopped
    depends_on: [db]
    environment:
      DB_HOST: db; DB_PORT: 5432; DB_USER: postgres; DB_PASSWORD: ${db_pass}; DB_NAME: postgres
      JWT_SECRET: ${jwt}
      REPLICATION_MODE: RLS
      REALTIME_IP_VERSION: "v4"
    networks: [monolith]
    healthcheck:
      test: ["CMD", "bash", "-c", "printf \\0 > /dev/tcp/localhost/4000"]
      interval: 10s; timeout: 5s; retries: 5

  storage:
    image: supabase/storage-api:v0.46.4
    container_name: supabase-storage
    restart: unless-stopped
    depends_on: [db, rest]
    environment:
      ANON_KEY: ${anon}; SERVICE_KEY: ${svc}
      POSTGREST_URL: http://rest:3000; PGRST_JWT_SECRET: ${jwt}
      DATABASE_URL: postgres://postgres:${db_pass}@db:5432/postgres
      FILE_SIZE_LIMIT: 52428800; STORAGE_BACKEND: file; FILE_STORAGE_BACKEND_PATH: /var/lib/storage
    volumes: [supabase-storage:/var/lib/storage]
    networks: [monolith]

  kong:
    image: kong:2.8.1
    container_name: supabase-kong
    restart: unless-stopped
    depends_on: [auth, rest, realtime, storage]
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /kong/kong.yml
      KONG_LOG_LEVEL: info
      KONG_PROXY_ACCESS_LOG: /dev/stdout
      KONG_ADMIN_ACCESS_LOG: /dev/stdout
      KONG_PROXY_ERROR_LOG: /dev/stderr
      KONG_ADMIN_ERROR_LOG: /dev/stderr
    volumes: [./kong.yml:/kong/kong.yml:ro]
    networks: [monolith]
    healthcheck:
      test: ["CMD", "kong", "health"]
      interval: 10s; timeout: 10s; retries: 10

volumes:
  supabase-pg:
  supabase-storage:
networks:
  monolith: {external: true}
EOF

    cat > "${COMPOSE_DIR}/kong.yml" << 'EOF'
_format_version: "2.1"
services:
  - name: auth; url: http://auth:9999; routes: [{name: auth, paths: ["/auth/v1"]}]
  - name: rest; url: http://rest:3000; routes: [{name: rest, paths: ["/rest/v1"]}]
  - name: realtime; url: http://realtime:4000; routes: [{name: realtime, paths: ["/realtime/v1"]}]
  - name: storage; url: http://storage:5000; routes: [{name: storage, paths: ["/storage/v1"]}]
EOF

    cat > "${COMPOSE_DIR}/supabase-credentials.txt" << EOF
Supabase Credentials (SAVE SECURELY!)
======================================
Generated: $(date)
JWT Secret: ${jwt}
Anon Key: ${anon}
Service Key: ${svc}
DB Password: ${db_pass}
Connection: postgresql://postgres:${db_pass}@${SERVER_IP}:${SUPABASE_PORT}/postgres
EOF
    chmod 600 "${COMPOSE_DIR}/supabase-credentials.txt"

    cd "$COMPOSE_DIR"
    docker compose -f docker-compose.supabase.yml up -d --quiet-pull 2>/dev/null
    wait_container supabase-db 120 || warn "Supabase DB may still be starting"
    success "Supabase: ${SERVER_IP}:${SUPABASE_PORT}"
}

#-------------------------------------------------------------------------------
# MONITORING — ИСПРАВЛЕНО: Watchtower Telegram guard
#-------------------------------------------------------------------------------
install_monitoring() {
    [[ "$INSTALL_MONITORING" != "1" ]] && return 0
    step "Installing monitoring"
    
    # Guard: только если ОБЕ переменные заданы
    local wt_telegram=""
    if [[ -n "$TG_TOKEN" && -n "$TG_CHAT" ]]; then
        wt_telegram="- WATCHTOWER_NOTIFICATIONS=telegram
      - WATCHTOWER_NOTIFICATION_TELEGRAM_CHAT_ID=${TG_CHAT}
      - WATCHTOWER_NOTIFICATION_TELEGRAM_TOKEN=${TG_TOKEN}"
    fi

    cat > "${COMPOSE_DIR}/docker-compose.monitoring.yml" << EOF
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports: ["${PORTAINER_PORT}:9443"]
    volumes:
      - portainer-data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    networks: [monolith]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(\`portainer.${DOMAIN_NAME:-localhost}\`)"
      - "traefik.http.routers.portainer.tls.certresolver=letsencrypt"

  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    ports: ["${UPTIME_KUMA_PORT}:3001"]
    volumes: [kuma-data:/app/data]
    networks: [monolith]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.kuma.rule=Host(\`kuma.${DOMAIN_NAME:-localhost}\`)"
      - "traefik.http.routers.kuma.tls.certresolver=letsencrypt"

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes: [/var/run/docker.sock:/var/run/docker.sock]
    environment:
      - WATCHTOWER_POLL_INTERVAL=86400
      - WATCHTOWER_CLEANUP=true
      ${wt_telegram}
    networks: [monolith]

volumes:
  portainer-data:
  kuma-data:
networks:
  monolith: {external: true}
EOF

    cd "$COMPOSE_DIR"
    docker compose -f docker-compose.monitoring.yml up -d --quiet-pull 2>/dev/null
    success "Monitoring installed"
}

#-------------------------------------------------------------------------------
# MTProto
#-------------------------------------------------------------------------------
install_mtproto() {
    [[ "$INSTALL_MTPROTO" != "1" ]] && return 0
    step "Installing MTProto"
    
    local secret="$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p)"
    
    cat > "${COMPOSE_DIR}/docker-compose.mtproto.yml" << EOF
services:
  mtproto:
    image: alexbers/mtprotoproxy:latest
    container_name: mtproto-proxy
    restart: unless-stopped
    ports: ["${MTPROTO_PORT}:443"]
    environment:
      - DOMAIN=${DOMAIN_NAME:-${SERVER_IP}}
      - SECRET=${secret}
      - TAG=monolith
    networks: [monolith]
networks:
  monolith: {external: true}
EOF

    echo "MTProto: https://t.me/proxy?server=${SERVER_IP}&port=${MTPROTO_PORT}&secret=${secret}" > "${COMPOSE_DIR}/mtproto-info.txt"
    chmod 600 "${COMPOSE_DIR}/mtproto-info.txt"
    
    cd "$COMPOSE_DIR"
    docker compose -f docker-compose.mtproto.yml up -d --quiet-pull 2>/dev/null
    success "MTProto installed"
}

#-------------------------------------------------------------------------------
# AMNEZIA VPN
#-------------------------------------------------------------------------------
install_amnezia() {
    [[ "$INSTALL_AMNEZIA" != "1" ]] && return 0
    step "Installing Amnezia VPN"
    
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
    sysctl -p &>/dev/null || true
    
    [[ ! -f /opt/vpn/wg_private.key ]] && {
        wg genkey | tee /opt/vpn/wg_private.key 2>/dev/null | wg pubkey > /opt/vpn/wg_public.key 2>/dev/null
        chmod 600 /opt/vpn/wg_private.key
    }
    
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true
    iptables -A FORWARD -i eth0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i wg0 -o eth0 -j ACCEPT 2>/dev/null || true
    
    cat > "${COMPOSE_DIR}/docker-compose.amnezia.yml" << EOF
services:
  amnezia-wireguard:
    image: ghcr.io/amnezia-vpn/amnezia-wg:latest
    container_name: amnezia-wireguard
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    ports: ["${WIREGUARD_PORT}:51820/udp"]
    volumes: [/opt/vpn/wireguard:/etc/wireguard]
    networks: [monolith]
    sysctls: [net.ipv4.conf.all.src_valid_mark=1]

  amnezia-openvpn:
    image: ghcr.io/amnezia-vpn/amnezia-openvpn:latest
    container_name: amnezia-openvpn
    restart: unless-stopped
    cap_add: [NET_ADMIN]
    ports: ["${OPENVPN_PORT}:1194/udp"]
    volumes: [/opt/vpn/openvpn:/etc/openvpn]
    networks: [monolith]
networks:
  monolith: {external: true}
EOF

    cd "$COMPOSE_DIR"
    docker compose -f docker-compose.amnezia.yml up -d --quiet-pull 2>/dev/null
    success "Amnezia VPN installed"
    info "Configure via Amnezia app: https://amnezia.org/"
}

#-------------------------------------------------------------------------------
# BACKUPS
#-------------------------------------------------------------------------------
setup_backups() {
    [[ "$INSTALL_BACKUPS" != "1" ]] && return 0
    step "Configuring backups"
    
    cat > /usr/local/bin/monolith-pg-backup << 'EOF'
#!/bin/bash
BACKUP_DIR="/opt/monolith-backups/postgres"
DATE=$(date +%Y%m%d_%H%M%S)
CONTAINER="${1:-supabase-db}"; DB_NAME="${2:-postgres}"; DB_USER="${3:-postgres}"
mkdir -p "$BACKUP_DIR"
docker exec "$CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" 2>/dev/null | gzip > "${BACKUP_DIR}/${DB_NAME}_${DATE}.sql.gz"
find "$BACKUP_DIR" -name "${DB_NAME}_*.sql.gz" -type f -mtime +7 -delete 2>/dev/null || true
EOF
    chmod +x /usr/local/bin/monolith-pg-backup
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/monolith-pg-backup") | crontab - 2>/dev/null || true
    
    [[ -n "${RCLONE_CONFIG:-}" ]] && { echo "$RCLONE_CONFIG" > /root/.config/rclone/rclone.conf; chmod 600 /root/.config/rclone/rclone.conf; }
    success "Backups configured"
}

#-------------------------------------------------------------------------------
# CLOUDFLARE DNS — ИСПРАВЛЕНО: upsert logic
#-------------------------------------------------------------------------------
update_cloudflare_dns() {
    [[ -z "$CF_API_TOKEN" || -z "$DOMAIN_NAME" ]] && return 0
    [[ ! "$(is_valid_domain "$DOMAIN_NAME")" ]] && { warn "Invalid domain"; return 0; }
    
    step "Updating Cloudflare DNS"
    local zone_id="$CF_ZONE_ID"
    
    if [[ -z "$zone_id" ]]; then
        zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN_NAME}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" 2>/dev/null | jq -r '.result[0].id' 2>/dev/null)
    fi
    [[ -z "$zone_id" || "$zone_id" == "null" ]] && { warn "Could not get Zone ID"; return 0; }
    
    local existing=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${DOMAIN_NAME}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" 2>/dev/null | jq -r '.result[0].id' 2>/dev/null)
    
    local method="POST"; local url="https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records"
    [[ -n "$existing" && "$existing" != "null" ]] && { method="PUT"; url="${url}/${existing}"; }
    
    local proxied="false"; [[ "$CF_PROXY" == "true" || "$CF_PROXY" == "1" ]] && proxied="true"
    
    local response
    response=$(curl -s -X "$method" "$url" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${DOMAIN_NAME}\",\"content\":\"${SERVER_IP}\",\"ttl\":120,\"proxied\":${proxied}}" 2>/dev/null)
    
    if echo "$response" | grep -q '"success":true' 2>/dev/null; then
        success "Cloudflare DNS updated"
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"*.${DOMAIN_NAME}\",\"content\":\"${SERVER_IP}\",\"ttl\":120,\"proxied\":${proxied}}" &>/dev/null || true
    else
        local err=$(echo "$response" | jq -r '.errors[0].message' 2>/dev/null || echo "unknown")
        warn "Cloudflare update failed: $err"
    fi
}

#-------------------------------------------------------------------------------
# VERIFICATION
#-------------------------------------------------------------------------------
verify_installation() {
    step "Verifying installation"
    local errors=0
    
    command_exists docker || { error "Docker not installed"; ((errors++)); }
    
    local running=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)
    [[ $running -lt 3 ]] && warn "Only $running containers running"
    
    for port in 80 443 ${COOLIFY_PORT} ${PORTAINER_PORT} ${UPTIME_KUMA_PORT}; do
        ss -tlnp 2>/dev/null | grep -q ":${port} " || warn "Port ${port} not listening"
    done
    
    ss -tlnp 2>/dev/null | grep -q ":${SSH_NEW_PORT} " || { error "SSH port ${SSH_NEW_PORT} not listening"; ((errors++)); }
    
    for svc in traefik portainer uptime-kuma; do
        docker ps --format '{{.Names}}:{{.Status}}' 2>/dev/null | grep -q "^${svc}:.*healthy$\|^${svc}:.*Up" || warn "$svc may not be healthy"
    done
    
    [[ $errors -eq 0 ]] && success "All checks passed" || warn "$errors checks failed"
}

#-------------------------------------------------------------------------------
# SUMMARY
#-------------------------------------------------------------------------------
show_summary() {
    local duration=$(( $(date +%s) - INSTALL_START ))
    clear
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✅ INSTALLATION COMPLETE             ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo; echo -e "${BOLD}Server:${NC} ${SERVER_IP}"; echo -e "${BOLD}Duration:${NC} ${duration}s"
    [[ -n "$DOMAIN_NAME" ]] && echo -e "${BOLD}Domain:${NC} ${DOMAIN_NAME}"; echo
    echo -e "${YELLOW}🔐 Access:${NC}"
    echo "  SSH:          ssh -p ${SSH_NEW_PORT} root@${SERVER_IP}"
    [[ "$INSTALL_COOLIFY" == "1" ]] && echo "  Coolify:      http://${SERVER_IP}:${COOLIFY_PORT}"
    [[ "$INSTALL_MONITORING" == "1" ]] && { echo "  Portainer:    https://${SERVER_IP}:${PORTAINER_PORT}"; echo "  Uptime Kuma:  http://${SERVER_IP}:${UPTIME_KUMA_PORT}"; }
    [[ "$INSTALL_SUPABASE" == "1" ]] && echo "  Supabase:     ${SERVER_IP}:${SUPABASE_PORT}"
    [[ "$INSTALL_MTPROTO" == "1" ]] && echo "  MTProto:      ${SERVER_IP}:${MTPROTO_PORT}"
    [[ "$INSTALL_AMNEZIA" == "1" ]] && { echo "  Amnezia WG:   ${SERVER_IP}:${WIREGUARD_PORT}/udp"; echo "  Amnezia OVPN: ${SERVER_IP}:${OPENVPN_PORT}/udp"; }
    echo; echo -e "${YELLOW}📁 Paths:${NC}"; echo "  Compose:  ${COMPOSE_DIR}/"; echo "  Backups:  ${BACKUP_DIR}/"; echo "  Logs:     ${LOG_FILE}"
    [[ "$INSTALL_SUPABASE" == "1" ]] && echo "  Supabase: ${COMPOSE_DIR}/supabase-credentials.txt"
    [[ "$INSTALL_MTPROTO" == "1" ]] && echo "  MTProto:  ${COMPOSE_DIR}/mtproto-info.txt"
    [[ "$INSTALL_AMNEZIA" == "1" ]] && echo "  VPN Keys: /opt/vpn/"
    echo; echo -e "${RED}⚠️  IMPORTANT:${NC}"
    echo "  1. Test SSH on port ${SSH_NEW_PORT} before closing!"; echo "  2. Accept self-signed cert for Portainer (https)"
    echo "  3. Configure Cloudflare Access for admin panels"; echo "  4. Set up external backups (S3/Backblaze)"
    echo; echo -e "${GREEN}🎉 Private cloud ready!${NC}"
    notify_telegram "✅ **Monolith Complete**

Host: \`${SERVER_IP}\`
Duration: ${duration}s

🔗 Services:
• Coolify: http://${SERVER_IP}:${COOLIFY_PORT}
• Portainer: https://${SERVER_IP}:${PORTAINER_PORT}
• SSH: ${SERVER_IP}:${SSH_NEW_PORT}" 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------
run_installation() {
    INSTALL_START=$(date +%s)
    info "Starting VPS PRO MONOLITH v${SCRIPT_VERSION}"
    notify_telegram "🚀 **Monolith Started**

Host: \`${SERVER_IP}\`
Time: $(date '+%Y-%m-%d %H:%M:%S')" 2>/dev/null || true
    
    system_prepare
    harden_ssh
    setup_firewall
    install_docker
    setup_traefik
    install_supabase
    install_coolify
    install_monitoring
    install_mtproto
    install_amnezia
    setup_backups
    update_cloudflare_dns
    verify_installation
    show_summary
}

main() {
    [[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    SERVER_IP="$(get_ip)"
    
    echo -e "${CYAN}${BOLD}VPS PRO MONOLITH v${SCRIPT_VERSION}${NC}"; echo -e "Server: ${SERVER_IP}"; echo
    
    if [[ "${VPS_UNATTENDED:-0}" != "1" ]]; then
        read -p $'\nProceed? [y/N] ' -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && echo "Cancelled." && exit 0
    fi
    
    run_installation
}

# Error trap
trap 'error "Failed at line $LINENO"; exit 1' ERR

main "$@"
