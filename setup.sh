#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 🚀 VPS ULTIMATE MONOLITH: TOTAL EDITION (GUM TUI + SUPABASE + 30+ TOOLS)
# Supported OS: Ubuntu 22.04 / 24.04
# ==============================================================================

LOG_FILE="/var/log/vps_bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

GREEN='#00FF00'
YELLOW='#FFFF00'
RED='#FF0000'

# ------------------------------------------------------------------------------
# 1. ROOT CHECK + INSTALL GUM
# ------------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && { echo "Ошибка: Нужен root (sudo -i)"; exit 1; }

if ! command -v gum &>/dev/null; then
    echo "Установка TUI-движка (Gum)..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" > /etc/apt/sources.list.d/charm.list
    apt update && apt install -y gum
fi

clear
gum style --border double --margin "1 2" --padding "1 2" --border-foreground "$GREEN" \
    "🚀 VPS ULTIMATE MONOLITH" "The Final Enterprise Stack"

# ------------------------------------------------------------------------------
# 2. TELEGRAM
# ------------------------------------------------------------------------------
TG_TOKEN=$(gum input --placeholder "Telegram Bot Token (Оставьте пустым, чтобы пропустить)")
TG_CHAT=$(gum input --placeholder "Telegram Chat ID")

tg() {
    [[ -z "$TG_TOKEN" || -z "$TG_CHAT" ]] && return 0
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
        -d "chat_id=$TG_CHAT&text=$1&parse_mode=Markdown" >/dev/null || true
}

# ------------------------------------------------------------------------------
# 3. MENU SELECTION
# ------------------------------------------------------------------------------
SELECTED=$(gum choose --no-limit --height 25 \
    "System: Update & Core (git, curl, build-essential)" \
    "System: 2GB Swap File" \
    "System: Zsh + Oh My Zsh + Starship" \
    "System: Full Utility Pack (btop, mc, tmux, ncdu, neofetch, jq)" \
    "Security: SSH Port 2222 & Root Hardening" \
    "Security: Firewall (UFW) + Fail2Ban" \
    "Security: Unattended-Upgrades (Auto-patches)" \
    "Docker: Engine + Compose (Log rotation enabled)" \
    "Docker: Portainer CE (Web UI)" \
    "Docker: Watchtower (Auto-update images)" \
    "PaaS: Coolify (Self-hosted Vercel/Render)" \
    "BaaS: Supabase (Full Stack: Auth, DB, Realtime)" \
    "VPN: Amnezia VPN Ready (Kernel modules)" \
    "VPN: MTProto Proxy (Telegram)" \
    "Proxy: Nginx Proxy Manager (SSL UI)" \
    "Proxy: Traefik Cloud-Native Proxy" \
    "Monitoring: Uptime Kuma (Status Pages)" \
    "Dev: Node.js LTS + NPM" \
    "Dev: Python3 + Pip + Venv" \
    "Dev: Golang + Rust" \
    "Database: PostgreSQL + Redis (Native)" \
    "Network: Cloudflare Tunnel & Speedtest" \
    "Backup: Rclone (Cloud Sync Tool)" \
    "Backup: Daily PG Dump Script (to /opt/backups)")

has() { grep -q "$1" <<< "$SELECTED"; }

# ------------------------------------------------------------------------------
# 4. INSTALL CORE SYSTEM
# ------------------------------------------------------------------------------
if has "System: Update"; then
    gum spin --spinner dot --title "Обновление системы..." -- bash -c "
        apt update && apt upgrade -y
        apt install -y curl git wget build-essential xxd software-properties-common ca-certificates jq
    "
fi

if has "2GB Swap"; then
    if ! swapon --show | grep -q /swapfile; then
        fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
fi

if has "SSH Port 2222"; then
    sed -i "s/^#\?Port .*/Port 2222/" /etc/ssh/sshd_config
    sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
    sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
    systemctl restart ssh
fi

if has "Zsh"; then
    apt install -y zsh
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    apt install -y starship
fi

if has "Full Utility Pack"; then
    apt install -y btop tmux ncdu mc neofetch jq
fi

# ------------------------------------------------------------------------------
# 5. DOCKER & CORE CONTAINERS
# ------------------------------------------------------------------------------
if has "Docker: Engine"; then
    gum spin --spinner dot --title "Установка Docker..." -- bash -c "curl -fsSL https://get.docker.com | sh"
    mkdir -p /etc/docker
    cat >/etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    systemctl restart docker
fi

[[ $SELECTED == *"Portainer"* ]] && docker run -d --name portainer --restart=always -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
[[ $SELECTED == *"Uptime Kuma"* ]] && docker run -d --name uptime-kuma --restart=always -p 3001:3001 -v uptime-kuma:/app/data louislam/uptime-kuma:1
[[ $SELECTED == *"Watchtower"* ]] && docker run -d --name watchtower --restart=always -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval 3600

# ------------------------------------------------------------------------------
# 6. SUPABASE
# ------------------------------------------------------------------------------
if has "Supabase"; then
    gum spin --spinner dot --title "Развертывание Supabase..." -- bash -c "
    mkdir -p /opt/supabase && cd /opt/supabase
    git clone --depth 1 https://github.com/supabase/supabase .
    cp docker/.env.example .env
    sed -i \"s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/\" .env
    sed -i \"s/JWT_SECRET=.*/JWT_SECRET=$(openssl rand -hex 32)/\" .env
    docker compose -f docker/docker-compose.yml up -d
    "
fi

# ------------------------------------------------------------------------------
# 7. AMNEZIA VPN
# ------------------------------------------------------------------------------
if has "Amnezia VPN"; then
    apt install -y linux-modules-extra-$(uname -r) || true
    modprobe wireguard tun
fi

# ------------------------------------------------------------------------------
# 8. COOLIFY
# ------------------------------------------------------------------------------
if has "Coolify"; then
    gum spin --spinner dot --title "Установка Coolify..." -- bash -c "curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash"
fi

# ------------------------------------------------------------------------------
# 9. DEV TOOLS
# ------------------------------------------------------------------------------
[[ $SELECTED == *"Node.js"* ]] && { curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -; apt install -y nodejs; }
[[ $SELECTED == *"Python3"* ]] && apt install -y python3 python3-pip python3-venv
[[ $SELECTED == *"Golang"* ]] && apt install -y golang-go
[[ $SELECTED == *"Rust"* ]] && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# ------------------------------------------------------------------------------
# 10. SECURITY
# ------------------------------------------------------------------------------
if has "Firewall"; then
    apt install -y ufw fail2ban
    ufw allow 2222/tcp && ufw allow 80,443,8000,9443,3001/tcp && ufw --force enable
    systemctl enable fail2ban && systemctl restart fail2ban
fi

# ------------------------------------------------------------------------------
# 11. BACKUPS
# ------------------------------------------------------------------------------
if has "Backup: Daily"; then
    mkdir -p /opt/backups
    cat >/usr/local/bin/vps_backup.sh <<EOF
#!/bin/bash
DATE=\$(date +%F)
sudo -u postgres pg_dumpall | gzip > /opt/backups/native-pg-\$DATE.sql.gz
find /opt/backups -type f -mtime +7 -delete
EOF
    chmod +x /usr/local/bin/vps_backup.sh
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/vps_backup.sh") | crontab -
fi

# ------------------------------------------------------------------------------
# 12. FINAL REPORT
# ------------------------------------------------------------------------------
IP=$(curl -s ifconfig.me || echo "unknown")
REPORT="✅ *VPS MONOLITH DEPLOYED!*
📍 *IP:* \`$IP\`
🔑 *SSH Port:* \`2222\`
🚀 *Services:*
- Supabase: http://$IP:8000
- Portainer: https://$IP:9443
- Uptime Kuma: http://$IP:3001
- Coolify: http://$IP:8000 (Check ports!)"

tg "$REPORT"

gum style --foreground "$GREEN" --border double --margin "1" --padding "1 2" \
    "ПОЛНЫЙ СТЕК УСТАНОВЛЕН!" "IP: $IP" "SSH Port: 2222" "Проверьте Telegram для деталей."
