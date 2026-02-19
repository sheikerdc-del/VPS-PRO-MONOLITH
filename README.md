# VPS Ultimate Monolith: Traefik Edition

🚀 **VPS Ultimate Monolith** — это полный стек автоматизации для Ubuntu 22.04 / 24.04.  
Скрипт разворачивает более **30 инструментов и сервисов**, включая Docker, Traefik, Supabase, Coolify, Amnezia VPN, MTProto Proxy, Portainer, Uptime Kuma, Dev Tools и бэкапы.

---

## 📌 Особенности

- TUI-выбор компонентов через **Gum Wizard**  
- Поддержка **unattended mode** через переменные окружения  
- Разделение портов для **Supabase** и **Coolify** через **Traefik**  
- Авто-настройка **SSH**, **Firewall (UFW)** и **Fail2Ban**  
- Бэкапы PostgreSQL с ротацией  
- Поддержка Amnezia VPN и MTProto Proxy  
- Dev Tools: Node.js, Python, Go, Rust  
- Docker Watchtower для автоматического обновления контейнеров  
- Telegram уведомления

---

## ⚙️ Системные требования

- Ubuntu 22.04 / 24.04 (x86_64)  
- Минимум 2 CPU, 4GB RAM, 20GB диска  
- Root доступ или `sudo -i`  
- Открытые порты: 22/2222, 80, 443, 9443, 3001, 8000+

---

## 📥 Установка

## 📥 Быстрая установка (одной командой)

На сервере с root-доступом выполните:

```bash
sudo bash -c "$(curl -fsSL https://github.com/sheikerdc-del/VPS-PRO-MONOLITH/main/setup.sh)"

1. Клонируем репозиторий:

```bash
git clone https://github.com/sheikerdc-del/VPS-PRO-MONOLITH.git
cd vps-ultimate-monolith
chmod +x setup.sh
````

2. Запуск интерактивного выбора (TUI Wizard):

```bash
sudo ./setup.sh
```

3. Unattended mode (без интерактивного выбора) через env переменные:

```bash
export VPS_TG_TOKEN="YOUR_BOT_TOKEN"
export VPS_TG_CHAT="YOUR_CHAT_ID"
sudo VPS_UNATTENDED=1 ./setup.sh
```

---

## 🌐 Traefik Subdomain (Supabase + Coolify)

Traefik позволяет запускать **несколько веб-сервисов на одном сервере**, разделяя их по поддоменам.

Пример:

| Сервис   | Поддомен             | Docker-порт |
| -------- | -------------------- | ----------- |
| Supabase | supabase.example.com | 54321       |
| Coolify  | coolify.example.com  | 8000        |

> **Важно:** Не запускать Coolify и Supabase на одном порту напрямую, иначе будет конфликт.

### Настройка `.env` для Supabase

Создается автоматически при запуске скрипта в `/opt/supabase/.env`:

```env
POSTGRES_PASSWORD=<случайный_пароль>
JWT_SECRET=<случайный_секрет>
API_PORT=54321
```

Для Coolify порт можно изменить через `.env` или docker-compose override:

```env
COOLIFY_PORT=8001
```

---

## 🔐 Безопасность

* SSH перенесен на порт `2222`, root доступ отключен
* Firewall (UFW) настроен на все необходимые порты
* Fail2Ban включен для защиты от брутфорса
* Автообновления через Unattended-Upgrades

---

## 💾 Бэкапы

* PostgreSQL дампы создаются ежедневно в `/opt/backups`
* Хранятся последние 7 дней
* Можно включить Rclone для синхронизации с облаком

---

## 🛠 Dev Tools

* Node.js LTS + NPM
* Python 3 + Pip + Venv
* Golang
* Rust

---

## 📈 Мониторинг и PaaS

* **Portainer**: https://<IP>:9443
* **Uptime Kuma**: http://<IP>:3001
* **Supabase**: [http://supabase.example.com](http://supabase.example.com)
* **Coolify**: [http://coolify.example.com](http://coolify.example.com)

---

## 💬 Telegram уведомления

Если заданы `VPS_TG_TOKEN` и `VPS_TG_CHAT`, скрипт отправляет отчет о развернутых сервисах.

---

## ⚡ VPN

* **Amnezia VPN** — модуль WireGuard + TUN
* **MTProto Proxy** — для Telegram

---

## 🧰 Полный список сервисов

* System: Update, Swap, Zsh + Oh My Zsh, Utilities (btop, mc, tmux, ncdu, neofetch, jq)
* Security: SSH Hardening, UFW, Fail2Ban, Unattended-Upgrades
* Docker: Engine + Compose, Portainer CE, Watchtower
* PaaS: Coolify, Supabase
* Proxy: Nginx Proxy Manager, Traefik
* VPN: Amnezia, MTProto Proxy
* Monitoring: Uptime Kuma
* Dev: Node.js, Python, Golang, Rust
* Database: PostgreSQL, Redis
* Network: Cloudflare Tunnel, Speedtest-cli
* Backup: Rclone, Daily PG Dump

---

## 📜 Лицензия

MIT License © 2026 YourName

---

> ✅ Рекомендуется использовать отдельные поддомены для Supabase и Coolify, Traefik автоматически управляет SSL сертификатами через Let's Encrypt.

