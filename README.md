# VPS PRO MONOLITH


🚀 Запуск
Bash

curl -sSL https://raw.githubusercontent.com/sheikerdc-del/VPS-PRO-MONOLITH/main/vps_monolith.sh | sudo bash

> One-shot bootstrap для развёртывания **production-ready private cloud** на чистом Ubuntu-сервере.

![Lint Status](https://github.com/sheikerdc-del/VPS-PRO-MONOLITH/actions/workflows/lint.yml/badge.svg)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420)]()
[![Docker](https://img.shields.io/badge/Docker-supported-2496ED)]()
[![Status](https://img.shields.io/badge/status-stable-brightgreen)]()
[![Release](https://img.shields.io/badge/release-v1.0-informational)]()


<img width="1536" height="1024" alt="shema" src="https://github.com/user-attachments/assets/8c81dafb-d26b-42fa-9369-7bc70295b6d4" />
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
Интеграция DNS: Скрипт отправляет API-запрос к Cloudflare и создает A-запись, направляя ваш домен на текущий IP сервера.

Гибкость: Если вы не введете токены Cloudflare, этот этап просто пропустится.

Умные ссылки: В итоговом отчете Telegram вместо «голого» IP теперь будут использоваться ссылки с вашим доменом.
Как получить данные для Cloudflare:

    API Token: Создайте в панели Cloudflare (нужен шаблон "Edit zone DNS").

    Zone ID: Находится на главной странице вашего домена в панели Cloudflare (правая колонка).

Автор **не несёт ответственности** за потерю данных, доступности или безопасности.

