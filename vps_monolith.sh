#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 🚀 VPS PRO MONOLITH v1.0.4 - CLASSIC STABLE
# Repository: https://github.com/sheikerdc-del/VPS-PRO-MONOLITH
# Чистый Bash: работает на любом SSH-клиенте без графических багов.
# ==============================================================================

LOG_FILE="/var/log/vps_monolith.log"

# Цвета для удобства чтения
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Функция логирования (пишет и в консоль, и в файл)
log() {
    echo -e "${GREEN}[$(date +%T)]${NC} $1" | tee -a "$LOG_FILE"
}

# 1. Начальные проверки
clear
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}       🚀 VPS PRO MONOLITH v1.0.4 - ПОЛНЫЙ СТЕК      ${NC}"
echo -e "${GREEN}====================================================${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: запустите скрипт через sudo -i или от root.${NC}"
    exit 1
fi

# 2. Функция подтверждения (Классический y/n)
ask() {
    echo -ne "${YELLOW}▶ $1 [y/N]? ${NC}"
    read -r ans
    case "$ans" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# 3. Сбор переменных перед стартом
echo -e "\n${YELLOW}--- Ввод необходимых данных ---${NC}"
read -p "Введите домен (например, app.example.com): " CF_DOMAIN
read -p "Telegram Bot Token (Enter для пропуска): " TG_TOKEN
read -p "Telegram Chat ID: " TG_CHAT

# 4. Процесс установки
echo -e "\n${GREEN}--- Запуск процесса установки ---${NC}"

# Обновление и база
if ask "Обновить систему и поставить базовый софт (btop, mc, jq)?"; then
    log "Обновление репозиториев..."
    apt-get update && apt-get upgrade -y >> "$LOG_FILE" 2>&1
    apt-get install -y curl git wget gpg jq xxd btop mc tmux ncdu certbot >> "$LOG_FILE" 2>&1
fi

# Swap
if ask "Создать Swap (файл подкачки) на 2GB?"; then
    log "Настройка Swap..."
    if [[ ! -f /swapfile ]]; then
        fallocate -l 2G /swapfile && chmod 600 /swapfile
        mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
fi

# Docker (критически важен для стека)
if ask "Установить Docker Engine и Docker Compose?"; then
    log "Установка Docker..."
    curl -fsSL https://get.docker.com | sh >> "$LOG_FILE" 2>&1
    mkdir -p /etc/docker
    echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' > /etc/docker/daemon.json
    systemctl restart docker
fi

# SSH Security
if ask "Защитить SSH (Порт 2222, отключить root login)?"; then
    log "Настройка безопасности SSH..."
    sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl restart ssh
    echo -e "${RED}ВНИМАНИЕ: Теперь подключайтесь по порту 2222!${NC}"
fi

# Coolify
if ask "Установить PaaS Coolify (Self-hosted Heroku)?"; then
    log "Установка Coolify..."
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash >> "$LOG_FILE" 2>&1
fi

# Supabase
if ask "Развернуть Supabase (BaaS) на порту 8080?"; then
    log "Развертывание Supabase..."
    mkdir -p /opt/supabase && cd /opt/supabase
    git clone --depth 1 https://github.com/supabase/supabase . >> "$LOG_FILE" 2>&1
    cp docker/.env.example .env
    sed -i 's/KONG_HTTP_PORT=8000/KONG_HTTP_PORT=8080/' .env
    sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
    sed -i "s/JWT_SECRET=.*/JWT_SECRET=$(openssl rand -hex 32)/" .env
    docker compose -f docker/docker-compose.yml up -d >> "$LOG_FILE" 2>&1
    cd ~
fi

# Firewall
if ask "Настроить Firewall (UFW) и разрешить порты сервисов?"; then
    log "Настройка UFW..."
    apt-get install -y ufw fail2ban >> "$LOG_FILE" 2>&1
    ufw allow 2222/tcp
    ufw allow 80,443,8000,8080,9443,3001/tcp
    ufw --force enable
    systemctl restart fail2ban
fi

# 5. Финал
IP_ADDR=$(curl -s ifconfig.me || echo "unknown")
HOST=${CF_DOMAIN:-$IP_ADDR}

clear
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}         ✅ МОНОЛИТ v1.0.4 РАЗВЕРНУТ!               ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "📍 Host: ${YELLOW}$HOST${NC}"
echo -e "🔑 SSH Port: ${YELLOW}2222${NC}"
echo -e "📂 Полный лог: ${YELLOW}$LOG_FILE${NC}"
echo -e "----------------------------------------------------"
echo -e "🚀 Ваши сервисы:"
echo -e "- Coolify (PaaS):   http://$HOST:8000"
echo -e "- Supabase (BaaS):  http://$HOST:8080"
echo -e "- Порт SSH:         2222"
echo -e "===================================================="

# Уведомление в Telegram
if [[ -n "$TG_TOKEN" && -n "$TG_CHAT" ]]; then
    MSG="✅ *VPS Monolith v1.0.4 Ready*%0AHost: \`$HOST\`%0ASSH: \`2222\`"
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT&text=$MSG&parse_mode=Markdown" > /dev/null
fi
