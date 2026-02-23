#!/bin/bash
#===============================================================================
# VPS PRO MONOLITH — One-Shot Private Cloud Bootstrap
# Ubuntu 22.04 / 24.04 | Docker | Traefik | Coolify | Supabase | Monitoring
# License: MIT | Author: @sheikerdc-del
# Version: 1.0.1 (FIXED)
#===============================================================================

# Отключаем строгий режим для стабильности
set +e
set +u
set +o pipefail

#-------------------------------------------------------------------------------
# VERSION & CONSTANTS
#-------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.1"
readonly SCRIPT_NAME="vps_monolith"
readonly LOG_FILE="/var/log/${SCRIPT_NAME}.log"
readonly BACKUP_DIR="/opt/monolith-backups"
readonly COMPOSE_DIR="/opt/monolith"

# Default ports
readonly SSH_NEW_PORT="${VPS_SSH_PORT:-2222}"
readonly TRAEFIK_HTTP_PORT=80
readonly TRAEFIK_HTTPS_PORT=443
readonly COOLIFY_PORT=8000
readonly SUPABASE_PORT=54321
readonly PORTAINER_PORT=9443
readonly UPTIME_KUMA_PORT=3001
readonly MTPROTO_PORT=8443

# Default services
DEFAULT_SERVICES=("docker" "traefik" "coolify" "supabase" "monitoring" "security" "devstack" "backups")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

#-------------------------------------------------------------------------------
# GLOBAL VARIABLES
#-------------------------------------------------------------------------------
UNATTENDED="${VPS_UNATTENDED:-0}"
SKIP_TUI="${VPS_SKIP_TUI:-0}"
SKIP_CONFIRM="${VPS_SKIP_CONFIRM:-0}"
DRY_RUN="${VPS_DRY_RUN:-0}"
TG_TOKEN="${VPS_TG_TOKEN:-}"
TG_CHAT="${VPS_TG_CHAT:-}"
CF_API_TOKEN="${VPS_CF_TOKEN:-}"
CF_ZONE_ID="${VPS_CF_ZONE:-}"
DOMAIN_NAME="${VPS_DOMAIN:-}"
ADMIN_EMAIL="${VPS_ADMIN_EMAIL:-}"
LOG_LEVEL="${VPS_LOG_LEVEL:-INFO}"
SWAP_SIZE="${VPS_SWAP_SIZE:-4G}"
SKIP_DNS="${VPS_SKIP_DNS:-0}"

# Service toggles
INSTALL_DOCKER="${VPS_INSTALL_DOCKER:-1}"
INSTALL_TRAEFIK="${VPS_INSTALL_TRAEFIK:-1}"
INSTALL_COOLIFY="${VPS_INSTALL_COOLIFY:-1}"
INSTALL_SUPABASE="${VPS_INSTALL_SUPABASE:-1}"
INSTALL_MONITORING="${VPS_INSTALL_MONITORING:-1}"
INSTALL_SECURITY="${VPS_INSTALL_SECURITY:-1}"
INSTALL_DEVSTACK="${VPS_INSTALL_DEVSTACK:-1}"
INSTALL_BACKUPS="${VPS_INSTALL_BACKUPS:-1}"
INSTALL_MTPROTO="${VPS_INSTALL_MTPROTO:-0}"

# Security options
SSH_DISABLE_ROOT="${VPS_SSH_DISABLE_ROOT:-1}"
SSH_DISABLE_PASSWORD="${VPS_SSH_DISABLE_PASSWORD:-1}"
UFW_ENABLE="${VPS_UFW_ENABLE:-1}"
FAIL2BAN_ENABLE="${VPS_FAIL2BAN_ENABLE:-1}"
AUTO_UPDATES="${VPS_AUTO_UPDATES:-1}"

# Runtime
SELECTED_SERVICES=()
SERVER_IP=""
HOSTNAME=""
INSTALLATION_START_TIME=""

#-------------------------------------------------------------------------------
# LOGGING
#-------------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo -e "$msg" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "$msg"
}

info()  { log "INFO" "${BLUE}ℹ${NC} $@"; }
warn()  { log "WARN" "${YELLOW}⚠${NC} $*"; }
error() { log "ERROR" "${RED}✗${NC} $*"; }
success(){ log "INFO" "${GREEN}✓${NC} ${GREEN}$*${NC}"; }
step()  { log "INFO" "${MAGENTA}▶${NC} ${BOLD}$*${NC}"; }

die() {
    error "$@"
    notify_telegram "❌ Installation Failed: $*" 2>/dev/null || true
    exit 1
}

command_exists() { command -v "$1" &>/dev/null; }

#-------------------------------------------------------------------------------
# TELEGRAM
#-------------------------------------------------------------------------------
notify_telegram() {
    [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]] && return 0
    local msg="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT}" \
        -d text="${msg}" \
        -d parse_mode="Markdown" \
        --connect-timeout 5 &>/dev/null || true
}

#-------------------------------------------------------------------------------
# UTILS
#-------------------------------------------------------------------------------
get_public_ip() {
    curl -s4m10 https://ifconfig.me/ip 2>/dev/null || \
    curl -s4m10 https://api.ipify.org 2>/dev/null || \
    hostname -I | awk '{print $1}' || echo "127.0.0.1"
}

generate_secret() {
    openssl rand -base64 32 2>/dev/null | tr -d '\n' || \
    head -c 32 /dev/urandom | base64 | tr -d '\n'
}

generate_jwt_secret() {
    openssl rand -hex 32 2>/dev/null || \
    head -c 32 /dev/urandom | xxd -p 2>/dev/null | tr -d '\n'
}

is_valid_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

#-------------------------------------------------------------------------------
# CONFIG PARSER
#-------------------------------------------------------------------------------
parse_config() {
    step "Parsing configuration"
    
    # Dry run
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\n${YELLOW}🔍 DRY RUN MODE${NC}\n"
    fi
    
    # Build service list
    if [[ -n "${VPS_SERVICES:-}" ]]; then
        IFS=',' read -ra SELECTED_SERVICES <<< "${VPS_SERVICES}"
        info "Using services from VPS_SERVICES: ${SELECTED_SERVICES[*]}"
    elif [[ "$SKIP_TUI" == "1" || "$UNATTENDED" == "1" ]]; then
        SELECTED_SERVICES=("${DEFAULT_SERVICES[@]}")
        info "Using default services"
    fi
    
    # Apply overrides
    apply_service_overrides
    
    # Generate secrets
    COOLIFY_DB_PASS="${VPS_COOLIFY_DB_PASS:-$(generate_secret)}"
    SUPABASE_JWT_SECRET="${VPS_SUPABASE_JWT_SECRET:-$(generate_jwt_secret)}"
    SUPABASE_ANON_KEY="${VPS_SUPABASE_ANON_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.$(generate_secret 20).$(generate_secret 20)}"
    SUPABASE_SERVICE_KEY="${VPS_SUPABASE_SERVICE_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.$(generate_secret 20).$(generate_secret 20)}"
    SUPABASE_DB_PASS="${VPS_SUPABASE_DB_PASS:-$(generate_secret)}"
    
    success "Configuration parsed"
    return 0
}

apply_service_overrides() {
    local overrides=(
        "DOCKER:INSTALL_DOCKER"
        "TRAEFIK:INSTALL_TRAEFIK"
        "COOLIFY:INSTALL_COOLIFY"
        "SUPABASE:INSTALL_SUPABASE"
        "MONITORING:INSTALL_MONITORING"
        "SECURITY:INSTALL_SECURITY"
        "DEVSTACK:INSTALL_DEVSTACK"
        "BACKUPS:INSTALL_BACKUPS"
        "MTPROTO:INSTALL_MTPROTO"
    )
    
    for pair in "${overrides[@]}"; do
        local svc="${pair%%:*}"
        local var="${pair##*:}"
        local val="${!var:-1}"
        local svc_lower="${svc,,}"
        
        if [[ "$val" == "0" ]]; then
            local new_services=()
            for s in "${SELECTED_SERVICES[@]}"; do
                [[ "$s" != "$svc_lower" ]] && new_services+=("$s")
            done
            SELECTED_SERVICES=("${new_services[@]}")
        elif [[ "$val" == "1" ]]; then
            local found=0
            for s in "${SELECTED_SERVICES[@]}"; do
                [[ "$s" == "$svc_lower" ]] && found=1 && break
            done
            [[ $found -eq 0 ]] && SELECTED_SERVICES+=("$svc_lower")
        fi
    done
    return 0
}

validate_config() {
    step "Validating configuration"
    local errors=0
    
    if [[ -n "$CF_API_TOKEN" && -z "$CF_ZONE_ID" ]]; then
        error "VPS_CF_TOKEN set but VPS_CF_ZONE missing"
        ((errors++))
    fi
    
    if [[ -n "$TG_TOKEN" && -z "$TG_CHAT" ]]; then
        error "VPS_TG_TOKEN set but VPS_TG_CHAT missing"
        ((errors++))
    fi
    
    if [[ -n "$DOMAIN_NAME" ]] && ! is_valid_domain "$DOMAIN_NAME"; then
        error "Invalid domain: $DOMAIN_NAME"
        ((errors++))
    fi
    
    if [[ "$UNATTENDED" == "1" && ${#SELECTED_SERVICES[@]} -eq 0 ]]; then
        error "No services selected"
        ((errors++))
    fi
    
    if [[ $errors -gt 0 ]]; then
        die "Validation failed ($errors errors)"
    fi
    
    success "Configuration validated"
    return 0
}

show_installation_plan() {
    echo -e "\n${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   📋 INSTALLATION PLAN                 ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}\n"
    
    echo -e "${BOLD}Server:${NC} ${SERVER_IP}"
    echo -e "${BOLD}Domain:${NC} ${DOMAIN_NAME:-<none>}"
    echo -e "${BOLD}Services:${NC} ${SELECTED_SERVICES[*]}"
    echo
    
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "${YELLOW}🔍 DRY RUN — Run with VPS_DRY_RUN=0${NC}\n"
        return 0
    fi
    
    echo -e "${GREEN}🚀 Ready to install${NC}\n"
    return 0
}

#-------------------------------------------------------------------------------
# SYSTEM PREP
#-------------------------------------------------------------------------------
system_prepare() {
    step "System preparation"
    
    apt-get update -qq 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq 2>/dev/null
    
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget gnupg2 ca-certificates lsb-release \
        software-properties-common apt-transport-https jq \
        netcat-openbsd 2>/dev/null || true
    
    HOSTNAME="${VPS_HOSTNAME:-vps-monolith-$(head -c 8 /dev/urandom | xxd -p 2>/dev/null || echo $$)}"
    hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
    
    timedatectl set-timezone UTC 2>/dev/null || true
    
    mkdir -p "$COMPOSE_DIR" "$BACKUP_DIR/postgres" "/etc/traefik" "/var/log/traefik"
    
    success "System prepared (${HOSTNAME})"
}

setup_swap() {
    [[ "$SWAP_SIZE" == "0" ]] && return 0
    [[ -f /swapfile ]] && return 0
    
    step "Setting up swap (${SWAP_SIZE})"
    
    fallocate -l "${SWAP_SIZE}" /swapfile 2>/dev/null || \
        dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none 2>/dev/null
    
    chmod 600 /swapfile
    mkswap /swapfile 2>/dev/null
    swapon /swapfile 2>/dev/null
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    
    success "Swap configured"
}

#-------------------------------------------------------------------------------
# SSH HARDENING
#-------------------------------------------------------------------------------
harden_ssh() {
    [[ "$INSTALL_SECURITY" != "1" ]] && return 0
    
    step "Hardening SSH"
    
    local sshd_config="/etc/ssh/sshd_config"
    cp "$sshd_config" "${sshd_config}.monolith.bak" 2>/dev/null || true
    
    if [[ "$SSH_NEW_PORT" != "22" ]]; then
        grep -q "^Port ${SSH_NEW_PORT}$" "$sshd_config" 2>/dev/null || \
            echo "Port ${SSH_NEW_PORT}" >> "$sshd_config"
    fi
    
    [[ "$SSH_DISABLE_ROOT" == "1" ]] && echo "PermitRootLogin no" >> "$sshd_config"
    [[ "$SSH_DISABLE_PASSWORD" == "1" ]] && echo "PasswordAuthentication no" >> "$sshd_config"
    echo "PubkeyAuthentication yes" >> "$sshd_config"
    echo "X11Forwarding no" >> "$sshd_config"
    echo "MaxAuthTries 3" >> "$sshd_config"
    
    if command_exists sshd; then
        sshd -t 2>/dev/null && systemctl reload sshd 2>/dev/null || true
        success "SSH hardened (port: ${SSH_NEW_PORT})"
        warn "⚠️ Keep current session open!"
    fi
}

#-------------------------------------------------------------------------------
# FIREWALL
#-------------------------------------------------------------------------------
setup_firewall() {
    [[ "$INSTALL_SECURITY" != "1" || "$UFW_ENABLE" != "1" ]] && return 0
    
    step "Configuring firewall"
    
    if ! command_exists ufw; then
        apt-get install -y -qq ufw 2>/dev/null
    fi
    
    ufw --force reset &>/dev/null
    ufw default deny incoming
    ufw default allow outgoing
    
    ufw allow "${SSH_NEW_PORT}/tcp" 2>/dev/null
    ufw allow "80/tcp" 2>/dev/null
    ufw allow "443/tcp" 2>/dev/null
    ufw allow "${COOLIFY_PORT}/tcp" 2>/dev/null
    ufw allow "${PORTAINER_PORT}/tcp" 2>/dev/null
    ufw allow "${UPTIME_KUMA_PORT}/tcp" 2>/dev/null
    ufw allow "${SUPABASE_PORT}/tcp" 2>/dev/null
    
    ufw --force enable 2>/dev/null || true
    
    if [[ "$FAIL2BAN_ENABLE" == "1" ]]; then
        apt-get install -y -qq fail2ban 2>/dev/null || true
        systemctl enable --now fail2ban 2>/dev/null || true
    fi
    
    success "Firewall configured"
}

setup_auto_updates() {
    [[ "$INSTALL_SECURITY" != "1" || "$AUTO_UPDATES" != "1" ]] && return 0
    
    step "Enabling auto updates"
    
    apt-get install -y -qq unattended-upgrades 2>/dev/null || true
    systemctl enable --now unattended-upgrades 2>/dev/null || true
    
    success "Auto-updates enabled"
}

#-------------------------------------------------------------------------------
# DOCKER
#-------------------------------------------------------------------------------
install_docker() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " docker " ]] && return 0
    
    step "Installing Docker"
    
    if command_exists docker; then
        info "Docker already installed"
        return 0
    fi
    
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-compose-plugin 2>/dev/null
    
    usermod -aG docker "$SUDO_USER" 2>/dev/null || true
    
    cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
EOF
    
    systemctl enable --now docker 2>/dev/null || true
    
    success "Docker installed"
}

#-------------------------------------------------------------------------------
# TRAEFIK
#-------------------------------------------------------------------------------
setup_traefik() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " traefik " ]] && return 0
    
    step "Setting up Traefik"
    
    [[ -z "$ADMIN_EMAIL" ]] && ADMIN_EMAIL="admin@${DOMAIN_NAME:-localhost}"
    
    cat > "${COMPOSE_DIR}/traefik.yml" << EOF
api:
  dashboard: true
  insecure: true

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
    http:
      tls:
        certResolver: letsencrypt

certificatesResolvers:
  letsencrypt:
    acme:
      email: "${ADMIN_EMAIL}"
      storage: /etc/traefik/acme.json
      httpChallenge:
        entryPoint: web

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    filename: /etc/traefik/dynamic.yml
    watch: true

log:
  level: INFO
EOF
    
    touch /etc/traefik/acme.json && chmod 600 /etc/traefik/acme.json
    touch /etc/traefik/dynamic.yml
    
    cat > "${COMPOSE_DIR}/docker-compose.traefik.yml" << EOF
version: '3.8'
services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - /etc/traefik:/etc/traefik
      - /var/log/traefik:/var/log/traefik
    networks:
      - monolith

networks:
  monolith:
    external: true
EOF
    
    docker network create monolith 2>/dev/null || true
    
    cd "$COMPOSE_DIR"
    docker compose -f docker-compose.traefik.yml up -d --quiet-pull 2>/dev/null
    
    success "Traefik configured"
}

#-------------------------------------------------------------------------------
# COOLIFY
#-------------------------------------------------------------------------------
install_coolify() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " coolify " ]] && return 0
    
    step "Installing Coolify"
    
    cat > "${COMPOSE_DIR}/docker-compose.coolify.yml" << EOF
version: '3.8'
services:
  coolify:
    image: ghcr.io/coollabsio/coolify:latest
    container_name: coolify
    restart: unless-stopped
    ports:
      - "8000:80"
    volumes:
      - coolify-data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - APP_ENV=production
      - DB_PASSWORD=${COOLIFY_DB_PASS}
    networks:
      - monolith
    depends_on:
      - postgres

  postgres:
    image: postgres:15-alpine
    container_name: coolify-postgres
    restart: unless-stopped
    volumes:
      - coolify-pgdata:/var/lib/postgresql/data
    environment:
      - POSTGRES_DB=coolify
      - POSTGRES_USER=coolify
      - POSTGRES_PASSWORD=${COOLIFY_DB_PASS}
    networks:
      - monolith

volumes:
  coolify-data:
  coolify-pgdata:

networks:
  monolith:
    external: true
EOF
    
    cd "$COMPOSE_DIR"
    docker compose -f docker-compose.coolify.yml up -d --quiet-pull 2>/dev/null
    
    success "Coolify: http://${SERVER_IP}:8000"
}

#-------------------------------------------------------------------------------
# MONITORING
#-------------------------------------------------------------------------------
install_monitoring() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] && return 0
    
    step "Installing monitoring"
    
    cat > "${COMPOSE_DIR}/docker-compose.monitoring.yml" << EOF
version: '3.8'
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - "9443:9443"
    volumes:
      - portainer-data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - monolith

  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "3001:3001"
    volumes:
      - kuma-/app/data
    networks:
      - monolith

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_POLL_INTERVAL=86400
      - WATCHTOWER_CLEANUP=true
    networks:
      - monolith

volumes:
  portainer-
  kuma-

networks:
  monolith:
    external: true
EOF
    
    cd "$COMPOSE_DIR"
    docker compose -f docker-compose.monitoring.yml up -d --quiet-pull 2>/dev/null
    
    success "Monitoring installed"
}

#-------------------------------------------------------------------------------
# BACKUPS
#-------------------------------------------------------------------------------
setup_backups() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " backups " ]] && return 0
    
    step "Configuring backups"
    
    cat > /usr/local/bin/monolith-pg-backup << 'EOF'
#!/bin/bash
BACKUP_DIR="/opt/monolith-backups/postgres"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR"
docker exec supabase-postgres pg_dump -U postgres 2>/dev/null | \
    gzip > "${BACKUP_DIR}/backup_${DATE}.sql.gz"
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete 2>/dev/null
EOF
    chmod +x /usr/local/bin/monolith-pg-backup
    
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/monolith-pg-backup") | crontab - 2>/dev/null
    
    success "Backups configured"
}

#-------------------------------------------------------------------------------
# CLOUDFLARE DNS
#-------------------------------------------------------------------------------
update_cloudflare_dns() {
    [[ "$SKIP_DNS" == "1" ]] && return 0
    [[ -z "$CF_API_TOKEN" || -z "$CF_ZONE_ID" || -z "$DOMAIN_NAME" ]] && return 0
    
    step "Updating Cloudflare DNS"
    
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"${DOMAIN_NAME}\",\"content\":\"${SERVER_IP}\",\"ttl\":120,\"proxied\":true}" \
        &>/dev/null && success "Cloudflare DNS updated" || warn "Cloudflare update failed"
}

#-------------------------------------------------------------------------------
# SUMMARY
#-------------------------------------------------------------------------------
show_summary() {
    local duration=$(( $(date +%s) - INSTALLATION_START_TIME ))
    
    clear
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✅ INSTALLATION COMPLETE             ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Server:${NC} ${HOSTNAME} (${SERVER_IP})"
    echo -e "${BOLD}Duration:${NC} ${duration}s"
    echo
    echo -e "${YELLOW}🔐 Access:${NC}"
    echo "  SSH:          ssh -p ${SSH_NEW_PORT} root@${SERVER_IP}"
    [[ " ${SELECTED_SERVICES[*]} " =~ " coolify " ]] && echo "  Coolify:      http://${SERVER_IP}:8000"
    [[ " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] && echo "  Portainer:    https://${SERVER_IP}:9443"
    [[ " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] && echo "  Uptime Kuma:  http://${SERVER_IP}:3001"
    echo
    echo -e "${YELLOW}📁 Paths:${NC}"
    echo "  Compose:      ${COMPOSE_DIR}/"
    echo "  Backups:      ${BACKUP_DIR}/"
    echo "  Logs:         ${LOG_FILE}"
    echo
    echo -e "${GREEN}🎉 Private cloud ready!${NC}"
    
    notify_telegram "✅ **Monolith Installation Complete**

Host: \`${HOSTNAME}\`
IP: \`${SERVER_IP}\`
Duration: ${duration}s

🔗 Services:
• Coolify: http://${SERVER_IP}:8000
• Portainer: https://${SERVER_IP}:9443" 2>/dev/null || true
}

#-------------------------------------------------------------------------------
# MAIN
#-------------------------------------------------------------------------------
run_installation() {
    INSTALLATION_START_TIME=$(date +%s)
    
    info "Starting VPS PRO MONOLITH v${SCRIPT_VERSION}"
    notify_telegram "🚀 **Monolith Installation Started**

Host: \`${SERVER_IP}\`
Time: $(date '+%Y-%m-%d %H:%M:%S')" 2>/dev/null || true
    
    system_prepare
    setup_swap
    
    [[ " ${SELECTED_SERVICES[*]} " =~ " security " ]] && {
        harden_ssh
        setup_firewall
        setup_auto_updates
    }
    
    install_docker
    setup_traefik
    install_coolify
    install_monitoring
    setup_backups
    
    update_cloudflare_dns
    
    show_summary
}

main() {
    [[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"
    
    mkdir -p "$(dirname "$LOG_FILE")"
    SERVER_IP="$(get_public_ip)"
    
    echo -e "${CYAN}${BOLD}VPS PRO MONOLITH v${SCRIPT_VERSION}${NC}"
    echo -e "Server: ${SERVER_IP}"
    echo
    
    parse_config
    validate_config
    
    if [[ "$DRY_RUN" == "1" ]]; then
        show_installation_plan
        exit 0
    fi
    
    show_installation_plan
    
    if [[ "$SKIP_TUI" != "1" && "$UNATTENDED" != "1" ]]; then
        read -p $'\nProceed? [y/N] ' -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && echo "Cancelled." && exit 0
    fi
    
    run_installation
}

main "$@"
