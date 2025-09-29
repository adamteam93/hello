#!/bin/bash

set -e

ZIP_URL="https://raw.githubusercontent.com/adamteam93/hello/refs/heads/main/All_Docker.zip"

# Функция логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "INFO: Загружаем All_Docker.zip..."
curl -L -o All_Docker.zip "$ZIP_URL" || {
    log "ERROR: Не удалось загрузить архив"
    exit 1
}

# ======= Ввод доменов с валидацией =======
validate_domain() {
    if [[ ! $1 =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        log "ERROR: Неверный формат домена: $1"
        return 1
    fi
}

read -p "Введите основной домен (например, example.com): " MAIN_DOMAIN
if [ -z "$MAIN_DOMAIN" ] || ! validate_domain "$MAIN_DOMAIN"; then
    log "ERROR: Основной домен не может быть пустым или иметь неверный формат."
    exit 1
fi

read -p "Введите второй домен (например, second.com): " SECOND_DOMAIN
if [ -z "$SECOND_DOMAIN" ] || ! validate_domain "$SECOND_DOMAIN"; then
    log "ERROR: Второй домен не может быть пустым или иметь неверный формат."
    exit 1
fi

log "INFO: Используем домены: $MAIN_DOMAIN и $SECOND_DOMAIN"

# ======= Установка необходимых пакетов =======
install_if_missing() {
    if ! command -v $1 &> /dev/null; then
        log "INFO: Устанавливаем $1..."
        apt update && apt install -y $1
    fi
}

install_if_missing unzip
install_if_missing docker.io

# ======= Распаковка архива =======
log "INFO: Распаковываем All_Docker.zip..."
unzip -o All_Docker.zip || {
    log "ERROR: Не удалось распаковать архив"
    exit 1
}

if [ ! -d "All_Docker" ]; then
    log "ERROR: Директория All_Docker не найдена после распаковки"
    exit 1
fi

cd All_Docker

# ======= Проверка наличия конфигурационного файла =======
if [ ! -f "default.conf" ]; then
    log "ERROR: Файл default.conf не найден"
    exit 1
fi

# ======= Подстановка доменов =======
log "INFO: Заменяем домены в конфигурации..."
sed -i.bak "s/esportsteam24\.ru/$MAIN_DOMAIN/g" default.conf
sed -i.bak "s/esportsteam555\.ru/$SECOND_DOMAIN/g" default.conf

# ======= Остановка веб-сервисов перед получением сертификатов =======
log "INFO: Останавливаем веб-сервисы перед получением SSL..."
systemctl stop nginx apache2 2>/dev/null || true
docker stop $(docker ps -q) 2>/dev/null || true

# ======= Установка и настройка certbot =======
install_if_missing certbot

# ======= Получение SSL-сертификатов =======
get_certificate() {
    local domain=$1
    log "INFO: Получаем SSL-сертификат для $domain..."
    
    certbot certonly --standalone \
        -d "$domain" \
        --non-interactive \
        --agree-tos \
        -m "admin@$domain" \
        --rsa-key-size 4096 || {
        log "WARN: Ошибка при получении сертификата для $domain"
        return 1
    }
}

get_certificate "$MAIN_DOMAIN"
get_certificate "$SECOND_DOMAIN"

# ======= Проверка наличия Dockerfile =======
if [ ! -f "Dockerfile" ]; then
    log "ERROR: Dockerfile не найден"
    exit 1
fi

# ======= Сборка Docker-образа =======
log "INFO: Собираем Docker-образ stealth-bridge..."
docker build -t stealth-bridge . || {
    log "ERROR: Не удалось собрать Docker-образ"
    exit 1
}

# ======= Удаляем старый контейнер =======
docker rm -f stealth-bridge 2>/dev/null || true

# ======= Применяем оптимизированные параметры sysctl =======
log "INFO: Применяем параметры sysctl для оптимизации TCP..."

# Создаем файл для постоянных настроек
cat >> /etc/sysctl.conf << EOF
# TCP optimizations for high load
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

# Применяем настройки
sysctl -p

# ======= Создаем systemd сервис для автозапуска =======
cat > /etc/systemd/system/stealth-bridge.service << EOF
[Unit]
Description=Stealth Bridge Container
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/bin/docker run -d \\
    --name stealth-bridge \\
    -v /etc/letsencrypt:/etc/letsencrypt:ro \\
    --network host \\
    --ulimit nofile=65535:65535 \\
    --memory=1800m \\
    --cpus=2 \\
    --log-driver=none \\
    --restart=unless-stopped \\
    stealth-bridge
ExecStop=/usr/bin/docker stop stealth-bridge
ExecStopPost=/usr/bin/docker rm -f stealth-bridge

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable stealth-bridge

# ======= Запуск контейнера =======
log "INFO: Запускаем контейнер stealth-bridge..."
docker run -d \
    --name stealth-bridge \
    -v /etc/letsencrypt:/etc/letsencrypt:ro \
    --network host \
    --ulimit nofile=65535:65535 \
    --memory=1800m \
    --cpus=2 \
    --log-driver=none \
    --restart=unless-stopped \
    stealth-bridge || {
    log "ERROR: Не удалось запустить контейнер"
    exit 1
}

log "SUCCESS: Контейнер stealth-bridge успешно запущен с доменами: $MAIN_DOMAIN, $SECOND_DOMAIN"
log "INFO: Сервис добавлен в автозапуск"

# Показываем статус
docker ps | grep stealth-bridge
