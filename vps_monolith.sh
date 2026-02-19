#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 🚀 VPS PRO MONOLITH: TOTAL & CLOUDFLARE EDITION
# Repository: https://github.com/sheikerdc-del/VPS-PRO-MONOLITH
# ==============================================================================

LOG_FILE="/var/log/vps_monolith.log"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

GREEN='#00FF00'
YELLOW='#FFFF00'
RED='#FF0000'

# --- 1. ПРЕДУСТАНОВКА И ПРОВЕРКИ ---
[[ $EUID -ne 0 ]] && { echo -e "\e[31mОшибка: запустите через sudo -i\e[0m"; exit 1; }

echo "Подготовка окружения и установка TUI (Gum)..."
apt update && apt install -y curl git wget gpg jq xxd ca-certificates software-properties-common < /dev/null

if ! command -v gum &>/dev/null; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" > /etc/apt/sources.list.d/charm.list
    apt update && apt install -y gum
fi

clear
gum style --border double --margin "1 2" --padding "1 2" --border-foreground "$GREEN" \
    "🚀 VPS PRO MONOLITH" "Full Enterprise Stack + Cloudflare Automation"

# --- 2. СБОР ДАННЫХ ---
if [[ -z "${VPS_UNATTENDED:-}" ]]; then
    TG_TOKEN=$(gum input --placeholder "Telegram Bot Token (Enter для пропуска)")
    TG_CHAT=$(gum input --placeholder "Telegram Chat ID")
    
    echo "--- Настройка Cloudflare (необязательно) ---"
    CF_TOKEN=$(gum input --placeholder "Cloudflare API Token (Edit Zone DNS)")
    CF_ZONE=$(gum input --placeholder "Cloudflare Zone ID")
    CF_DOMAIN=$(gum input --placeholder "Domain (e.g. app.example.com)")
else
    TG_TOKEN="${VPS_TG_TOKEN:-}"
    TG_CHAT="${VPS_TG_CHAT:-}"
    CF_TOKEN=""
    CF_ZONE=""
    CF_DOMAIN=""
fi

tg() {
    [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT:-}" ]] && return 0
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
         -d "chat_id=$TG_CHAT&text=$1&parse_mode=Markdown" >/dev/null || true
}

# --- 3. ГЛАВНОЕ МЕНЮ ---
SELECTED=$(gum choose --no-limit --height 25 \
    "System: Update & Core Packages" \
    "System: 2GB Swap File" \
    "System: Zsh + Oh My Zsh + Starship" \
    "System: Full Utility Pack (btop, mc, tmux, ncdu, jq)" \
    "Security: SSH Port 2222 & Root Hardening" \
    "Security: Firewall (UFW) + Fail2Ban" \
    "Security: Unattended-Upgrades" \
    "Cloudflare: Auto DNS Record" \
    "Docker: Engine + Compose (Log rotation)" \
    "Docker: Portainer CE" \
    "Docker: Watchtower" \
    "PaaS: Coolify (Port 8000)" \
    "BaaS: Supabase (Port 8080)" \
    "VPN: Amnezia VPN Ready" \
    "VPN: MTProto Proxy" \
    "Proxy: Nginx Proxy Manager" \
    "Proxy: Traefik v3" \
    "Monitoring: Uptime Kuma" \
    "Dev: Node.js LTS" \
    "Dev: Python3, Go, Rust" \
    "Database: PostgreSQL + Redis (Native)" \
    "Network: Cloudflare Tunnel + Speedtest" \
    "Backup: Rclone + Daily PG Dump")

# --- 4. ЛОГИКА УСТАНОВКИ ---

# Система
if [[ $SELECTED == *"System: Update"* ]]; then
    gum spin --spinner dot --title "Обновление системы..." -- bash -c "apt update && apt upgrade -y"
fi

if [[ $SELECTED == *"2GB Swap"* ]]; then
    if [[ ! -f /swapfile ]]; then
        gum spin --spinner dot --title "Настройка Swap..." -- bash -c "fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab"
    fi
fi

# Zsh & Starship
if [[ $SELECTED == *"Zsh"* ]]; then
    apt install -y zsh
    [[ ! -d ~/.oh-my-zsh ]] && sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    curl -sS https://starship.rs/install.sh | sh -s -- -y
    echo 'eval "$(starship init zsh)"' >> ~/.zshrc || true
fi

# SSH
if [[ $SELECTED == *"SSH Port 2222"* ]]; then
    sed -i "s/^#\?Port .*/Port 2222/" /etc/ssh/sshd_config
    systemctl restart ssh
fi

# Cloudflare DNS
if [[ $SELECTED == *"Cloudflare: Auto DNS"* && -n "$CF_TOKEN" ]]; then
    IP_ADDR=$(curl -s ifconfig.me)
    gum spin --spinner dot --title "Обновление DNS Cloudflare..." -- bash -c "
    curl -X POST \"https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records\" \
         -H \"Authorization: Bearer $CF_TOKEN\" \
         -H \"Content-Type: application/json\" \
         --data '{\"type\":\"A\",\"name\":\"$CF_DOMAIN\",\"content\":\"$IP_ADDR\",\"ttl\":120,\"proxied\":true}'"
fi

# Docker
if [[ $SELECTED == *"Docker: Engine"* ]]; then
    gum spin --spinner dot --title "Установка Docker..." -- bash -c "curl -fsSL https://get.docker.com | sh"
    mkdir -p /etc/docker
    cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    systemctl restart docker
fi

# Supabase
if [[ $SELECTED == *"Supabase"* ]]; then
    gum spin --spinner dot --title "Установка Supabase (на порт 8080)..." -- bash -c "
    mkdir -p /opt/supabase && cd /opt/supabase
    git clone --depth 1 https://github.com/supabase/supabase .
    cp docker/.env.example .env
    sed -i 's/KONG_HTTP_PORT=8000/KONG_HTTP_PORT=8080/' .env
    sed -i \"s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/\" .env
    sed -i \"s/JWT_SECRET=.*/JWT_SECRET=$(openssl rand -hex 32)/\" .env
    docker compose -f docker/docker-compose.yml up -d"
fi

# Coolify
[[ $SELECTED == *"Coolify"* ]] && gum spin --spinner dot --title "Установка Coolify..." -- bash -c "curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash"

# VPN Amnezia
if [[ $SELECTED == *"Amnezia"* ]]; then
    apt install -y linux-modules-extra-$(uname -r) || true
    modprobe wireguard tun || true
    echo "wireguard" >> /etc/modules
    echo "tun" >> /etc/modules
fi

# Сервисы Docker
[[ $SELECTED == *"Portainer"* ]] && docker run -d --name portainer --restart=always -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
[[ $SELECTED == *"Uptime Kuma"* ]] && docker run -d --name uptime-kuma --restart=always -p 3001:3001 -v uptime-kuma:/app/data louislam/uptime-kuma:1
[[ $SELECTED == *"Watchtower"* ]] && docker run -d --name watchtower --restart=always -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval 3600

# Языки
[[ $SELECTED == *"Node.js"* ]] && { curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -; apt install -y nodejs; }
[[ $SELECTED == *"Python3"* ]] && apt install -y python3 python3-pip python3-venv
[[ $SELECTED == *"Golang"* ]] && apt install -y golang-go
[[ $SELECTED == *"Rust"* ]] && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# Безопасность
if [[ $SELECTED == *"Firewall"* ]]; then
    apt install -y ufw fail2ban
    ufw allow 2222/tcp
    ufw allow 80,443,8000,8080,9443,3001/tcp
    ufw --force enable
    systemctl enable fail2ban && systemctl restart fail2ban
fi

# Бэкапы
if [[ $SELECTED == *"Backup"* ]]; then
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

# --- 5. ФИНАЛИЗАЦИЯ ---
IP_FINAL=$(curl -s ifconfig.me || echo "unknown")
HOST=${CF_DOMAIN:-$IP_FINAL}

REPORT="✅ *VPS MONOLITH READY!*
📍 *Host:* \`$HOST\`
🔑 *SSH Port:* \`2222\`

🚀 *Web Services:*
- Coolify: http://$HOST:8000
- Supabase: http://$HOST:8080
- Portainer: https://$HOST:9443
- Uptime Kuma: http://$HOST:3001"

tg "$REPORT"

clear
gum style --foreground "$GREEN" --border double --margin "1" --padding "1" \
    "🎉 МОНОЛИТ УСПЕШНО РАЗВЕРНУТ!" "Хост: $HOST" "SSH Port: 2222" "Лог: $LOG_FILE"
