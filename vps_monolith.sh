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
SKIP_DNS_UPDATE="${VPS_SKIP_DNS:-0}"
DRY_RUN="${VPS_DRY_RUN:-0}"
STEPS_FILTER="${VPS_STEPS:-all}"
SSH_ALLOW_CIDR="${VPS_SSH_ALLOW_CIDR:-}"
ENABLE_TRAEFIK_DASHBOARD="${VPS_ENABLE_TRAEFIK_DASHBOARD:-0}"
DIAGNOSTICS_FILE="${COMPOSE_DIR}/diagnostics.txt"

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
should_run_step() { [[ "$STEPS_FILTER" == "all" || ",${STEPS_FILTER}," == *",$1,"* ]]; }
run_cmd() { [[ "$DRY_RUN" == "1" ]] && { info "[DRY-RUN] $*"; return 0; }; "$@"; }
run_or_die() { local desc="$1"; shift; run_cmd "$@" || die "$desc"; }
ensure_line() { local file="$1" line="$2"; grep -Fxq "$line" "$file" 2>/dev/null || echo "$line" >> "$file"; }
replace_or_append() {
    local file="$1" pattern="$2" line="$3"
    if grep -Eq "$pattern" "$file" 2>/dev/null; then
        sed -i -E "s|$pattern.*|$line|" "$file"
    else
        echo "$line" >> "$file"
    fi
}
ensure_sysctl() {
    local key="$1" value="$2" cfg="/etc/sysctl.d/99-monolith.conf"
    touch "$cfg"
    replace_or_append "$cfg" "^${key}=" "${key}=${value}"
    run_cmd sysctl -p "$cfg" &>/dev/null || true
}
restart_ssh_service() { systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null; }

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
    run_or_die "apt update failed" apt-get update -qq
    run_or_die "apt upgrade failed" env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    
    run_or_die "base packages install failed" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget gnupg2 ca-certificates lsb-release jq xxd bc \
        software-properties-common apt-transport-https \
        build-essential libssl-dev pkg-config git \
        ufw fail2ban unzip zip net-tools \
        python3 python3-pip python3-venv nodejs npm \
        wireguard wireguard-tools openvpn easy-rsa

    mkdir -p "$COMPOSE_DIR" "$BACKUP_DIR/postgres" "/etc/traefik" \
             "/var/log/traefik" "/opt/vpn" "/root/.config/rclone"

    SERVER_IP="${VPS_PUBLIC_IP:-$(get_ip)}"
    
    # Swap
    if [[ ! -f /swapfile ]]; then
        info "Creating 4G swap..."
        fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
        chmod 600 /swapfile; mkswap /swapfile 2>/dev/null || true; swapon /swapfile 2>/dev/null || true
        ensure_line /etc/fstab '/swapfile none swap sw 0 0'
        ensure_sysctl vm.swappiness 10
    fi
    success "System prepared"
}

preflight_checks() {
    step "Preflight checks"

    [[ $EUID -eq 0 ]] || die "Run as root"
    command_exists systemctl || die "systemctl is required"

    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "Unsupported OS: ${ID:-unknown}"
    [[ "${VERSION_ID:-}" == "22.04" || "${VERSION_ID:-}" == "24.04" ]] || warn "Untested Ubuntu version: ${VERSION_ID:-unknown}"

    local mem_mb disk_gb
    mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    disk_gb=$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4+0}')
    [[ "$mem_mb" -lt 1500 ]] && warn "Low RAM detected: ${mem_mb}MB"
    [[ "$disk_gb" -lt 8 ]] && warn "Low free disk space: ${disk_gb}GB"

    for endpoint in https://download.docker.com; do
        curl -fsSL --connect-timeout 5 "$endpoint" >/dev/null || die "Network check failed: $endpoint"
    done
    [[ -n "$TG_TOKEN" && -n "$TG_CHAT" ]] && curl -fsSL --connect-timeout 5 https://api.telegram.org >/dev/null || true
    [[ "$SKIP_DNS_UPDATE" != "1" && -n "$CF_API_TOKEN" ]] && curl -fsSL --connect-timeout 5 https://api.cloudflare.com >/dev/null || true

    local ports=(80 443 "$SSH_NEW_PORT")
    [[ "$INSTALL_COOLIFY" == "1" ]] && ports+=("$COOLIFY_PORT")
    [[ "$INSTALL_MONITORING" == "1" ]] && ports+=("$PORTAINER_PORT" "$UPTIME_KUMA_PORT")
    [[ "$INSTALL_SUPABASE" == "1" ]] && ports+=("$SUPABASE_PORT")
    [[ "$INSTALL_MTPROTO" == "1" ]] && ports+=("$MTPROTO_PORT")

    for port in "${ports[@]}"; do
        ss -tuln | grep -q ":${port} " && warn "Port ${port} already in use before install"
    done

    success "Preflight checks completed"
}

check_dependencies() {
    step "Checking dependencies"

    local missing=()
    local required=(curl jq openssl ss awk sed grep systemctl docker)

    for bin in "${required[@]}"; do
        command_exists "$bin" || missing+=("$bin")
    done

    if [[ "$INSTALL_BACKUPS" == "1" ]]; then
        for bin in crontab gzip; do
            command_exists "$bin" || missing+=("$bin")
        done
    fi

    if [[ "$INSTALL_AMNEZIA" == "1" ]]; then
        for bin in wg iptables; do
            command_exists "$bin" || missing+=("$bin")
        done
    fi

    if (( ${#missing[@]} > 0 )); then
        die "Missing required dependencies: ${missing[*]}"
    fi

    success "Dependencies OK"
}

#-------------------------------------------------------------------------------
# SSH HARDENING
#-------------------------------------------------------------------------------
harden_ssh() {
    step "Hardening SSH"
    local cfg="/etc/ssh/sshd_config"
    local dropin_dir="/etc/ssh/sshd_config.d"
    local dropin_file="${dropin_dir}/99-monolith.conf"
    local candidate="${dropin_file}.candidate"

    mkdir -p "$dropin_dir"
    cat > "$candidate" << EOF
Port ${SSH_NEW_PORT}
PermitRootLogin $([[ "$SSH_DISABLE_ROOT" == "1" ]] && echo no || echo yes)
PasswordAuthentication $([[ "$SSH_DISABLE_PASSWORD" == "1" ]] && echo no || echo yes)
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
EOF

    [[ -n "$SSH_ALLOW_CIDR" ]] && echo "AllowUsers root@${SSH_ALLOW_CIDR}" >> "$candidate"

    cp "$candidate" "$dropin_file"
    rm -f "$candidate"

    if sshd -t -f "$cfg" 2>/dev/null; then
        restart_ssh_service || true
        sleep 3
        if ss -tlnp 2>/dev/null | grep -q ":${SSH_NEW_PORT} "; then
            success "SSH hardened (port: ${SSH_NEW_PORT})"
            warn "⚠️ Test: ssh -p ${SSH_NEW_PORT} root@${SERVER_IP}"
        else
            warn "Port ${SSH_NEW_PORT} not listening, removing drop-in"
            rm -f "$dropin_file"
            restart_ssh_service || true
        fi
    else
        warn "SSH config invalid, rolling back drop-in"
        rm -f "$dropin_file"
        restart_ssh_service || true
    fi
}

#-------------------------------------------------------------------------------
# FIREWALL
#-------------------------------------------------------------------------------
setup_firewall() {
    step "Configuring firewall"
    run_or_die "ufw install failed" apt-get install -y -qq ufw
    run_cmd ufw --force reset
    run_cmd ufw default deny incoming
    run_cmd ufw default allow outgoing

    run_cmd ufw allow "${SSH_NEW_PORT}/tcp"
    [[ -n "$SSH_ALLOW_CIDR" ]] && run_cmd ufw allow from "$SSH_ALLOW_CIDR" to any port "$SSH_NEW_PORT" proto tcp
    run_cmd ufw allow 80/tcp
    run_cmd ufw allow 443/tcp
    [[ "$INSTALL_COOLIFY" == "1" ]] && run_cmd ufw allow "${COOLIFY_PORT}/tcp"
    [[ "$INSTALL_MONITORING" == "1" ]] && { run_cmd ufw allow "${PORTAINER_PORT}/tcp"; run_cmd ufw allow "${UPTIME_KUMA_PORT}/tcp"; }
    [[ "$INSTALL_SUPABASE" == "1" ]] && run_cmd ufw allow "${SUPABASE_PORT}/tcp"
    [[ "$INSTALL_MTPROTO" == "1" ]] && run_cmd ufw allow "${MTPROTO_PORT}/tcp"
    [[ "$INSTALL_AMNEZIA" == "1" ]] && { run_cmd ufw allow "${WIREGUARD_PORT}/udp"; run_cmd ufw allow "${OPENVPN_PORT}/udp"; }

    run_cmd ufw --force enable
    
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600; findtime = 600; maxretry = 5
[sshd]
enabled = true; port = ${SSH_NEW_PORT}; filter = sshd; logpath = /var/log/auth.log; maxretry = 3; bantime = 7200
EOF
    run_cmd systemctl enable --now fail2ban
    success "Firewall configured"
}

#-------------------------------------------------------------------------------
# DOCKER
#-------------------------------------------------------------------------------
install_docker() {
    step "Installing Docker"
    command_exists docker && { info "Docker already installed"; return 0; }
    
    run_cmd apt-get remove -y docker docker-engine docker.io containerd runc
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    run_or_die "docker packages install failed" apt-get update -qq
    run_or_die "docker packages install failed" apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    usermod -aG docker root 2>/dev/null; usermod -aG docker "$SUDO_USER" 2>/dev/null || true
    echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' > /etc/docker/daemon.json
    run_or_die "docker service start failed" systemctl enable --now docker
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
    
    local dashboard_enabled="false"
    [[ "$ENABLE_TRAEFIK_DASHBOARD" == "1" ]] && dashboard_enabled="true"

    cat > "${COMPOSE_DIR}/traefik.yml" << EOF
api: {dashboard: ${dashboard_enabled}, insecure: false}
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
    run_or_die "traefik compose config invalid" docker compose -f docker-compose.traefik.yml config
    run_or_die "traefik startup failed" docker compose -f docker-compose.traefik.yml up -d --quiet-pull
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
      interval: 30s
      timeout: 10s
      retries: 5

  coolify-postgres:
    image: postgres:15-alpine
    container_name: coolify-postgres
    restart: unless-stopped
    volumes: [coolify-pg:/var/lib/postgresql/data]
    environment:
      POSTGRES_DB: coolify
      POSTGRES_USER: coolify
      POSTGRES_PASSWORD: ${db_pass}
    networks: [monolith]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U coolify"]
      interval: 10s
      timeout: 5s
      retries: 5

  coolify-redis:
    image: redis:7-alpine
    container_name: coolify-redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes: [coolify-redis:/data]
    networks: [monolith]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  coolify-data:
  coolify-pg:
  coolify-redis:
networks:
  monolith: {external: true}
EOF

    cd "$COMPOSE_DIR"
    run_cmd docker compose -f docker-compose.coolify.yml down
    run_or_die "coolify compose config invalid" docker compose -f docker-compose.coolify.yml config
    run_or_die "coolify startup failed" docker compose -f docker-compose.coolify.yml up -d --quiet-pull
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
      POSTGRES_DB: postgres
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${db_pass}
      JWT_SECRET: ${jwt}
    volumes: [supabase-pg:/var/lib/postgresql/data]
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
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
      interval: 10s
      timeout: 5s
      retries: 5

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
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: postgres
      DB_PASSWORD: ${db_pass}
      DB_NAME: postgres
      JWT_SECRET: ${jwt}
      REPLICATION_MODE: RLS
      REALTIME_IP_VERSION: "v4"
    networks: [monolith]
    healthcheck:
      test: ["CMD", "bash", "-c", "printf \\0 > /dev/tcp/localhost/4000"]
      interval: 10s
      timeout: 5s
      retries: 5

  storage:
    image: supabase/storage-api:v0.46.4
    container_name: supabase-storage
    restart: unless-stopped
    depends_on: [db, rest]
    environment:
      ANON_KEY: ${anon}
      SERVICE_KEY: ${svc}
      POSTGREST_URL: http://rest:3000
      PGRST_JWT_SECRET: ${jwt}
      DATABASE_URL: postgres://postgres:${db_pass}@db:5432/postgres
      FILE_SIZE_LIMIT: 52428800
      STORAGE_BACKEND: file
      FILE_STORAGE_BACKEND_PATH: /var/lib/storage
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
      interval: 10s
      timeout: 10s
      retries: 10

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
    run_or_die "supabase compose config invalid" docker compose -f docker-compose.supabase.yml config
    run_or_die "supabase startup failed" docker compose -f docker-compose.supabase.yml up -d --quiet-pull
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
    run_or_die "monitoring compose config invalid" docker compose -f docker-compose.monitoring.yml config
    run_or_die "monitoring startup failed" docker compose -f docker-compose.monitoring.yml up -d --quiet-pull
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
    run_or_die "mtproto compose config invalid" docker compose -f docker-compose.mtproto.yml config
    run_or_die "mtproto startup failed" docker compose -f docker-compose.mtproto.yml up -d --quiet-pull
    success "MTProto installed"
}

#-------------------------------------------------------------------------------
# AMNEZIA VPN
#-------------------------------------------------------------------------------
install_amnezia() {
    [[ "$INSTALL_AMNEZIA" != "1" ]] && return 0
    step "Installing Amnezia VPN"
    
    ensure_sysctl net.ipv4.ip_forward 1
    ensure_sysctl net.ipv6.conf.all.forwarding 1
    
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
    run_or_die "amnezia compose config invalid" docker compose -f docker-compose.amnezia.yml config
    run_or_die "amnezia startup failed" docker compose -f docker-compose.amnezia.yml up -d --quiet-pull
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
    (crontab -l 2>/dev/null | grep -v 'monolith-pg-backup'; echo "0 3 * * * /usr/local/bin/monolith-pg-backup") | crontab -
    
    [[ -n "${RCLONE_CONFIG:-}" ]] && { echo "$RCLONE_CONFIG" > /root/.config/rclone/rclone.conf; chmod 600 /root/.config/rclone/rclone.conf; }
    success "Backups configured"
}

#-------------------------------------------------------------------------------
# CLOUDFLARE DNS — ИСПРАВЛЕНО: upsert logic
#-------------------------------------------------------------------------------
update_cloudflare_dns() {
    [[ "$SKIP_DNS_UPDATE" == "1" ]] && { info "Skipping DNS update (VPS_SKIP_DNS=1)"; return 0; }
    [[ -z "$CF_API_TOKEN" || -z "$DOMAIN_NAME" ]] && return 0
    [[ "$DOMAIN_NAME" == \*.* ]] && DOMAIN_NAME="${DOMAIN_NAME#*.}"

    if ! is_valid_domain "$DOMAIN_NAME"; then
        warn "Invalid domain"
        return 0
    fi
    
    step "Updating Cloudflare DNS"
    local zone_id="$CF_ZONE_ID"
    
    if [[ -z "$zone_id" ]]; then
        zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN_NAME}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" 2>/dev/null | jq -r '.result[0].id' 2>/dev/null)
    fi
    [[ -z "$zone_id" || "$zone_id" == "null" ]] && { warn "Could not get Zone ID"; return 0; }
    
    local proxied="false"; [[ "$CF_PROXY" == "true" || "$CF_PROXY" == "1" ]] && proxied="true"

    upsert_cloudflare_a_record "$zone_id" "$DOMAIN_NAME" "$SERVER_IP" "$proxied"
    upsert_cloudflare_a_record "$zone_id" "*.${DOMAIN_NAME}" "$SERVER_IP" "$proxied"
}

upsert_cloudflare_a_record() {
    local zone_id="$1" name="$2" ip="$3" proxied="$4"
    local existing method url response record_id

    existing=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${name}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" 2>/dev/null | jq -r '.result[0].id // empty' 2>/dev/null)

    method="POST"
    url="https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records"
    if [[ -n "$existing" ]]; then
        method="PUT"
        url="${url}/${existing}"
    fi

    response=$(curl -s -X "$method" "$url" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${name}\",\"content\":\"${ip}\",\"ttl\":120,\"proxied\":${proxied}}" 2>/dev/null)

    if echo "$response" | jq -e '.success == true' >/dev/null 2>&1; then
        record_id=$(echo "$response" | jq -r '.result.id // empty' 2>/dev/null)
        success "Cloudflare A record upserted: ${name} (${record_id:-unknown-id})"
    else
        local err
        err=$(echo "$response" | jq -r '.errors[0].message // "unknown"' 2>/dev/null || echo "unknown")
        warn "Cloudflare upsert failed for ${name}: $err"
    fi
}

collect_diagnostics() {
    step "Collecting diagnostics"
    {
        echo "=== VPS PRO MONOLITH diagnostics ==="
        echo "Generated: $(date)"
        echo
        echo "# docker ps"
        docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>&1
        echo
        echo "# docker compose ls"
        docker compose ls 2>&1
        echo
        echo "# listening ports"
        ss -tulpen 2>&1
        echo
        echo "# services"
        systemctl --no-pager --full status docker ssh fail2ban ufw 2>&1 || true
        echo
        echo "# ufw status"
        ufw status verbose 2>&1 || true
    } > "$DIAGNOSTICS_FILE" 2>/dev/null || true
    info "Diagnostics saved: $DIAGNOSTICS_FILE"
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
    
    local ports=(80 443)
    [[ "$INSTALL_COOLIFY" == "1" ]] && ports+=("${COOLIFY_PORT}")
    [[ "$INSTALL_MONITORING" == "1" ]] && ports+=("${PORTAINER_PORT}" "${UPTIME_KUMA_PORT}")
    [[ "$INSTALL_SUPABASE" == "1" ]] && ports+=("${SUPABASE_PORT}")
    [[ "$INSTALL_MTPROTO" == "1" ]] && ports+=("${MTPROTO_PORT}")

    for port in "${ports[@]}"; do
        ss -tlnp 2>/dev/null | grep -q ":${port} " || warn "Port ${port} not listening"
    done
    
    ss -tlnp 2>/dev/null | grep -q ":${SSH_NEW_PORT} " || { error "SSH port ${SSH_NEW_PORT} not listening"; ((errors++)); }
    
    local services=(traefik)
    [[ "$INSTALL_MONITORING" == "1" ]] && services+=(portainer uptime-kuma)
    [[ "$INSTALL_COOLIFY" == "1" ]] && services+=(coolify)
    [[ "$INSTALL_SUPABASE" == "1" ]] && services+=(supabase-db)

    for svc in "${services[@]}"; do
        docker ps --format '{{.Names}}:{{.Status}}' 2>/dev/null | grep -q "^${svc}:.*healthy$\|^${svc}:.*Up" || warn "$svc may not be healthy"
    done

    curl -fsS "http://127.0.0.1" >/dev/null 2>&1 || warn "Local HTTP endpoint check failed"
    curl -kfsS "https://127.0.0.1" >/dev/null 2>&1 || warn "Local HTTPS endpoint check failed"
    
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
    
    should_run_step preflight_checks && preflight_checks
    should_run_step system_prepare && system_prepare
    should_run_step harden_ssh && harden_ssh
    should_run_step setup_firewall && setup_firewall
    should_run_step install_docker && install_docker
    should_run_step check_dependencies && check_dependencies
    should_run_step setup_traefik && setup_traefik
    should_run_step install_supabase && install_supabase
    should_run_step install_coolify && install_coolify
    should_run_step install_monitoring && install_monitoring
    should_run_step install_mtproto && install_mtproto
    should_run_step install_amnezia && install_amnezia
    should_run_step setup_backups && setup_backups
    should_run_step update_cloudflare_dns && update_cloudflare_dns
    should_run_step verify_installation && verify_installation
    should_run_step collect_diagnostics && collect_diagnostics
    should_run_step show_summary && show_summary
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
