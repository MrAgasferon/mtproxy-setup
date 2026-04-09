#!/bin/bash
set -e

# =============================================================================
# MTProxy Setup Script
# Installs, updates, backs up and restores personal_mtproxy
# Repository: https://github.com/MrAgasferon/mtproxy-setup
# =============================================================================

REPO_URL="https://github.com/MrAgasferon/mtproxy-setup"
UPSTREAM_URL="https://github.com/seriyps/personal_mtproxy.git"
INSTALL_DIR="/root/personal_mtproxy"
OPT_DIR="/opt/personal_mtproxy"
BACKUP_DIR="/root/mtproxy_backups"
DETS_FILE="/var/lib/personal_mtproxy/proxies.dets"
LOG_FILE="/var/log/personal_mtproxy/application.log"
SERVICE="personal_mtproxy"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    [ "$EUID" -eq 0 ] || error "Запустите скрипт от root: sudo bash install.sh"
}

check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" ]]; then
            warn "Скрипт тестировался на Ubuntu. Текущая ОС: $ID"
        fi
        info "ОС: $PRETTY_NAME"
    fi
}

install_deps() {
    info "Устанавливаем зависимости..."
    apt-get update -q
    apt-get install -y -q \
        build-essential autoconf libncurses5-dev libssl-dev \
        m4 unixodbc-dev git curl wget make \
        python3-pip python3-venv
    success "Зависимости установлены"
}

get_latest_erlang_version() {
    # Берём последний релиз мажорной ветки 27+
    curl -s https://api.github.com/repos/erlang/otp/releases \
        | grep '"tag_name"' \
        | grep '"OTP-2[789]\.' \
        | head -1 \
        | sed 's/.*"OTP-\([^"]*\)".*/\1/'
}

install_erlang() {
    if command -v erl &>/dev/null; then
        CURRENT=$(erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell 2>/dev/null | tr -d '"')
        info "Erlang уже установлен: OTP $CURRENT"
        if [ "$CURRENT" -ge 25 ] 2>/dev/null; then
            success "Версия подходит"
            return
        fi
        warn "Версия слишком старая, обновляем..."
    fi

    info "Определяем последнюю версию Erlang..."
    ERLANG_VSN=$(get_latest_erlang_version)
    if [ -z "$ERLANG_VSN" ]; then
        ERLANG_VSN="27.3"
        warn "Не удалось определить версию автоматически, используем $ERLANG_VSN"
    fi
    info "Будет установлен Erlang/OTP $ERLANG_VSN"

    if [ ! -f /usr/local/bin/kerl ]; then
        info "Устанавливаем kerl..."
        curl -fsSL https://raw.githubusercontent.com/kerl/kerl/master/kerl -o /usr/local/bin/kerl
        chmod +x /usr/local/bin/kerl
    fi

    # Чистим незавершённые сборки и старые установки
    rm -rf /root/.kerl/builds/$ERLANG_VSN 2>/dev/null || true
    rm -rf /opt/erlang/$ERLANG_VSN 2>/dev/null || true

    info "Собираем Erlang $ERLANG_VSN (займёт 5-10 минут)..."
    KERL_BUILD_BACKEND=git kerl build $ERLANG_VSN $ERLANG_VSN
    kerl install $ERLANG_VSN /opt/erlang/$ERLANG_VSN

    ACTIVATE_LINE=". /opt/erlang/$ERLANG_VSN/activate"
    if ! grep -q "$ACTIVATE_LINE" ~/.bashrc; then
        echo "$ACTIVATE_LINE" >> ~/.bashrc
    fi
    . /opt/erlang/$ERLANG_VSN/activate

    success "Erlang/OTP $ERLANG_VSN установлен"
}

activate_erlang() {
    ERLANG_DIR=$(ls -d /opt/erlang/* 2>/dev/null | sort -V | tail -1)
    if [ -n "$ERLANG_DIR" ] && [ -f "$ERLANG_DIR/activate" ]; then
        . "$ERLANG_DIR/activate"
    else
        error "Erlang не найден в /opt/erlang/. Сначала выполните установку."
    fi
}

install_rebar3() {
    if command -v rebar3 &>/dev/null; then
        success "rebar3 уже установлен: $(rebar3 --version 2>/dev/null | head -1)"
        return
    fi
    info "Устанавливаем rebar3..."
    wget -q https://s3.amazonaws.com/rebar3/rebar3 -O /usr/local/bin/rebar3
    chmod +x /usr/local/bin/rebar3
    success "rebar3 установлен"
}

install_certbot() {
    if command -v certbot &>/dev/null; then
        success "certbot уже установлен"
        return
    fi
    info "Устанавливаем certbot..."
    python3 -m venv /opt/certbot
    /opt/certbot/bin/pip install --upgrade pip -q
    /opt/certbot/bin/pip install certbot certbot-dns-duckdns -q
    ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot
    success "certbot установлен"
}

get_certificate_duckdns() {
    local domain=$1
    local token=$2
    local email=$3

    mkdir -p ~/.secrets
    echo "dns_duckdns_token=$token" > ~/.secrets/duckdns.ini
    chmod 600 ~/.secrets/duckdns.ini

    info "Получаем wildcard-сертификат для *.$domain ..."
    certbot certonly \
        --authenticator dns-duckdns \
        --dns-duckdns-credentials ~/.secrets/duckdns.ini \
        --dns-duckdns-propagation-seconds 240 \
        --email "$email" \
        --agree-tos \
        --non-interactive \
        -d "$domain" \
        -d "*.$domain"
}

get_certificate_http() {
    local domain=$1
    local email=$2

    info "Получаем сертификат для $domain через HTTP-01..."
    certbot certonly \
        --standalone \
        --email "$email" \
        --agree-tos \
        --non-interactive \
        -d "$domain"
}

fix_cert_permissions() {
    local domain=$1
    chmod 755 /etc/letsencrypt/live 2>/dev/null || true
    chmod 755 /etc/letsencrypt/archive 2>/dev/null || true
    chmod 755 /etc/letsencrypt/archive/$domain 2>/dev/null || true
    chmod 755 /etc/letsencrypt/live/$domain 2>/dev/null || true
    chmod 640 /etc/letsencrypt/archive/$domain/privkey1.pem 2>/dev/null || true
}

clone_repo() {
    if [ -d "$INSTALL_DIR" ]; then
        warn "Директория $INSTALL_DIR уже существует, пропускаем клонирование"
        return
    fi
    info "Клонируем personal_mtproxy..."
    git clone "$UPSTREAM_URL" "$INSTALL_DIR"

    # Исправляем SSH→HTTPS в зависимостях
    sed -i 's|git@github.com:|https://github.com/|g' "$INSTALL_DIR/rebar.config"
    sed -i 's|git@github.com:|https://github.com/|g' "$INSTALL_DIR/rebar.lock"
    success "Репозиторий клонирован"
}

apply_patches() {
    local domain=$1
    local secret=$2
    local admin_pass=$3

    info "Применяем патчи..."

    # Скачиваем наши доработанные файлы
    PATCHES_URL="https://raw.githubusercontent.com/MrAgasferon/mtproxy-setup/main"

    curl -fsSL "$PATCHES_URL/patches/pm_web_handler.erl" \
        -o "$INSTALL_DIR/src/pm_web_handler.erl"
    curl -fsSL "$PATCHES_URL/patches/pm_auth_middleware.erl" \
        -o "$INSTALL_DIR/src/pm_auth_middleware.erl"
    curl -fsSL "$PATCHES_URL/patches/personal_mtproxy_app.erl" \
        -o "$INSTALL_DIR/src/personal_mtproxy_app.erl"
    curl -fsSL "$PATCHES_URL/htdocs/admin.html" \
        -o "$INSTALL_DIR/priv/htdocs/admin.html"
    curl -fsSL "$PATCHES_URL/htdocs/index.html" \
        -o "$INSTALL_DIR/priv/htdocs/index.html"

    # Подставляем домен в index.html
    sed -i "s|example.com|$domain|g" "$INSTALL_DIR/priv/htdocs/index.html"

    success "Патчи применены"
}

write_config() {
    local domain=$1
    local secret=$2
    local admin_pass=$3

    info "Записываем конфигурацию..."

    cat > "$INSTALL_DIR/config/sys.config" << EOF
[
  {mtproto_proxy, [
    {ports, [
      #{name      => mtp_ipv4,
        listen_ip => "0.0.0.0",
        port      => 443,
        secret    => <<"${secret}">>,
        tag       => <<"dcbe8f1493fa4cd9ab300891c0b5b326">>},
      #{name      => mtp_ipv6,
        listen_ip => "::",
        port      => 443,
        secret    => <<"${secret}">>,
        tag       => <<"dcbe8f1493fa4cd9ab300891c0b5b326">>}
    ]},
    {allowed_protocols, [mtp_fake_tls]},
    {domain_fronting, "127.0.0.1:1443"},
    {policy, [
      {in_table, tls_domain, personal_domains},
      {max_connections, [tls_domain], 100}
    ]}
  ]},
  {personal_mtproxy, [
    {admin_password, "${admin_pass}"},
    {base_domain,   "${domain}"},
    {dets_file,     "/var/lib/personal_mtproxy/proxies.dets"},
    {ssl_cert,      "/etc/letsencrypt/live/${domain}/fullchain.pem"},
    {ssl_key,       "/etc/letsencrypt/live/${domain}/privkey.pem"}
  ]},
  {kernel,
   [{logger_level, info},
    {logger,
     [{filters, log,
       [{progress, {fun logger_filters:progress/2, stop}}]},
      {handler, default, logger_std_h,
       #{level => info,
         formatter => {logger_formatter, #{single_line => true}},
         config => #{type => file,
                     file => "/var/log/personal_mtproxy/application.log",
                     max_no_bytes => 104857600,
                     max_no_files => 10,
                     filesync_repeat_interval => no_repeat}}},
      {handler, console, logger_std_h,
       #{level => critical,
         formatter => {logger_formatter, #{single_line => true}},
         config => #{type => standard_io}}}
     ]}]},
  {sasl, [{errlog_type, error}]}
].
EOF

    cp "$INSTALL_DIR/config/vm.args.example" "$INSTALL_DIR/config/vm.args" 2>/dev/null || true
    success "Конфигурация записана"
}

build_and_install() {
    info "Собираем проект (может занять несколько минут)..."
    cd "$INSTALL_DIR"
    make

    if systemctl is-active --quiet $SERVICE 2>/dev/null; then
        systemctl stop $SERVICE
    fi

    make install
    mkdir -p /var/lib/personal_mtproxy

    # Деплоим beam файлы (make install не перезаписывает существующие)
    deploy_beams

    systemctl enable $SERVICE
    systemctl start $SERVICE
    success "Установка завершена, сервис запущен"
}

deploy_beams() {
    local lib_dir="$OPT_DIR/lib/personal_mtproxy-0.1.0"
    local build_lib="$INSTALL_DIR/_build/prod/lib/personal_mtproxy/ebin"

    info "Деплоим скомпилированные модули..."

    for beam in pm_web_handler pm_auth_middleware personal_mtproxy_app; do
        if [ -f "$build_lib/$beam.beam" ]; then
            cp "$build_lib/$beam.beam" "$lib_dir/ebin/"
        fi
    done

    # Деплоим статические файлы
    cp -rf "$INSTALL_DIR/_build/prod/rel/personal_mtproxy/lib/personal_mtproxy-0.1.0/priv" \
           "$lib_dir/"

    # Деплоим конфиг
    cp "$INSTALL_DIR/config/sys.config" \
       "$OPT_DIR/releases/0.1.0/sys.config"

    success "Модули задеплоены"
}

setup_cron() {
    local cert_cmd="/opt/certbot/bin/certbot renew --quiet && systemctl restart $SERVICE"
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * $cert_cmd") | crontab -
        success "Автообновление сертификата настроено (ежедневно в 3:00)"
    else
        info "Cron для certbot уже настроен"
    fi
}

do_backup() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="$BACKUP_DIR/$timestamp"
    mkdir -p "$backup_path"

    info "Создаём резервную копию в $backup_path ..."

    # База пользователей
    [ -f "$DETS_FILE" ] && cp "$DETS_FILE" "$backup_path/"

    # Конфиги
    [ -f "$OPT_DIR/releases/0.1.0/sys.config" ] && \
        cp "$OPT_DIR/releases/0.1.0/sys.config" "$backup_path/sys.config"
    [ -f "$INSTALL_DIR/config/sys.config" ] && \
        cp "$INSTALL_DIR/config/sys.config" "$backup_path/sys.config.src"

    # Исходники с патчами
    [ -d "$INSTALL_DIR/src" ] && cp -r "$INSTALL_DIR/src" "$backup_path/"
    [ -d "$INSTALL_DIR/priv" ] && cp -r "$INSTALL_DIR/priv" "$backup_path/"
    [ -f "$INSTALL_DIR/rebar.config" ] && cp "$INSTALL_DIR/rebar.config" "$backup_path/"
    [ -f "$INSTALL_DIR/rebar.lock" ] && cp "$INSTALL_DIR/rebar.lock" "$backup_path/"

    # /opt (бинарники)
    [ -d "$OPT_DIR" ] && cp -r "$OPT_DIR" "$backup_path/opt_personal_mtproxy"

    local size=$(du -sh "$backup_path" | cut -f1)
    success "Резервная копия создана: $backup_path ($size)"
    echo "$timestamp"
}

do_restore() {
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A $BACKUP_DIR 2>/dev/null)" ]; then
        error "Резервные копии не найдены в $BACKUP_DIR"
    fi

    echo ""
    echo "Доступные резервные копии:"
    echo "──────────────────────────"
    local i=1
    local backups=()
    for d in $(ls -r "$BACKUP_DIR"); do
        local size=$(du -sh "$BACKUP_DIR/$d" 2>/dev/null | cut -f1)
        echo "  $i) $d ($size)"
        backups+=("$d")
        ((i++))
    done
    echo ""

    read -rp "Выберите номер копии для восстановления: " choice
    local selected="${backups[$((choice-1))]}"
    [ -z "$selected" ] && error "Неверный выбор"

    local backup_path="$BACKUP_DIR/$selected"
    info "Восстанавливаем из $backup_path ..."

    systemctl stop $SERVICE 2>/dev/null || true

    # Восстанавливаем /opt
    if [ -d "$backup_path/opt_personal_mtproxy" ]; then
        rm -rf "$OPT_DIR"
        cp -r "$backup_path/opt_personal_mtproxy" "$OPT_DIR"
        success "/opt восстановлен"
    fi

    # Восстанавливаем конфиг
    if [ -f "$backup_path/sys.config" ]; then
        cp "$backup_path/sys.config" "$OPT_DIR/releases/0.1.0/sys.config"
        success "Конфиг восстановлен"
    fi

    # Восстанавливаем базу пользователей
    if [ -f "$backup_path/proxies.dets" ]; then
        mkdir -p /var/lib/personal_mtproxy
        cp "$backup_path/proxies.dets" "$DETS_FILE"
        success "База пользователей восстановлена"
    fi

    # Восстанавливаем исходники
    if [ -d "$backup_path/src" ] && [ -d "$INSTALL_DIR" ]; then
        cp -r "$backup_path/src" "$INSTALL_DIR/"
        success "Исходники восстановлены"
    fi

    systemctl start $SERVICE
    sleep 5
    if systemctl is-active --quiet $SERVICE; then
        success "Сервис запущен успешно"
    else
        error "Сервис не запустился, проверьте: journalctl -u $SERVICE -n 30"
    fi
}

do_update() {
    info "Обновление personal_mtproxy..."

    # Автобэкап перед обновлением
    info "Создаём резервную копию перед обновлением..."
    do_backup

    activate_erlang

    cd "$INSTALL_DIR"
    info "Получаем обновления из upstream..."
    git pull origin master

    # Исправляем SSH→HTTPS на случай если rebar.lock обновился
    sed -i 's|git@github.com:|https://github.com/|g' rebar.config
    sed -i 's|git@github.com:|https://github.com/|g' rebar.lock

    # Применяем патчи заново
    local domain=$(grep "base_domain" "$OPT_DIR/releases/0.1.0/sys.config" | \
                   sed 's/.*"\(.*\)".*/\1/')
    local secret=$(grep "secret.*<<" "$OPT_DIR/releases/0.1.0/sys.config" | \
                   head -1 | sed 's/.*<<"\(.*\)">>.*/\1/')
    local admin_pass=$(grep "admin_password" "$OPT_DIR/releases/0.1.0/sys.config" | \
                       sed 's/.*"\(.*\)".*/\1/')

    apply_patches "$domain" "$secret" "$admin_pass"

    info "Пересобираем..."
    make

    systemctl stop $SERVICE
    deploy_beams
    systemctl start $SERVICE

    sleep 5
    if systemctl is-active --quiet $SERVICE; then
        success "Обновление завершено, сервис запущен"
    else
        error "Сервис не запустился после обновления. Откатитесь через: $0 restore"
    fi
}

do_status() {
    echo ""
    echo "═══════════════════════════════════"
    echo "       MTProxy Status"
    echo "═══════════════════════════════════"

    # Статус сервиса
    if systemctl is-active --quiet $SERVICE; then
        echo -e " Сервис:      ${GREEN}работает${NC}"
    else
        echo -e " Сервис:      ${RED}остановлен${NC}"
    fi

    # Активные соединения
    CONNS=$("$OPT_DIR/bin/personal_mtproxy" eval \
        'lists:sum([proplists:get_value(all_connections, L) || {_, L} <- ranch:info()]).' \
        2>/dev/null | tr -d '\n' || echo "N/A")
    echo " Соединений:  $CONNS"

    # Количество пользователей
    USERS=$("$OPT_DIR/bin/personal_mtproxy" eval \
        'mtp_policy_table:table_size(personal_domains).' \
        2>/dev/null | tr -d '\n' || echo "N/A")
    echo " Пользователей: $USERS"

    # Срок сертификата
    DOMAIN=$(grep "base_domain" "$OPT_DIR/releases/0.1.0/sys.config" 2>/dev/null | \
             sed 's/.*"\(.*\)".*/\1/')
    if [ -n "$DOMAIN" ]; then
        CERT_EXPIRY=$(openssl x509 -enddate -noout \
            -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" 2>/dev/null | \
            sed 's/notAfter=//')
        echo " Домен:       $DOMAIN"
        echo " Сертификат:  истекает $CERT_EXPIRY"
    fi

    # Резервные копии
    if [ -d "$BACKUP_DIR" ]; then
        BACKUP_COUNT=$(ls "$BACKUP_DIR" 2>/dev/null | wc -l)
        echo " Бэкапов:     $BACKUP_COUNT"
    fi

    echo "═══════════════════════════════════"
    echo ""
}

do_install() {
    check_root
    check_os

    echo ""
    echo "═══════════════════════════════════════════"
    echo "   Personal MTProxy — Установка"
    echo "═══════════════════════════════════════════"
    echo ""

    # Спрашиваем параметры
    read -rp "Ваш домен (например example.com): " DOMAIN
    [ -z "$DOMAIN" ] && error "Домен не может быть пустым"

    echo ""
    echo "Тип домена:"
    echo "  1) DuckDNS (бесплатный поддомен)"
    echo "  2) Собственный домен"
    read -rp "Выберите [1/2]: " DOMAIN_TYPE

    DUCKDNS_TOKEN=""
    if [ "$DOMAIN_TYPE" = "1" ]; then
        read -rp "DuckDNS Token: " DUCKDNS_TOKEN
        [ -z "$DUCKDNS_TOKEN" ] && error "Token не может быть пустым"
    fi

    read -rp "Email для Let's Encrypt (для уведомлений об истечении): " CERT_EMAIL
    [ -z "$CERT_EMAIL" ] && error "Email не может быть пустым"

    read -rsp "Пароль для панели администратора: " ADMIN_PASS
    echo ""
    [ -z "$ADMIN_PASS" ] && error "Пароль не может быть пустым"

    SECRET=$(openssl rand -hex 16)
    info "Сгенерирован секрет прокси: $SECRET"

    echo ""
    echo "Параметры установки:"
    echo "  Домен:   $DOMAIN"
    echo "  Секрет:  $SECRET"
    echo ""
    read -rp "Продолжить? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy]$ ]] || { info "Установка отменена"; exit 0; }

    echo ""
    install_deps
    install_erlang
    activate_erlang
    install_rebar3
    install_certbot

    if [ "$DOMAIN_TYPE" = "1" ]; then
        get_certificate_duckdns "$DOMAIN" "$DUCKDNS_TOKEN" "$CERT_EMAIL"
    else
        get_certificate_http "$DOMAIN" "$CERT_EMAIL"
    fi
    fix_cert_permissions "$DOMAIN"

    clone_repo
    apply_patches "$DOMAIN" "$SECRET" "$ADMIN_PASS"
    write_config "$DOMAIN" "$SECRET" "$ADMIN_PASS"
    build_and_install
    setup_cron

    echo ""
    echo "═══════════════════════════════════════════"
    echo -e "   ${GREEN}Установка завершена успешно!${NC}"
    echo "═══════════════════════════════════════════"
    echo ""
    echo "  Страница регистрации: https://$DOMAIN/"
    echo "  Панель администратора: https://$DOMAIN/admin.html"
    echo ""
    echo -e "${YELLOW}  Не забудьте открыть порт 443 в вашем firewall!${NC}"
    echo ""
    echo "  Управление:"
    echo "    Статус:   bash install.sh status"
    echo "    Бэкап:    bash install.sh backup"
    echo "    Откат:    bash install.sh restore"
    echo "    Обновление: bash install.sh update"
    echo ""
}

# =============================================================================
# Точка входа
# =============================================================================

COMMAND="${1:-install}"

case "$COMMAND" in
    install)
        do_install
        ;;
    backup)
        check_root
        do_backup
        ;;
    restore)
        check_root
        do_restore
        ;;
    update)
        check_root
        activate_erlang
        do_update
        ;;
    status)
        do_status
        ;;
    *)
        echo "Использование: bash install.sh [install|backup|restore|update|status]"
        echo ""
        echo "  install  — установка с нуля"
        echo "  backup   — создать резервную копию"
        echo "  restore  — восстановить из резервной копии"
        echo "  update   — обновить до последней версии"
        echo "  status   — показать состояние сервиса"
        exit 1
        ;;
esac
