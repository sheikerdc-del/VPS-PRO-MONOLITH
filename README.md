# VPS PRO MONOLITH

Production bootstrap script for Ubuntu 22.04/24.04 to deploy Docker-based private cloud services.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/sheikerdc-del/VPS-PRO-MONOLITH/main/vps_monolith.sh | sudo bash
```

## Features

- Docker + Compose plugin installation
- Traefik reverse proxy with Let's Encrypt
- Optional stacks: Coolify, Supabase, Monitoring, MTProto, Amnezia VPN
- UFW + Fail2ban hardening
- Cloudflare DNS upsert (apex + wildcard)
- Backup cron for PostgreSQL
- Diagnostics report generation
- Dry-run and step-filter execution modes

---

## Environment variables

### Core

| Variable | Default | Description |
|---|---:|---|
| `VPS_UNATTENDED` | `0` | `1` = no interactive prompt |
| `VPS_DOMAIN` | empty | Apex domain only (`example.com`) |
| `VPS_ADMIN_EMAIL` | `admin@<domain>` | Email for ACME |
| `VPS_PUBLIC_IP` | auto | Override detected server IP |
| `VPS_SSH_PORT` | `2222` | SSH port |

### Security and controls

| Variable | Default | Description |
|---|---:|---|
| `VPS_SSH_DISABLE_ROOT` | `1` | Disable root login in SSH |
| `VPS_SSH_DISABLE_PASSWORD` | `1` | Disable password auth in SSH |
| `VPS_SSH_ALLOW_CIDR` | empty | Optional CIDR allow rule for SSH in UFW |
| `VPS_ENABLE_TRAEFIK_DASHBOARD` | `0` | Enable Traefik dashboard (non-insecure mode) |

### Integrations

| Variable | Default | Description |
|---|---:|---|
| `VPS_TG_TOKEN` | empty | Telegram bot token |
| `VPS_TG_CHAT` | empty | Telegram chat ID |
| `VPS_CF_TOKEN` | empty | Cloudflare API token |
| `VPS_CF_ZONE` | empty | Cloudflare Zone ID (optional) |
| `VPS_CF_PROXY` | `false` | `true/1` for proxied DNS records |
| `VPS_SKIP_DNS` | `0` | `1` to skip Cloudflare DNS update step |

### Feature toggles

| Variable | Default | Description |
|---|---:|---|
| `VPS_INSTALL_SUPABASE` | `1` | Install Supabase stack |
| `VPS_INSTALL_COOLIFY` | `1` | Install Coolify |
| `VPS_INSTALL_MONITORING` | `1` | Install Portainer + Uptime Kuma + Watchtower |
| `VPS_INSTALL_MTPROTO` | `0` | Install MTProto |
| `VPS_INSTALL_AMNEZIA` | `0` | Install Amnezia VPN containers |
| `VPS_INSTALL_BACKUPS` | `1` | Configure daily backup cron |

### Execution controls

| Variable | Default | Description |
|---|---:|---|
| `VPS_DRY_RUN` | `0` | `1` = print commands without executing |
| `VPS_STEPS` | `all` | Comma-separated step names to run selectively |

Available step names:

`preflight_checks,system_prepare,harden_ssh,setup_firewall,install_docker,check_dependencies,setup_traefik,install_supabase,install_coolify,install_monitoring,install_mtproto,install_amnezia,setup_backups,update_cloudflare_dns,verify_installation,collect_diagnostics,show_summary`

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

## Example: full unattended run

```bash
export VPS_UNATTENDED=1
export VPS_DOMAIN="example.com"
export VPS_ADMIN_EMAIL="admin@example.com"
export VPS_CF_TOKEN="<token>"
export VPS_CF_ZONE="<zone_id>"
export VPS_CF_PROXY=true

curl -fsSL https://raw.githubusercontent.com/sheikerdc-del/VPS-PRO-MONOLITH/main/vps_monolith.sh | sudo bash
```

## Example: skip DNS updates

```bash
export VPS_UNATTENDED=1
export VPS_DOMAIN="example.com"
export VPS_ADMIN_EMAIL="admin@example.com"
export VPS_SKIP_DNS=1

curl -fsSL https://raw.githubusercontent.com/sheikerdc-del/VPS-PRO-MONOLITH/main/vps_monolith.sh | sudo bash
```

## Example: dry-run preflight only

```bash
export VPS_DRY_RUN=1
export VPS_STEPS="preflight_checks"
sudo bash vps_monolith.sh
```

Generated files:

## Artifacts and logs

- Compose files: `/opt/monolith/`
- Supabase credentials: `/opt/monolith/supabase-credentials.txt`
- MTProto info: `/opt/monolith/mtproto-info.txt`
- Backups: `/opt/monolith-backups/postgres/`
- Diagnostics: `/opt/monolith/diagnostics.txt`
- Main log: `/var/log/vps_monolith.log`

## License

MIT
