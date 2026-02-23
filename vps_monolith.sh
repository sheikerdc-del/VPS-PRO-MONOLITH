#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 🚀 VPS PRO MONOLITH v1.0.2
# Исправлено: зависание интерфейса и инициализация TUI.
# ==============================================================================

LOG_FILE="/var/log/vps_monolith.log"
GREEN='#00FF00'
YELLOW='#FFFF00'

# 1. Проверка прав (Root)
if [[ $EUID -ne 0 ]]; then
    echo "❌ Ошибка: запустите от root (sudo -i)"
    exit 1
fi

# 2. Установка зависимостей (тихий режим)
echo "🔄 Подготовка системы и установка интерфейса..."
apt-get update -qq && apt-get install -y curl git wget gpg jq xxd ca-certificates software-properties-common -qq > /dev/null 2>&1

# Установка GUM, если его нет
if ! command -v gum &>/dev/null; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" > /etc/apt/sources.list.d/charm.list
    apt-get update -qq && apt-get install -y gum -qq > /dev/null 2>&1
fi

# 3. Приветствие
clear
gum style --border double --margin "1 2" --padding "1 2" --border-foreground "$GREEN" \
    "🚀 VPS PRO MONOLITH v1.0.2" "Private Cloud One-Shot Bootstrap"

# 4. Интерактивный сбор данных (через gum, с принудительным TTY)
echo "📝 Введите данные (или оставьте пустыми):"
TG_TOKEN=$(gum input --placeholder "Telegram Bot Token") || TG_TOKEN=""
TG_CHAT=$(gum input --placeholder "Telegram Chat ID") || TG_CHAT=""

echo "🌐 Настройка домена (Cloudflare):"
CF_DOMAIN=$(gum input --placeholder "Domain (e.g., vps.example.com)") || CF_DOMAIN=""
CF_TOKEN=$(gum input --placeholder "Cloudflare API Token") || CF_TOKEN=""
CF_ZONE=$(gum input --placeholder "Cloudflare Zone ID") || CF_ZONE=""

# 5. Главное меню (Цикл выбора)
SELECTED=""
while [[ -z "$SELECTED" ]]; do
    SELECTED=$(gum choose --no-limit --height 20 --header "Выберите компоненты (Пробел - выбор, Enter - старт):" \
        "System: Core Updates" \
        "System: 2GB Swap" \
        "System: Zsh + Starship UI" \
        "Security: SSH Port 2222" \
        "Security: Firewall + Fail2Ban" \
        "Docker: Engine + Compose" \
        "PaaS: Coolify (Port 8000)" \
        "BaaS: Supabase (Port 8080)" \
        "VPN: Amnezia Kernel Ready" \
        "VPN: MTProto Proxy" \
        "UI: Portainer CE" \
        "UI: Uptime Kuma" \
        "Ops: Watchtower" \
        "Database: PostgreSQL + Redis" \
        "Backup: Daily PG Dumps")
    
    if [[ -z "$SELECTED" ]]; then
        echo "⚠️ Пожалуйста, выберите хотя бы один пункт!"
        sleep 1
    fi
done

# 6. Функция уведомлений
tg_notify() {
    if [[ -n "$TG_TOKEN" && -n "$TG_CHAT" ]]; then
        curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
             -d "chat_id=$TG_CHAT&text=$1&parse_mode=Markdown" >/dev/null || true
    fi
}

# 7. Исполнение
clear
gum style --foreground "$YELLOW" "🚀 Начинаем установку... Логи: $LOG_FILE"

# Docker (База)
if [[ $SELECTED == *"Docker: Engine"* ]]; then
    gum spin --spinner dot --title "Установка Docker..." -- bash -c "
    curl -fsSL https://get.docker.com | sh
    mkdir -p /etc/docker
    echo '{\"log-driver\":\"json-file\",\"log-opts\":{\"max-size\":\"10m\",\"max-file\":\"3\"}}' > /etc/docker/daemon.json
    systemctl restart docker" >> "$LOG_FILE" 2>&1
fi

# Системные правки
[[ $SELECTED == *"System: Core Updates"* ]] && gum spin --spinner dot --title "Обновление системы..." -- bash -c "apt-get upgrade -y && apt-get install -y btop mc tmux ncdu" >> "$LOG_FILE" 2>&1
[[ $SELECTED == *"System: 2GB Swap"* ]] && gum spin --spinner dot --title "Swap 2GB..." -- bash -c "fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab" >> "$LOG_FILE" 2>&1

# SSH Security
if [[ $SELECTED == *"SSH Port 2222"* ]]; then
    gum spin --spinner dot --title "Hardening SSH..." -- bash -c "sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config && systemctl restart ssh" >> "$LOG_FILE" 2>&1
fi

# Supabase & Coolify
if [[ $SELECTED == *"Supabase"* ]]; then
    gum spin --spinner dot --title "Supabase (Port 8080)..." -- bash -c "
    mkdir -p /opt/supabase && cd /opt/supabase
    git clone --depth 1 https://github.com/supabase/supabase .
    cp docker/.env.example .env
    sed -i 's/KONG_HTTP_PORT=8000/KONG_HTTP_PORT=8080/' .env
    sed -i \"s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/\" .env
    sed -i \"s/JWT_SECRET=.*/JWT_SECRET=$(openssl rand -hex 32)/\" .env
    docker compose -f docker/docker-compose.yml up -d" >> "$LOG_FILE" 2>&1
fi

[[ $SELECTED == *"Coolify"* ]] && gum spin --spinner dot --title "Coolify..." -- bash -c "curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash" >> "$LOG_FILE" 2>&1

# Cloudflare DNS
if [[ -n "$CF_TOKEN" && -n "$CF_DOMAIN" ]]; then
    IP=$(curl -s ifconfig.me)
    gum spin --spinner dot --title "Cloudflare DNS..." -- bash -c "
    curl -s -X POST \"https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records\" \
         -H \"Authorization: Bearer $CF_TOKEN\" \
         -H \"Content-Type: application/json\" \
         --data '{\"type\":\"A\",\"name\":\"$CF_DOMAIN\",\"content\":\"$IP\",\"ttl\":120}'" >> "$LOG_FILE" 2>&1
fi

# 8. Финал
clear
IP_ADDR=$(curl -s ifconfig.me)
FINAL_HOST=${CF_DOMAIN:-$IP_ADDR}

MESSAGE="✅ *VPS PRO MONOLITH Ready!*
Host: \`$FINAL_HOST\`
SSH: \`2222\`
---
Coolify: http://$FINAL_HOST:8000
Supabase: http://$FINAL_HOST:8080"

tg_notify "$MESSAGE"

gum style --border double --margin "1 2" --padding "1 2" --border-foreground "$GREEN" \
    "🎉 ВСЁ ГОТОВО!" \
    "IP: $IP_ADDR" \
    "SSH Port: 2222" \
    "Логи: $LOG_FILE"

echo -e "\nДля выхода нажмите Enter..."
read
