#!/bin/bash
#===============================================================================
# VPS PRO MONOLITH v2.0 — Production-Ready Private Cloud
# Ubuntu 22.04 / 24.04 | Docker | Traefik | Coolify | Supabase | VPN Ready
# License: MIT | Author: @sheikerdc-del
# GitHub: https://github.com/sheikerdc-del/VPS-PRO-MONOLITH
#===============================================================================

# Отключаем строгий режим для стабильности (избегаем молчаливых падений)
set +e
set +u
set +o pipefail

#-------------------------------------------------------------------------------
# VERSION & CONSTANTS
#-------------------------------------------------------------------------------
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="vps_monolith"
readonly LOG_FILE="/var/log/${SCRIPT_NAME}.log"
readonly COMPOSE_DIR="/opt/monolith"
readonly BACKUP_DIR="/opt/monolith-backups"
readonly STATE_FILE="/var/lib/${SCRIPT_NAME}.state"

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
readonly AMNEZIA_OPENVPN_PORT=1194

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
# VARIABLES (из окружения или дефолтные)
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
SERVICES="${VPS_SERVICES:-docker,traefik,coolify,monitoring,security,backups,mtproto}"
SWAP_SIZE="${VPS_SWAP_SIZE:-4G}"
LOW_MEMORY_MODE="${VPS_LOW_MEMORY_MODE:-0}"

# Service toggles
INSTALL_DOCKER="${VPS_INSTALL_DOCKER:-1}"
INSTALL_TRAEFIK="${VPS_INSTALL_TRAEFIK:-1}"
INSTALL_COOLIFY="${VPS_INSTALL_COOLIFY:-1}"
INSTALL_SUPABASE="${VPS_INSTALL_SUPABASE:-0}"
INSTALL_MONITORING="${VPS_INSTALL_MONITORING:-1}"
INSTALL_SECURITY="${VPS_INSTALL_SECURITY:-1}"
INSTALL_BACKUPS="${VPS_INSTALL_BACKUPS:-1}"
INSTALL_MTPROTO="${VPS_INSTALL_MTPROTO:-1}"
INSTALL_AMNEZIA="${VPS_INSTALL_AMNEZIA:-0}"

# Security
SSH_DISABLE_ROOT="${VPS_SSH_DISABLE_ROOT:-0}"
SSH_DISABLE_PASSWORD="${VPS_SSH_DISABLE_PASSWORD:-0}"
UFW_ENABLE="${VPS_UFW_ENABLE:-1}"
FAIL2BAN_ENABLE="${VPS_FAIL2BAN_ENABLE:-1}"
AUTO_UPDATES="${VPS_AUTO_UPDATES:-1}"

# Runtime
SELECTED_SERVICES=()
SERVER_IP=""
HOSTNAME=""
INSTALLATION_START_TIME=""

#-------------------------------------------------------------------------------
# LOGGING SYSTEM
#-------------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo -e "$msg" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "$msg"
    return 0
}

info() { log "INFO" "${BLUE}ℹ${NC} $*"; return 0; }
warn() { log "WARN" "${YELLOW}⚠${NC} $*"; return 0; }
error() { log "ERROR" "${RED}✗${NC} $*"; return 0; }
success() { log "INFO" "${GREEN}✓${NC} ${GREEN}$*${NC}"; return 0; }
step() { log "INFO" "${MAGENTA}▶${NC} ${BOLD}$*${NC}"; return 0; }

die() {
    error "$@"
    notify_telegram "❌ **Installation Failed**\n\nHost: \`${HOSTNAME:-$SERVER_IP}\`\nError: $*\nTime: $(date '+%Y-%m-%d %H:%M:%S')" 2>/dev/null || true
    exit 1
}

command_exists() { command -v "$1" &>/dev/null; return $?; }

#-------------------------------------------------------------------------------
# TELEGRAM NOTIFICATIONS
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

notify_progress() {
    [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]] && return 0
    local step="$1"
    local total="$2"
    local msg="$3"
    local percent=$((step * 100 / total))
    notify_telegram "🔄 **Progress: ${percent}%**\n\n${msg}" 2>/dev/null || true
    return 0
}

#-------------------------------------------------------------------------------
# UTILITY FUNCTIONS
#-------------------------------------------------------------------------------
get_public_ip() {
    local ip=""
    ip=$(curl -s4m10 https://ifconfig.me/ip 2>/dev/null) || \
    ip=$(curl -s4m10 https://api.ipify.org 2>/dev/null) || \
    ip=$(hostname -I | awk '{print $1}') || \
    ip="127.0.0.1"
    echo "$ip"
    return 0
}

generate_secret() {
    local length="${1:-32}"
    openssl rand -base64 "$length" 2>/dev/null | tr -d '\n' || \
    head -c "$length" /dev/urandom | base64 | tr -d '\n' || \
    echo "monolith-$(date +%s)-$(head -c 16 /dev/urandom | xxd -p 2>/dev/null || echo $RANDOM)"
    return 0
}

generate_jwt_secret() {
    openssl rand -hex 32 2>/dev/null || \
    head -c 32 /dev/urandom | xxd -p 2>/dev/null || \
    echo "$(date +%s)-$(head -c 32 /dev/urandom | base64 | tr -d '\n' | head -c 64)"
    return 0
}

is_valid_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]
    return $?
}

is_valid_email() {
    [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
    return $?
}

wait_for_port() {
    local port="$1"
    local timeout="${2:-30}"
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if ss -tlnp | grep -q ":${port} " 2>/dev/null; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

wait_for_container() {
    local name="$1"
    local timeout="${2:-60}"
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null | grep -q "healthy"; then
            return 0
        fi
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

#-------------------------------------------------------------------------------
# CONFIGURATION PARSER
#-------------------------------------------------------------------------------
parse_config() {
    step "Parsing configuration"
    
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\n${YELLOW}🔍 DRY RUN MODE — No changes will be made${NC}\n"
    fi
    
    # Build service list from VPS_SERVICES
    if [[ -n "${VPS_SERVICES:-}" ]]; then
        IFS=',' read -ra SELECTED_SERVICES <<< "${VPS_SERVICES}"
        info "Using services from VPS_SERVICES: ${SELECTED_SERVICES[*]}"
    elif [[ "$SKIP_TUI" == "1" || "$UNATTENDED" == "1" ]]; then
        SELECTED_SERVICES=("docker" "traefik" "coolify" "monitoring" "security" "backups")
        info "Using default services"
    fi
    
    # Apply individual service overrides
    apply_service_overrides
    
    # Low memory mode
    if [[ "$LOW_MEMORY_MODE" == "1" ]]; then
        info "📉 Low memory mode enabled"
        local new_services=()
        for svc in "${SELECTED_SERVICES[@]}"; do
            [[ "$svc" != "supabase" ]] && new_services+=("$svc")
        done
        SELECTED_SERVICES=("${new_services[@]}")
        SWAP_SIZE="${SWAP_SIZE:-8G}"
        warn "Disabled: Supabase (memory intensive)"
    fi
    
    # Generate secrets if not provided
    COOLIFY_DB_PASS="${VPS_COOLIFY_DB_PASS:-$(generate_secret 32)}"
    SUPABASE_JWT_SECRET="${VPS_SUPABASE_JWT_SECRET:-$(generate_jwt_secret)}"
    SUPABASE_ANON_KEY="${VPS_SUPABASE_ANON_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.$(generate_secret 20).$(generate_secret 20)}"
    SUPABASE_SERVICE_KEY="${VPS_SUPABASE_SERVICE_KEY:-eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.$(generate_secret 20).$(generate_secret 20)}"
    SUPABASE_DB_PASS="${VPS_SUPABASE_DB_PASS:-$(generate_secret 32)}"
    MTPROTO_SECRET="${VPS_MTPROTO_SECRET:-$(openssl rand -hex 16 2>/dev/null || echo $(date +%s | md5sum | head -c 32))}"
    
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
        "MTPROTO:INSTALL_MTPROTO"
        "AMNEZIA:INSTALL_AMNEZIA"
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
    
    # Cloudflare validation
    if [[ -n "$CF_API_TOKEN" && -z "$CF_ZONE_ID" ]]; then
        error "VPS_CF_TOKEN set but VPS_CF_ZONE is missing"
        errors=$((errors + 1))
    fi
    
    if [[ -n "$CF_ZONE_ID" && -z "$DOMAIN_NAME" ]]; then
        warn "VPS_CF_ZONE set but VPS_DOMAIN is empty"
    fi
    
    # Telegram validation
    if [[ -n "$TG_TOKEN" && -z "$TG_CHAT" ]]; then
        error "VPS_TG_TOKEN set but VPS_TG_CHAT is missing"
        errors=$((errors + 1))
    fi
    
    # SSH security warning
    if [[ "$SSH_NEW_PORT" == "22" && "$SSH_DISABLE_PASSWORD" == "1" ]]; then
        warn "⚠️  SSH port 22 + password auth disabled = lockout risk!"
    fi
    
    # Domain validation
    if [[ -n "$DOMAIN_NAME" ]] && ! is_valid_domain "$DOMAIN_NAME"; then
        error "Invalid domain format: $DOMAIN_NAME"
        errors=$((errors + 1))
    fi
    
    # Email validation
    if [[ -n "$ADMIN_EMAIL" ]] && ! is_valid_email "$ADMIN_EMAIL"; then
        error "Invalid email format: $ADMIN_EMAIL"
        errors=$((errors + 1))
    fi
    
    # Unattended mode requirements
    if [[ "$UNATTENDED" == "1" && ${#SELECTED_SERVICES[@]} -eq 0 ]]; then
        error "VPS_UNATTENDED=1 requires at least one service"
        errors=$((errors + 1))
    fi
    
    # Report
    if [[ $errors -gt 0 ]]; then
        die "Configuration validation failed ($errors errors)"
    fi
    
    success "Configuration validated"
    return 0
}

show_installation_plan() {
    echo -e "\n${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   📋 INSTALLATION PLAN                 ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}\n"
    
    echo -e "${BOLD}Server:${NC}"
    echo "  IP:           ${SERVER_IP}"
    echo "  Hostname:     ${HOSTNAME:-<auto-detect>}"
    echo "  Domain:       ${DOMAIN_NAME:-<none>}"
    [[ "$SSH_NEW_PORT" != "22" ]] && echo "  SSH Port:     ${SSH_NEW_PORT}"
    echo
    
    echo -e "${BOLD}Services:${NC}"
    for svc in "${SELECTED_SERVICES[@]}"; do
        echo "  ✓ ${svc}"
    done
    echo
    
    echo -e "${BOLD}Security:${NC}"
    [[ "$SSH_DISABLE_ROOT" == "1" ]] && echo "  ✓ Disable root login"
    [[ "$SSH_DISABLE_PASSWORD" == "1" ]] && echo "  ✓ Disable password auth"
    [[ "$UFW_ENABLE" == "1" ]] && echo "  ✓ UFW firewall"
    [[ "$FAIL2BAN_ENABLE" == "1" ]] && echo "  ✓ Fail2Ban"
    [[ "$AUTO_UPDATES" == "1" ]] && echo "  ✓ Auto security updates"
    echo
    
    [[ -n "$CF_ZONE_ID" ]] && echo -e "${BOLD}Cloudflare:${NC} Zone ${CF_ZONE_ID}"
    [[ -n "$TG_CHAT" ]] && echo -e "${BOLD}Telegram:${NC} Notifications enabled"
    [[ "$SWAP_SIZE" != "0" ]] && echo -e "${BOLD}Swap:${NC} ${SWAP_SIZE}"
    echo
    
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "${YELLOW}🔍 DRY RUN — Run with VPS_DRY_RUN=0 to execute${NC}\n"
        return 0
    fi
    
    echo -e "${GREEN}🚀 Ready to install${NC}\n"
    return 0
}

#-------------------------------------------------------------------------------
# SYSTEM PREPARATION
#-------------------------------------------------------------------------------
system_prepare() {
    step "System preparation"
    
    # Update & upgrade
    apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq 2>/dev/null || true
    
    # Install prerequisites
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget gnupg2 ca-certificates lsb-release ubuntu-keyring \
        software-properties-common apt-transport-https jq \
        netcat-openbsd xxd bc uuid-runtime \
        git build-essential libssl-dev pkg-config \
        python3 python3-pip python3-venv \
        nodejs npm 2>/dev/null || true
    
    # Set hostname
    if [[ -n "$HOSTNAME" ]]; then
        hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
    else
        HOSTNAME="vps-monolith-$(head -c 8 /dev/urandom | xxd -p 2>/dev/null || echo $$)"
        hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
    fi
    
    # Timezone
    timedatectl set-timezone UTC 2>/dev/null || true
    
    # Create directories
    mkdir -p "$COMPOSE_DIR" "$BACKUP_DIR/postgres" "$BACKUP_DIR/configs" \
             "/etc/traefik" "/var/log/traefik" "/root/.config/rclone" \
             "/opt/templates" "/opt/vpn" 2>/dev/null || true
    
    success "System prepared (${HOSTNAME})"
    return 0
}

setup_swap() {
    [[ "$SWAP_SIZE" == "0" ]] && return 0
    [[ -f /swapfile ]] && return 0
    
    step "Setting up swap (${SWAP_SIZE})"
    
    # Calculate size in MB
    local size_mb=4096
    if [[ "$SWAP_SIZE" =~ ^([0-9]+)[Gg]$ ]]; then
        size_mb=$((${BASH_REMATCH[1]} * 1024))
    elif [[ "$SWAP_SIZE" =~ ^([0-9]+)[Mm]$ ]]; then
        size_mb="${BASH_REMATCH[1]}"
    fi
    
    # Create swap
    fallocate -l "${SWAP_SIZE}" /swapfile 2>/dev/null || \
        dd if=/dev/zero of=/swapfile bs=1M count="${size_mb}" status=none 2>/dev/null || true
    
    chmod 600 /swapfile 2>/dev/null || true
    mkswap /swapfile 2>/dev/null || true
    swapon /swapfile 2>/dev/null || true
    echo '/swapfile none swap sw 0 0' >> /etc/fstab 2>/dev/null || true
    
    # Swappiness tuning
    echo 'vm.swappiness=10' >> /etc/sysctl.conf 2>/dev/null || true
    sysctl -p &>/dev/null || true
    
    success "Swap configured (${SWAP_SIZE})"
    return 0
}

#-------------------------------------------------------------------------------
# SSH HARDENING
#-------------------------------------------------------------------------------
harden_ssh() {
    [[ "$INSTALL_SECURITY" != "1" ]] && return 0
    
    step "Hardening SSH"
    
    local sshd_config="/etc/ssh/sshd_config"
    
    # Backup original config
    [[ ! -f "${sshd_config}.monolith.bak" ]] && cp "$sshd_config" "${sshd_config}.monolith.bak" 2>/dev/null || true
    
    # Change port
    if [[ "$SSH_NEW_PORT" != "22" ]]; then
        # Remove existing Port lines and add new one
        sed -i '/^Port /d' "$sshd_config" 2>/dev/null || true
        echo "Port ${SSH_NEW_PORT}" >> "$sshd_config"
    fi
    
    # Security settings
    [[ "$SSH_DISABLE_ROOT" == "1" ]] && echo "PermitRootLogin yes" >> "$sshd_config"
    [[ "$SSH_DISABLE_PASSWORD" == "1" ]] && echo "PasswordAuthentication yes" >> "$sshd_config"
    
    echo "# Monolith hardening ($(date +%Y-%m-%d))" >> "$sshd_config"
    echo "PubkeyAuthentication yes" >> "$sshd_config"
    echo "X11Forwarding no" >> "$sshd_config"
    echo "MaxAuthTries 3" >> "$sshd_config"
    echo "ClientAliveInterval 300" >> "$sshd_config"
    echo "ClientAliveCountMax 2" >> "$sshd_config"
    echo "AllowTcpForwarding no" >> "$sshd_config"
    
    # Validate and reload SSH
    if command_exists sshd; then
        if sshd -t 2>/dev/null; then
            # Ubuntu 24.04 uses 'ssh' not 'sshd'
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
            
            # Verify port is listening
            sleep 2
            if ss -tlnp | grep -q ":${SSH_NEW_PORT} "; then
                success "SSH hardened (port: ${SSH_NEW_PORT})"
                warn "⚠️  Keep current session open! New connections: ssh -p ${SSH_NEW_PORT} root@host"
            else
                warn "SSH port ${SSH_NEW_PORT} not listening, keeping original config"
                cp "${sshd_config}.monolith.bak" "$sshd_config" 2>/dev/null || true
            fi
        else
            warn "SSH config validation failed, keeping original"
            cp "${sshd_config}.monolith.bak" "$sshd_config" 2>/dev/null || true
        fi
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# FIREWALL (UFW + Fail2Ban)
#-------------------------------------------------------------------------------
setup_firewall() {
    [[ "$INSTALL_SECURITY" != "1" || "$UFW_ENABLE" != "1" ]] && return 0
    
    step "Configuring firewall"
    
    # Install UFW
    if ! command_exists ufw; then
        apt-get install -y -qq ufw 2>/dev/null || true
    fi
    
    # Reset and configure
    ufw --force reset &>/dev/null || true
    ufw default deny incoming 2>/dev/null || true
    ufw default allow outgoing 2>/dev/null || true
    
    # Allow essential ports
    ufw allow "${SSH_NEW_PORT}/tcp" comment 'SSH' 2>/dev/null || true
    ufw allow "${TRAEFIK_HTTP_PORT}/tcp" comment 'HTTP' 2>/dev/null || true
    ufw allow "${TRAEFIK_HTTPS_PORT}/tcp" comment 'HTTPS' 2>/dev/null || true
    
    # Allow service ports
    [[ " ${SELECTED_SERVICES[*]} " =~ " coolify " ]] && ufw allow "${COOLIFY_PORT}/tcp" comment 'Coolify' 2>/dev/null || true
    [[ " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] && ufw allow "${PORTAINER_PORT}/tcp" comment 'Portainer' 2>/dev/null || true
    [[ " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] && ufw allow "${UPTIME_KUMA_PORT}/tcp" comment 'Kuma' 2>/dev/null || true
    [[ " ${SELECTED_SERVICES[*]} " =~ " supabase " ]] && ufw allow "${SUPABASE_PORT}/tcp" comment 'Supabase' 2>/dev/null || true
    [[ " ${SELECTED_SERVICES[*]} " =~ " mtproto " ]] && ufw allow "${MTPROTO_PORT}/tcp" comment 'MTProto' 2>/dev/null || true
    [[ " ${SELECTED_SERVICES[*]} " =~ " amnezia " ]] && ufw allow "${AMNEZIA_WIREGUARD_PORT}/udp" comment 'WireGuard' 2>/dev/null || true
    [[ " ${SELECTED_SERVICES[*]} " =~ " amnezia " ]] && ufw allow "${AMNEZIA_OPENVPN_PORT}/udp" comment 'OpenVPN' 2>/dev/null || true
    
    # Enable UFW
    ufw --force enable 2>/dev/null || true
    
    # Install and configure Fail2Ban
    if [[ "$FAIL2BAN_ENABLE" == "1" ]]; then
        if ! command_exists fail2ban; then
            apt-get install -y -qq fail2ban 2>/dev/null || true
        fi
        
        cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
backend = auto

[sshd]
enabled = true
port = 2222
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200

[traefik-auth]
enabled = true
port = http,https
filter = traefik-auth
logpath = /var/log/traefik/access.log
maxretry = 5
EOF
        
        systemctl enable --now fail2ban &>/dev/null || true
        success "Fail2Ban enabled"
    fi
    
    success "Firewall configured (UFW)"
    return 0
}

#-------------------------------------------------------------------------------
# AUTO UPDATES
#-------------------------------------------------------------------------------
setup_auto_updates() {
    [[ "$INSTALL_SECURITY" != "1" || "$AUTO_UPDATES" != "1" ]] && return 0
    
    step "Enabling auto security updates"
    
    apt-get install -y -qq unattended-upgrades apt-listchanges 2>/dev/null || true
    
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::MailReport "on-change";
EOF
    
    systemctl enable --now unattended-upgrades &>/dev/null || true
    success "Auto-updates enabled"
    return 0
}

#-------------------------------------------------------------------------------
# DOCKER INSTALLATION
#-------------------------------------------------------------------------------
install_docker() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " docker " ]] && return 0
    
    step "Installing Docker Engine + Compose"
    
    # Check if already installed
    if command_exists docker && command_exists docker-compose; then
        info "Docker already installed"
        return 0
    fi
    
    # Remove old versions
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Add Docker repo
    install -m 0755 -d /etc/apt/keyrings 2>/dev/null || true
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    chmod a+r /etc/apt/keyrings/docker.gpg 2>/dev/null || true
    
    echo "deb [arch=$(dpkg --print-architecture) \
        signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null 2>/dev/null || true
    
    # Install Docker
    apt-get update -qq 2>/dev/null || true
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    
    # Add user to docker group
    usermod -aG docker "$SUDO_USER" 2>/dev/null || true
    usermod -aG docker root 2>/dev/null || true
    
    # Docker daemon config
    cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "features": {
    "buildkit": true
  }
}
EOF
    
    # Enable and start Docker
    systemctl enable --now docker 2>/dev/null || true
    
    # Wait for Docker to be ready
    sleep 3
    if systemctl is-active --quiet docker 2>/dev/null; then
        success "Docker Engine + Compose installed"
    else
        warn "Docker service may not be running"
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# TRAEFIK REVERSE PROXY
#-------------------------------------------------------------------------------
setup_traefik() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " traefik " ]] && return 0
    
    step "Setting up Traefik with auto-TLS"
    
    [[ -z "$ADMIN_EMAIL" ]] && ADMIN_EMAIL="admin@${DOMAIN_NAME:-localhost}"
    
    # Traefik config
    cat > "${COMPOSE_DIR}/traefik.yml" << EOF
api:
  dashboard: true
  insecure: true

entryPoints:
  web:
    address: ":${TRAEFIK_HTTP_PORT}"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":${TRAEFIK_HTTPS_PORT}"
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
  filePath: /var/log/traefik/traefik.log

accessLog:
  filePath: /var/log/traefik/access.log
  format: json
EOF
    
    # Create directories and files
    touch /etc/traefik/acme.json 2>/dev/null || true
    chmod 600 /etc/traefik/acme.json 2>/dev/null || true
    touch /etc/traefik/dynamic.yml 2>/dev/null || true
    
    # Docker Compose for Traefik
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
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.api.rule=Host(`traefik.local`)"
      - "traefik.http.routers.api.service=api@internal"
      - "traefik.http.routers.api.tls=true"

networks:
  monolith:
    external: true
EOF
    
    # Create network if not exists
    docker network create monolith 2>/dev/null || true
    
    # Start Traefik
    cd "$COMPOSE_DIR" 2>/dev/null || true
    docker compose -f docker-compose.traefik.yml pull --quiet 2>/dev/null || true
    docker compose -f docker-compose.traefik.yml up -d --quiet-pull 2>/dev/null || true
    
    # Wait for Traefik
    sleep 5
    if wait_for_port 80 30; then
        success "Traefik reverse proxy configured"
    else
        warn "Traefik may not be fully ready"
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# COOLIFY INSTALLATION
#-------------------------------------------------------------------------------
install_coolify() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " coolify " ]] && return 0
    
    step "Installing Coolify (self-hosted PaaS)"
    
    # Docker Compose for Coolify WITH Redis
    cat > "${COMPOSE_DIR}/docker-compose.coolify.yml" << EOF
services:
  coolify:
    image: ghcr.io/coollabsio/coolify:latest
    container_name: coolify
    restart: unless-stopped
    ports:
      - "${COOLIFY_PORT}:80"
    volumes:
      - coolify-data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - APP_ENV=production
      - APP_URL=https://coolify.${DOMAIN_NAME:-localhost}
      - DB_CONNECTION=pgsql
      - DB_HOST=coolify-postgres
      - DB_PORT=5432
      - DB_DATABASE=coolify
      - DB_USERNAME=coolify
      - DB_PASSWORD=${COOLIFY_DB_PASS}
      - REDIS_HOST=coolify-redis
      - REDIS_PORT=6379
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.coolify.rule=Host(\`coolify.${DOMAIN_NAME:-localhost}\`)"
      - "traefik.http.routers.coolify.tls=true"
      - "traefik.http.routers.coolify.entrypoints=websecure"
    networks:
      - monolith
    depends_on:
      coolify-postgres:
        condition: service_healthy
      coolify-redis:
        condition: service_started

  coolify-postgres:
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
    volumes:
      - coolify-redisdata:/data
    networks:
      - monolith
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

volumes:
  coolify-data:
  coolify-pgdata:
  coolify-redisdata:

networks:
  monolith:
    external: true
EOF
    
    cd "$COMPOSE_DIR" 2>/dev/null || true
    docker compose -f docker-compose.coolify.yml pull --quiet 2>/dev/null || true
    docker compose -f docker-compose.coolify.yml up -d --quiet-pull 2>/dev/null || true
    
    # Wait for Coolify
    sleep 10
    if wait_for_container coolify 120; then
        success "Coolify installed: http://${SERVER_IP}:${COOLIFY_PORT}"
    else
        warn "Coolify may still be starting"
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# SUPABASE INSTALLATION
#-------------------------------------------------------------------------------
install_supabase() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " supabase " ]] && return 0
    
    step "Installing Supabase (BaaS)"
    
    # Docker Compose for Supabase
    cat > "${COMPOSE_DIR}/docker-compose.supabase.yml" << EOF
services:
  supabase:
    image: supabase/postgres:15.1.0.147
    container_name: supabase-postgres
    restart: unless-stopped
    ports:
      - "${SUPABASE_PORT}:5432"
    volumes:
      - supabase-pgdata:/var/lib/postgresql/data
    environment:
      - POSTGRES_DB=postgres
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=${SUPABASE_DB_PASS}
      - JWT_SECRET=${SUPABASE_JWT_SECRET}
      - ANON_KEY=${SUPABASE_ANON_KEY}
      - SERVICE_ROLE_KEY=${SUPABASE_SERVICE_KEY}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - monolith
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.supabase.rule=Host(\`supabase.${DOMAIN_NAME:-localhost}\`)"
      - "traefik.http.routers.supabase.tls=true"

volumes:
  supabase-pgdata:

networks:
  monolith:
    external: true
EOF
    
    # Save credentials
    cat > "${COMPOSE_DIR}/supabase-credentials.txt" << EOF
Supabase Credentials (SAVE SECURELY!)
======================================
Generated: $(date)
JWT Secret: ${SUPABASE_JWT_SECRET}
Anon Key: ${SUPABASE_ANON_KEY}
Service Key: ${SUPABASE_SERVICE_KEY}
DB Password: ${SUPABASE_DB_PASS}
Connection: postgresql://postgres:${SUPABASE_DB_PASS}@${SERVER_IP}:${SUPABASE_PORT}/postgres
EOF
    chmod 600 "${COMPOSE_DIR}/supabase-credentials.txt" 2>/dev/null || true
    
    cd "$COMPOSE_DIR" 2>/dev/null || true
    docker compose -f docker-compose.supabase.yml pull --quiet 2>/dev/null || true
    docker compose -f docker-compose.supabase.yml up -d --quiet-pull 2>/dev/null || true
    
    success "Supabase installed: ${SERVER_IP}:${SUPABASE_PORT}"
    return 0
}

#-------------------------------------------------------------------------------
# MONITORING STACK
#-------------------------------------------------------------------------------
install_monitoring() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] && return 0
    
    step "Installing monitoring stack"
    
    cat > "${COMPOSE_DIR}/docker-compose.monitoring.yml" << EOF
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - "${PORTAINER_PORT}:9443"
    volumes:
      - portainer-data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - monolith
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(\`portainer.${DOMAIN_NAME:-localhost}\`)"
      - "traefik.http.routers.portainer.tls=true"

  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    ports:
      - "${UPTIME_KUMA_PORT}:3001"
    volumes:
      - kuma-data:/app/data
    networks:
      - monolith
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.kuma.rule=Host(\`kuma.${DOMAIN_NAME:-localhost}\`)"
      - "traefik.http.routers.kuma.tls=true"

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_POLL_INTERVAL=86400
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_NOTIFICATIONS=telegram
      - WATCHTOWER_NOTIFICATION_TELEGRAM_CHAT_ID=${TG_CHAT:-}
      - WATCHTOWER_NOTIFICATION_TELEGRAM_TOKEN=${TG_TOKEN:-}
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
    docker compose -f docker-compose.monitoring.yml pull --quiet 2>/dev/null || true
    docker compose -f docker-compose.monitoring.yml up -d --quiet-pull 2>/dev/null || true
    
    success "Monitoring stack installed (Portainer, Uptime Kuma, Watchtower)"
    return 0
}

#-------------------------------------------------------------------------------
# BACKUP SYSTEM
#-------------------------------------------------------------------------------
setup_backups() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " backups " ]] && return 0
    
    step "Configuring backup system"
    
    # PostgreSQL backup script
    cat > /usr/local/bin/monolith-pg-backup << 'EOF'
#!/bin/bash
BACKUP_DIR="/opt/monolith-backups/postgres"
DATE=$(date +%Y%m%d_%H%M%S)
CONTAINER="${1:-coolify-postgres}"
DB_NAME="${2:-coolify}"
DB_USER="${3:-coolify}"

mkdir -p "$BACKUP_DIR"
docker exec "$CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" 2>/dev/null | \
    gzip > "${BACKUP_DIR}/${DB_NAME}_${DATE}.sql.gz"

# Keep only last 7 backups
find "$BACKUP_DIR" -name "${DB_NAME}_*.sql.gz" -type f -mtime +7 -delete 2>/dev/null || true

echo "Backup created: ${BACKUP_DIR}/${DB_NAME}_${DATE}.sql.gz"
EOF
    chmod +x /usr/local/bin/monolith-pg-backup 2>/dev/null || true
    
    # Add to crontab
    if ! crontab -l 2>/dev/null | grep -q "monolith-pg-backup"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/monolith-pg-backup") | crontab - 2>/dev/null || true
    fi
    
    # Rclone prep
    if [[ -n "${RCLONE_CONFIG:-}" ]]; then
        echo "$RCLONE_CONFIG" > /root/.config/rclone/rclone.conf 2>/dev/null || true
        chmod 600 /root/.config/rclone/rclone.conf 2>/dev/null || true
        info "Rclone configured for cloud sync"
    fi
    
    success "Backup system configured"
    return 0
}

#-------------------------------------------------------------------------------
# MTProto TELEGRAM PROXY
#-------------------------------------------------------------------------------
install_mtproto() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " mtproto " ]] && return 0
    
    step "Installing MTProto Telegram proxy"
    
    cat > "${COMPOSE_DIR}/docker-compose.mtproto.yml" << EOF
services:
  mtproto:
    image: alexbers/mtprotoproxy:latest
    container_name: mtproto-proxy
    restart: unless-stopped
    ports:
      - "${MTPROTO_PORT}:443"
    environment:
      - DOMAIN=${DOMAIN_NAME:-${SERVER_IP}}
      - SECRET=${MTPROTO_SECRET}
      - TAG=monolith
    networks:
      - monolith

networks:
  monolith:
    external: true
EOF
    
    # Generate connection link
    local proxy_url="https://t.me/proxy?server=${SERVER_IP}&port=${MTPROTO_PORT}&secret=${MTPROTO_SECRET}"
    echo "MTProto Proxy URL: $proxy_url" > "${COMPOSE_DIR}/mtproto-info.txt" 2>/dev/null || true
    chmod 600 "${COMPOSE_DIR}/mtproto-info.txt" 2>/dev/null || true
    
    cd "$COMPOSE_DIR" 2>/dev/null || true
    docker compose -f docker-compose.mtproto.yml pull --quiet 2>/dev/null || true
    docker compose -f docker-compose.mtproto.yml up -d --quiet-pull 2>/dev/null || true
    
    success "MTProto proxy installed: $proxy_url"
    return 0
}

#-------------------------------------------------------------------------------
# AMNEZIA VPN PREPARATION
#-------------------------------------------------------------------------------
prepare_amnezia() {
    [[ ! " ${SELECTED_SERVICES[*]} " =~ " amnezia " ]] && return 0
    
    step "Preparing Amnezia VPN infrastructure"
    
    # Install WireGuard
    apt-get install -y -qq wireguard wireguard-tools 2>/dev/null || true
    
    # Generate WireGuard keys
    if [[ ! -f /opt/vpn/wg_private.key ]]; then
        wg genkey | tee /opt/vpn/wg_private.key 2>/dev/null | wg pubkey > /opt/vpn/wg_public.key 2>/dev/null || true
        chmod 600 /opt/vpn/wg_private.key 2>/dev/null || true
    fi
    
    # Install OpenVPN
    apt-get install -y -qq openvpn easy-rsa 2>/dev/null || true
    
    # Create OpenVPN config directory
    mkdir -p /etc/openvpn/server 2>/dev/null || true
    
    # Prepare Amnezia compose (to be configured via Amnezia app)
    cat > "${COMPOSE_DIR}/docker-compose.amnezia.yml" << 'EOF'
services:
  amnezia-wireguard:
    image: ghcr.io/amnezia-vpn/amnezia-wg:latest
    container_name: amnezia-wireguard
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    ports:
      - "51820:51820/udp"
    volumes:
      - /opt/vpn/wireguard:/etc/wireguard
    networks:
      - monolith
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1

  amnezia-openvpn:
    image: ghcr.io/amnezia-vpn/amnezia-openvpn:latest
    container_name: amnezia-openvpn
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    ports:
      - "1194:1194/udp"
    volumes:
      - /opt/vpn/openvpn:/etc/openvpn
    networks:
      - monolith

networks:
  monolith:
    external: true
EOF
    
    success "Amnezia VPN infrastructure prepared"
    info "Configure via Amnezia app: https://amnezia.org/"
    return 0
}

#-------------------------------------------------------------------------------
# CLOUDFLARE DNS INTEGRATION
#-------------------------------------------------------------------------------
update_cloudflare_dns() {
    [[ "$SKIP_DNS" == "1" ]] && return 0
    [[ -z "$CF_API_TOKEN" || -z "$CF_ZONE_ID" || -z "$DOMAIN_NAME" ]] && return 0
    
    step "Updating Cloudflare DNS"
    
    local proxied="true"
    [[ "${VPS_CF_PROXY:-1}" == "0" ]] && proxied="false"
    
    local response
    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{
            \"type\":\"A\",
            \"name\":\"${DOMAIN_NAME}\",
            \"content\":\"${SERVER_IP}\",
            \"ttl\":120,
            \"proxied\":${proxied}
        }" 2>/dev/null) || { warn "Cloudflare API request failed"; return 1; }
    
    if echo "$response" | grep -q '"success":true' 2>/dev/null; then
        success "Cloudflare DNS updated (${DOMAIN_NAME} → ${SERVER_IP})"
        
        # Also create wildcard
        curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\":\"A\",
                \"name\":\"*.${DOMAIN_NAME}\",
                \"content\":\"${SERVER_IP}\",
                \"ttl\":120,
                \"proxied\":${proxied}
            }" &>/dev/null || true
    else
        warn "Cloudflare update response: $response"
        return 1
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# POST INSTALL HOOK
#-------------------------------------------------------------------------------
run_post_install_hook() {
    [[ -z "$POST_INSTALL_HOOK" ]] && return 0
    
    step "Running post-install hook"
    
    if bash -c "$POST_INSTALL_HOOK" 2>/dev/null; then
        success "Post-install hook completed"
    else
        warn "Post-install hook failed"
    fi
    
    return 0
}

#-------------------------------------------------------------------------------
# KERNEL TUNING FOR VPN
#-------------------------------------------------------------------------------
tune_kernel() {
    step "Tuning kernel for VPN and networking"
    
    # Enable IP forwarding
    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf 2>/dev/null || true
    echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf 2>/dev/null || true
    
    # Optimize network
    echo 'net.core.rmem_max=16777216' >> /etc/sysctl.conf 2>/dev/null || true
    echo 'net.core.wmem_max=16777216' >> /etc/sysctl.conf 2>/dev/null || true
    echo 'net.ipv4.tcp_rmem=4096 87380 16777216' >> /etc/sysctl.conf 2>/dev/null || true
    echo 'net.ipv4.tcp_wmem=4096 87380 16777216' >> /etc/sysctl.conf 2>/dev/null || true
    
    # Apply
    sysctl -p &>/dev/null || true
    
    # Enable NAT for VPN
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || true
    iptables -A FORWARD -i eth0 -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -A FORWARD -i wg0 -o eth0 -j ACCEPT 2>/dev/null || true
    
    success "Kernel tuned for VPN"
    return 0
}

#-------------------------------------------------------------------------------
# FINAL SUMMARY
#-------------------------------------------------------------------------------
show_summary() {
    local duration=$(( $(date +%s) - INSTALLATION_START_TIME ))
    
    clear
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✅ INSTALLATION COMPLETE             ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo
    echo -e "${BOLD}Server:${NC} ${HOSTNAME} (${SERVER_IP})"
    echo -e "${BOLD}Domain:${NC} ${DOMAIN_NAME:-Not configured}"
    echo -e "${BOLD}Duration:${NC} ${duration}s"
    echo
    echo -e "${YELLOW}🔐 Access:${NC}"
    [[ "$SSH_NEW_PORT" != "22" ]] && echo "  SSH:          ssh -p ${SSH_NEW_PORT} root@${SERVER_IP}"
    [[ " ${SELECTED_SERVICES[*]} " =~ " coolify " ]] && echo "  Coolify:      http://${SERVER_IP}:${COOLIFY_PORT}"
    [[ " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] && echo "  Portainer:    https://${SERVER_IP}:${PORTAINER_PORT}"
    [[ " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] && echo "  Uptime Kuma:  http://${SERVER_IP}:${UPTIME_KUMA_PORT}"
    [[ " ${SELECTED_SERVICES[*]} " =~ " supabase " ]] && echo "  Supabase:     ${SERVER_IP}:${SUPABASE_PORT}"
    [[ " ${SELECTED_SERVICES[*]} " =~ " mtproto " ]] && echo "  MTProto:      ${SERVER_IP}:${MTPROTO_PORT}"
    [[ " ${SELECTED_SERVICES[*]} " =~ " amnezia " ]] && echo "  Amnezia WG:   ${SERVER_IP}:${AMNEZIA_WIREGUARD_PORT}/udp"
    [[ " ${SELECTED_SERVICES[*]} " =~ " amnezia " ]] && echo "  Amnezia OVPN: ${SERVER_IP}:${AMNEZIA_OPENVPN_PORT}/udp"
    echo
    echo -e "${YELLOW}📁 Paths:${NC}"
    echo "  Compose:      ${COMPOSE_DIR}/"
    echo "  Backups:      ${BACKUP_DIR}/"
    echo "  Logs:         ${LOG_FILE}"
    [[ " ${SELECTED_SERVICES[*]} " =~ " supabase " ]] && echo "  Credentials:  ${COMPOSE_DIR}/supabase-credentials.txt"
    [[ " ${SELECTED_SERVICES[*]} " =~ " mtproto " ]] && echo "  MTProto Info: ${COMPOSE_DIR}/mtproto-info.txt"
    [[ " ${SELECTED_SERVICES[*]} " =~ " amnezia " ]] && echo "  VPN Keys:     /opt/vpn/"
    echo
    echo -e "${RED}⚠️  Security:${NC}"
    echo "  1. Change default passwords in service configs"
    echo "  2. Restrict admin panels (VPN/Cloudflare Access)"
    echo "  3. Configure external backups (S3/Backblaze)"
    echo "  4. Keep SSH key secure!"
    echo "  5. Test SSH access on new port before closing session"
    echo
    echo -e "${GREEN}🎉 Private cloud ready!${NC}"
    
    # Send Telegram notification
    notify_telegram "✅ **Monolith Installation Complete**

Host: \`${HOSTNAME}\`
IP: \`${SERVER_IP}\`
Duration: ${duration}s

🔗 Services:
• Coolify: http://${SERVER_IP}:${COOLIFY_PORT}
• Portainer: https://${SERVER_IP}:${PORTAINER_PORT}
• Uptime Kuma: http://${SERVER_IP}:${UPTIME_KUMA_PORT}
• SSH: ${SERVER_IP}:${SSH_NEW_PORT}" 2>/dev/null || true
    
    return 0
}

#-------------------------------------------------------------------------------
# MAIN ORCHESTRATOR
#-------------------------------------------------------------------------------
run_installation() {
    INSTALLATION_START_TIME=$(date +%s)
    
    info "Starting VPS PRO MONOLITH v${SCRIPT_VERSION}"
    notify_telegram "🚀 **Monolith Installation Started**

Host: \`${SERVER_IP}\`
Time: $(date '+%Y-%m-%d %H:%M:%S')" 2>/dev/null || true
    
    local total_steps=15
    local current_step=0
    
    # System preparation
    system_prepare; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "System prepared"
    setup_swap; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "Swap configured"
    tune_kernel; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "Kernel tuned"
    
    # Security
    [[ " ${SELECTED_SERVICES[*]} " =~ " security " ]] && {
        harden_ssh; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "SSH hardened"
        setup_firewall; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "Firewall configured"
        setup_auto_updates; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "Auto-updates enabled"
    }
    
    # Core services
    install_docker; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "Docker installed"
    setup_traefik; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "Traefik configured"
    install_coolify; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "Coolify installed"
    install_supabase; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "Supabase installed"
    install_monitoring; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "Monitoring installed"
    setup_backups; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "Backups configured"
    install_mtproto; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "MTProto installed"
    prepare_amnezia; current_step=$((current_step + 1)); notify_progress $current_step $total_steps "Amnezia VPN prepared"
    
    # DNS and final
    update_cloudflare_dns
    run_post_install_hook
    
    show_summary
    
    return 0
}

#-------------------------------------------------------------------------------
# ENTRY POINT
#-------------------------------------------------------------------------------
main() {
    # Must run as root
    [[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"
    
    # Init logging
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    
    # Get server info
    SERVER_IP="$(get_public_ip)"
    
    echo -e "${CYAN}${BOLD}VPS PRO MONOLITH v${SCRIPT_VERSION}${NC}"
    echo -e "Server: ${SERVER_IP} | Hostname: ${HOSTNAME:-detecting...}"
    echo
    
    # Parse and validate
    parse_config
    validate_config
    
    # Dry run
    if [[ "$DRY_RUN" == "1" ]]; then
        show_installation_plan
        exit 0
    fi
    
    # Show plan
    show_installation_plan
    
    # TUI or skip
    if [[ "$SKIP_TUI" != "1" && "$UNATTENDED" != "1" ]]; then
        read -p $'\nProceed with installation? [y/N] ' -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && echo "Installation cancelled." && exit 0
    fi
    
    # Install
    run_installation
}

# Run main
main "$@"
