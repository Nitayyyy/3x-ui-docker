#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}Этот скрипт выполнит следующие действия:${NC}"
echo "1. Создаст файл подкачки (Swap) на 2GB"
echo "2. Включит алгоритм BBR для ускорения сети"
echo "3. Установит и настроит Fail2ban (защита от брутфорса)"
echo "4. Установит фаервол UFW и откроет порты 22, 80, 443 и 2055"
echo "5. Установит Docker и Docker Compose"
echo "6. Проверит или выпустит SSL-сертификат Let's Encrypt"
echo "7. Развернет 3x-ui (база SQLite) в Docker-контейнере"
echo "8. Автоматически привяжет сертификаты, порт 2055 и путь /black/"
echo ""

read -rp "Начать установку? (y/n): " START_INSTALL
if [[ ! "$START_INSTALL" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Установка отменена.${NC}"
    exit 1
fi

# ================= 1. ПРОВЕРКА СУЩЕСТВУЮЩИХ СЕРТИФИКАТОВ =================
USE_EXISTING_CERT=false
EXISTING_CERTS=()

if [ -d "/opt/3x-ui/cert/live" ]; then
    for d in /opt/3x-ui/cert/live/*; do
        if [ -d "$d" ] && [ -f "$d/fullchain.pem" ]; then
            EXISTING_CERTS+=("$(basename "$d")")
        fi
    done
fi

if [ ${#EXISTING_CERTS[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Обнаружены существующие сертификаты:${NC}"
    for cert_domain in "${EXISTING_CERTS[@]}"; do
        cert_file="/opt/3x-ui/cert/live/$cert_domain/fullchain.pem"
        EXP_DATE=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2 || echo "неизвестно")
        echo -e " - Домен: ${GREEN}${cert_domain}${NC} (действует до: ${EXP_DATE})"
    done
    echo ""
    read -rp "Использовать найденный сертификат? (y - использовать / n - выпустить заново) [y]: " CERT_CHOICE
    CERT_CHOICE=${CERT_CHOICE:-y}

    if [[ "$CERT_CHOICE" =~ ^[Yy]$ ]]; then
        USE_EXISTING_CERT=true
        DOMAIN="${EXISTING_CERTS[0]}"
        if [ ${#EXISTING_CERTS[@]} -gt 1 ]; then
            read -rp "Введите домен из списка выше, который хотите привязать: " DOMAIN
        fi
        echo -e "${GREEN}Выбран сертификат для домена: ${DOMAIN}${NC}"
    fi
fi

if [ "$USE_EXISTING_CERT" = false ]; then
    read -rp "Введите ваш домен (должен указывать на IP сервера): " DOMAIN
    read -rp "Введите вашу почту (для Let's Encrypt): " EMAIL
fi

# ================= 2. ПАРАМЕТРЫ ПАНЕЛИ =================
XUI_USER="admin"
XUI_PASS=$(LC_ALL=C tr -dc 'A-Z0-9!@#' < /dev/urandom | head -c 15)
XUI_PORT="2055"
XUI_PATH="/black/"

echo -e "\n${GREEN}Обновление списков пакетов...${NC}"
apt-get update -y >/dev/null 2>&1

# ================= 3. SWAP =================
echo -e "${GREEN}Настройка файла подкачки (Swap) 2GB...${NC}"
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab >/dev/null 2>&1
else
    echo -e "${YELLOW}Файл подкачки уже существует.${NC}"
fi

# ================= 4. BBR =================
echo -e "${GREEN}Включение алгоритма BBR...${NC}"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf >/dev/null 2>&1
    echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf >/dev/null 2>&1
    sysctl -p >/dev/null 2>&1
else
    echo -e "${YELLOW}BBR уже включен.${NC}"
fi

# ================= 5. FAIL2BAN =================
echo -e "${GREEN}Настройка Fail2ban...${NC}"
apt-get install -y fail2ban >/dev/null 2>&1
cat << 'EOF' > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 1d
findtime = 10m
maxretry = 3

[sshd]
enabled = true
EOF
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban >/dev/null 2>&1

# ================= 6. UFW =================
echo -e "${GREEN}Настройка фаервола UFW...${NC}"
apt-get install -y ufw >/dev/null 2>&1
ufw allow ssh >/dev/null 2>&1
ufw allow 22/tcp >/dev/null 2>&1
ufw allow "${XUI_PORT}"/tcp >/dev/null 2>&1
ufw allow 80/tcp >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1

# ================= 7. DOCKER =================
echo -e "${GREEN}Проверка Docker...${NC}"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | bash >/dev/null 2>&1
    systemctl enable docker && systemctl start docker
fi
if ! docker compose version &> /dev/null; then
    apt-get install -y docker-compose-plugin >/dev/null 2>&1
fi

# ================= 8. РАБОТА С SSL =================
mkdir -p /opt/3x-ui/cert
mkdir -p /opt/3x-ui/db

if [ "$USE_EXISTING_CERT" = false ]; then
    echo -e "${GREEN}Выпуск SSL-сертификата через Certbot...${NC}"
    if docker run --rm -p 80:80 -v /opt/3x-ui/cert:/etc/letsencrypt certbot/certbot certonly --standalone --agree-tos --no-eff-email --non-interactive --force-renewal -d "$DOMAIN" -m "$EMAIL" >/dev/null 2>&1; then
        echo -e "${GREEN}Сертификат успешно выпущен!${NC}"
    else
        echo -e "${RED}Ошибка выпуска сертификата! Проверьте порт 80 и DNS-запись домена.${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}Используем проверенный сертификат для ${DOMAIN}.${NC}"
fi

DOCKER_CERT_PATH="/cert/live/$DOMAIN/fullchain.pem"
DOCKER_KEY_PATH="/cert/live/$DOMAIN/privkey.pem"

# ================= 9. РАЗВЕРТЫВАНИЕ 3X-UI =================
echo -e "${GREEN}Запуск контейнера 3x-ui...${NC}"
cd /opt/3x-ui
cat << EOF > docker-compose.yml
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./db:/etc/x-ui
      - ./cert:/cert
    environment:
      - TZ=Europe/Moscow
EOF

docker compose pull >/dev/null 2>&1
docker compose up -d >/dev/null 2>&1

echo -e "${GREEN}Инициализация базы данных и применение настроек...${NC}"
sleep 10

# Обращаемся напрямую к ядру /app/x-ui без вызова лишнего меню
docker exec 3x-ui /app/x-ui setting -username "${XUI_USER}" -password "${XUI_PASS}" >/dev/null 2>&1
docker exec 3x-ui /app/x-ui setting -port "${XUI_PORT}" >/dev/null 2>&1
docker exec 3x-ui /app/x-ui setting -webBasePath "${XUI_PATH}" >/dev/null 2>&1
docker exec 3x-ui /app/x-ui setting -webCert "${DOCKER_CERT_PATH}" -webCertKey "${DOCKER_KEY_PATH}" >/dev/null 2>&1

# Перезапуск контейнера для активации защищенного режима
docker restart 3x-ui >/dev/null 2>&1

echo ""
echo -e "${GREEN}Установка полностью завершена!${NC}"
echo -e "Адрес панели: ${YELLOW}https://${DOMAIN}:${XUI_PORT}${XUI_PATH}${NC}"
echo -e "Логин:        ${YELLOW}${XUI_USER}${NC}"
echo -e "Пароль:       ${YELLOW}${XUI_PASS}${NC}"
