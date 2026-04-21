#!/bin/bash
# allCaddy.sh — разворачивает Caddy (Docker) в одном из трёх режимов:
#   1) Domains  — как раньше: два домена с auto LE
#   2) IP       — только публичный IP с LE shortlived сертом (домены не нужны)
#   3) Both     — домены + IP
# Архив Proxy_docker.zip должен лежать рядом со скриптом или скачиваться по URL.

set -e

ZIP_URL="https://raw.githubusercontent.com/adamteam93/hello/refs/heads/main/Proxy_docker.zip"
ARCHIVE_NAME="Proxy_docker.zip"
DIR_NAME="Proxy_docker"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
die() { log "ERROR: $1"; exit 1; }

validate_domain() {
    [[ $1 =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || return 1
}

validate_ip() {
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
}

log "INFO: Загружаем $ARCHIVE_NAME..."
curl -L -o "$ARCHIVE_NAME" "$ZIP_URL" || die "скачка не удалась"

# ====================================================================
# 1. ВЫБОР РЕЖИМА — это САМЫЙ ПЕРВЫЙ вопрос
# ====================================================================
echo ""
echo "Выбери режим развёртывания Caddy:"
echo "  1) Только домены  — два домена с автоматическим LE (нужны DNS A-записи)"
echo "  2) Только IP      — HTTPS на публичный IP с LE shortlived cert (домены НЕ нужны)"
echo "  3) Оба            — и домены, и IP"
echo ""
read -p "Твой выбор (1/2/3, default 1): " MODE
MODE="${MODE:-1}"

case "$MODE" in
    1) USE_DOMAINS=1; USE_IP=0; MODE_NAME="Domains" ;;
    2) USE_DOMAINS=0; USE_IP=1; MODE_NAME="IP-only" ;;
    3) USE_DOMAINS=1; USE_IP=1; MODE_NAME="Domains + IP" ;;
    *) die "Неверный выбор: $MODE" ;;
esac

log "INFO: Выбран режим: $MODE_NAME"

# ====================================================================
# 2. ПАРАМЕТРЫ по режиму
# ====================================================================
if [ "$USE_DOMAINS" = "1" ]; then
    read -p "Основной домен (заменяет esportsteam24.ru): " MAIN_DOMAIN
    validate_domain "$MAIN_DOMAIN" || die "MAIN_DOMAIN невалиден"

    read -p "Второй домен (заменяет esportsteam555.ru): " SECOND_DOMAIN
    validate_domain "$SECOND_DOMAIN" || die "SECOND_DOMAIN невалиден"

    log "INFO: Домены: $MAIN_DOMAIN, $SECOND_DOMAIN"
fi

if [ "$USE_IP" = "1" ]; then
    DEFAULT_IP=$(curl -s4 https://ifconfig.me 2>/dev/null || curl -s4 https://api.ipify.org 2>/dev/null || echo "")
    read -p "Публичный IPv4 (default: $DEFAULT_IP): " SSL_IP
    SSL_IP="${SSL_IP:-$DEFAULT_IP}"
    validate_ip "$SSL_IP" || die "IP невалиден: $SSL_IP"

    # Email для LE (example.com запрещён, пустое значение = ошибка)
    while true; do
        read -p "Email для Let's Encrypt (например you@gmail.com): " LE_EMAIL
        if [ -z "$LE_EMAIL" ]; then
            log "ERROR: Email обязателен"
            continue
        fi
        if [[ "$LE_EMAIL" =~ @(example\.(com|org|net)|localhost|test|invalid)$ ]]; then
            log "ERROR: $LE_EMAIL — запрещённый домен в LE. Используй реальный (gmail.com, yandex.ru, и т.п.)"
            continue
        fi
        if ! [[ "$LE_EMAIL" =~ ^[^@]+@[^@]+\.[a-zA-Z]{2,}$ ]]; then
            log "ERROR: Невалидный email: $LE_EMAIL"
            continue
        fi
        break
    done

    read -p "Куда проксировать https://$SSL_IP/? (default: https://s1.znayaclub.ru): " IP_UPSTREAM
    IP_UPSTREAM="${IP_UPSTREAM:-https://s1.znayaclub.ru}"

    IP_CERT_DIR="/etc/ssl/ipcert"
    log "INFO: IP HTTPS: https://$SSL_IP → $IP_UPSTREAM"
fi

# ====================================================================
# 3. SSH порт
# ====================================================================
read -p "SSH порт (22-65535, default 22): " SSH_PORT
SSH_PORT="${SSH_PORT:-22}"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 22 ] || [ "$SSH_PORT" -gt 65535 ]; then
    die "SSH порт невалиден"
fi
log "INFO: SSH порт: $SSH_PORT"

# ====================================================================
# 4. Пакеты
# ====================================================================
install_if_missing() {
    if ! command -v "$1" &>/dev/null; then
        log "INFO: apt install $1..."
        apt update && apt install -y "$1"
    fi
}
install_if_missing unzip
install_if_missing docker.io
install_if_missing curl
[ "$USE_IP" = "1" ] && install_if_missing socat

# ====================================================================
# 5. Получаем LE серт на IP (до старта Docker — порт 80 должен быть свободен)
# ====================================================================
if [ "$USE_IP" = "1" ]; then
    log "INFO: Освобождаем порт 80 для ACME HTTP-01..."
    systemctl stop caddy 2>/dev/null || true
    systemctl stop nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true
    docker stop stealth-bridge 2>/dev/null || true
    sleep 2

    # Валидация email (LE запрещает example.com и другие reserved-домены)
    if [[ "$LE_EMAIL" =~ @(example\.(com|org|net)|localhost|test|invalid)$ ]]; then
        die "Email домен запрещён Let's Encrypt: $LE_EMAIL (используй реальный домен, например gmail.com)"
    fi

    if [ ! -f ~/.acme.sh/acme.sh ]; then
        log "INFO: Устанавливаем acme.sh..."
        curl -s https://get.acme.sh | sh -s email="$LE_EMAIL" >/dev/null
    fi
    ACME=~/.acme.sh/acme.sh

    # ЖЁСТКИЙ сброс email в account.conf (если acme.sh был установлен раньше)
    log "INFO: Чистим кэш acme.sh-аккаунта..."
    # Затираем ACCOUNT_EMAIL в глобальном конфиге
    if [ -f ~/.acme.sh/account.conf ]; then
        sed -i "/^ACCOUNT_EMAIL=/d" ~/.acme.sh/account.conf
    fi
    echo "ACCOUNT_EMAIL='$LE_EMAIL'" >> ~/.acme.sh/account.conf
    # Удаляем локальные CA-кэши (там хранятся зарегистрированные с невалидным email аккаунты)
    rm -rf ~/.acme.sh/ca 2>/dev/null || true

    log "INFO: Регистрируем LE-аккаунт с email=$LE_EMAIL..."
    if ! $ACME --register-account --accountemail "$LE_EMAIL" --server letsencrypt; then
        log "ERROR: Не удалось зарегистрировать LE-аккаунт с email $LE_EMAIL"
        exit 1
    fi

    mkdir -p "$IP_CERT_DIR"

    log "INFO: Запрашиваем LE cert на $SSL_IP (profile=shortlived, 6 дней)..."
    $ACME --set-default-ca --server letsencrypt --force >/dev/null 2>&1

    if ! $ACME --issue \
            -d "$SSL_IP" \
            --standalone \
            --server letsencrypt \
            --accountemail "$LE_EMAIL" \
            --certificate-profile shortlived \
            --days 6 \
            --httpport 80 \
            --force; then
        log "ERROR: acme.sh не смог выпустить серт на $SSL_IP"
        log "       Проверь:"
        log "       1) порт 80 открыт снаружи (security group cloud-провайдера)"
        log "       2) IP публичный (не NAT, не серый)"
        log "       3) Email валидный (не example.com/test/localhost)"
        log "       4) Свежий acme.sh (должен знать --certificate-profile)"
        exit 1
    fi

    $ACME --installcert -d "$SSL_IP" \
        --key-file      "$IP_CERT_DIR/privkey.pem" \
        --fullchain-file "$IP_CERT_DIR/fullchain.pem" \
        --reloadcmd     "docker restart stealth-bridge 2>/dev/null || true"

    chmod 644 "$IP_CERT_DIR/privkey.pem" "$IP_CERT_DIR/fullchain.pem"

    $ACME --upgrade --auto-upgrade >/dev/null 2>&1
    log "SUCCESS: IP серт в $IP_CERT_DIR"

    # Cron: renewal каждые 4 дня в 05:00 по UTC+5 (Asia/Yekaterinburg)
    cat > /etc/cron.d/acme-ip-renew <<EOF
# Auto-renew LE IP cert: stop container, renew (standalone :80), start container
# Schedule: каждые 4 дня в 05:00 по Asia/Yekaterinburg (UTC+5)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON_TZ=Asia/Yekaterinburg
0 5 */4 * * root docker stop stealth-bridge >/dev/null 2>&1; $ACME --cron --home /root/.acme.sh >/dev/null 2>&1; docker start stealth-bridge >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/acme-ip-renew
    log "INFO: Cron renewal: /etc/cron.d/acme-ip-renew (05:00 UTC+5, каждые 4 дня)"
fi

# ====================================================================
# 6. Распаковка архива
# ====================================================================
log "INFO: Распаковываем $ARCHIVE_NAME..."
unzip -o "$ARCHIVE_NAME" || die "unzip"

[ -d "$DIR_NAME" ] || die "папка $DIR_NAME не найдена после распаковки"
cd "$DIR_NAME"

[ -f "Dockerfile" ] || die "Dockerfile не найден"
[ -f "Caddyfile" ]  || die "Caddyfile не найден"

# ====================================================================
# 7. Формируем Caddyfile под выбранный режим
# ====================================================================
if [ "$USE_DOMAINS" = "1" ] && [ "$USE_IP" = "0" ]; then
    # Только домены — просто подменяем как раньше
    log "INFO: Caddyfile: только домены"
    sed -i.bak "s/esportsteam24\.ru/$MAIN_DOMAIN/g" Caddyfile
    sed -i.bak "s/esportsteam555\.ru/$SECOND_DOMAIN/g" Caddyfile

elif [ "$USE_DOMAINS" = "0" ] && [ "$USE_IP" = "1" ]; then
    # Только IP — переписываем Caddyfile полностью (домены не нужны)
    log "INFO: Caddyfile: только IP"
    UPSTREAM_HOST=$(echo "$IP_UPSTREAM" | sed -E 's#^https?://##; s#/.*##')
    cat > Caddyfile <<EOF
# Generated by allCaddy.sh — IP-only режим
$SSL_IP:443 {
    tls /etc/ssl/ipcert/fullchain.pem /etc/ssl/ipcert/privkey.pem

    reverse_proxy $IP_UPSTREAM {
        transport http {
            versions 2 1.1
            tls_insecure_skip_verify
            tls_server_name $UPSTREAM_HOST
        }
        header_up Host $UPSTREAM_HOST
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
EOF

else
    # Оба режима — домены + IP-блок
    log "INFO: Caddyfile: домены + IP"
    sed -i.bak "s/esportsteam24\.ru/$MAIN_DOMAIN/g" Caddyfile
    sed -i.bak "s/esportsteam555\.ru/$SECOND_DOMAIN/g" Caddyfile

    UPSTREAM_HOST=$(echo "$IP_UPSTREAM" | sed -E 's#^https?://##; s#/.*##')
    cat >> Caddyfile <<EOF

# ==== Injected: HTTPS на IP с LE shortlived cert ====
$SSL_IP:443 {
    tls /etc/ssl/ipcert/fullchain.pem /etc/ssl/ipcert/privkey.pem

    reverse_proxy $IP_UPSTREAM {
        transport http {
            versions 2 1.1
            tls_insecure_skip_verify
            tls_server_name $UPSTREAM_HOST
        }
        header_up Host $UPSTREAM_HOST
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }
}
EOF
fi

log "INFO: --- Финальный Caddyfile: ---"
cat Caddyfile
log "INFO: --- end of Caddyfile ---"

# ====================================================================
# 8. Сборка Docker
# ====================================================================
log "INFO: Собираем stealth-bridge..."
docker build -t stealth-bridge . || die "docker build"

# ====================================================================
# 9. sysctl (идемпотентно)
# ====================================================================
if ! grep -q "net.core.somaxconn=65535" /etc/sysctl.conf 2>/dev/null; then
    log "INFO: Применяем sysctl..."
    cat >> /etc/sysctl.conf <<EOF

# TCP optimizations (allCaddy.sh)
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
net.ipv4.tcp_max_orphans=65536
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=10
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_syncookies=1
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.icmp_ignore_bogus_error_responses=1
EOF
    sysctl -p >/dev/null
fi

# ====================================================================
# 10. SSH порт (учитывает socket activation в Ubuntu 22.10+)
# ====================================================================
if [ "$SSH_PORT" != "22" ]; then
    log "INFO: Меняем SSH порт на $SSH_PORT..."

    # 10.1 sshd_config — на случай не-systemd-socket систем
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    if grep -q "^Port " /etc/ssh/sshd_config; then
        sed -i "s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
    elif grep -q "^#Port " /etc/ssh/sshd_config; then
        sed -i "s/^#Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
    else
        echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
    fi

    # 10.2 ssh.socket override — для Ubuntu 22.10+ / 24.04 / 25.04, где SSH работает через socket activation
    if systemctl list-unit-files | grep -qE "^ssh\.socket"; then
        log "INFO: Обнаружен ssh.socket (socket activation) — создаём override..."
        mkdir -p /etc/systemd/system/ssh.socket.d
        cat > /etc/systemd/system/ssh.socket.d/override.conf <<EOF
[Socket]
ListenStream=
ListenStream=$SSH_PORT
EOF
        systemctl daemon-reload
        systemctl restart ssh.socket || log "WARN: не удалось рестартить ssh.socket"
    fi

    # 10.3 Рестарт самого sshd
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

    # 10.4 Проверка: SSH реально слушает новый порт?
    sleep 2
    if ss -tlnp 2>/dev/null | grep -qE ":${SSH_PORT}\s"; then
        log "SUCCESS: SSH слушает $SSH_PORT"
    else
        log "ERROR: SSH НЕ слушает $SSH_PORT! Откатываем всё на порт 22..."
        # Откатываем sshd_config
        cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
        # Удаляем socket override
        rm -f /etc/systemd/system/ssh.socket.d/override.conf
        systemctl daemon-reload
        systemctl restart ssh.socket 2>/dev/null || true
        systemctl restart ssh 2>/dev/null || true
        SSH_PORT=22
        log "WARN: SSH порт откачен на 22, продолжаем установку"
    fi
fi

# ====================================================================
# 11. Firewall
# ====================================================================
if command -v ufw &>/dev/null; then
    log "INFO: Настраиваем ufw..."
    ufw --force reset || true
    ufw allow "$SSH_PORT"/tcp || true
    ufw allow 80/tcp   || true
    ufw allow 443/tcp  || true
    ufw --force enable || true
fi
iptables -A INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || true
iptables -A INPUT -p tcp --dport 80  -j ACCEPT 2>/dev/null || true
iptables -A INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
log "INFO: Открыты порты: $SSH_PORT (SSH), 80, 443"

# ====================================================================
# 12. systemd unit (с volume для IP-серта если нужно)
# ====================================================================
VOL_ARG=""
[ "$USE_IP" = "1" ] && VOL_ARG="-v /etc/ssl/ipcert:/etc/ssl/ipcert:ro"

cat > /etc/systemd/system/stealth-bridge.service <<EOF
[Unit]
Description=Stealth Bridge Container (Caddy)
After=docker.service
Requires=docker.service

[Service]
Type=forking
RemainAfterExit=true
ExecStartPre=-/usr/bin/docker stop stealth-bridge
ExecStartPre=-/usr/bin/docker rm stealth-bridge
ExecStart=/usr/bin/docker run -d \\
    --name stealth-bridge \\
    --network host \\
    --ulimit nofile=65535:65535 \\
    --memory=1800m \\
    --cpus=2 \\
    --log-driver=none \\
    --restart=unless-stopped \\
    $VOL_ARG \\
    stealth-bridge
ExecStop=/usr/bin/docker stop stealth-bridge
ExecStopPost=/usr/bin/docker rm -f stealth-bridge

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable stealth-bridge

# ====================================================================
# 13. Старт
# ====================================================================
log "INFO: Чистим старые контейнеры..."
docker stop stealth-bridge 2>/dev/null || true
docker rm -f stealth-bridge 2>/dev/null || true

log "INFO: Запускаем stealth-bridge..."
if ! systemctl start stealth-bridge; then
    log "WARN: systemd не запустил, пробую docker run напрямую..."
    docker run -d \
        --name stealth-bridge \
        --network host \
        --ulimit nofile=65535:65535 \
        --memory=1800m \
        --cpus=2 \
        --log-driver=none \
        --restart=unless-stopped \
        $VOL_ARG \
        stealth-bridge || die "docker run"
fi

# ====================================================================
# 14. Итоговая информация
# ====================================================================
log "SUCCESS: Установка завершена ($MODE_NAME)"
[ "$USE_DOMAINS" = "1" ] && log "  https://$MAIN_DOMAIN   → s1.znayaclub.ru (LE auto)"
[ "$USE_DOMAINS" = "1" ] && log "  https://$SECOND_DOMAIN → kenricklomar.ru (LE auto)"
[ "$USE_IP"      = "1" ] && log "  https://$SSL_IP        → $IP_UPSTREAM (LE shortlived, 6d)"
log "  SSH: $SSH_PORT"

docker ps | grep stealth-bridge || log "WARN: контейнер не в docker ps"
systemctl status stealth-bridge --no-pager | head -20 || true

log "INFO: Ребут через 15 секунд для применения всех настроек..."
log "WARNING: После ребута SSH на порту $SSH_PORT!"
sleep 15
log "INFO: Перезагружаем..."
shutdown -r now
