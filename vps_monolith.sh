#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 🚀 VPS PRO MONOLITH v1.0.0 (Interactive TUI Edition)
# Исправлена проблема с отрисовкой интерфейса и конфликтом портов.
# ==============================================================================

LOG_FILE="/var/log/vps_monolith_install.log"
touch "$LOG_FILE"

GREEN='#00FF00'
YELLOW='#FFFF00'
RED='#FF0000'

# --- 1. ПРЕДУСТАНОВКА И ПРОВЕРКИ ---
if [[ $EUID -ne 0 ]]; then
    echo -e "\e[31mОшибка: скрипт должен быть запущен от root (sudo -i)\e[0m"
    exit 1
fi

echo "Инициализация системы и установка интерфейса..."
apt update -y >> "$LOG_FILE" 2>&1
apt install -y curl git wget gpg jq xxd ca-certificates software-properties-common certbot >> "$LOG_FILE" 2>&1

if ! command -v gum &>/dev/null; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" > /etc/apt/sources.list.d/charm.list
    apt update -y >> "$LOG_FILE" 2>&1
    apt install -y gum >> "$LOG_FILE" 2>&1
fi

clear
gum style --border double --margin "1 2" --padding "1 2" --border-foreground "$GREEN" \
    "🚀 VPS PRO MONOLITH v1.0" "Interactive Enterprise Cloud Bootstrap"

# --- 2. СБОР ДАННЫХ ---
echo "Заполните данные для автоматизации (или нажмите Enter, чтобы пропустить):"
TG_TOKEN=$(gum input --placeholder "Telegram Bot Token")
TG_CHAT=$(gum input --placeholder "Telegram Chat ID")

echo "Настройка Cloudflare и SSL (опционально):"
CF_TOKEN=$(gum input --placeholder "Cloudflare API Token")
CF_ZONE=$(gum input --placeholder "Cloudflare Zone ID")
CF_DOMAIN=$(gum input --placeholder "Ваш домен (например: app.site.com)")
SSL_EMAIL=$(gum input --placeholder "Email для SSL Let's Encrypt")

# Функция отправки в Telegram
tg() {
    if [[ -n "${TG_TOKEN}" && -n "${TG_CHAT}" ]]; then
        curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
             -d "chat_id=$TG_CHAT&text=$1&parse_mode=Markdown" >/dev/null || true
    fi
}

# --- 3. ГЛАВНОЕ МЕНЮ ---
clear
echo "Используйте Пробел для выбора, Enter для подтверждения:"
SELECTED=$(gum choose --no-limit --height 25 \
    "System: Core Updates & Utilities" \
    "System: 2GB Swap Provisioning" \
    "System: Zsh + Starship UI" \
    "Security: Hardened SSH (Port 2222)" \
    "Security: UFW Firewall + Fail2Ban" \
    "Cloudflare: Auto DNS & SSL" \
    "Docker: Engine + Log Rotation" \
    "PaaS: Coolify (Port 8000)" \
    "BaaS: Supabase (Port 8080)" \
    "VPN: Amnezia Kernel Ready" \
    "VPN: MTProto Proxy (Telegram)" \
    "Observability: Portainer + Uptime Kuma" \
    "Ops: Watchtower (Auto-updates)" \
    "Database: PostgreSQL + Redis" \
    "Backup: Daily PG Backups")

clear
gum style --foreground "$YELLOW" "Начинаем установку выбранных компонентов. Пожалуйста, подождите..."

# --- 4. ВЫПОЛНЕНИЕ УСТАНОВКИ ---

# Система и утилиты
if [[ $SELECTED == *"System: Core Updates"* ]]; then
    gum spin --spinner dot --title "Обновление пакетов и утилит..." -- bash -c "apt update && apt upgrade -y && apt install -y btop mc tmux ncdu neofetch" >> "$LOG_FILE" 2>&1
fi

# Swap
if [[ $SELECTED == *"2GB Swap"* ]]; then
    if [[ ! -f /swapfile ]]; then
        gum spin --spinner dot --title "Создание Swap файла..." -- bash -c "fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab" >> "$LOG_FILE" 2>&1
    fi
fi

# Zsh & Starship
if [[ $SELECTED == *"Zsh"* ]]; then
    gum spin --spinner dot --title "Установка Zsh и Starship..." -- bash -c "
    apt install -y zsh
    [[ ! -d ~/.oh-my-zsh ]] && sh -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\" \"\" --unattended
    curl -sS https://starship.rs/install.sh | sh -s -- -y
    echo 'eval \"\$(starship init zsh)\"' >> ~/.zshrc || true
    " >> "$LOG_FILE" 2>&1
fi

# SSH Hardening
if [[ $SELECTED == *"Hardened SSH"* ]]; then
    gum spin --spinner dot --title "Смена порта SSH на 2222..." -- bash -c "
    sed -i 's/^#\?Port .*/Port 2222/' /etc/ssh/sshd_config
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
    systemctl restart ssh
    " >> "$LOG_FILE" 2>&1
fi

# Cloudflare DNS & SSL
if [[ $SELECTED == *"Cloudflare: Auto DNS"* && -n "$CF_TOKEN" && -n "$CF_DOMAIN" ]]; then
    IP_ADDR=$(curl -s ifconfig.me)
    gum spin --spinner dot --title "Обновление DNS Cloudflare..." -- bash -c "
    curl -s -X POST \"https://api.cloudflare.com/client/v4/zones/$CF_ZONE/dns_records\" \
         -H \"Authorization: Bearer $CF_TOKEN\" \
         -H \"Content-Type: application/json\" \
         --data '{\"type\":\"A\",\"name\":\"$CF_DOMAIN\",\"content\":\"$IP_ADDR\",\"ttl\":120,\"proxied\":false}'
    " >> "$LOG_FILE" 2>&1
    
    if [[ -n "$SSL_EMAIL" ]]; then
        gum spin --spinner dot --title "Получение SSL сертификата..." -- bash -c "certbot certonly --standalone -d \"$CF_DOMAIN\" --email \"$SSL_EMAIL\" --agree-tos --non-interactive" >> "$LOG_FILE" 2>&1
    fi
fi

# Docker
if [[ $SELECTED == *"Docker: Engine"* ]]; then
    gum spin --spinner dot --title "Установка Docker..." -- bash -c "
    curl -fsSL https://get.docker.com | sh
    mkdir -p /etc/docker
    echo '{\"log-driver\":\"json-file\",\"log-opts\":{\"max-size\":\"10m\",\"max-file\":\"3\"}}' > /etc/docker/daemon.json
    systemctl restart docker
    " >> "$LOG_FILE" 2>&1
fi

# Supabase (С исправлением портов)
if [[ $SELECTED == *"Supabase"* ]]; then
    gum spin --spinner dot --title "Развертывание Supabase (порт 8080)..." -- bash -c "
    mkdir -p /opt/supabase && cd /opt/supabase
    git clone --depth 1 https://github.com/supabase/supabase .
    cp docker/.env.example .env
    sed -i 's/KONG_HTTP_PORT=8000/KONG_HTTP_PORT=8080/' .env
    sed -i \"s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=\$(openssl rand -hex 16)/\" .env
    sed -i \"s/JWT_SECRET=.*/JWT_SECRET=\$(openssl rand -hex 32)/\" .env
    docker compose -f docker/docker-compose.yml up -d
    " >> "$LOG_FILE" 2>&1
fi

# Coolify
if [[ $SELECTED == *"Coolify"* ]]; then
    gum spin --spinner dot --title "Установка Coolify (порт 8000)..." -- bash -c "curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash" >> "$LOG_FILE" 2>&1
fi

# Amnezia & MTProto
if [[ $SELECTED == *"Amnezia"* ]]; then
    gum spin --spinner dot --title "Подготовка ядра для Amnezia VPN..." -- bash -c "apt install -y linux-modules-extra-\$(uname -r) || true && modprobe wireguard tun || true" >> "$LOG_FILE" 2>&1
fi

if [[ $SELECTED == *"MTProto"* ]]; then
    MT_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    gum spin --spinner dot --title "Запуск MTProto Proxy..." -- bash -c "docker run -d --name mtproto-proxy --restart always -p 8443:443 -e SECRET=\"$MT_SECRET\" telegrammessenger/proxy:latest" >> "$LOG_FILE" 2>&1
fi

# Portainer, Kuma, Watchtower
[[ $SELECTED == *"Portainer"* ]] && gum spin --spinner dot --title "Установка Portainer..." -- bash -c "docker run -d --name portainer --restart=always -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest" >> "$LOG_FILE" 2>&1
[[ $SELECTED == *"Uptime Kuma"* ]] && gum spin --spinner dot --title "Установка Uptime Kuma..." -- bash -c "docker run -d --name uptime-kuma --restart=always -p 3001:3001 -v uptime-kuma:/app/data louislam/uptime-kuma:1" >> "$LOG_FILE" 2>&1
[[ $SELECTED == *"Watchtower"* ]] && gum spin --spinner dot --title "Установка Watchtower..." -- bash -c "docker run -d --name watchtower --restart=always -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval 3600" >> "$LOG_FILE" 2>&1

# Базы данных
if [[ $SELECTED == *"PostgreSQL"* ]]; then
    gum spin --spinner dot --title "Установка PostgreSQL и Redis..." -- bash -c "apt install -y postgresql redis-server" >> "$LOG_FILE" 2>&1
fi

# Security (Firewall ставим в конце)
if [[ $SELECTED == *"UFW Firewall"* ]]; then
    gum spin --spinner dot --title "Настройка Firewall и Fail2Ban..." -- bash -c "
    apt install -y ufw fail2ban
    ufw allow 2222/tcp
    ufw allow 80,443,8000,8080,9443,3001/tcp
    ufw --force enable
    systemctl enable fail2ban && systemctl restart fail2ban
    " >> "$LOG_FILE" 2>&1
fi

# Бэкапы
if [[ $SELECTED == *"Backup: Daily"* ]]; then
    gum spin --spinner dot --title "Настройка бэкапов БД..." -- bash -c "
    mkdir -p /opt/backups
    cat >/usr/local/bin/vps_backup.sh <<EOF
#!/bin/bash
DATE=\\\$(date +%F)
sudo -u postgres pg_dumpall | gzip > /opt/backups/native-pg-\\\$DATE.sql.gz
find /opt/backups -type f -mtime +7 -delete
EOF
    chmod +x /usr/local/bin/vps_backup.sh
    (crontab -l 2>/dev/null; echo \"0 3 * * * /usr/local/bin/vps_backup.sh\") | crontab -
    " >> "$LOG_FILE" 2>&1
fi

# --- 5. ФИНАЛИЗАЦИЯ И ЧИСТЫЙ ВЫВОД ---
clear

IP_FINAL=$(curl -s ifconfig.me || echo "unknown")
HOST=${CF_DOMAIN:-$IP_FINAL}

REPORT="✅ *VPS PRO MONOLITH v1.0.0 DEPLOYED!*

📍 *Host:* \`$HOST\`
🔑 *SSH Port:* \`2222\`
👤 *Root Login:* Disabled

🚀 *Web Services:*
- 📦 Coolify: http://$HOST:8000
- ⚡ Supabase: http://$HOST:8080
- 🐳 Portainer: https://$HOST:9443
- 📊 Uptime Kuma: http://$HOST:3001"

tg "$REPORT"

gum style --border double --margin "1 2" --padding "1 2" --border-foreground "$GREEN" \
    "🎉 МОНОЛИТ v1.0 УСПЕШНО РАЗВЕРНУТ!" \
    "" \
    "🌐 Хост: $HOST" \
    "🔑 SSH Port: 2222" \
    "📂 Подробный лог: $LOG_FILE" \
    "" \
    "💡 Важно: Пароли БД для Supabase сохранены в /opt/supabase/.env" \
    "💡 Важно: Для входа по SSH используйте флаг -p 2222"

echo -e "\nУстановка завершена. Вы можете закрыть это окно."
