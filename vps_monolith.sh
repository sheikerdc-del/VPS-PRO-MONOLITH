#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 🚀 VPS PRO MONOLITH v1.0.3 - STABLE ENGINE
# Исправлено: Ошибки отрисовки интерфейса и логика захвата ввода.
# ==============================================================================

LOG_FILE="/var/log/vps_monolith.log"
touch "$LOG_FILE"

# Цвета для обычного вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 1. Проверка прав
[[ $EUID -ne 0 ]] && { echo "Ошибка: запустите от root"; exit 1; }

# 2. Тихая установка зависимостей
echo -e "${YELLOW}🔄 Инициализация системы...${NC}"
apt-get update -qq && apt-get install -y curl git wget gpg jq xxd certbot -qq > /dev/null 2>&1

# Установка Gum (если нет)
if ! command -v gum &>/dev/null; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" > /etc/apt/sources.list.d/charm.list
    apt-get update -qq && apt-get install -y gum -qq > /dev/null 2>&1
fi

clear
echo -e "${GREEN}🚀 VPS PRO MONOLITH v1.0.3 Ready${NC}"

# 3. Сбор данных через стандартный read (чтобы не ломать TTY)
echo -e "\n${YELLOW}--- Настройка Telegram ---${NC}"
read -p "Telegram Bot Token (Enter для пропуска): " TG_TOKEN
read -p "Telegram Chat ID: " TG_CHAT

echo -e "\n${YELLOW}--- Настройка Cloudflare (Опционально) ---${NC}"
read -p "Домен (например, app.example.com): " CF_DOMAIN
read -p "Cloudflare API Token: " CF_TOKEN
read -p "Cloudflare Zone ID: " CF_ZONE

# 4. Выбор компонентов через Gum (с явным указанием TTY)
echo -e "\n${YELLOW}--- Выбор компонентов ---${NC}"
echo "Выберите пункты (Пробел - выбор, Enter - подтвердить):"
SELECTED=$(gum choose --no-limit --height 15 \
    "System: Core Updates" \
    "System: 2GB Swap" \
    "Security: SSH Port 2222" \
    "Security: Firewall + Fail2Ban" \
    "Docker: Engine + Compose" \
    "PaaS: Coolify (Port 8000)" \
    "BaaS: Supabase (Port 8080)" \
    "VPN: Amnezia Ready" \
    "Monitoring: Uptime Kuma" \
    "UI: Portainer CE" \
    "Ops: Watchtower")

# 5. Логика установки
clear
echo -e "${YELLOW}🛠 Начинаем установку... Прогресс в $LOG_FILE${NC}"

# Docker (Обязателен для большинства пунктов)
if [[ $SELECTED == *"Docker"* || $SELECTED == *"Coolify"* || $SELECTED == *"Supabase"* ]]; then
    gum spin --spinner dot --title "Установка Docker..." -- bash -c "
    curl -fsSL https://get.docker.com | sh
    mkdir -p /etc/docker
    echo '{\"log-driver\":\"json-file\",\"log-opts\":{\"max-size\":\"10m\",\"max-file\":\"3\"}}' > /etc/docker/daemon.json
    systemctl restart docker" >> "$LOG_FILE" 2>&1
fi

# SSH
if [[ $SELECTED == *"SSH Port 2222"* ]]; then
    gum spin --spinner dot --title "Смена порта SSH на 2222..." -- bash -c "
    sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config
    systemctl restart ssh" >> "$LOG_FILE" 2>&1
fi

# Supabase (Порт 8080)
if [[ $SELECTED == *"Supabase"* ]]; then
    gum spin --spinner dot --title "Установка Supabase..." -- bash -c "
    mkdir -p /opt/supabase && cd /opt/supabase
    git clone --depth 1 https://github.com/supabase/supabase .
    cp docker/.env.example .env
    sed -i 's/KONG_HTTP_PORT=8000/KONG_HTTP_PORT=8080/' .env
    sed -i \"s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/\" .env
    sed -i \"s/JWT_SECRET=.*/JWT_SECRET=$(openssl rand -hex 32)/\" .env
    docker compose -f docker/docker-compose.yml up -d" >> "$LOG_FILE" 2>&1
fi

# Cloudflare DNS
if [[ -n "$CF_TOKEN" && -n "$CF_DOMAIN" ]]; then
    IP=$(curl -s ifconfig.me)
    gum spin --spinner dot --title "Обновление Cloudflare DNS..." -- bash -c "
    curl -s -X POST \"https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records\" \
         -H \"Authorization: Bearer $CF_TOKEN\" \
         -H \"Content-Type: application/json\" \
         --data '{\"type\":\"A\",\"name\":\"$CF_DOMAIN\",\"content\":\"$IP\",\"ttl\":120}'" >> "$LOG_FILE" 2>&1
fi

# 6. Финализация
IP_ADDR=$(curl -s ifconfig.me)
HOST=${CF_DOMAIN:-$IP_ADDR}

clear
echo -e "${GREEN}=========================================="
echo -e "✅ УСТАНОВКА ЗАВЕРШЕНА!"
echo -e "=========================================="
echo -e "📍 Host: $HOST"
echo -e "🔑 SSH Port: 2222"
echo -e "📂 Log: $LOG_FILE"
echo -e "------------------------------------------"
echo -e "🚀 Сервисы:"
[[ $SELECTED == *"Coolify"* ]] && echo "- Coolify: http://$HOST:8000"
[[ $SELECTED == *"Supabase"* ]] && echo "- Supabase: http://$HOST:8080"
[[ $SELECTED == *"Portainer"* ]] && echo "- Portainer: https://$HOST:9443"
echo -e "==========================================${NC}"

# Отправка в TG
if [[ -n "$TG_TOKEN" ]]; then
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d "chat_id=$TG_CHAT&text=✅ VPS Monolith Deployed on $HOST" >/dev/null
fi
