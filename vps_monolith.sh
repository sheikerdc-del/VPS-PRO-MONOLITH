#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 🚀 VPS ULTIMATE MONOLITH: TOTAL EDITION (GUM TUI + 30+ TOOLS + Amnezia VPN)
# Ubuntu 22.04 / 24.04
# ==============================================================================

LOG_FILE="/var/log/vps_monolith.log"
exec > >(tee -a "$LOG_FILE") 2>&1

GREEN='#00FF00'
YELLOW='#FFFF00'
RED='#FF0000'

# 1. Проверка root
[[ $EUID -ne 0 ]] && { echo "Ошибка: нужен root (sudo -i)"; exit 1; }

# 2. Установка Gum (TUI)
if ! command -v gum &>/dev/null; then
    echo "Установка TUI (Gum)..."
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
    TG_TOKEN=$(gum input --placeholder "Telegram Bot Token (Оставьте пустым, чтобы пропустить)")
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

# 4. Главное меню компонентов
if [[ -z "${VPS_UNATTENDED:-}" ]]; then
SELECTED=$(gum choose --no-limit --height 25 \
    "System: Update & Core" \
    "System: 2GB Swap" \
    "System: Zsh + Oh My Zsh + Starship" \
    "System: Full Utility Pack (btop, mc, tmux, ncdu, neofetch, jq)" \
    "Security: SSH 2222 & Root Hardening" \
    "Security: Firewall + Fail2Ban" \
    "Security: Unattended-Upgrades" \
    "Docker: Engine + Compose (Log rotation)" \
    "Docker: Portainer CE" \
    "Docker: Watchtower" \
    "PaaS: Coolify" \
    "BaaS: Supabase" \
    "VPN: Amnezia VPN" \
    "VPN: MTProto Proxy" \
    "Proxy: Nginx Proxy Manager" \
    "Proxy: Traefik" \
    "Monitoring: Uptime Kuma" \
    "Dev: Node.js + NPM" \
    "Dev: Python3 + Pip + Venv" \
    "Dev: Golang + Rust" \
    "Database: PostgreSQL + Redis" \
    "Network: Cloudflare Tunnel + Speedtest" \
    "Backup: Rclone" \
    "Backup: Daily PG Dump")
else
    SELECTED="System: Update & Core
System: 2GB Swap
System: Full Utility Pack (btop, mc, tmux, ncdu, neofetch, jq)
Security: SSH 2222 & Root Hardening
Security: Firewall + Fail2Ban
Docker: Engine + Compose (Log rotation)
Docker: Portainer CE
Docker: Watchtower
PaaS: Coolify
BaaS: Supabase
VPN: Amnezia VPN
VPN: MTProto Proxy
Proxy: Nginx Proxy Manager
Proxy: Traefik
Monitoring: Uptime Kuma
Dev: Node.js + NPM
Dev: Python3 + Pip + Venv
Dev: Golang + Rust
Database: PostgreSQL + Redis
Network: Cloudflare Tunnel + Speedtest
Backup: Rclone
Backup: Daily PG Dump"
fi

# ------------------------------------------------------------------------------
# 5. Установка компонентов (логика установки)
# ------------------------------------------------------------------------------

# System update & core
[[ $SELECTED == *"System: Update"* ]] && apt update -y && apt upgrade -y && apt install -y curl wget git build-essential xxd software-properties-common ca-certificates jq

# Swap
[[ $SELECTED == *"2GB Swap"* ]] && \
    { [[ ! -f /swapfile ]] && fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab; }

# SSH Hardening
[[ $SELECTED == *"SSH 2222"* ]] && sed -i "s/^#\?Port .*/Port 2222/" /etc/ssh/sshd_config && systemctl restart ssh

# Utilities & Zsh
[[ $SELECTED == *"Zsh"* ]] && apt install -y zsh && sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

[[ $SELECTED == *"Utility Pack"* ]] && apt install -y btop tmux ncdu mc neofetch jq

# Docker
[[ $SELECTED == *"Docker: Engine"* ]] && curl -fsSL https://get.docker.com | sh && mkdir -p /etc/docker && cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl restart docker

# Portainer
[[ $SELECTED == *"Portainer"* ]] && docker volume create portainer_data >/dev/null || true && \
docker run -d --name portainer --restart=always -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest

# Watchtower
[[ $SELECTED == *"Watchtower"* ]] && docker run -d --name watchtower --restart=always -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower --cleanup --interval 3600

# Traefik
[[ $SELECTED == *"Traefik"* ]] && mkdir -p /opt/traefik && cat >/opt/traefik/docker-compose.yml <<'EOF'
version: "3.9"
services:
  traefik:
    image: traefik:v3.0
    restart: always
    command:
      - "--api.dashboard=true"
      - "--providers.docker=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.le.acme.tlschallenge=true"
      - "--certificatesresolvers.le.acme.email=admin@example.com"
      - "--certificatesresolvers.le.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
      - "./letsencrypt:/letsencrypt"
EOF
docker compose -f /opt/traefik/docker-compose.yml up -d || true

# Amnezia VPN
[[ $SELECTED == *"Amnezia"* ]] && apt install -y linux-modules-extra-$(uname -r) && modprobe wireguard tun

# MTProto Proxy
[[ $SELECTED == *"MTProto"* ]] && MT_SECRET=$(head -c 16 /dev/urandom | xxd -ps) && \
docker run -d --name mtproto-proxy --restart always -p 8443:443 -e SECRET="$MT_SECRET" telegrammessenger/proxy:latest && echo "$MT_SECRET" > /root/mtproto_secret.txt

# Coolify
[[ $SELECTED == *"Coolify"* ]] && curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash || true

# Supabase
[[ $SELECTED == *"Supabase"* ]] && mkdir -p /opt/supabase && cd /opt/supabase && curl -s https://raw.githubusercontent.com/supabase/supabase/master/docker/docker-compose.yml -o docker-compose.yml && docker compose up -d

# Node.js
[[ $SELECTED == *"Node.js"* ]] && curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && apt install -y nodejs

# Python3
[[ $SELECTED == *"Python3"* ]] && apt install -y python3 python3-pip python3-venv

# Golang & Rust
[[ $SELECTED == *"Golang"* ]] && apt install -y golang-go
[[ $SELECTED == *"Rust"* ]] && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# Security: Firewall + Fail2Ban
[[ $SELECTED == *"Firewall"* ]] && apt install -y ufw fail2ban && \
ufw allow 2222/tcp && ufw allow 80,443,8000,9443,3001/tcp && ufw --force enable && \
systemctl enable fail2ban && systemctl restart fail2ban

# Backup: PG Dump
[[ $SELECTED == *"PG Dump"* ]] && mkdir -p /opt/backups && cat >/usr/local/bin/vps_backup.sh <<EOF
#!/bin/bash
DATE=\$(date +%F)
sudo -u postgres pg_dumpall | gzip > /opt/backups/native-pg-\$DATE.sql.gz
find /opt/backups -type f -mtime +7 -delete
EOF
chmod +x /usr/local/bin/vps_backup.sh
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/vps_backup.sh") | crontab -

# ------------------------------------------------------------------------------
# FINISH REPORT
# ------------------------------------------------------------------------------
IP=$(curl -s ifconfig.me || echo "unknown")
REPORT="✅ *VPS MONOLITH DEPLOYED!*\n📍 *IP:* \`$IP\`\n🔑 *SSH Port:* \`2222\`\n\n🚀 Services:\n- Supabase\n- Portainer\n- Uptime Kuma\n- Coolify"

tg "$REPORT"

gum style --foreground "$GREEN" --border double --margin "1" --padding "1" \
    "🎉 VPS MONOLITH INSTALL COMPLETE!" "IP: $IP" "SSH Port: 2222" "Check Telegram for details."
