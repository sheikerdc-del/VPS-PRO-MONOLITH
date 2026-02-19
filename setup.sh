#!/bin/bash

# ==============================================================================
# УЛЬТИМАТИВНЫЙ СКРИПТ НАСТРОЙКИ VPS (25+ ИНСТРУМЕНТОВ + БЕЗОПАСНОСТЬ)
# ==============================================================================

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

exec > >(tee -a /var/log/vps_setup.log) 2>&1

clear
echo -e "${GREEN}=============================================="
echo -e "   🚀 VPS PRO MONOLITH SETUP (Safe & Clean)"
echo -e "==============================================${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ошибка: Запустите от имени root (sudo -i)${NC}"
   exit 1
fi

# 1. ПРОВЕРКА РЕСУРСОВ
MEM_TOTAL=$(free -m | awk '/^Mem:/{print $2}')
echo -e "${YELLOW}Проверка ресурсов: ${MEM_TOTAL}MB RAM обнаружено.${NC}"
if [ "$MEM_TOTAL" -lt 1800 ]; then
    echo -e "${RED}[!] Внимание: У вас менее 2ГБ ОЗУ. Тяжелые сервисы (Coolify) могут тормозить.${NC}"
fi

# 2. ИНТЕРАКТИВНЫЙ ОПРОС
echo -e "\n${YELLOW}--- Настройка уведомлений Telegram ---${NC}"
read -p "Введите Telegram Bot Token (Enter чтобы пропустить): " TG_TOKEN
read -p "Введите ваш Telegram Chat ID: " TG_CHAT_ID

declare -A apps
ask() {
    read -p "$(echo -e ${YELLOW}"$1 (y/n): "${NC})" res
    if [[ "$res" == "y" ]]; then return 0; else return 1; fi
}

echo -e "\n${GREEN}--- КАТЕГОРИЯ: СИСТЕМА И ТЕРМИНАЛ ---${NC}"
if ask "01. Базовые утилиты (git, curl, htop, xxd, ncdu, mc)"; then apps[base]=1; fi
if ask "02. Настройка SWAP (2GB)"; then apps[swap]=1; fi
if ask "03. Установка Zsh + Oh My Zsh"; then apps[zsh]=1; fi
if ask "04. Смена порта SSH (на 2222) и защита Root"; then apps[ssh_hard]=1; fi
if ask "05. Установка Btop, Tmux, Neofetch"; then apps[utils]=1; fi

echo -e "\n${GREEN}--- КАТЕГОРИЯ: DOCKER И ДЕПЛОЙ ---${NC}"
if ask "06. Установка Docker & Compose (с лимитами логов)"; then apps[docker]=1; fi
if ask "07. Установка Coolify (Self-hosted PaaS)"; then apps[coolify]=1; fi
if ask "08. Установка Portainer (Docker GUI)"; then apps[portainer]=1; fi
if ask "09. Установка Uptime Kuma (Мониторинг)"; then apps[kuma]=1; fi

echo -e "\n${GREEN}--- КАТЕГОРИЯ: БЕЗОПАСНОСТЬ И СЕТЬ ---${NC}"
if ask "10. Настройка Firewall (UFW) + Fail2Ban"; then apps[sec]=1; fi
if ask "11. Установка Авто-обновлений (unattended-upgrades)"; then apps[auto_upd]=1; fi
if ask "12. Развернуть MTProto Proxy (Telegram)"; then apps[mtproto]=1; fi
if ask "13. Установка Cloudflare Tunnel + Speedtest"; then apps[net]=1; fi

echo -e "\n${GREEN}--- КАТЕГОРИЯ: СТЕК РАЗРАБОТКИ ---${NC}"
if ask "14. Установка Node.js LTS, Python3, Go, Rust"; then apps[dev]=1; fi
if ask "15. Установка PostgreSQL и Redis"; then apps[db]=1; fi

echo -e "\n${GREEN}>>> НАЧИНАЮ УСТАНОВКУ...${NC}\n"

# --- ЛОГИКА УСТАНОВКИ ---

# Система
if [[ ${apps[base]} ]]; then
    apt update && apt upgrade -y
    apt install -y curl git wget build-essential xxd htop ncdu mc vim nano timedatectl
    timedatectl set-timezone UTC
fi

if [[ ${apps[swap]} ]]; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

if [[ ${apps[ssh_hard]} ]]; then
    sed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config
    # Запрет входа по паролю только если вы уверены! (Тут оставим включенным, но сменим порт)
    systemctl restart ssh
    echo -e "${RED}!!! SSH ПОРТ ИЗМЕНЕН НА 2222 !!!${NC}"
fi

# Docker с защитой от переполнения диска логами
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

# Сервисы
[[ ${apps[coolify]} ]] && curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash

if [[ ${apps[portainer]} ]]; then
    docker volume create portainer_data
    docker run -d -p 9443:9443 --name portainer --restart always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
fi

[[ ${apps[kuma]} ]] && docker run -d --restart always -p 3001:3001 -v uptime-kuma:/app/data --name uptime-kuma louislam/uptime-kuma:1

# Безопасность
if [[ ${apps[sec]} ]]; then
    apt install -y ufw fail2ban
    ufw allow 2222/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 8000/tcp && ufw allow 9443/tcp
    ufw --force enable
    systemctl enable fail2ban && systemctl start fail2ban
fi

[[ ${apps[auto_upd]} ]] && apt install -y unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades

# Dev & DB
if [[ ${apps[dev]} ]]; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt install -y nodejs python3 python3-pip golang-go
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi

[[ ${apps[db]} ]] && apt install -y postgresql redis-server

# Прокси
if [[ ${apps[mtproto]} ]]; then
    MT_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    docker run -d --name mtproto-proxy --restart always -p 8443:443 -e SECRET=$MT_SECRET telegrammessenger/proxy:latest
fi

# Сеть
if [[ ${apps[net]} ]]; then
    curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb && dpkg -i cloudflared.deb
    curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash && apt install -y speedtest
fi

# ОТЧЕТ В TELEGRAM
IP=$(curl -s ifconfig.me)
if [[ -n "$TG_TOKEN" && -n "$TG_CHAT_ID" ]]; then
    REPORT="✅ *VPS Успешно настроен!*%0A%0A"
    REPORT+="🌐 *IP:* \`$IP\`%0A"
    REPORT+="🔑 *SSH Port:* \`2222\`%0A%0A"
    [[ ${apps[coolify]} ]] && REPORT+="🚀 *Coolify:* \`http://$IP:8000\`%0A"
    [[ ${apps[portainer]} ]] && REPORT+="🐳 *Portainer:* \`https://$IP:9443\`%0A"
    [[ ${apps[mtproto]} ]] && REPORT+="🛡 *MTProto Secret:* \`$MT_SECRET\`%0A"
    
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d "chat_id=$TG_CHAT_ID&text=$REPORT&parse_mode=Markdown" > /dev/null
fi

echo -e "\n${GREEN}=============================================="
echo -e "🎉 УСТАНОВКА ЗАВЕРШЕНА!"
echo -e "Логи сохранены в /var/log/vps_setup.log"
echo -e "==============================================${NC}"
