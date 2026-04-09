# MTProxy Setup

Скрипт установки, обновления и управления [personal_mtproxy](https://github.com/seriyps/personal_mtproxy) с расширенным функционалом:

- Панель администратора с мониторингом соединений в реальном времени
- Basic Auth защита админки (пароль хранится на сервере, не в HTML)
- Расширенный API (`/api/config`, `/api/proxies`, `/api/connections`)
- Страница-заглушка (парковка домена) вместо страницы регистрации

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/MrAgasferon/mtproxy-setup/main/install.sh -o install.sh
bash install.sh
```

## Требования

- Ubuntu 22.04 или 24.04
- Порт 443 доступен
- Домен или бесплатный поддомен DuckDNS

## Команды

```bash
bash install.sh install   # установка с нуля
bash install.sh status    # статус сервиса
bash install.sh backup    # резервная копия
bash install.sh restore   # восстановление из копии
bash install.sh update    # обновление до последней версии
```

## Структура репозитория

```
mtproxy-setup/
├── install.sh                      # главный скрипт
├── patches/
│   ├── pm_web_handler.erl          # расширенный API handler
│   ├── pm_auth_middleware.erl      # Basic Auth middleware
│   └── personal_mtproxy_app.erl   # роуты + middleware
├── htdocs/
│   ├── admin.html                  # панель администратора
│   └── index.html                  # страница-заглушка
└── README.md
```

## После установки

Откройте порт 443 в вашем firewall:
```bash
# ufw
sudo ufw allow 443/tcp

# iptables
sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
```

## Источники

- [personal_mtproxy](https://github.com/seriyps/personal_mtproxy) — оригинальное приложение
- [mtproto_proxy](https://github.com/seriyps/mtproto_proxy) — ядро прокси
- [Статья на Хабре](https://habr.com/ru/articles/1019648/)
