#!/usr/bin/env bash

# Останавливать при критических ошибках, но не падать из-за пустых переменных
set -e

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}       🚀 VPS PRO MONOLITH v1.0.7 - FULL STABLE     ${NC}"
echo -e "${GREEN}====================================================${NC}"

# 1. Проверка прав (Root)
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: запустите от root (sudo -i)${NC}"
    exit 1
fi

# 2. Функция принудительного вопроса (читает напрямую из терминала)
ask_confirm() {
    local prompt="$1"
    while true; do
        echo -ne "${YELLOW}▶ $prompt [y/N]? ${NC}"
        # < /dev/tty заставляет Bash ждать ввода именно от пользователя
        read -r ans < /dev/tty
        case "$ans" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]|"") return 1 ;;
            *) echo -e "${RED}Введите y (да) или n (нет).${NC}" ;;
        esac
    done
}

# 3. Сбор предварительных данных
echo -e "\n${YELLOW}--- Настройка сети ---${NC}"
echo -n "Введите ваш домен (например, app.site.com) или нажмите Enter: "
read -r CF_DOMAIN < /dev/tty

# 4. Модульная установка
echo -e "\n${GREEN}--- Выбор компонентов для установки ---${NC}"

# --- SYSTEM & UTILS ---
if ask_confirm "Обновить систему и установить утилиты (btop, mc, jq, tmux)?"; then
    echo "Выполняется установка..."
    apt-get update && apt-get upgrade -y
    apt-get install -y curl git wget gpg jq xxd btop mc tmux ncdu certbot software-properties-common
fi

if ask_confirm "Создать файл подкачки (Swap) на 2GB?"; then
    echo "Настройка Swap..."
    if [[ ! -f /swapfile ]]; then
        fallocate -l 2G /swapfile && chmod 600 /swapfile
        mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
fi

# --- DOCKER (Обязателен для панелей) ---
if ask_confirm "Установить Docker Engine и Docker Compose?"; then
    echo "Установка Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    mkdir -p /etc/docker
    echo '{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}' > /etc/docker/daemon.json
    systemctl restart docker
fi

# --- SECURITY ---
if ask_confirm "Сменить порт SSH на 2222 и отключить вход Root?"; then
    echo "Настройка SSH..."
    sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl restart ssh
    echo -e "${RED}ВНИМАНИЕ: Подключайтесь по порту 2222!${NC}"
fi

# --- PAAS & BAAS ---
if ask_confirm "Установить Coolify (управление приложениями)?"; then
    echo "Установка Coolify..."
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
fi

if ask_confirm "Установить Supabase (Postgres, Auth, Storage) на порт 8080?"; then
    echo "Установка Supabase..."
    mkdir -p /opt/supabase && cd /opt/supabase
    git clone --depth 1 https://github.com/supabase/supabase .
    cp docker/.env.example .env
    sed -i 's/KONG_HTTP_PORT=8000/KONG_HTTP_PORT=8080/' .env
    # Генерация безопасных ключей
    DB_PASS=$(openssl rand -hex 16)
    JWT_SEC=$(openssl rand -hex 32)
    sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$DB_PASS/" .env
    sed -i "s/JWT_SECRET=.*/JWT_SECRET=$JWT_SEC/" .env
    docker compose -f docker/docker-compose.yml up -d
    cd ~
fi

# --- OPS & TOOLS ---
if ask_confirm "Установить Portainer (управление контейнерами)?"; then
    docker run -d --name portainer --restart=always -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
fi

if ask_confirm "Установить Uptime Kuma (мониторинг)?"; then
    docker run -d --name uptime-kuma --restart=always -p 3001:3001 -v uptime-kuma:/app/data louislam/uptime-kuma:1
fi

if ask_confirm "Установить Watchtower (автообновление контейнеров)?"; then
    docker run -d --name watchtower --restart=always -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval 3600
fi

# --- NETWORK & VPN ---
if ask_confirm "Подготовить ядро для Amnezia VPN (модули Wireguard)?"; then
    apt install -y linux-modules-extra-$(uname -r) || true
    modprobe wireguard tun || true
fi

if ask_confirm "Настроить Firewall (UFW) и открыть нужные порты?"; then
    apt-get install -y ufw
    ufw allow 2222/tcp
    ufw allow 80,443,8000,8080,9443,3001/tcp
    ufw --force enable
fi

# 5. Финализация
clear
IP_ADDR=$(curl -s ifconfig.me || echo "unknown")
FINAL_HOST=${CF_DOMAIN:-$IP_ADDR}

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}         ✅ УСТАНОВКА МОНОЛИТА ЗАВЕРШЕНА!           ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "📍 Host: ${YELLOW}$FINAL_HOST${NC}"
echo -e "🔑 SSH Port: ${YELLOW}2222${NC}"
echo -e "----------------------------------------------------"
echo -e "🚀 Ваши инструменты (если выбраны):"
echo -e "- PaaS Coolify:  http://$FINAL_HOST:8000"
echo -e "- BaaS Supabase: http://$FINAL_HOST:8080"
echo -e "- Portainer:     https://$FINAL_HOST:9443"
echo -e "- Monitoring:    http://$FINAL_HOST:3001"
echo -e "===================================================="
echo -e "Рекомендуется перезагрузить сервер (reboot) или перезайти по SSH на порт 2222."
