#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 🚀 VPS ULTIMATE MONOLITH: TOTAL EDITION
# Репозиторий: https://github.com/sheikerdc-del/VPS-PRO-MONOLITH
# ==============================================================================

LOG_FILE="/var/log/vps_monolith.log"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

GREEN='#00FF00'
YELLOW='#FFFF00'
RED='#FF0000'

# 1. Проверка root
[[ $EUID -ne 0 ]] && { echo -e "\e[31mОшибка: запустите через sudo -i\e[0m"; exit 1; }

# 2. Установка Gum (TUI) и зависимостей для работы скрипта
if ! command -v gum &>/dev/null; then
    echo "Установка интерфейса (Gum)..."
    apt update && apt install -y curl git wget gpg jq xxd < /dev/null
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" > /etc/apt/sources.list.d/charm.list
    apt update && apt install -y gum
fi

clear
gum style --border double --margin "1 2" --padding "1 2" --border-foreground "$GREEN" \
    "🚀 VPS ULTIMATE MONOLITH" "Full Enterprise Stack Installer"

# 3. Сбор данных для Telegram
if [[ -z "${VPS_UNATTENDED:-}" ]]; then
    TG_TOKEN=$(gum input --placeholder "Telegram Bot Token (Enter для пропуска)")
    TG_CHAT=$(gum input --placeholder "Telegram Chat ID")
else
    TG_TOKEN="${VPS_TG_TOKEN:-}"
    TG_CHAT="${VPS_TG_CHAT:-}"
fi

tg() {
    [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT:-}" ]] && return 0
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
         -d "chat_id=$TG_CHAT&text=$1&parse_mode=Markdown" >/dev/null || true
}

# 4. Меню выбора
if [[ -z "${VPS_UNATTENDED:-}" ]]; then
    SELECTED=$(gum choose --no-limit --height 22 \
        "System: Update & Core" \
        "System: 2GB Swap" \
        "System: Zsh + Starship Prompt" \
        "System: Utility Pack (btop, mc, tmux, ncdu, neofetch)" \
        "Security: SSH 2222 & Root Hardening" \
        "Security: Firewall + Fail2Ban" \
        "Docker: Engine + Compose" \
        "Docker: Portainer CE" \
        "Docker: Watchtower" \
        "PaaS: Coolify" \
        "BaaS: Supabase (Auth, DB, Storage)" \
        "VPN: Amnezia VPN Ready" \
        "VPN: MTProto Proxy" \
        "Proxy: Nginx Proxy Manager" \
        "Monitoring: Uptime Kuma" \
        "Dev: Node.js LTS" \
        "Dev: Python3, Go, Rust" \
        "Database: PostgreSQL + Redis" \
        "Backup: Daily PG Dump")
else
    SELECTED="System: Update & Core,System: 2GB Swap,Docker: Engine + Compose,Security: Firewall + Fail2Ban"
fi

# ------------------------------------------------------------------------------
# 5. Логика установки
# ------------------------------------------------------------------------------

# Обновление системы
if [[ $SELECTED == *"System: Update"* ]]; then
    gum spin --spinner dot --title "Обновление системы..." -- bash -c "apt update && apt upgrade -y && apt install -y build-essential ca-certificates software-properties-common"
fi

# Swap
if [[ $SELECTED == *"2GB Swap"* ]]; then
    if [[ ! -f /swapfile ]]; then
        gum spin --spinner dot --title "Создание Swap..." -- bash -c "fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab"
    fi
fi

# SSH
if [[ $SELECTED == *"SSH 2222"* ]]; then
    gum spin --spinner dot --title "Настройка SSH (Порт 2222)..." -- bash -c "sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config && systemctl restart ssh"
fi

# Zsh & Starship
if [[ $SELECTED == *"Zsh"* ]]; then
    apt install -y zsh
    [[ ! -d ~/.oh-my-zsh ]] && sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
    curl -sS https://starship.rs/install.sh | sh -s -- -y
    echo 'eval "$(starship init zsh)"' >> ~/.zshrc
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

# Supabase (С исправлением конфликтов и генерацией секретов)
if [[ $SELECTED == *"Supabase"* ]]; then
    gum spin --spinner dot --title "Развертывание Supabase (Порт 8080)..." -- bash -c "
    mkdir -p /opt/supabase && cd /opt/supabase
    git clone --depth 1 https://github.com/supabase/supabase .
    cp docker/.env.example .env
    # Меняем порт, чтобы не конфликтовать с Coolify
    sed -i 's/KONG_HTTP_PORT=8000/KONG_HTTP_PORT=8080/' .env
    sed -i \"s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/\" .env
    sed -i \"s/JWT_SECRET=.*/JWT_SECRET=$(openssl rand -hex 32)/\" .env
    docker compose -f docker/docker-compose.yml up -d"
fi

# Coolify
[[ $SELECTED == *"Coolify"* ]] && gum spin --spinner dot --title "Установка Coolify..." -- bash -c "curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash"

# VPN & Proxy
if [[ $SELECTED == *"Amnezia"* ]]; then
    apt install -y linux-modules-extra-$(uname -r) || true
    modprobe wireguard tun || true
fi

if [[ $SELECTED == *"MTProto"* ]]; then
    MT_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    docker run -d --name mtproto-proxy --restart always -p 8443:443 -e SECRET="$MT_SECRET" telegrammessenger/proxy:latest
    echo "$MT_SECRET" > /root/mtproto_secret.txt
fi

# Сервисы мониторинга и управления
[[ $SELECTED == *"Portainer"* ]] && docker run -d --name portainer --restart=always -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
[[ $SELECTED == *"Uptime Kuma"* ]] && docker run -d --name uptime-kuma --restart=always -p 3001:3001 -v uptime-kuma:/app/data louislam/uptime-kuma:1
[[ $SELECTED == *"Watchtower"* ]] && docker run -d --name watchtower --restart=always -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval 3600

# Security
if [[ $SELECTED == *"Firewall"* ]]; then
    apt install -y ufw fail2ban
    ufw allow 2222/tcp
    ufw allow 80,443,8000,8080,9443,3001/tcp
    ufw --force enable
    systemctl enable fail2ban && systemctl restart fail2ban
fi

# ------------------------------------------------------------------------------
# ОТЧЕТ
# ------------------------------------------------------------------------------
IP=$(curl -s ifconfig.me || echo "unknown")
REPORT="✅ *VPS MONOLITH DEPLOYED!*
📍 *IP:* \`$IP\`
🔑 *SSH Port:* \`2222\`

🚀 *Сервисы:*
- Supabase Studio: http://$IP:8080
- Coolify: http://$IP:8000
- Portainer: https://$IP:9443
- Uptime Kuma: http://$IP:3001"

tg "$REPORT"

gum style --foreground "$GREEN" --border double --margin "1" --padding "1" \
    "🎉 УСТАНОВКА ЗАВЕРШЕНА!" "IP: $IP" "SSH Port: 2222" "Проверьте Telegram."
