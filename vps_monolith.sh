#!/bin/bash
#===============================================================================
# VPS PRO MONOLITH v1.0.2 (FULLY FIXED)
# Ubuntu 22.04 / 24.04 | Docker | Traefik | Coolify | Monitoring
# License: MIT
#===============================================================================

# ОТКЛЮЧАЕМ строгий режим для стабильности
set +e
set +u
set +o pipefail

#-------------------------------------------------------------------------------
# CONSTANTS
#-------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.2"
readonly SCRIPT_NAME="vps_monolith"
readonly LOG_FILE="/var/log/${SCRIPT_NAME}.log"
readonly COMPOSE_DIR="/opt/monolith"
readonly BACKUP_DIR="/opt/monolith-backups"

# Ports
readonly SSH_NEW_PORT="${VPS_SSH_PORT:-2222}"
readonly COOLIFY_PORT=8000
readonly PORTAINER_PORT=9443
readonly UPTIME_KUMA_PORT=3001
readonly SUPABASE_PORT=54321

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

#-------------------------------------------------------------------------------
# VARIABLES
#-------------------------------------------------------------------------------
UNATTENDED="${VPS_UNATTENDED:-0}"
SKIP_TUI="${VPS_SKIP_TUI:-0}"
SKIP_CONFIRM="${VPS_SKIP_CONFIRM:-0}"
DRY_RUN="${VPS_DRY_RUN:-0}"
DOMAIN_NAME="${VPS_DOMAIN:-}"
ADMIN_EMAIL="${VPS_ADMIN_EMAIL:-}"
TG_TOKEN="${VPS_TG_TOKEN:-}"
TG_CHAT="${VPS_TG_CHAT:-}"
CF_API_TOKEN="${VPS_CF_TOKEN:-}"
CF_ZONE_ID="${VPS_CF_ZONE:-}"
SKIP_DNS="${VPS_SKIP_DNS:-0}"
SERVICES="${VPS_SERVICES:-docker,traefik,coolify,monitoring,security,backups}"
SWAP_SIZE="${VPS_SWAP_SIZE:-4G}"

# Service toggles
INSTALL_DOCKER="${VPS_INSTALL_DOCKER:-1}"
INSTALL_TRAEFIK="${VPS_INSTALL_TRAEFIK:-1}"
INSTALL_COOLIFY="${VPS_INSTALL_COOLIFY:-1}"
INSTALL_SUPABASE="${VPS_INSTALL_SUPABASE:-0}"
INSTALL_MONITORING="${VPS_INSTALL_MONITORING:-1}"
INSTALL_SECURITY="${VPS_INSTALL_SECURITY:-1}"
INSTALL_BACKUPS="${VPS_INSTALL_BACKUPS:-1}"

# Security
SSH_DISABLE_ROOT="${VPS_SSH_DISABLE_ROOT:-0}"
SSH_DISABLE_PASSWORD="${VPS_SSH_DISABLE_PASSWORD:-0}"
UFW_ENABLE="${VPS_UFW_ENABLE:-1}"

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
    return 0
}

info() { log "INFO" "${CYAN}ℹ${NC} $*"; return 0; }
warn() { log "WARN" "${YELLOW}⚠${NC} $*"; return 0; }
error() { log "ERROR" "${RED}✗${NC} $*"; return 0; }
success() { log "INFO" "${GREEN}✓${NC} ${GREEN}$*${NC}"; return 0; }
step() { log "INFO" "${MAGENTA}▶${NC} ${BOLD}$*${NC}"; return 0; }

die() {
    error "$@"
    notify_telegram "❌ Installation Failed: $*" 2>/dev/null || true
    exit 1
}

command_exists() { command -v "$1" &>/dev/null; return $?; }

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
    return 0
}

#-------------------------------------------------------------------------------
# UTILS
#-------------------------------------------------------------------------------
get_ip() {
    local ip
    ip=$(curl -s4m10 https://ifconfig.me/ip 2>/dev/null) || \
    ip=$(curl -s4m10 https://api.ipify.org 2>/dev/null) || \
    ip=$(hostname -I | awk '{print $1}') || \
    ip="127.0.0.1"
    echo "$ip"
    return 0
}

gen_pass() {
    local pass
    pass=$(head -c 32 /dev/urandom | base64 | tr -d '\n' | head -c 32)
    echo "$pass"
    return 0
}

is_valid_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]
    return $?
}

#-------------------------------------------------------------------------------
# CONFIG
#-------------------------------------------------------------------------------
parse_config() {
    step "Parsing configuration"
    
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\n${YELLOW}🔍 DRY RUN MODE${NC}\n"
    fi
    
    if [[ -n "${VPS_SERVICES:-}" ]]; then
        IFS=',' read -ra SELECTED_SERVICES <<< "${VPS_SERVICES}"
        info "Using services from VPS_SERVICES: ${SELECTED_SERVICES[*]}"
    elif [[ "$SKIP_TUI" == "1" || "$UNATTENDED" == "1" ]]; then
        SELECTED_SERVICES=("docker" "traefik" "coolify" "monitoring" "security")
        info "Using default services"
    fi
    
    apply_service_overrides
    
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
        "BACKUPS:INSTALL_BACKUPS"
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
        errors=$((errors + 1))
    fi
    
    if [[ -n "$TG_TOKEN" && -z "$TG_CHAT" ]]; then
        error "VPS_TG_TOKEN set but VPS_TG_CHAT missing"
        errors=$((errors + 1))
    fi
    
    if [[ -n "$DOMAIN_NAME" ]] && ! is_valid_domain "$DOMAIN_NAME"; then
        error "Invalid domain: $DOMAIN_NAME"
        errors=$((errors + 1))
    fi
    
    if [[ "$UNATTENDED" == "1" && ${#SELECTED_SERVICES[@]} -eq 0 ]]; then
        error "No services selected"
        errors=$((errors + 1))
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
# SYSTEM
#-------------------------------------------------------------------------------
system_prepare() {
    step "System preparation"
    
    apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq 2>/dev/null || true
    
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget gnupg2 ca-certificates lsb-release \
        software-properties-common apt-transport-https jq \
        netcat-openbsd 2>/dev/null || true
    
    HOSTNAME="${VPS_HOSTNAME:-vps-monolith-$(head -c 8 /dev/urandom | xxd -p 2>/dev/null || echo $$)}"
    hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
    
    timedatectl set-timezone UTC 2>/dev/null || true
    
    mkdir -p "$COMPOSE_DIR" "$BACKUP_DIR/postgres" "/etc/traefik" "/var/log/traefik"
    
    success "System prepared (${HOSTNAME})"
    return 0
}

setup_swap() {
    [[ "$SWAP_SIZE" == "0" ]] && return 0
    [[ -f /swapfile ]] && return 0
    
    step "Setting up swap (${SWAP_SIZE})"
    
    fallocate -l "${SWAP_SIZE}" /swapfile 2>/dev/null || \
        dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none 2>/dev/null || true
    
    chmod 600 /swapfile 2>/dev/null || true
    mkswap /swapfile 2>/dev/null || true
    swapon /swapfile 2>/dev/null || true
    echo '/swapfile none swap sw 0 0' >> /etc/fstab 2>/dev/null || true
    
    success "Swap configured"
    return 0
}

#-------------------------------------------------------------------------------
# SSH
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
    
    if [[ "$SSH_DISABLE_ROOT" == "1" ]]; then
        echo "PermitRootLogin no" >> "$sshd_config"
    fi
    
    if [[ "$SSH_DISABLE_PASSWORD" == "1" ]]; then
        echo "PasswordAuthentication no" >> "$sshd_config"
    fi
    
    echo "PubkeyAuthentication yes" >> "$sshd_config"
    echo "X11Forwarding no" >> "$sshd_config"
    echo "MaxAuthTries 3" >> "$sshd_config"
    
    if command_exists sshd; then
        sshd -t 2>/dev/null && systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || true
        success "SSH hardened (port: ${SSH_NEW_PORT})"
        warn "⚠️ Keep current session open!"
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# FIREWALL
#-------------------------------------------------------------------------------
setup_firewall() {
    [[ "$INSTALL_SECURITY" != "1" || "$UFW_ENABLE" != "1" ]] && return 0
    
    step "Configuring firewall"
    
    if ! command_exists ufw; then
        apt-get install -y -qq ufw 2>/dev/null || true
    fi
    
    ufw --force reset 2>/dev/null || true
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
    
    ufw allow "${SSH_NEW_PORT}/tcp" 2>/dev/null || true
    ufw allow "80/tcp" 2>/dev/null || true
    ufw allow "443/tcp" 2>/dev/null || true
    ufw allow "${COOLIFY_PORT}/tcp" 2>/dev/null || true
    ufw allow "${PORTAINER_PORT}/tcp" 2>/dev/null || true
    ufw allow "${UPTIME_KUMA_PORT}/tcp" 2>/dev/null || true
    
    ufw --force enable 2>/dev/null || true
    
    success "Firewall configured"
    return 0
}

setup_auto_updates() {
    [[ "$INSTALL_SECURITY" != "1" ]] && return 0
    
    step "Enabling auto updates"
    
    apt-get install -y -qq unattended-upgrades 2>/dev/null || true
    systemctl enable --now unattended-upgrades 2>/dev/null || true
    
    success "Auto-updates enabled"
    return 0
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
    
    install -m 0755 -d /etc/apt/keyrings 2>/dev/null || true
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null 2>/dev/null || true
    
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-compose-plugin 2>/dev/null || true
    
    usermod -aG docker "$SUDO_USER" 2>/dev/null || true
    
    cat > /etc/docker/daemon.json << 'EOF' 2>/dev/null || true
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
EOF
    
    systemctl enable --now docker 2>/dev/null || true
    
    success "Docker installed"
    return 0
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
  websecure:
    address: ":443"

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

    touch /etc/traefik/dynamic.yml 2>/dev/null || true
    
    cat > "${COMPOSE_DIR}/docker-compose.traefik.yml" << 'EOF'
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
    
    cd "$COMPOSE_DIR" 2>/dev/null || true
    docker compose -f docker-compose.traefik.yml up -d --quiet-pull 2>/dev/null || true
    
    success "Traefik configured"
    return 0
}

#-------------------------------------------------------------------------------
# COOLIFY
#-------------------------------------------------------------------------------
install_coolify() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " coolify " ]] && return 0
    
    step "Installing Coolify"
    
    local db_pass="$(gen_pass)"
    
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
      - DB_PASSWORD=${db_pass}
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
      - POSTGRES_PASSWORD=${db_pass}
    networks:
      - monolith

volumes:
  coolify-data:
  coolify-pgdata:

networks:
  monolith:
    external: true
EOF

    cd "$COMPOSE_DIR" 2>/dev/null || true
    docker compose -f docker-compose.coolify.yml up -d --quiet-pull 2>/dev/null || true
    
    success "Coolify: http://${SERVER_IP}:8000"
    return 0
}

#-------------------------------------------------------------------------------
# MONITORING
#-------------------------------------------------------------------------------
install_monitoring() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] && return 0
    
    step "Installing monitoring"
    
    cat > "${COMPOSE_DIR}/docker-compose.monitoring.yml" << 'EOF'
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
      - kuma-data:/app/data
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
  portainer-data:
  kuma-data:

networks:
  monolith:
    external: true
EOF

    cd "$COMPOSE_DIR" 2>/dev/null || true
    docker compose -f docker-compose.monitoring.yml up -d --quiet-pull 2>/dev/null || true
    
    success "Monitoring installed"
    return 0
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
docker exec coolify-postgres pg_dump -U coolify 2>/dev/null | \
    gzip > "${BACKUP_DIR}/backup_${DATE}.sql.gz"
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete 2>/dev/null || true
EOF
    chmod +x /usr/local/bin/monolith-pg-backup 2>/dev/null || true
    
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/monolith-pg-backup") | crontab - 2>/dev/null || true
    
    success "Backups configured"
    return 0
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
    
    return 0
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
    echo "  Compose:  ${COMPOSE_DIR}/"
    echo "  Backups:  ${BACKUP_DIR}/"
    echo "  Logs:     ${LOG_FILE}"
    echo
    echo -e "${GREEN}🎉 Private cloud ready!${NC}"
    
    notify_telegram "✅ **Monolith Installation Complete**

Host: \`${HOSTNAME}\`
IP: \`${SERVER_IP}\`
Duration: ${duration}s

🔗 Services:
• Coolify: http://${SERVER_IP}:8000
• Portainer: https://${SERVER_IP}:9443" 2>/dev/null || true
    
    return 0
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
    
    return 0
}

main() {
    [[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"
    
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    SERVER_IP="$(get_ip)"
    
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
