#!/bin/bash

set -e

ZIP_URL="https://raw.githubusercontent.com/adamteam93/hello/refs/heads/main/All_DockerCaddy.zip"

# Функция логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "INFO: Загружаем All_DockerCaddy.zip..."
curl -L -o All_DockerCaddy.zip "$ZIP_URL" || {
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

# ======= Ввод SSH порта =======
read -p "Введите новый SSH порт (22-65535, по умолчанию 22): " SSH_PORT
if [ -z "$SSH_PORT" ]; then
    SSH_PORT=22
fi

# Валидация SSH порта
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 22 ] || [ "$SSH_PORT" -gt 65535 ]; then
    log "ERROR: SSH порт должен быть числом от 22 до 65535"
    exit 1
fi

log "INFO: Используем SSH порт: $SSH_PORT"

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
log "INFO: Распаковываем All_DockerCaddy.zip..."
unzip -o All_DockerCaddy.zip || {
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

# ======= Настройка SSH порта ПЕРЕД запуском контейнера =======
if [ "$SSH_PORT" != "22" ]; then
    log "INFO: Настраиваем SSH порт $SSH_PORT..."

    # Создаем резервную копию конфигурации SSH
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

    # Изменяем порт в конфигурации SSH
    if grep -q "^Port " /etc/ssh/sshd_config; then
        sed -i "s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
    elif grep -q "^#Port " /etc/ssh/sshd_config; then
        sed -i "s/^#Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
    else
        echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
    fi

    log "INFO: SSH порт изменен на $SSH_PORT"
fi

# ======= Настройка firewall =======
if command -v ufw &> /dev/null; then
    log "INFO: Настраиваем ufw для портов..."
    ufw --force reset || true  # Сбрасываем правила
    ufw allow $SSH_PORT/tcp || true    # SSH
    ufw allow 80/tcp || true          # HTTP для Let's Encrypt
    ufw allow 443/tcp || true         # HTTPS для контейнера
    ufw --force enable || true
fi

# Настраиваем iptables как резерв
iptables -A INPUT -p tcp --dport $SSH_PORT -j ACCEPT 2>/dev/null || true
iptables -A INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
iptables -A INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true

log "INFO: Открыты порты: $SSH_PORT (SSH), 80 (HTTP), 443 (HTTPS)"

# ======= Создаем улучшенный systemd сервис =======
cat > /etc/systemd/system/stealth-bridge.service << EOF
[Unit]
Description=Stealth Bridge Container
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
    stealth-bridge
ExecStop=/usr/bin/docker stop stealth-bridge
ExecStopPost=/usr/bin/docker rm -f stealth-bridge

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable stealth-bridge

# ======= Остановка и удаление старых контейнеров =======
log "INFO: Очищаем старые контейнеры..."
docker stop stealth-bridge 2>/dev/null || true
docker rm -f stealth-bridge 2>/dev/null || true

# ======= Запуск контейнера через systemd =======
log "INFO: Запускаем контейнер stealth-bridge через systemd..."
systemctl start stealth-bridge || {
    log "ERROR: Не удалось запустить сервис stealth-bridge"
    # Пробуем запустить напрямую для диагностики
    log "INFO: Пробуем запустить контейнер напрямую..."
    docker run -d \
        --name stealth-bridge \
        --network host \
        --ulimit nofile=65535:65535 \
        --memory=1800m \
        --cpus=2 \
        --log-driver=none \
        --restart=unless-stopped \
        stealth-bridge || {
        log "ERROR: Критическая ошибка при запуске контейнера"
        exit 1
    }
}

log "SUCCESS: Контейнер stealth-bridge успешно запущен с доменами: $MAIN_DOMAIN, $SECOND_DOMAIN"
log "INFO: Сервис добавлен в автозапуск"

# ======= Проверяем статус =======
log "INFO: Статус контейнера:"
docker ps | grep stealth-bridge || log "WARN: Контейнер не найден в списке запущенных"

# Проверяем статус сервиса
systemctl status stealth-bridge --no-pager || log "WARN: Проблемы со статусом сервиса"

# ======= Финальная информация и перезагрузка =======
log "SUCCESS: Установка завершена!"
log "INFO: Домены: $MAIN_DOMAIN, $SECOND_DOMAIN"
log "INFO: SSH порт: $SSH_PORT"
log "INFO: Контейнер stealth-bridge запущен и добавлен в автозапуск"

# Пауза перед перезагрузкой
log "INFO: Сервер будет перезагружен через 15 секунд для применения всех настроек..."
log "WARNING: После перезагрузки подключайтесь по SSH через порт $SSH_PORT"

sleep 15

log "INFO: Перезагружаем сервер..."
shutdown -r now
