#!/bin/bash
#===============================================================================
# VPS PRO MONOLITH — One-Shot Private Cloud Bootstrap
# Ubuntu 22.04 / 24.04 | Docker | Traefik | Coolify | Supabase | Monitoring
# License: MIT | Author: @sheikerdc-del
# GitHub: https://github.com/sheikerdc-del/VPS-PRO-MONOLITH
#===============================================================================

set -euo pipefail

#-------------------------------------------------------------------------------
# VERSION & CONSTANTS
#-------------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="vps_monolith"
readonly LOG_FILE="${VPS_LOG_FILE:-/var/log/${SCRIPT_NAME}.log}"
readonly STATE_FILE="/var/lib/${SCRIPT_NAME}.state"
readonly BACKUP_DIR="/opt/monolith-backups"
readonly COMPOSE_DIR="${VPS_CUSTOM_COMPOSE_DIR:-/opt/monolith}"

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
readonly DEFAULT_SERVICES=("docker" "traefik" "coolify" "supabase" "monitoring" "security" "devstack" "backups")

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'
readonly BOLD='\033[1m'

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
CF_PROXY="${VPS_CF_PROXY:-1}"
DOMAIN_NAME="${VPS_DOMAIN:-}"
WILDCARD_DOMAIN="${VPS_WILDCARD_DOMAIN:-}"
SERVER_IP="${VPS_PUBLIC_IP:-}"
HOSTNAME="${VPS_HOSTNAME:-}"
ADMIN_EMAIL="${VPS_ADMIN_EMAIL:-}"
LOG_LEVEL="${VPS_LOG_LEVEL:-INFO}"
SWAP_SIZE="${VPS_SWAP_SIZE:-4G}"
LOW_MEMORY_MODE="${VPS_LOW_MEMORY_MODE:-0}"
SKIP_PULL="${VPS_SKIP_PULL:-0}"
POST_INSTALL_HOOK="${VPS_POST_INSTALL_HOOK:-}"

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
SKIP_DNS="${VPS_SKIP_DNS:-0}"

# Secrets (will be generated if empty)
COOLIFY_DB_PASS="${VPS_COOLIFY_DB_PASS:-}"
SUPABASE_JWT_SECRET="${VPS_SUPABASE_JWT_SECRET:-}"
SUPABASE_ANON_KEY="${VPS_SUPABASE_ANON_KEY:-}"
SUPABASE_SERVICE_KEY="${VPS_SUPABASE_SERVICE_KEY:-}"
SUPABASE_DB_PASS="${VPS_SUPABASE_DB_PASS:-}"

# Runtime
SELECTED_SERVICES=()
INSTALLATION_START_TIME=""

#-------------------------------------------------------------------------------
# LOGGING SYSTEM
#-------------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    
    # Log level filtering
    local -A level_priority=( ["DEBUG"]=0 ["INFO"]=1 ["WARN"]=2 ["ERROR"]=3 )
    local current_priority="${level_priority[$LOG_LEVEL]:-1}"
    local msg_priority="${level_priority[$level]:-1}"
    
    [[ $msg_priority -lt $current_priority ]] && return 0
    
    echo -e "$msg" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "$msg"
}

debug() { log "DEBUG" "$@"; }
info()  { log "INFO" "${BLUE}ℹ${NC} $@"; }
warn()  { log "WARN" "${YELLOW}⚠${NC} $*"; }
error() { log "ERROR" "${RED}✗${NC} $*"; return 0; }
success(){ log "INFO" "${GREEN}✓${NC} ${GREEN}$*${NC}"; }
step()  { log "INFO" "${MAGENTA}▶${NC} ${BOLD}$*${NC}"; }

die() {
    error "$@"
    notify_telegram "❌ **Installation Failed**\n\nHost: \`${HOSTNAME:-$SERVER_IP}\`\nError: $*\nTime: $(date '+%Y-%m-%d %H:%M:%S')"
    exit 1
}

command_exists() { command -v "$1" &>/dev/null; }

#-------------------------------------------------------------------------------
# TELEGRAM NOTIFICATIONS
#-------------------------------------------------------------------------------
notify_telegram() {
    [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]] && return 0
    
    local msg="$1"
    local curl_result
    curl_result=$(curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT}" \
        -d text="${msg}" \
        -d parse_mode="Markdown" \
        --connect-timeout 5 2>/dev/null) || true
    
    if echo "$curl_result" | grep -q '"ok":true' 2>/dev/null; then
        debug "Telegram notification sent"
    else
        debug "Telegram notification failed: $curl_result"
    fi
}

notify_progress() {
    local step="$1"
    local total="$2"
    local msg="$3"
    
    [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]] && return 0
    
    local percent=$((step * 100 / total))
    local bar=""
    for ((i=0; i<10; i++)); do
        if [[ $i -lt $((percent / 10)) ]]; then
            bar+="█"
        else
            bar+="░"
        fi
    done
    
    notify_telegram "🔄 **Progress: ${percent}%**\n\`[${bar}]\`\n\n${msg}"
}

#-------------------------------------------------------------------------------
# UTILITY FUNCTIONS
#-------------------------------------------------------------------------------
get_public_ip() {
    if [[ -n "$SERVER_IP" ]]; then
        echo "$SERVER_IP"
        return 0
    fi
    
    local ip
    ip=$(curl -s4m10 https://ifconfig.me/ip 2>/dev/null) || \
    ip=$(curl -s6m10 https://ifconfig.me/ip 2>/dev/null) || \
    ip=$(curl -s4m10 https://api.ipify.org 2>/dev/null) || \
    ip=$(hostname -I | awk '{print $1}') || \
    ip="127.0.0.1"
    
    echo "$ip"
}

generate_secret() {
    local length="${1:-32}"
    openssl rand -base64 "$length" 2>/dev/null | tr -d '\n' || \
    head -c "$length" /dev/urandom | base64 | tr -d '\n'
}

generate_jwt_secret() {
    openssl rand -hex 32 2>/dev/null || \
    head -c 32 /dev/urandom | xxd -p | tr -d '\n'
}

is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

is_valid_email() {
    local email="$1"
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

wait_for_service() {
    local service="$1"
    local port="$2"
    local timeout="${3:-30}"
    local elapsed=0
    
    info "Waiting for $service on port $port..."
    
    while [[ $elapsed -lt $timeout ]]; do
        if nc -z localhost "$port" 2>/dev/null || curl -s "http://localhost:$port" &>/dev/null; then
            success "$service is ready"
            return 0
        fi
        sleep 2
        ((elapsed += 2))
        echo -n "."
    done
    
    echo
    warn "$service did not become ready in ${timeout}s"
    return 1
}

#-------------------------------------------------------------------------------
# CONFIGURATION PARSER
#-------------------------------------------------------------------------------
parse_config() {
    step "Parsing configuration"
    
    # Dry run mode
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "\n${YELLOW}╔════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║   🔍 DRY RUN MODE — No changes will be made${NC}"
        echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}\n"
    fi
    
    # Build service list
    if [[ -n "${VPS_SERVICES:-}" ]]; then
        IFS=',' read -ra SELECTED_SERVICES <<< "${VPS_SERVICES}"
        info "Using services from VPS_SERVICES: ${SELECTED_SERVICES[*]}"
    elif [[ "$SKIP_TUI" == "1" || "$UNATTENDED" == "1" ]]; then
        SELECTED_SERVICES=("${DEFAULT_SERVICES[@]}")
        info "Using default services"
    fi
    
    # Apply individual service overrides
    apply_service_overrides
    
    # Low memory mode
    if [[ "$LOW_MEMORY_MODE" == "1" ]]; then
        info "📉 Low memory mode enabled"
        SELECTED_SERVICES=("${SELECTED_SERVICES[@]/supabase/}")
        SELECTED_SERVICES=("${SELECTED_SERVICES[@]/coolify/}")
        SWAP_SIZE="${SWAP_SIZE:-8G}"
        warn "Disabled: Coolify, Supabase (memory intensive)"
    fi
    
    # Set defaults for secrets
    [[ -z "$COOLIFY_DB_PASS" ]] && COOLIFY_DB_PASS="$(generate_secret 32)"
    [[ -z "$SUPABASE_JWT_SECRET" ]] && SUPABASE_JWT_SECRET="$(generate_jwt_secret)"
    [[ -z "$SUPABASE_ANON_KEY" ]] && SUPABASE_ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.$(generate_secret 20).$(generate_secret 20)"
    [[ -z "$SUPABASE_SERVICE_KEY" ]] && SUPABASE_SERVICE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.$(generate_secret 20).$(generate_secret 20)"
    [[ -z "$SUPABASE_DB_PASS" ]] && SUPABASE_DB_PASS="$(generate_secret 32)"
    
    success "Configuration parsed"
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
        local val="${!var:-}"
        local svc_lower="${svc,,}"
        
        if [[ "$val" == "0" ]]; then
            SELECTED_SERVICES=("${SELECTED_SERVICES[@]/$svc_lower/}")
            [[ "$LOG_LEVEL" == "DEBUG" ]] && debug "Disabled: $svc_lower"
        elif [[ "$val" == "1" ]]; then
            [[ ! " ${SELECTED_SERVICES[*]} " =~ " ${svc_lower} " ]] && SELECTED_SERVICES+=("$svc_lower")
            [[ "$LOG_LEVEL" == "DEBUG" ]] && debug "Enabled: $svc_lower"
        fi
    done
}

validate_config() {
    step "Validating configuration"
    local errors=0
    local warnings=0
    
    # Cloudflare validation
    if [[ -n "$CF_API_TOKEN" && -z "$CF_ZONE_ID" ]]; then
        error "VPS_CF_TOKEN set but VPS_CF_ZONE is missing"
        ((errors++))
    fi
    
    if [[ -n "$CF_ZONE_ID" && -z "$DOMAIN_NAME" ]]; then
        warn "VPS_CF_ZONE set but VPS_DOMAIN is empty"
        ((warnings++))
    fi
    
    # Telegram validation
    if [[ -n "$TG_TOKEN" && -z "$TG_CHAT" ]]; then
        error "VPS_TG_TOKEN set but VPS_TG_CHAT is missing"
        ((errors++))
    fi
    
    # SSH security warning
    if [[ "$SSH_NEW_PORT" == "22" && "$SSH_DISABLE_PASSWORD" == "1" ]]; then
        warn "⚠️  SSH port 22 + password auth disabled = lockout risk!"
        ((warnings++))
    fi
    
    # Domain validation
    if [[ -n "$DOMAIN_NAME" ]] && ! is_valid_domain "$DOMAIN_NAME"; then
        error "Invalid domain format: $DOMAIN_NAME"
        ((errors++))
    fi
    
    # Email validation
    if [[ -n "$ADMIN_EMAIL" ]] && ! is_valid_email "$ADMIN_EMAIL"; then
        error "Invalid email format: $ADMIN_EMAIL"
        ((errors++))
    fi
    
    # Unattended mode requirements
    if [[ "$UNATTENDED" == "1" && ${#SELECTED_SERVICES[@]} -eq 0 ]]; then
        error "VPS_UNATTENDED=1 requires at least one service"
        ((errors++))
    fi
    
    # Report
    if [[ $errors -gt 0 ]]; then
        die "Configuration validation failed ($errors errors, $warnings warnings)"
    elif [[ $warnings -gt 0 ]]; then
        warn "Validation completed with $warnings warning(s)"
    else
        success "Configuration validated"
    fi
}

show_installation_plan() {
    echo -e "\n${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   📋 INSTALLATION PLAN                 ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}\n"
    
    echo -e "${BOLD}Server:${NC}"
    echo "  IP:           ${SERVER_IP}"
    echo "  Hostname:     ${HOSTNAME:-<auto-detect>}"
    echo "  Domain:       ${DOMAIN_NAME:-<none>}"
    [[ -n "$WILDCARD_DOMAIN" ]] && echo "  Wildcard:     ${WILDCARD_DOMAIN}"
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
    
    [[ -n "$CF_ZONE_ID" ]] && echo -e "${BOLD}Cloudflare:${NC} Zone ${CF_ZONE_ID} (Proxy: ${CF_PROXY})"
    [[ -n "$TG_CHAT" ]] && echo -e "${BOLD}Telegram:${NC} Notifications enabled"
    [[ "$SWAP_SIZE" != "0" ]] && echo -e "${BOLD}Swap:${NC} ${SWAP_SIZE}"
    echo
    
    if [[ "$DRY_RUN" == "1" ]]; then
        echo -e "${YELLOW}🔍 DRY RUN — Run with VPS_DRY_RUN=0 to execute${NC}\n"
    else
        echo -e "${GREEN}🚀 Ready to install${NC}\n"
    fi
}

#-------------------------------------------------------------------------------
# INTERACTIVE TUI MENU
#-------------------------------------------------------------------------------
show_tui_menu() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║   ${BOLD}VPS PRO MONOLITH v${SCRIPT_VERSION}${NC}${CYAN}              ║${NC}"
    echo -e "${CYAN}║   Private Cloud Bootstrap              ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo
    
    # Check if VPS_SERVICES provides initial selection
    if [[ -n "${VPS_SERVICES:-}" ]]; then
        echo -e "${YELLOW}Pre-selected from VPS_SERVICES:${NC} ${VPS_SERVICES}"
        echo
    fi
    
    local options=(
        "docker:Docker Engine + Compose"
        "traefik:Traefik Reverse Proxy (TLS)"
        "coolify:Coolify (Self-hosted PaaS)"
        "supabase:Supabase (BaaS)"
        "monitoring:Monitoring (Portainer, Kuma)"
        "security:Security Hardening"
        "devstack:Dev Toolchain"
        "backups:Backup System"
        "mtproto:MTProto Telegram Proxy"
        "---:────────────────────────────────"
        "start:[✓] Start Installation"
        "exit:[✗] Exit"
    )
    
    local selected=0
    local choices=("${SELECTED_SERVICES[@]}")
    
    while true; do
        echo -e "${YELLOW}Select components (↑↓ navigate, Space toggle, Enter confirm):${NC}\n"
        
        for i in "${!options[@]}"; do
            local opt="${options[$i]}"
            local key="${opt%%:*}"
            local label="${opt##*:}"
            local marker="  "
            local checked="[ ]"
            
            [[ $i -eq $selected ]] && marker="${GREEN}>${NC} "
            
            if [[ "$key" == "---" || "$key" == "start" || "$key" == "exit" ]]; then
                echo -e "${marker}${label}"
            else
                [[ " ${choices[*]} " =~ " ${key} " ]] && checked="${GREEN}[✓]${NC}"
                echo -e "${marker}${checked} ${label}"
            fi
        done
        
        # Read key
        read -rsn1 key
        
        case "$key" in
            $'\x1b')
                read -rsn2 -t 0.1
                case "${key}${REPLY:0:1}" in
                    $'\x1b[A') ((selected--)) ;;
                    $'\x1b[B') ((selected++)) ;;
                esac
                ;;
            " ")
                local opt="${options[$selected]}"
                local key="${opt%%:*}"
                if [[ "$key" != "---" && "$key" != "start" && "$key" != "exit" ]]; then
                    if [[ " ${choices[*]} " =~ " ${key} " ]]; then
                        choices=("${choices[@]/$key/}")
                    else
                        choices+=("$key")
                    fi
                fi
                ;;
            "")
                local opt="${options[$selected]}"
                local key="${opt%%:*}"
                if [[ "$key" == "start" ]]; then
                    SELECTED_SERVICES=("${choices[@]}")
                    return 0
                elif [[ "$key" == "exit" ]]; then
                    echo -e "\n${YELLOW}Installation cancelled.${NC}"
                    exit 0
                fi
                ;;
        esac
        
        # Bounds
        ((selected < 0)) && selected=$((${#options[@]} - 1))
        ((selected >= ${#options[@]})) && selected=0
        
        # Redraw
        clear
        echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║   ${BOLD}VPS PRO MONOLITH v${SCRIPT_VERSION}${NC}${CYAN}              ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
        echo
    done
}

#-------------------------------------------------------------------------------
# SYSTEM PREPARATION
#-------------------------------------------------------------------------------
system_prepare() {
    step "System preparation"
    
    # Update
    apt-get update -qq 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq 2>/dev/null
    
    # Install prerequisites
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget gnupg2 ca-certificates lsb-release ubuntu-keyring \
        software-properties-common apt-transport-https jq uuid-runtime \
        netcat-openbsd xxd 2>/dev/null || true
    
    # Hostname
    if [[ -n "$HOSTNAME" ]]; then
        hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
    else
        HOSTNAME="vps-monolith-$(uuidgen | cut -c1-8)"
        hostnamectl set-hostname "$HOSTNAME" 2>/dev/null || true
    fi
    
    # Timezone
    timedatectl set-timezone UTC 2>/dev/null || true
    
    # Directories
    mkdir -p "$COMPOSE_DIR" "$BACKUP_DIR/postgres" "/etc/traefik" "/etc/monolith"
    mkdir -p /var/log/traefik /root/.config/rclone
    
    success "System prepared (${HOSTNAME})"
}

#-------------------------------------------------------------------------------
# SWAP
#-------------------------------------------------------------------------------
setup_swap() {
    [[ "$SWAP_SIZE" == "0" ]] && return 0
    
    step "Setting up swap (${SWAP_SIZE})"
    
    if [[ -f /swapfile ]]; then
        info "Swap already exists"
        return 0
    fi
    
    local size_mb
    size_mb=$(echo "$SWAP_SIZE" | sed 's/[Gg]/*1024/; s/[Mm]//; s/[Gg]//' | bc 2>/dev/null || echo "4096")
    
    fallocate -l "${SWAP_SIZE}" /swapfile 2>/dev/null || \
        dd if=/dev/zero of=/swapfile bs=1M count="${size_mb}" status=none
    
    chmod 600 /swapfile
    mkswap /swapfile 2>/dev/null
    swapon /swapfile 2>/dev/null
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    
    # Swappiness
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl -p &>/dev/null || true
    
    success "Swap configured (${SWAP_SIZE})"
}

#-------------------------------------------------------------------------------
# SSH HARDENING
#-------------------------------------------------------------------------------
harden_ssh() {
    [[ "$INSTALL_SECURITY" != "1" ]] && return 0
    [[ "$SSH_NEW_PORT" == "22" && "$SSH_DISABLE_ROOT" == "0" && "$SSH_DISABLE_PASSWORD" == "0" ]] && return 0
    
    step "Hardening SSH"
    
    local sshd_config="/etc/ssh/sshd_config"
    [[ ! -f "${sshd_config}.monolith.bak" ]] && cp "$sshd_config" "${sshd_config}.monolith.bak"
    
    # Port
    if [[ "$SSH_NEW_PORT" != "22" ]]; then
        grep -q "^Port ${SSH_NEW_PORT}$" "$sshd_config" 2>/dev/null || \
            echo "Port ${SSH_NEW_PORT}" >> "$sshd_config"
    fi
    
    # Security settings
    cat >> "$sshd_config" << EOF

# Monolith hardening ($(date +%Y-%m-%d))
EOF
    
    [[ "$SSH_DISABLE_ROOT" == "1" ]] && echo "PermitRootLogin no" >> "$sshd_config"
    [[ "$SSH_DISABLE_PASSWORD" == "1" ]] && echo "PasswordAuthentication no" >> "$sshd_config"
    echo "PubkeyAuthentication yes" >> "$sshd_config"
    echo "X11Forwarding no" >> "$sshd_config"
    echo "MaxAuthTries 3" >> "$sshd_config"
    echo "ClientAliveInterval 300" >> "$sshd_config"
    echo "ClientAliveCountMax 2" >> "$sshd_config"
    
    # Validate and reload
    if command_exists sshd; then
        if sshd -t 2>/dev/null; then
            systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || true
            success "SSH hardened (port: ${SSH_NEW_PORT})"
            warn "⚠️  Keep current session open! New connections: ssh -p ${SSH_NEW_PORT} user@host"
        else
            warn "SSH config validation failed, keeping original"
            cp "${sshd_config}.monolith.bak" "$sshd_config"
        fi
    fi
}

#-------------------------------------------------------------------------------
# FIREWALL
#-------------------------------------------------------------------------------
setup_firewall() {
    [[ "$INSTALL_SECURITY" != "1" || "$UFW_ENABLE" != "1" ]] && return 0
    
    step "Configuring firewall"
    
    # UFW
    if ! command_exists ufw; then
        apt-get install -y -qq ufw 2>/dev/null
    fi
    
    ufw --force reset &>/dev/null || true
    ufw default deny incoming
    ufw default allow outgoing
    
    # Essential ports
    ufw allow "${SSH_NEW_PORT}/tcp" comment 'SSH' 2>/dev/null || true
    ufw allow "${TRAEFIK_HTTP_PORT}/tcp" comment 'HTTP' 2>/dev/null || true
    ufw allow "${TRAEFIK_HTTPS_PORT}/tcp" comment 'HTTPS' 2>/dev/null || true
    
    # Service ports
    [[ " ${SELECTED_SERVICES[*]} " =~ " coolify " ]] && ufw allow "${COOLIFY_PORT}/tcp" comment 'Coolify' 2>/dev/null || true
    [[ " ${SELECTED_SERVICES[*]} " =~ " supabase " ]] && ufw allow "${SUPABASE_PORT}/tcp" comment 'Supabase' 2>/dev/null || true
    [[ " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] && ufw allow "${PORTAINER_PORT}/tcp" comment 'Portainer' 2>/dev/null || true
    [[ " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] && ufw allow "${UPTIME_KUMA_PORT}/tcp" comment 'Kuma' 2>/dev/null || true
    [[ " ${SELECTED_SERVICES[*]} " =~ " mtproto " ]] && ufw allow "${MTPROTO_PORT}/tcp" comment 'MTProto' 2>/dev/null || true
    
    ufw --force enable 2>/dev/null || true
    
    # Fail2Ban
    if [[ "$FAIL2BAN_ENABLE" == "1" ]]; then
        if ! command_exists fail2ban; then
            apt-get install -y -qq fail2ban 2>/dev/null
        fi
        
        cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = 2222
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
EOF
        
        systemctl enable --now fail2ban &>/dev/null || true
        success "Fail2Ban enabled"
    fi
    
    success "Firewall configured (UFW)"
}

#-------------------------------------------------------------------------------
# AUTO UPDATES
#-------------------------------------------------------------------------------
setup_auto_updates() {
    [[ "$INSTALL_SECURITY" != "1" || "$AUTO_UPDATES" != "1" ]] && return 0
    
    step "Enabling auto security updates"
    
    apt-get install -y -qq unattended-upgrades apt-listchanges 2>/dev/null
    
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    
    systemctl enable --now unattended-upgrades &>/dev/null || true
    success "Auto-updates enabled"
}

#-------------------------------------------------------------------------------
# DOCKER
#-------------------------------------------------------------------------------
install_docker() {
    [[ " ${SELECTED_SERVICES[*]} " =~ " docker " ]] || return 0
    
    step "Installing Docker Engine"
    
    if command_exists docker && command_exists docker-compose; then
        info "Docker already installed"
        return 0
    fi
    
    # Remove old
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Add repo
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin 2>/dev/null
    
    usermod -aG docker "$SUDO_USER" 2>/dev/null || true
    
    # Daemon config
    cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "features": {"buildkit": true}
}
EOF
    
    systemctl enable --now docker
    success "Docker Engine + Compose installed"
}

#-------------------------------------------------------------------------------
# TRAEFIK
#-------------------------------------------------------------------------------
setup_traefik() {
    [[ " ${SELECTED_SERVICES[*]} " =~ " traefik " ]] || return 0
    
    step "Setting up Traefik"
    
    [[ -z "$ADMIN_EMAIL" ]] && ADMIN_EMAIL="admin@${DOMAIN_NAME:-localhost}"
    
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
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.api.rule=Host(\`traefik.${DOMAIN_NAME:-localhost}\`)"
      - "traefik.http.routers.api.service=api@internal"
      - "traefik.http.routers.api.tls=true"

networks:
  monolith:
    external: true
EOF
    
    docker network create monolith 2>/dev/null || true
    
    cd "$COMPOSE_DIR"
    [[ "$SKIP_PULL" != "1" ]] && docker compose -f docker-compose.traefik.yml pull --quiet
    docker compose -f docker-compose.traefik.yml up -d --quiet-pull
    
    success "Traefik configured"
}

#-------------------------------------------------------------------------------
# COOLIFY
#-------------------------------------------------------------------------------
install_coolify() {
    [[ " ${SELECTED_SERVICES[*]} " =~ " coolify " ]] || return 0
    
    step "Installing Coolify"
    
    cat > "${COMPOSE_DIR}/docker-compose.coolify.yml" << EOF
version: '3.8'
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
      - DB_HOST=postgres
      - DB_PORT=5432
      - DB_DATABASE=coolify
      - DB_USERNAME=coolify
      - DB_PASSWORD=${COOLIFY_DB_PASS}
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.coolify.rule=Host(\`coolify.${DOMAIN_NAME:-localhost}\`)"
      - "traefik.http.routers.coolify.tls=true"
      - "traefik.http.routers.coolify.entrypoints=websecure"
    networks:
      - monolith
    depends_on:
      - postgres

  postgres:
    image: postgres:15-alpine
    container_name: coolify-postgres
    restart: unless-stopped
    volumes:
      - coolify-pg/var/lib/postgresql/data
    environment:
      - POSTGRES_DB=coolify
      - POSTGRES_USER=coolify
      - POSTGRES_PASSWORD=${COOLIFY_DB_PASS}
    networks:
      - monolith

volumes:
  coolify-
  coolify-pg

networks:
  monolith:
    external: true
EOF
    
    cd "$COMPOSE_DIR"
    [[ "$SKIP_PULL" != "1" ]] && docker compose -f docker-compose.coolify.yml pull --quiet
    docker compose -f docker-compose.coolify.yml up -d --quiet-pull
    
    success "Coolify: https://coolify.${DOMAIN_NAME:-${SERVER_IP}}:${COOLIFY_PORT}"
}

#-------------------------------------------------------------------------------
# SUPABASE
#-------------------------------------------------------------------------------
install_supabase() {
    [[ " ${SELECTED_SERVICES[*]} " =~ " supabase " ]] || return 0
    
    step "Installing Supabase"
    
    cat > "${COMPOSE_DIR}/docker-compose.supabase.yml" << EOF
version: '3.8'
services:
  supabase:
    image: supabase/postgres:15.1.0.147
    container_name: supabase-postgres
    restart: unless-stopped
    ports:
      - "${SUPABASE_PORT}:5432"
    volumes:
      - supabase-pg/var/lib/postgresql/data
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
  supabase-pg

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
    chmod 600 "${COMPOSE_DIR}/supabase-credentials.txt"
    
    cd "$COMPOSE_DIR"
    [[ "$SKIP_PULL" != "1" ]] && docker compose -f docker-compose.supabase.yml pull --quiet
    docker compose -f docker-compose.supabase.yml up -d --quiet-pull
    
    success "Supabase: ${SERVER_IP}:${SUPABASE_PORT}"
}

#-------------------------------------------------------------------------------
# MONITORING
#-------------------------------------------------------------------------------
install_monitoring() {
    [[ " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] || return 0
    
    step "Installing monitoring stack"
    
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
      - portainer-/data
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
      - "3001:3001"
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
  portainer-
  kuma-data:

networks:
  monolith:
    external: true
EOF
    
    cd "$COMPOSE_DIR"
    [[ "$SKIP_PULL" != "1" ]] && docker compose -f docker-compose.monitoring.yml pull --quiet
    docker compose -f docker-compose.monitoring.yml up -d --quiet-pull
    
    success "Monitoring: Portainer, Uptime Kuma, Watchtower"
}

#-------------------------------------------------------------------------------
# DEVSTACK
#-------------------------------------------------------------------------------
install_devstack() {
    [[ " ${SELECTED_SERVICES[*]} " =~ " devstack " ]] || return 0
    
    step "Installing development toolchain"
    
    apt-get install -y -qq \
        nodejs npm python3 python3-pip python3-venv \
        golang-go rustc cargo \
        postgresql-client redis-tools \
        git build-essential libssl-dev pkg-config 2>/dev/null || true
    
    npm install -g pnpm yarn typescript ts-node 2>/dev/null || true
    
    # Template
    mkdir -p /opt/templates/python-app
    cat > /opt/templates/python-app/requirements.txt << 'EOF'
fastapi
uvicorn[standard]
psycopg2-binary
redis
pydantic
EOF
    
    success "Dev toolchain installed"
}

#-------------------------------------------------------------------------------
# BACKUPS
#-------------------------------------------------------------------------------
setup_backups() {
    [[ " ${SELECTED_SERVICES[*]} " =~ " backups " ]] || return 0
    
    step "Configuring backup system"
    
    cat > /usr/local/bin/monolith-pg-backup << 'EOF'
#!/bin/bash
BACKUP_DIR="/opt/monolith-backups/postgres"
DATE=$(date +%Y%m%d_%H%M%S)
CONTAINER="${1:-supabase-postgres}"
DB_NAME="${2:-postgres}"
DB_USER="${3:-postgres}"

mkdir -p "$BACKUP_DIR"
docker exec "$CONTAINER" pg_dump -U "$DB_USER" "$DB_NAME" 2>/dev/null | \
    gzip > "${BACKUP_DIR}/${DB_NAME}_${DATE}.sql.gz"

find "$BACKUP_DIR" -name "${DB_NAME}_*.sql.gz" -type f -mtime +7 -delete
echo "Backup: ${BACKUP_DIR}/${DB_NAME}_${DATE}.sql.gz"
EOF
    chmod +x /usr/local/bin/monolith-pg-backup
    
    # Cron
    if ! crontab -l 2>/dev/null | grep -q "monolith-pg-backup"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/monolith-pg-backup") | crontab -
    fi
    
    success "Backup system configured"
}

#-------------------------------------------------------------------------------
# MTPROTO
#-------------------------------------------------------------------------------
install_mtproto() {
    [[ " ${SELECTED_SERVICES[*]} " =~ " mtproto " ]] || return 0
    
    step "Installing MTProto proxy"
    
    local secret="$(openssl rand -hex 16)"
    
    cat > "${COMPOSE_DIR}/docker-compose.mtproto.yml" << EOF
version: '3.8'
services:
  mtproto:
    image: alexbers/mtprotoproxy:latest
    container_name: mtproto-proxy
    restart: unless-stopped
    ports:
      - "${MTPROTO_PORT}:443"
    environment:
      - DOMAIN=${DOMAIN_NAME:-${SERVER_IP}}
      - SECRET=${secret}
      - TAG=monolith
    networks:
      - monolith

networks:
  monolith:
    external: true
EOF
    
    echo "MTProto Proxy: https://t.me/proxy?server=${SERVER_IP}&port=${MTPROTO_PORT}&secret=${secret}" \
        > "${COMPOSE_DIR}/mtproto-info.txt"
    
    cd "$COMPOSE_DIR"
    [[ "$SKIP_PULL" != "1" ]] && docker compose -f docker-compose.mtproto.yml pull --quiet
    docker compose -f docker-compose.mtproto.yml up -d --quiet-pull
    
    success "MTProto proxy installed"
}

#-------------------------------------------------------------------------------
# CLOUDFLARE DNS
#-------------------------------------------------------------------------------
update_cloudflare_dns() {
    [[ "$SKIP_DNS" == "1" ]] && return 0
    [[ -z "$CF_API_TOKEN" || -z "$CF_ZONE_ID" || -z "$DOMAIN_NAME" ]] && return 0
    
    step "Updating Cloudflare DNS"
    
    local proxied="false"
    [[ "$CF_PROXY" == "1" ]] && proxied="true"
    
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
        }" 2>/dev/null) || { warn "Cloudflare API failed"; return 1; }
    
    if echo "$response" | grep -q '"success":true' 2>/dev/null; then
        success "Cloudflare DNS updated (${DOMAIN_NAME} → ${SERVER_IP})"
    else
        warn "Cloudflare update: $response"
    fi
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
    [[ "$SSH_NEW_PORT" != "22" ]] && echo "  SSH:          ssh -p ${SSH_NEW_PORT} user@${SERVER_IP}"
    [[ " ${SELECTED_SERVICES[*]} " =~ " coolify " ]] && echo "  Coolify:      https://coolify.${DOMAIN_NAME:-${SERVER_IP}}:${COOLIFY_PORT}"
    [[ " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] && echo "  Portainer:    https://portainer.${DOMAIN_NAME:-${SERVER_IP}}:${PORTAINER_PORT}"
    [[ " ${SELECTED_SERVICES[*]} " =~ " monitoring " ]] && echo "  Uptime Kuma:  https://kuma.${DOMAIN_NAME:-${SERVER_IP}}:${UPTIME_KUMA_PORT}"
    [[ " ${SELECTED_SERVICES[*]} " =~ " supabase " ]] && echo "  Supabase:     ${SERVER_IP}:${SUPABASE_PORT}"
    echo
    echo -e "${YELLOW}📁 Paths:${NC}"
    echo "  Compose:      ${COMPOSE_DIR}/"
    echo "  Backups:      ${BACKUP_DIR}/"
    echo "  Logs:         ${LOG_FILE}"
    [[ " ${SELECTED_SERVICES[*]} " =~ " supabase " ]] && echo "  Credentials:  ${COMPOSE_DIR}/supabase-credentials.txt"
    echo
    echo -e "${RED}⚠️  Security:${NC}"
    echo "  1. Change default passwords"
    echo "  2. Restrict admin panels (VPN/Cloudflare Access)"
    echo "  3. Configure external backups (S3/Backblaze)"
    echo "  4. Keep SSH key secure!"
    echo
    echo -e "${GREEN}🎉 Private cloud ready!${NC}"
}

#-------------------------------------------------------------------------------
# MAIN ORCHESTRATOR
#-------------------------------------------------------------------------------
run_installation() {
    INSTALLATION_START_TIME=$(date +%s)
    
    info "Starting VPS PRO MONOLITH v${SCRIPT_VERSION}"
    notify_telegram "🚀 **Monolith Installation Started**\n\nHost: \`${HOSTNAME:-$SERVER_IP}\`\nIP: \`${SERVER_IP}\`\nTime: $(date '+%Y-%m-%d %H:%M:%S')"
    
    local total_steps=10
    local current_step=0
    
    system_prepare; ((current_step++)); notify_progress $current_step $total_steps "System prepared"
    setup_swap; ((current_step++)); notify_progress $current_step $total_steps "Swap configured"
    
    [[ " ${SELECTED_SERVICES[*]} " =~ " security " ]] && {
        harden_ssh; ((current_step++)); notify_progress $current_step $total_steps "SSH hardened"
        setup_firewall; ((current_step++)); notify_progress $current_step $total_steps "Firewall configured"
        setup_auto_updates; ((current_step++)); notify_progress $current_step $total_steps "Auto-updates enabled"
    }
    
    install_docker; ((current_step++)); notify_progress $current_step $total_steps "Docker installed"
    setup_traefik; ((current_step++)); notify_progress $current_step $total_steps "Traefik configured"
    install_coolify; ((current_step++)); notify_progress $current_step $total_steps "Coolify installed"
    install_supabase; ((current_step++)); notify_progress $current_step $total_steps "Supabase installed"
    install_monitoring; ((current_step++)); notify_progress $current_step $total_steps "Monitoring installed"
    install_devstack; ((current_step++)); notify_progress $current_step $total_steps "Devstack installed"
    setup_backups; ((current_step++)); notify_progress $current_step $total_steps "Backups configured"
    install_mtproto; ((current_step++)); notify_progress $current_step $total_steps "MTProto installed"
    
    update_cloudflare_dns
    run_post_install_hook
    
    show_summary
    
    notify_telegram "✅ **Monolith Installation Complete**\n\nHost: \`${HOSTNAME:-$SERVER_IP}\`\nDuration: ${duration}s\n\n🔗 Services:\n• Coolify: https://coolify.${DOMAIN_NAME:-${SERVER_IP}}:${COOLIFY_PORT}\n• Portainer: https://portainer.${DOMAIN_NAME:-${SERVER_IP}}:${PORTAINER_PORT}\n• SSH: ${SERVER_IP}:${SSH_NEW_PORT}"
}

#-------------------------------------------------------------------------------
# ENTRY POINT
#-------------------------------------------------------------------------------
main() {
    [[ $EUID -ne 0 ]] && exec sudo bash "$0" "$@"
    
    mkdir -p "$(dirname "$LOG_FILE")"
    SERVER_IP="${SERVER_IP:-$(get_public_ip)}"
    
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
        show_tui_menu
        [[ ${#SELECTED_SERVICES[@]} -eq 0 ]] && warn "No services selected" && exit 0
    fi
    
    # Confirm
    if [[ "$SKIP_CONFIRM" != "1" && "$UNATTENDED" != "1" ]]; then
        read -p $'\nProceed with installation? [y/N] ' -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && echo "Cancelled." && exit 0
    fi
    
    # Install
    run_installation
}

# Error handler
trap 'error "Script failed at line $LINENO"; exit 1' ERR

# Run
main "$@"
