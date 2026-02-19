# VPS PRO MONOLITH

> One-shot bootstrap для развёртывания **production-ready private cloud** на чистом Ubuntu-сервере.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420)]()
[![Docker](https://img.shields.io/badge/Docker-supported-2496ED)]()
[![Status](https://img.shields.io/badge/status-stable-brightgreen)]()
[![Release](https://img.shields.io/badge/release-v1.0-informational)]()

---

## Overview

**VPS PRO MONOLITH** — это полностью автоматизированный установщик, который за один запуск превращает чистый VPS в:

* self-hosted **PaaS + BaaS**
* защищённый **private cloud**
* готовую **Dev/Prod инфраструктуру**
* систему **мониторинга, VPN и бэкапов**

Без ручной настройки Docker, reverse-proxy, SSL и безопасности.

---

## Features

### Infrastructure

* Docker Engine + Compose
* Traefik reverse proxy (auto-TLS)
* Nginx Proxy Manager (UI)
* Cloudflare Tunnel support

### PaaS / BaaS

* Coolify (self-hosted Vercel/Render)
* Supabase (Auth, Postgres, Realtime, Storage)

### Security

* SSH hardening (port change, root disable)
* UFW firewall + Fail2Ban
* Unattended security updates
* Swap provisioning

### Networking & VPN

* Amnezia VPN kernel readiness
* MTProto Telegram proxy

### Monitoring

* Uptime Kuma
* Portainer
* Watchtower auto-updates

### Dev Stack

* Node.js, Python, Go, Rust
* PostgreSQL + Redis
* CLI utility pack

### Backups

* Automated PostgreSQL dumps
* Rclone cloud sync ready

---

## Architecture

```
                Internet
                    │
               ┌────▼────┐
               │ Traefik  │  ← TLS / routing
               └────┬────┘
        ┌───────────┼───────────┐
        │           │           │
     Coolify     Supabase    NPM UI
        │           │
   Docker Apps   Postgres/RT
        │
   Monitoring Stack
```

---

## Requirements

**Minimum:**

* Ubuntu **22.04 / 24.04**
* 2 CPU
* 4 GB RAM
* 20 GB disk
* Root access
* Open ports: **22, 80, 443**

**Recommended (production):**

* 4 CPU / 8 GB RAM
* SSD storage
* Dedicated IP
* Domain name

---

## Quick Start

### Interactive install (TUI)

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/sheikerdc-del/VPS-PRO-MONOLITH/main/vps_monolith.sh)
```

Запустится TUI-wizard выбора компонентов.

---

### Unattended install

```bash
export VPS_UNATTENDED=1
export VPS_TG_TOKEN="BOT_TOKEN"
export VPS_TG_CHAT="CHAT_ID"

sudo bash <(curl -fsSL https://raw.githubusercontent.com/sheikerdc-del/VPS-PRO-MONOLITH/main/vps_monolith.sh)
```

Полностью автоматическая установка всех сервисов.

---

## Default Ports

| Service     | Port     |
| ----------- | -------- |
| SSH         | 2222     |
| Traefik     | 80 / 443 |
| Coolify     | 8000     |
| Supabase    | 54321    |
| Portainer   | 9443     |
| Uptime Kuma | 3001     |
| MTProto     | 8443     |

---

## Production Guide

### 1. Используйте домен + DNS

Настройте:

* `A` → IP сервера
* `*.domain` → IP сервера

Traefik автоматически выпустит SSL.

---

### 2. Сразу настройте бэкапы

Рекомендуется:

* подключить **S3 / Backblaze / Google Drive** через Rclone
* вынести Postgres-бэкапы за пределы VPS

---

### 3. Ограничьте доступ к админ-панелям

Обязательно:

* закрыть Portainer / Coolify через:

  * VPN
  * Cloudflare Access
  * Basic Auth

---

### 4. Обновления

Watchtower обновляет контейнеры автоматически,
но **ядро и систему** обновляйте вручную:

```bash
apt update && apt upgrade
```

---

## Security Disclaimer

Этот скрипт:

* изменяет SSH-порт
* отключает root-доступ
* настраивает firewall
* устанавливает сетевые сервисы

Перед использованием в production:

* проверьте код
* протестируйте на staging-сервере
* убедитесь, что у вас есть **резервный доступ к VPS**

Автор **не несёт ответственности** за потерю данных, доступности или безопасности.

---

## Logs

```
/var/log/vps_monolith.log
```

Docker-логи ротируются автоматически.

---

## Roadmap

### v1.x

* [ ] install.sh bootstrap
* [ ] domain auto-setup
* [ ] backup to S3 wizard
* [ ] health dashboard

### v2.0

* [ ] multi-node cluster
* [ ] k3s mode
* [ ] zero-trust access
* [ ] web control panel

---

## Contributing

PR и идеи приветствуются.

1. Fork
2. Feature branch
3. Pull Request

---

## License

MIT © VPS PRO MONOLITH

---

## Release v1.0

**Первый стабильный релиз:**

* полный bootstrap private cloud
* interactive + unattended режим
* production-ready стек
* базовая безопасность и мониторинг

---
