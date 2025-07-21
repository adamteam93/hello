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

# # ======= Ввод backend-домена (с дефолтом) =======
# read -p "Введите адрес backend-прокси [по умолчанию: 123.kenricklomar.ru]: " BACKEND_DOMAIN
# BACKEND_DOMAIN=${BACKEND_DOMAIN:-123.kenricklomar.ru}

echo "[INFO] Используем основной домен: $MAIN_DOMAIN"

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

# echo "[INFO] Заменяем 123.kenricklomar.ru на $BACKEND_DOMAIN..."
# sed -i "s/123\.kenricklomar\.ru/$BACKEND_DOMAIN/g" default.conf

# ======= Установка certbot при необходимости =======
if ! command -v certbot &> /dev/null; then
    echo "[INFO] Устанавливаем certbot..."
    apt install -y certbot
fi

# ======= Получение сертификата =======
echo "[INFO] Получаем SSL-сертификат для $MAIN_DOMAIN..."
certbot certonly --standalone -d "$MAIN_DOMAIN" --non-interactive --agree-tos -m admin@$MAIN_DOMAIN || {
    echo "[WARN] Certbot завершился с ошибкой. Проверьте DNS и свободен ли порт 80."
}

# ======= Установка docker при необходимости =======
if ! command -v docker &> /dev/null; then
    echo "[INFO] Устанавливаем Docker..."
    apt install -y docker.io
fi

# ======= Сборка Docker-образа =======
echo "[INFO] Собираем Docker-образ stealth-bridge..."
docker build -t stealth-bridge .

# ======= Запуск Docker-контейнера =======
echo "[INFO] Запускаем контейнер stealth-bridge..."
docker run -d \
    --name stealth-bridge \
    -v /etc/letsencrypt:/etc/letsencrypt:ro \
    -p 80:80 \
    -p 443:444 \
    --ulimit nofile=65535:65535 \
    --log-driver=json-file \
    --log-opt max-size=10m \
    --log-opt max-file=5 \
    stealth-bridge

echo "[✅ DONE] Контейнер stealth-bridge успешно запущен."
