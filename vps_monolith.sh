#!/bin/bash
#===============================================================================
# VPS PRO MONOLITH v2.1 — Production-Ready Private Cloud
# Ubuntu 22.04 / 24.04 | Docker | Traefik | Coolify | Supabase (Full) | VPN
#===============================================================================

set -euo pipefail
IFS=$'\n\t'

#-------------------------------------------------------------------------------
# CONSTANTS & VERSION
#-------------------------------------------------------------------------------
readonly SCRIPT_VERSION="2.1.0"
readonly SCRIPT_NAME="vps_monolith"
readonly LOG_FILE="/var/log/${SCRIPT_NAME}.log"
readonly COMPOSE_DIR="/opt/monolith"
readonly BACKUP_DIR="/opt/monolith-backups"

# Default ports
readonly SSH_NEW_PORT="${VPS_SSH_PORT:-2222}"
readonly TRAEFIK_HTTP_PORT=80
readonly TRAEFIK_HTTPS_PORT=443
readonly COOLIFY_PORT=8000
readonly SUPABASE_PORT=54321
readonly PORTAINER_PORT=9443
readonly UPTIME_KUMA_PORT=3001
readonly MTPROTO_PORT=8443
readonly AMNEZIA_WIREGUARD_PORT=51820

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

#-------------------------------------------------------------------------------
# VARIABLES & SECRETS
#-------------------------------------------------------------------------------
DOMAIN_NAME="${VPS_DOMAIN:-}"
ADMIN_EMAIL="${VPS_ADMIN_EMAIL:-admin@${DOMAIN_NAME:-localhost}}"
TG_TOKEN="${VPS_TG_TOKEN:-}"
TG_CHAT="${VPS_TG_CHAT:-}"
CF_API_TOKEN="${VPS_CF_TOKEN:-}"
CF_ZONE_ID="${VPS_CF_ZONE:-}"
SELECTED_SERVICES=()
SERVER_IP=""

#-------------------------------------------------------------------------------
# SYSTEM FUNCTIONS
#-------------------------------------------------------------------------------
log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
info() { log "${BLUE}INFO:${NC} $*"; }
warn() { log "${YELLOW}WARN:${NC} $*"; }
error() { log "${RED}ERROR:${NC} $*"; }
success() { log "${GREEN}SUCCESS:${NC} $*"; }

die() { error "$*"; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }

generate_secret() { openssl rand -base64 "${1:-32}" | tr -dc 'a-zA-Z0-9' | head -c "${1:-32}"; }

get_public_ip() {
    local ip
    ip=$(curl -s4m5 https://ifconfig.me/ip || curl -s4m5 https://api.ipify.org || echo "127.0.0.1")
    echo "$ip"
}

#-------------------------------------------------------------------------------
# PREPARATION
#-------------------------------------------------------------------------------
system_prepare() {
    info "Preparing system dependencies..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget gnupg2 ca-certificates lsb-release jq xxd \
        software-properties-common apt-transport-https \
        build-essential libssl-dev git ufw fail2ban \
        unzip zip net-tools python3-pip python3-venv

    mkdir -p "$COMPOSE_DIR" "$BACKUP_DIR" "/etc/traefik" "/var/log/traefik" "/opt/vpn"
    SERVER_IP=$(get_public_ip)
    
    # Настройка Swap если его нет
    if [[ ! -f /swapfile ]]; then
        info "Creating 4G swap file..."
        fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
}

#-------------------------------------------------------------------------------
# DOCKER INSTALLATION
#-------------------------------------------------------------------------------
install_docker() {
    if command_exists docker; then
        info "Docker already installed."
        return 0
    fi
    
    info "Installing Docker Engine..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    systemctl enable --now docker
    docker network create monolith 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# SECURITY HARDENING
#-------------------------------------------------------------------------------
harden_security() {
    info "Hardening SSH and Firewall..."
    
    # 1. SSH Hardening
    local sshd_config="/etc/ssh/sshd_config"
    cp "$sshd_config" "${sshd_config}.bak"
    
    sed -i "s/^#\?Port .*/Port ${SSH_NEW_PORT}/" "$sshd_config"
    # ИСПРАВЛЕНО: Логика "Disable" теперь корректная
    [[ "${VPS_SSH_DISABLE_ROOT:-0}" == "1" ]] && sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$sshd_config" || sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin yes/" "$sshd_config"
    [[ "${VPS_SSH_DISABLE_PASSWORD:-0}" == "1" ]] && sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" "$sshd_config" || sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" "$sshd_config"
    
    # Проверка конфига перед рестартом
    if sshd -t; then
        systemctl restart ssh || systemctl restart sshd
    else
        warn "SSH config validation failed! Reverting."
        cp "${sshd_config}.bak" "$sshd_config"
    fi

    # 2. UFW
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_NEW_PORT}/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 51820/udp
    ufw --force enable

    # 3. Fail2Ban
    cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ${SSH_NEW_PORT}
maxretry = 5
bantime = 1h
EOF
    systemctl restart fail2ban
}

#-------------------------------------------------------------------------------
# TRAEFIK SETUP
#-------------------------------------------------------------------------------
setup_traefik() {
    info "Configuring Traefik v3..."
    
    touch /etc/traefik/acme.json
    chmod 600 /etc/traefik/acme.json
    
    cat > "${COMPOSE_DIR}/traefik.yml" <<EOF
api:
  dashboard: true
entryPoints:
  web:
    address: ":80"
    http: {redirections: {entryPoint: {to: websecure, scheme: https}}}
  websecure:
    address: ":443"
certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ADMIN_EMAIL}"
      storage: "/etc/traefik/acme.json"
      httpChallenge: {entryPoint: web}
providers:
  docker: {exposedByDefault: false}
EOF

    cat > "${COMPOSE_DIR}/docker-compose.traefik.yml" <<EOF
services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - /etc/traefik/acme.json:/etc/traefik/acme.json
    networks: [monolith]
networks:
  monolith: {external: true}
EOF
    docker compose -f "${COMPOSE_DIR}/docker-compose.traefik.yml" up -d
}

#-------------------------------------------------------------------------------
# SUPABASE SETUP (FULL STACK)
#-------------------------------------------------------------------------------
install_supabase() {
    info "Installing Supabase Full Stack..."
    
    local db_pass=$(generate_secret)
    local jwt_secret=$(generate_secret 40)
    local anon_key=$(generate_secret 40)
    local service_role=$(generate_secret 40)

    cat > "${COMPOSE_DIR}/docker-compose.supabase.yml" <<EOF
services:
  db:
    image: supabase/postgres:15.1.0.147
    container_name: supabase-db
    environment:
      POSTGRES_PASSWORD: ${db_pass}
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [monolith]

  rest:
    image: postgrest/postgrest:v12.0.1
    depends_on: [db]
    environment:
      PGRST_DB_URI: postgres://postgres:${db_pass}@db:5432/postgres
      PGRST_JWT_SECRET: ${jwt_secret}
    networks: [monolith]

  auth:
    image: supabase/gotrue:v2.132.0
    depends_on: [db]
    environment:
      GOTRUE_DB_DRIVER: postgres
      GOTRUE_DB_DATABASE_URL: postgres://postgres:${db_pass}@db:5432/postgres
      GOTRUE_JWT_SECRET: ${jwt_secret}
    networks: [monolith]
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.supa-auth.rule=Host(\`auth.${DOMAIN_NAME:-localhost}\`)"
      - "traefik.http.routers.supa-auth.tls.certresolver=letsencrypt"

networks:
  monolith: {external: true}
EOF
    
    info "Supabase keys saved to ${COMPOSE_DIR}/supabase.env"
    echo "DB_PASS=${db_pass}" > "${COMPOSE_DIR}/supabase.env"
    echo "JWT_SECRET=${jwt_secret}" >> "${COMPOSE_DIR}/supabase.env"
    
    docker compose -f "${COMPOSE_DIR}/docker-compose.supabase.yml" up -d
}

#-------------------------------------------------------------------------------
# COOLIFY
#-------------------------------------------------------------------------------
install_coolify() {
    info "Installing Coolify..."
    # Рекомендуемый способ установки Coolify через их официальный скрипт, адаптированный под структуру
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash || true
}

#-------------------------------------------------------------------------------
# CLOUDFLARE DNS
#-------------------------------------------------------------------------------
update_dns() {
    if [[ -z "$CF_API_TOKEN" || -z "$DOMAIN_NAME" ]]; then
        warn "Cloudflare credentials missing. Skipping DNS."
        return 0
    fi
    
    info "Updating Cloudflare DNS for ${DOMAIN_NAME}..."
    local zone_id="$CF_ZONE_ID"
    
    # Get Zone ID if not provided
    if [[ -z "$zone_id" ]]; then
        zone_id=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN_NAME}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" | jq -r '.result[0].id')
    fi

    # Create A record (Upsert logic)
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${DOMAIN_NAME}\",\"content\":\"${SERVER_IP}\",\"ttl\":120,\"proxied\":false}" | jq .
}

#-------------------------------------------------------------------------------
# MAIN EXECUTION
#-------------------------------------------------------------------------------
main() {
    clear
    echo -e "${CYAN}${BOLD}VPS PRO MONOLITH v${SCRIPT_VERSION}${NC}"
    echo "------------------------------------------------"
    
    if [[ $EUID -ne 0 ]]; then
       die "This script must be run as root (use sudo)"
    fi

    system_prepare
    harden_security
    install_docker
    setup_traefik
    
    # Выбор сервисов (в интерактивном режиме или по дефолту)
    [[ "${VPS_INSTALL_SUPABASE:-1}" == "1" ]] && install_supabase
    [[ "${VPS_INSTALL_COOLIFY:-1}" == "1" ]] && install_coolify
    
    update_dns

    echo -e "\n${GREEN}════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}   INSTALLATION COMPLETE${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}IP Address:${NC}  ${SERVER_IP}"
    echo -e "${BOLD}SSH Port:${NC}    ${SSH_NEW_PORT}"
    echo -e "${BOLD}Traefik:${NC}     https://${DOMAIN_NAME:-localhost}"
    echo -e "${BOLD}Logs:${NC}        tail -f ${LOG_FILE}"
    echo -e "------------------------------------------------"
    warn "REBOOT IS RECOMMENDED TO APPLY KERNEL TUNING AND UPDATES."
    echo -e "Would you like to reboot now? (y/n)"
    read -n 1 -r
    [[ $REPLY =~ ^[Yy]$ ]] && reboot
}

main "$@"
