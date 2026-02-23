#!/usr/bin/env bash
# ==============================================================================
# 🚀 VPS PRO MONOLITH v1.0.1
# Исправлено: инициализация TUI и логика выбора компонентов.
# ==============================================================================

set -Eeuo pipefail

LOG_FILE="/var/log/vps_monolith.log"
GREEN='#00FF00'
YELLOW='#FFFF00'

# 1. Базовая проверка прав
if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: запустите от root (sudo -i)"
    exit 1
fi

# 2. Принудительная установка GUM перед запуском меню
install_gum() {
    if ! command -v gum &>/dev/null; then
        echo "Установка интерфейса (Gum)..."
        apt-get update -y > /dev/null
        apt-get install -y curl gnupg > /dev/null
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" > /etc/apt/sources.list.d/charm.list
        apt-get update -y > /dev/null
        apt-get install -y gum > /dev/null
    fi
}

install_gum

# 3. Приветствие
clear
gum style --border double --margin "1 2" --padding "1 2" --border-foreground "$GREEN" \
    "🚀 VPS PRO MONOLITH v1.0" "Private Cloud Bootstrap"

# 4. Сбор данных
echo "--- Настройка уведомлений ---"
TG_TOKEN=$(gum input --placeholder "Telegram Bot Token (Enter чтобы пропустить)")
TG_CHAT=$(gum input --placeholder "Telegram Chat ID")

echo "--- Настройка Cloudflare (Опционально) ---"
CF_DOMAIN=$(gum input --placeholder "Домен (например, vps.example.com)")
CF_TOKEN=$(gum input --placeholder "Cloudflare API Token")
CF_ZONE=$(gum input --placeholder "Cloudflare Zone ID")

# 5. Интерактивный выбор (Цикл, пока не выберут хотя бы один пункт)
SELECTED=""
while [[ -z "$SELECTED" ]]; do
    clear
    echo "Выберите компоненты (Пробел - выбрать, Enter - подтвердить):"
    SELECTED=$(gum choose --no-limit --height 20 \
        "System: Updates & Utilities" \
        "System: 2GB Swap File" \
        "System: Zsh + Starship UI" \
        "Security: SSH Port 2222" \
        "Security: Firewall & Fail2Ban" \
        "Docker: Engine + Compose" \
        "PaaS: Coolify (Port 8000)" \
        "BaaS: Supabase (Port 8080)" \
        "VPN: Amnezia Kernel Ready" \
        "VPN: MTProto Proxy" \
        "Monitoring: Uptime Kuma" \
        "Observability: Portainer" \
        "Ops: Watchtower" \
        "Database: PostgreSQL + Redis" \
        "Backup: Daily PG Dumps")
    
    if [[ -z "$SELECTED" ]]; then
        gum style --foreground "#FF0000" "Вы ничего не выбрали! Выберите хотя бы один пункт."
        sleep 2
    fi
done

# 6. Функция уведомлений
tg_notify() {
    if [[ -n "$TG_TOKEN" && -n "$TG_CHAT" ]]; then
        curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
             -d "chat_id=$TG_CHAT&text=$1&parse_mode=Markdown" >/dev/null || true
    fi
}

# 7. Процесс установки
clear
gum style --foreground "$YELLOW" "Начинается установка. Подробности в: $LOG_FILE"

# Docker Engine (ставим раньше других, если выбран)
if [[ $SELECTED == *"Docker: Engine"* ]]; then
    gum spin --spinner dot --title "Установка Docker..." -- bash -c "curl -fsSL https://get.docker.com | sh && systemctl enable --now docker" >> "$LOG_FILE" 2>&1
    echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' > /etc/docker/daemon.json
    systemctl restart docker >> "$LOG_FILE" 2>&1
fi

# System Updates
if [[ $SELECTED == *"System: Updates"* ]]; then
    gum spin --spinner dot --title "Обновление системы..." -- bash -c "apt-get update && apt-get upgrade -y && apt-get install -y btop mc tmux ncdu jq" >> "$LOG_FILE" 2>&1
fi

# Swap
if [[ $SELECTED == *"2GB Swap"* ]]; then
    gum spin --spinner dot --title "Настройка Swap..." -- bash -c "fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab" >> "$LOG_FILE" 2>&1
fi

# SSH
if [[ $SELECTED == *"SSH Port 2222"* ]]; then
    gum spin --spinner dot --title "Защита SSH..." -- bash -c "sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config && systemctl restart ssh" >> "$LOG_FILE" 2>&1
fi

# Supabase
if [[ $SELECTED == *"Supabase"* ]]; then
    gum spin --spinner dot --title "Развертывание Supabase (Порт 8080)..." -- bash -c "
    mkdir -p /opt/supabase && cd /opt/supabase
    git clone --depth 1 https://github.com/supabase/supabase .
    cp docker/.env.example .env
    sed -i 's/KONG_HTTP_PORT=8000/KONG_HTTP_PORT=8080/' .env
    sed -i \"s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/\" .env
    sed -i \"s/JWT_SECRET=.*/JWT_SECRET=$(openssl rand -hex 32)/\" .env
    docker compose -f docker/docker-compose.yml up -d" >> "$LOG_FILE" 2>&1
fi

# Coolify
if [[ $SELECTED == *"Coolify"* ]]; then
    gum spin --spinner dot --title "Установка Coolify..." -- bash -c "curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash" >> "$LOG_FILE" 2>&1
fi

# Cloudflare DNS
if [[ -n "$CF_TOKEN" && -n "$CF_DOMAIN" ]]; then
    IP=$(curl -s ifconfig.me)
    gum spin --spinner dot --title "Обновление DNS Cloudflare..." -- bash -c "
    curl -s -X POST \"https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records\" \
         -H \"Authorization: Bearer $CF_TOKEN\" \
         -H \"Content-Type: application/json\" \
         --data '{\"type\":\"A\",\"name\":\"$CF_DOMAIN\",\"content\":\"$IP\",\"ttl\":120}'" >> "$LOG_FILE" 2>&1
fi

# Monitoring & UI
[[ $SELECTED == *"Uptime Kuma"* ]] && docker run -d --name uptime-kuma --restart=always -p 3001:3001 -v uptime-kuma:/app/data louislam/uptime-kuma:1 >> "$LOG_FILE" 2>&1
[[ $SELECTED == *"Portainer"* ]] && docker run -d --name portainer --restart=always -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest >> "$LOG_FILE" 2>&1

# 8. Финал
clear
IP_ADDR=$(curl -s ifconfig.me)
FINAL_HOST=${CF_DOMAIN:-$IP_ADDR}

MESSAGE="✅ *VPS PRO MONOLITH v1.0.1 Ready!*
📍 Host: \`$FINAL_HOST\`
🔑 SSH: \`2222\`
---
📦 Coolify: http://$FINAL_HOST:8000
⚡ Supabase: http://$FINAL_HOST:8080
📊 Kuma: http://$FINAL_HOST:3001"

tg_notify "$MESSAGE"

gum style --border double --margin "1 2" --padding "1 2" --border-foreground "$GREEN" \
    "🎉 УСТАНОВКА ЗАВЕРШЕНА" \
    "IP: $IP_ADDR" \
    "Host: $FINAL_HOST" \
    "SSH Port: 2222" \
    "Логи: $LOG_FILE"

echo -e "\nНажмите любую клавишу для выхода..."
read -n 1
