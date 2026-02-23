#!/usr/bin/env bash

# Останавливаем при ошибках, но разрешаем пустые значения переменных
set -e

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}       🚀 VPS PRO MONOLITH v1.0.9 - FINAL           ${NC}"
echo -e "${GREEN}====================================================${NC}"

# 1. Проверка прав
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: запустите от root (sudo -i)${NC}"
    exit 1
fi

# 2. Функция "Железного" вопроса (читает напрямую из терминала)
ask() {
    local prompt="$1"
    while true; do
        echo -ne "${YELLOW}▶ $prompt [y/N]? ${NC}"
        read -r ans < /dev/tty
        case "$ans" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]|"") return 1 ;;
            *) echo -e "${RED}Введите y или n.${NC}" ;;
        esac
    done
}

# 3. Сбор данных
echo -e "\n${YELLOW}--- Настройка ---${NC}"
echo -n "Введите домен (например, site.com) или просто нажмите Enter: "
read -r CF_DOMAIN < /dev/tty

# 4. Установка компонентов
echo -e "\n${GREEN}--- Выбор компонентов ---${NC}"

if ask "Обновить систему и поставить софт (btop, mc, jq)?"; then
    apt-get update && apt-get upgrade -y
    apt-get install -y curl git wget gpg jq xxd btop mc tmux ncdu certbot
fi

if ask "Создать Swap 2GB (необходимо для работы баз данных)?"; then
    if [[ ! -f /swapfile ]]; then
        fallocate -l 2G /swapfile && chmod 600 /swapfile
        mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
fi

if ask "Установить Docker и Docker Compose?"; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    mkdir -p /etc/docker
    echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' > /etc/docker/daemon.json
    systemctl restart docker
fi

if ask "Сменить порт SSH на 2222?"; then
    sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config
    systemctl restart ssh
    echo -e "${RED}ВНИМАНИЕ: Порт SSH теперь 2222!${NC}"
fi

if ask "Установить Coolify (Панель управления)?"; then
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
fi

if ask "Установить Supabase (Backend-as-a-Service)?"; then
    echo "Настройка Supabase..."
    # Очистка старой папки (решает проблему с вашего фото №5)
    rm -rf /opt/supabase
    mkdir -p /opt/supabase && cd /opt/supabase
    git clone --depth 1 https://github.com/supabase/supabase .
    cp docker/.env.example .env
    
    # Заполнение .env (решает проблему с вашего фото №4)
    DB_PASS=$(openssl rand -hex 16)
    JWT_SEC=$(openssl rand -hex 32)
    sed -i 's/KONG_HTTP_PORT=8000/KONG_HTTP_PORT=8080/' .env
    sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$DB_PASS/" .env
    sed -i "s/JWT_SECRET=.*/JWT_SECRET=$JWT_SEC/" .env
    sed -i "s/ANON_KEY=.*/ANON_KEY=$(openssl rand -hex 32)/" .env
    sed -i "s/SERVICE_ROLE_KEY=.*/SERVICE_ROLE_KEY=$(openssl rand -hex 32)/" .env
    
    docker compose -f docker/docker-compose.yml up -d
    cd ~
fi

if ask "Установить Portainer (Управление контейнерами)?"; then
    docker run -d --name portainer --restart=always -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
fi

if ask "Установить Uptime Kuma (Мониторинг)?"; then
    docker run -d --name uptime-kuma --restart=always -p 3001:3001 -v uptime-kuma:/app/data louislam/uptime-kuma:1
fi

if ask "Настроить Firewall (UFW) и открыть порты?"; then
    apt-get install -y ufw
    ufw allow 2222/tcp
    ufw allow 80,443,8000,8080,9443,3001/tcp
    ufw --force enable
fi

# 5. Финал
clear
IP_ADDR=$(curl -s ifconfig.me || echo "unknown")
FINAL_HOST=${CF_DOMAIN:-$IP_ADDR}

echo -e "${GREEN}====================================================${NC}"
echo -e "✅ МОНОЛИТ УСПЕШНО РАЗВЕРНУТ!"
echo -e "====================================================${NC}"
echo -e "📍 Host: ${YELLOW}$FINAL_HOST${NC}"
echo -e "🔑 SSH Port: ${YELLOW}2222${NC}"
echo -e "----------------------------------------------------"
echo -e "🚀 Сервисы:"
echo -e "- Coolify:  http://$FINAL_HOST:8000"
echo -e "- Supabase: http://$FINAL_HOST:8080"
echo -e "- Portainer: https://$FINAL_HOST:9443"
echo -e "- Kuma:     http://$FINAL_HOST:3001"
echo -e "===================================================="
