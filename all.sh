#!/bin/bash

set -e

ZIP_URL="https://raw.githubusercontent.com/adamteam93/hello/refs/heads/main/All_Docker.zip"
echo "[INFO] Загружаем All_Docker.zip..."
curl -L -o All_Docker.zip "$ZIP_URL"

# ======= Ввод основного домена =======
read -p "Введите основной домен (например, example.com): " MAIN_DOMAIN
if [ -z "$MAIN_DOMAIN" ]; then
    echo "[ОШИБКА] Основной домен не может быть пустым."
    exit 1
fi

# ======= Ввод второго домена =======
read -p "Введите второй домен (например, second.com): " SECOND_DOMAIN
if [ -z "$SECOND_DOMAIN" ]; then
    echo "[ОШИБКА] Второй домен не может быть пустым."
    exit 1
fi

echo "[INFO] Используем домены: $MAIN_DOMAIN и $SECOND_DOMAIN"

# ======= Установка unzip при необходимости =======
if ! command -v unzip &> /dev/null; then
    echo "[INFO] Устанавливаем unzip..."
    apt update && apt install -y unzip
fi

# ======= Распаковка архива =======
echo "[INFO] Распаковываем All_Docker.zip..."
unzip -o All_Docker.zip

cd All_Docker

# ======= Подстановка доменов =======
echo "[INFO] Заменяем esportsteam24.ru на $MAIN_DOMAIN..."
sed -i "s/esportsteam24\.ru/$MAIN_DOMAIN/g" default.conf

echo "[INFO] Заменяем esportsteam555.ru на $SECOND_DOMAIN..."
sed -i "s/esportsteam555\.ru/$SECOND_DOMAIN/g" default.conf

# ======= Установка certbot при необходимости =======
if ! command -v certbot &> /dev/null; then
    echo "[INFO] Устанавливаем certbot..."
    apt install -y certbot
fi

# ======= Получение SSL-сертификатов =======
echo "[INFO] Получаем SSL-сертификаты..."
certbot certonly --standalone -d "$MAIN_DOMAIN" --non-interactive --agree-tos -m admin@$MAIN_DOMAIN || {
    echo "[WARN] Ошибка при получении сертификата для $MAIN_DOMAIN."
}
certbot certonly --standalone -d "$SECOND_DOMAIN" --non-interactive --agree-tos -m admin@$SECOND_DOMAIN || {
    echo "[WARN] Ошибка при получении сертификата для $SECOND_DOMAIN."
}

# ======= Установка docker при необходимости =======
if ! command -v docker &> /dev/null; then
    echo "[INFO] Устанавливаем Docker..."
    apt install -y docker.io
fi

# ======= Сборка Docker-образа =======
echo "[INFO] Собираем Docker-образ stealth-bridge..."
docker build -t stealth-bridge .

# ======= Удаляем старый контейнер (если есть) =======
docker rm -f stealth-bridge 2>/dev/null || true

echo "[INFO] Применяем параметры sysctl для оптимизации TCP..."

# Очереди соединений
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535
sysctl -w net.ipv4.tcp_max_orphans=65536

# TIME-WAIT и FIN
sysctl -w net.ipv4.tcp_fin_timeout=15
sysctl -w net.ipv4.tcp_tw_reuse=1

# Keepalive
sysctl -w net.ipv4.tcp_keepalive_time=600
sysctl -w net.ipv4.tcp_keepalive_intvl=30
sysctl -w net.ipv4.tcp_keepalive_probes=10

# Буферы
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216"

# Защита
sysctl -w net.ipv4.tcp_syncookies=1
sysctl -w net.ipv4.icmp_echo_ignore_broadcasts=1
sysctl -w net.ipv4.icmp_ignore_bogus_error_responses=1

# ======= Запуск Docker-контейнера =======
echo "[INFO] Запускаем контейнер stealth-bridge..."
docker run -d   --name stealth-bridge   -v /etc/letsencrypt:/etc/letsencrypt:ro   --network host   --ulimit nofile=65535:65535   --memory=1800m   --cpus=2   --log-driver=none   stealth-bridge


echo "[✅ DONE] Контейнер stealth-bridge успешно запущен с двумя доменами."
