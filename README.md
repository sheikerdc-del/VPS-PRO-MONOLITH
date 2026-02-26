# VPS PRO MONOLITH


🚀 Запуск
Bash

curl -sSL [https://raw.githubusercontent.com/sheikerdc-del/VPS-PRO-MONOLITH/main/vps_monolith.sh](https://raw.githubusercontent.com/sheikerdc-del/VPS-PRO-MONOLITH/main/vps_monolith.sh) | sudo bash

> One-shot bootstrap для развёртывания **production-ready private cloud** на чистом Ubuntu-сервере.

![Lint Status](https://github.com/sheikerdc-del/VPS-PRO-MONOLITH/actions/workflows/lint.yml/badge.svg)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420)]()
[![Docker](https://img.shields.io/badge/Docker-supported-2496ED)]()
[![Status](https://img.shields.io/badge/status-stable-brightgreen)]()
[![Release](https://img.shields.io/badge/release-v1.0-informational)]()


<img width="1536" height="1024" alt="shema" src="https://github.com/user-attachments/assets/8c81dafb-d26b-42fa-9369-7bc70295b6d4" />

One-shot bootstrap script for deploying a private cloud stack on Ubuntu 22.04 / 24.04.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/sheikerdc-del/VPS-PRO-MONOLITH/main/vps_monolith.sh | sudo bash
```

## What the script installs

- Docker + Docker Compose plugin
- Traefik (80/443)
- Coolify (optional)
- Supabase full stack (optional)
- Monitoring: Portainer + Uptime Kuma + Watchtower (optional)
- MTProto proxy (optional)
- Amnezia VPN (optional)
- UFW + Fail2ban
- PostgreSQL backups cron job (optional)

---

## Environment variables

### Core

| Variable | Default | Description |
|---|---:|---|
| `VPS_UNATTENDED` | `0` | `1` = non-interactive run |
| `VPS_DOMAIN` | empty | Apex domain only, e.g. `example.com` (without `*.`) |
| `VPS_ADMIN_EMAIL` | `admin@<domain>` | Email for Let's Encrypt |
| `VPS_PUBLIC_IP` | auto | Force public IP |
| `VPS_SSH_PORT` | `2222` | New SSH port |

### Optional integrations

| Variable | Default | Description |
|---|---:|---|
| `VPS_TG_TOKEN` | empty | Telegram bot token |
| `VPS_TG_CHAT` | empty | Telegram chat ID |
| `VPS_CF_TOKEN` | empty | Cloudflare API token |
| `VPS_CF_ZONE` | empty | Cloudflare Zone ID (optional if token can resolve zone) |
| `VPS_CF_PROXY` | `false` | `true/1` to enable proxied A-records |
| `VPS_SKIP_DNS` | `0` | `1` to disable Cloudflare DNS updates |

### Feature toggles

| Variable | Default | Description |
|---|---:|---|
| `VPS_INSTALL_SUPABASE` | `1` | Install Supabase stack |
| `VPS_INSTALL_COOLIFY` | `1` | Install Coolify |
| `VPS_INSTALL_MONITORING` | `1` | Install Portainer/Uptime/Watchtower |
| `VPS_INSTALL_MTPROTO` | `0` | Install MTProto proxy |
| `VPS_INSTALL_AMNEZIA` | `0` | Install Amnezia VPN containers |
| `VPS_INSTALL_BACKUPS` | `1` | Configure daily pg backup job |
| `VPS_SSH_DISABLE_ROOT` | `1` | Disable root SSH login |
| `VPS_SSH_DISABLE_PASSWORD` | `1` | Disable password SSH auth |

---

## Ports

| Service | Port | Protocol |
|---|---:|---|
| SSH | `${VPS_SSH_PORT:-2222}` | TCP |
| Traefik | `80`, `443` | TCP |
| Coolify | `8000` | TCP |
| Supabase Postgres | `54321` | TCP |
| Portainer | `9443` | TCP |
| Uptime Kuma | `3001` | TCP |
| MTProto | `8443` | TCP |
| WireGuard | `51820` | UDP |
| OpenVPN | `1194` | UDP |

---

## Recommended production run (Cloudflare)

```bash
export VPS_UNATTENDED=1
export VPS_DOMAIN="example.com"
export VPS_ADMIN_EMAIL="admin@example.com"
export VPS_CF_TOKEN="<cloudflare_token>"
export VPS_CF_ZONE="<zone_id>"        # optional but recommended
export VPS_CF_PROXY=true

curl -fsSL https://raw.githubusercontent.com/sheikerdc-del/VPS-PRO-MONOLITH/main/vps_monolith.sh | sudo bash
```

## Run without Cloudflare DNS updates

```bash
export VPS_UNATTENDED=1
export VPS_DOMAIN="example.com"
export VPS_ADMIN_EMAIL="admin@example.com"
export VPS_SKIP_DNS=1

curl -fsSL https://raw.githubusercontent.com/sheikerdc-del/VPS-PRO-MONOLITH/main/vps_monolith.sh | sudo bash
```

---

## Access after install

- Coolify: `http://<SERVER_IP>:8000`
- Portainer: `https://<SERVER_IP>:9443`
- Uptime Kuma: `http://<SERVER_IP>:3001`
- Supabase Postgres: `<SERVER_IP>:54321`

Generated files:

- Compose files: `/opt/monolith/`
- Supabase secrets: `/opt/monolith/supabase-credentials.txt`
- MTProto link: `/opt/monolith/mtproto-info.txt`
- Backups: `/opt/monolith-backups/postgres/`
- Script log: `/var/log/vps_monolith.log`

---

## Notes

- `VPS_DOMAIN` must be an apex domain (`example.com`), not `*.example.com`.
- If SSH hardening is enabled, verify access on the new port before closing current session.
- For HTTPS via Traefik/Let's Encrypt, ensure DNS points to server and ports `80/443` are reachable.

## License

MIT
