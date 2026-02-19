#!/bin/bash

# ==============================================================================
# 🚀 VPS ULTIMATE MONOLITH SETUP (25+ TOOLS)
# Полнофункциональный скрипт автоматизации для Ubuntu 22.04 / 24.04
# ==============================================================================

# Цвета для интерфейса
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Логирование всего процесса
LOG_FILE="/var/log/vps_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

clear
echo -e "${GREEN}=============================================="
echo -e "   🌐 VPS MASTER SETUP: ULTIMATE EDITION"
echo -e "==============================================${NC}"

# Проверка на права root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ошибка: Запустите скрипт от имени root (sudo -i)${NC}"
   exit 1
fi

# Настройка Telegram уведомлений
echo -e "${YELLOW}--- Уведомления в Telegram ---${NC}"
read -p "Введите Bot Token (пропустите, если не нужно): " TG_TOKEN
read -p "Введите Chat ID: " TG_CHAT_ID

declare -A apps

# Функция для опроса
ask() {
    read -p "$(echo -e ${YELLOW}"$1 (y/n): "${NC})" res
    if [[ "$res" == "y" ]]; then return 0; else return 1; fi
}

echo -e "\n${GREEN}--- [1] СИСТЕМА, ТЕРМИНАЛ И UX ---${NC}"
if ask "Установить базу (curl, git, wget, build-essential, htop)"; then apps[base]=1; fi
if ask "Настроить SWAP (2GB) для стабильности"; then apps[swap]=1; fi
if ask "Установить Zsh + Oh My Zsh (удобная оболочка)"; then apps[zsh]=1; fi
if ask "Сменить SSH порт на 2222 (безопасность)"; then apps[ssh]=1; fi
if ask "Установить Btop, Tmux, Ncdu, MC, Neofetch"; then apps[utils]=1; fi

echo -e "\n${GREEN}--- [2] DOCKER И ПЛАТФОРМЫ ---${NC}"
if ask "Установить Docker & Compose (с лимитами логов)"; then apps[docker]=1; fi
if ask "Установить Coolify (личный Render/Vercel)"; then apps[coolify]=1; fi
if ask "Установить Portainer (управление Docker в браузере)"; then apps[portainer]=1; fi
if ask "Установить Uptime Kuma (мониторинг сайтов)"; then apps[kuma]=1; fi
if ask "Установить Nginx Proxy Manager (админка для доменов)"; then apps[npm]=1; fi

echo -e "\n${GREEN}--- [3] БЕЗОПАСНОСТЬ И БЭКАПЫ ---${NC}"
if ask "Настроить UFW Firewall + Fail2Ban"; then apps[sec]=1; fi
if ask "Установить Unattended-Upgrades (автопатчи безопасности)"; then apps[auto_upd]=1; fi
if ask "Установить Rclone (бэкапы в облака)"; then apps[rclone]=1; fi
if ask "Установить ClamAV (антивирус)"; then apps[clamav]=1; fi

echo -e "\n${GREEN}--- [4] ЯЗЫКИ ПРОГРАММИРОВАНИЯ И СУБД ---${NC}"
if ask "Установить Node.js LTS (NPM)"; then apps[node]=1; fi
if ask "Установить Python3 + Pip + Venv"; then apps[python]=1; fi
if ask "Установить Golang (Go)"; then apps[go]=1; fi
if ask "Установить Rust"; then apps[rust]=1; fi
if ask "Установить PostgreSQL + Redis (серверы)"; then apps[db]=1; fi

echo -e "\n${GREEN}--- [5] СЕТЕВЫЕ ИНСТРУМЕНТЫ ---${NC}"
if ask "Развернуть MTProto Proxy (Telegram)"; then apps[mtproto]=1; fi
if ask "Установить Cloudflare Tunnel (cloudflared)"; then apps[cftunnel]=1; fi
if ask "Установить Speedtest-cli (тест канала)"; then apps[speedtest]=1; fi

echo -e "\n${GREEN}>>> ЗАПУСК УСТАНОВКИ. ПОЖАЛУЙСТА, ПОДОЖДИТЕ...${NC}\n"

# 1. Base & Swap
if [[ ${apps[base]} ]]; then
    apt update && apt upgrade -y
    apt install -y curl git wget build-essential xxd htop software-properties-common ca-certificates vim nano
fi
if [[ ${apps[swap]} ]]; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 2. SSH Hardening
if [[ ${apps[ssh]} ]]; then
    sed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config
    systemctl restart ssh
fi

# 3. Zsh & Utils
if [[ ${apps[zsh]} ]]; then
    apt install -y zsh
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi
[[ ${apps[utils]} ]] && apt install -y btop tmux ncdu mc neofetch

# 4. Docker (с ограничением логов)
if [[ ${apps[docker]} ]]; then
    mkdir -p /etc/docker
    cat <<EOF > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    curl -fsSL https://get.docker.com | sh
fi

# 5. Platforms
[[ ${apps[coolify]} ]] && curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
if [[ ${apps[portainer]} ]]; then
    docker volume create portainer_data
    docker run -d -p 9000:9000 -p 9443:9443 --name portainer --restart always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
fi
[[ ${apps[kuma]} ]] && docker run -d --restart always -p 3001:3001 -v uptime-kuma:/app/data --name uptime-kuma louislam/uptime-kuma:1

# 6. Nginx Proxy Manager
if [[ ${apps[npm]} ]]; then
    mkdir -p ~/npm && cd ~/npm
    cat <<EOF > docker-compose.yml
version: '3.8'
services:
  app:
    image: 'jc21/nginx-proxy-manager:latest'
    restart: unless-stopped
    ports: [ '80:80', '81:81', '443:443' ]
    volumes: [ './data:/data', './letsencrypt:/etc/letsencrypt' ]
EOF
    docker compose up -d && cd ~
fi

# 7. Security & Auto-upgrades
if [[ ${apps[sec]} ]]; then
    apt install -y ufw fail2ban
    ufw allow 2222/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 8000/tcp && ufw allow 9443/tcp
    ufw --force enable
    systemctl enable fail2ban && systemctl start fail2ban
fi
[[ ${apps[auto_upd]} ]] && apt install -y unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades
[[ ${apps[rclone]} ]] && curl https://rclone.org/install.sh | bash
[[ ${apps[clamav]} ]] && apt install -y clamav clamav-daemon

# 8. Languages & DB
if [[ ${apps[node]} ]]; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt install -y nodejs
fi
[[ ${apps[python]} ]] && apt install -y python3 python3-pip python3-venv
[[ ${apps[go]} ]] && apt install -y golang-go
[[ ${apps[rust]} ]] && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
[[ ${apps[db]} ]] && apt install -y postgresql redis-server

# 9. Net tools
if [[ ${apps[mtproto]} ]]; then
    MT_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    docker run -d --name mtproto-proxy --restart always -p 8443:443 -e SECRET=$MT_SECRET telegrammessenger/proxy:latest
fi
[[ ${apps[cftunnel]} ]] && curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb && dpkg -i cloudflared.deb
if [[ ${apps[speedtest]} ]]; then
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash && apt install -y speedtest
fi

# Финализация и Telegram отчет
IP=$(curl -s ifconfig.me)
REPORT="✅ *VPS SETUP COMPLETE*%0A%0A🌐 *IP:* \`$IP\`%0A🔑 *SSH Port:* \`2222\`%0A%0A"
[[ ${apps[coolify]} ]] && REPORT+="🚀 *Coolify:* \`http://$IP:8000\`%0A"
[[ ${apps[portainer]} ]] && REPORT+="🐳 *Portainer:* \`https://$IP:9443\`%0A"
[[ ${apps[mtproto]} ]] && REPORT+="🛡 *MTProto Secret:* \`$MT_SECRET\`%0A"

if [[ -n "$TG_TOKEN" && -n "$TG_CHAT_ID" ]]; then
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID&text=$REPORT&parse_mode=Markdown" > /dev/null
fi

echo -e "\n${GREEN}=============================================="
echo -e "🎉 УСТАНОВКА ЗАВЕРШЕНА!"
echo -e "SSH доступ теперь по порту 2222"
echo -e "Лог установки: $LOG_FILE"
echo -e "==============================================${NC}"
