#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 🚀 VPS ULTIMATE ENTERPRISE BOOTSTRAP (INTERACTIVE)
# Ubuntu 22.04 / 24.04
# ==============================================================================

LOG_FILE="/var/log/vps_bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== VPS ULTIMATE ENTERPRISE BOOTSTRAP START ===${NC}"

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root (sudo -i)${NC}"; exit 1; }

# ------------------------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------------------------
DEPLOY_USER="deploy"
SSH_PORT="2222"
BACKUP_DIR="/opt/backups"
RETENTION_DAYS="7"

# ------------------------------------------------------------------------------
# HELPER: ASK FUNCTION
# ------------------------------------------------------------------------------
ask() {
  read -rp "$(echo -e "${YELLOW}$1 (y/n): ${NC}")" ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# ------------------------------------------------------------------------------
# TELEGRAM
# ------------------------------------------------------------------------------
echo -e "${YELLOW}Telegram notifications (optional)${NC}"
read -rp "Bot token: " TG_TOKEN || true
read -rp "Chat ID: " TG_CHAT || true

tg() {
  [[ -z "${TG_TOKEN:-}" || -z "${TG_CHAT:-}" ]] && return 0
  curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    -d "chat_id=$TG_CHAT&text=$1&parse_mode=Markdown" >/dev/null || true
}

# ------------------------------------------------------------------------------
# SYSTEM UPDATE
# ------------------------------------------------------------------------------
if ask "Update system packages"; then
  apt update -y
  apt upgrade -y
fi

# ------------------------------------------------------------------------------
# BASE TOOLS
# ------------------------------------------------------------------------------
if ask "Install base utilities (curl, git, htop, tmux, etc.)"; then
  apt install -y \
    curl wget git vim nano htop tmux ncdu btop mc neofetch jq \
    ca-certificates software-properties-common build-essential \
    ufw fail2ban unattended-upgrades logrotate \
    python3 python3-pip python3-venv \
    golang-go clamav clamav-daemon \
    postgresql redis-server speedtest-cli
fi

# ------------------------------------------------------------------------------
# SWAP
# ------------------------------------------------------------------------------
if ask "Create 2GB swap"; then
  if ! swapon --show | grep -q /swapfile; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
fi

# ------------------------------------------------------------------------------
# USER + SSH HARDENING
# ------------------------------------------------------------------------------
if ask "Create deploy user and harden SSH"; then
  id "$DEPLOY_USER" &>/dev/null || {
    adduser --disabled-password --gecos "" "$DEPLOY_USER"
    usermod -aG sudo "$DEPLOY_USER"
  }

  sed -i "s/^#\?Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
  sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
  sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config

  sshd -t
  systemctl restart ssh
fi

# ------------------------------------------------------------------------------
# FIREWALL + FAIL2BAN
# ------------------------------------------------------------------------------
if ask "Configure firewall and Fail2Ban"; then
  ufw allow "$SSH_PORT"/tcp
  ufw allow 80/tcp
  ufw allow 81/tcp
  ufw allow 443/tcp
  ufw allow 3001/tcp
  ufw allow 8000/tcp
  ufw allow 8443/tcp
  ufw allow 9000/tcp
  ufw allow 9443/tcp
  ufw --force enable

  cat >/etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
fi

# ------------------------------------------------------------------------------
# DOCKER
# ------------------------------------------------------------------------------
if ask "Install Docker"; then
  if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
  fi

  systemctl enable docker
  usermod -aG docker "$DEPLOY_USER"

  mkdir -p /etc/docker
  cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF

  systemctl restart docker
fi

# ------------------------------------------------------------------------------
# NODE + RUST
# ------------------------------------------------------------------------------
if ask "Install Node.js LTS"; then
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt install -y nodejs
fi

if ask "Install Rust"; then
  command -v rustc &>/dev/null || curl https://sh.rustup.rs -sSf | sh -s -- -y
fi

# ------------------------------------------------------------------------------
# RCLONE
# ------------------------------------------------------------------------------
if ask "Install rclone"; then
  command -v rclone &>/dev/null || curl https://rclone.org/install.sh | bash
fi

# ------------------------------------------------------------------------------
# TRAEFIK
# ------------------------------------------------------------------------------
if ask "Deploy Traefik reverse proxy"; then
  mkdir -p /opt/traefik
  cat >/opt/traefik/docker-compose.yml <<'EOF'
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
fi

# ------------------------------------------------------------------------------
# CORE DOCKER APPS
# ------------------------------------------------------------------------------
if ask "Install Portainer + Uptime Kuma + Watchtower"; then
  docker volume create portainer_data >/dev/null || true

  docker run -d --name portainer --restart=always \
    -p 9000:9000 -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data portainer/portainer-ce:latest || true

  docker run -d --name uptime-kuma --restart=always \
    -p 3001:3001 -v uptime-kuma:/app/data \
    louislam/uptime-kuma:1 || true

  docker run -d --name watchtower --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower --cleanup --interval 3600 || true
fi

# ------------------------------------------------------------------------------
# NGINX PROXY MANAGER
# ------------------------------------------------------------------------------
if ask "Install Nginx Proxy Manager"; then
  mkdir -p /opt/npm
  cat >/opt/npm/docker-compose.yml <<'EOF'
version: "3.8"
services:
  app:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - "./data:/data"
      - "./letsencrypt:/etc/letsencrypt"
EOF

  docker compose -f /opt/npm/docker-compose.yml up -d || true
fi

# ------------------------------------------------------------------------------
# COOLIFY
# ------------------------------------------------------------------------------
if ask "Install Coolify PaaS"; then
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash || true
fi

# ------------------------------------------------------------------------------
# MTProto
# ------------------------------------------------------------------------------
if ask "Deploy MTProto proxy"; then
  MT_SECRET=$(head -c 16 /dev/urandom | xxd -ps)

  docker run -d --name mtproto-proxy --restart always \
    -p 8443:443 -e SECRET="$MT_SECRET" telegrammessenger/proxy:latest || true

  echo "$MT_SECRET" > /root/mtproto_secret.txt
fi

# ------------------------------------------------------------------------------
# CLOUDFLARED
# ------------------------------------------------------------------------------
if ask "Install Cloudflare Tunnel (cloudflared)"; then
  if ! command -v cloudflared &>/dev/null; then
    wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i cloudflared-linux-amd64.deb || apt -f install -y
  fi
fi

# ------------------------------------------------------------------------------
# POSTGRES BACKUP
# ------------------------------------------------------------------------------
if ask "Configure PostgreSQL backups"; then
  mkdir -p "$BACKUP_DIR"

  cat >/usr/local/bin/pg_backup.sh <<EOF
#!/usr/bin/env bash
set -e
DATE=\$(date +%F-%H%M)
sudo -u postgres pg_dumpall | gzip > "$BACKUP_DIR/pg-\$DATE.sql.gz"
find "$BACKUP_DIR" -type f -mtime +$RETENTION_DAYS -delete
EOF

  chmod +x /usr/local/bin/pg_backup.sh
  (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/pg_backup.sh") | crontab -
fi

# ------------------------------------------------------------------------------
# FINAL REPORT
# ------------------------------------------------------------------------------
IP=$(curl -s ifconfig.me || echo "unknown")

MSG="✅ VPS READY
IP: $IP
SSH: $SSH_PORT
Portainer: https://$IP:9443
Uptime: http://$IP:3001"

tg "$MSG"

echo -e "${GREEN}=== VPS ULTIMATE ENTERPRISE BOOTSTRAP COMPLETE ===${NC}"
echo "Log: $LOG_FILE"
