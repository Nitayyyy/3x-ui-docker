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
echo "6. Выпустит SSL-сертификат Let's Encrypt на 90 дней (или оставит старый)"
echo "7. Развернет 3x-ui (база SQLite) в Docker-контейнере"
echo "8. Сгенерирует пароль, привяжет сертификат и настроит путь /black/"
echo ""

read -rp "Начать установку? (y/n): " START_INSTALL
if [[ ! "$START_INSTALL" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Установка отменена.${NC}"
    exit 1
fi

# ================= ЗАПРОС ДАННЫХ =================
read -rp "Введите ваш домен (он должен быть уже привязан к IP сервера): " DOMAIN
read -rp "Введите вашу почту (для выпуска Let's Encrypt): " EMAIL

# ================= ПАРАМЕТРЫ ПАНЕЛИ =================
XUI_USER="admin"
XUI_PASS=$(LC_ALL=C tr -dc 'A-Z0-9!@#' < /dev/urandom | head -c 15)
XUI_PORT="2055"
XUI_PATH="/black/"

echo -e "\n${GREEN}Обновление списков пакетов...${NC}"
apt-get update -y

# ================= SWAP =================
echo -e "\n${GREEN}Настройка файла подкачки (Swap) 2GB...${NC}"
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
else
    echo -e "${YELLOW}Файл подкачки уже существует, пропускаем.${NC}"
fi

# ================= BBR =================
echo -e "\n${GREEN}Включение алгоритма BBR...${NC}"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf
    sysctl -p
else
    echo -e "${YELLOW}BBR уже включен, пропускаем.${NC}"
fi

# ================= FAIL2BAN =================
echo -e "\n${GREEN}Установка и настройка Fail2ban...${NC}"
apt-get install -y fail2ban
cat << 'EOF' > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 1d
findtime = 10m
maxretry = 3

[sshd]
enabled = true
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# ================= UFW =================
echo -e "\n${GREEN}Настройка фаервола UFW...${NC}"
apt-get install -y ufw
ufw allow ssh
ufw allow 22/tcp
ufw allow "${XUI_PORT}"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# ================= DOCKER =================
echo -e "\n${GREEN}Установка Docker...${NC}"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker && systemctl start docker
fi
if ! docker compose version &> /dev/null; then
    apt-get install -y docker-compose-plugin
fi

# ================= SSL СЕРТИФИКАТ =================
echo -e "\n${GREEN}Получение SSL-сертификата Let's Encrypt...${NC}"
mkdir -p /opt/3x-ui/cert
mkdir -p /opt/3x-ui/db

if docker run --rm -p 80:80 -v /opt/3x-ui/cert:/etc/letsencrypt certbot/certbot certonly --standalone --agree-tos --no-eff-email --non-interactive --keep-until-expiring -d "$DOMAIN" -m "$EMAIL"; then
    echo -e "${GREEN}Сертификат успешно проверен/выпущен!${NC}"
    DOCKER_CERT_PATH="/cert/live/$DOMAIN/fullchain.pem"
    DOCKER_KEY_PATH="/cert/live/$DOMAIN/privkey.pem"
else
    echo -e "${RED}Ошибка выпуска сертификата! Убедитесь, что домен привязан к IP и порт 80 свободен. Скрипт прерван.${NC}"
    exit 1
fi

# ================= РАЗВЕРТЫВАНИЕ 3X-UI =================
echo -e "\n${GREEN}Создание конфигурации Docker Compose...${NC}"
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

echo -e "\n${GREEN}Запуск контейнера 3x-ui...${NC}"
docker compose pull
docker compose up -d

echo -e "\n${GREEN}Ожидание 10 секунд для инициализации базы данных...${NC}"
sleep 10

echo -e "\n${GREEN}Применение настроек...${NC}"
# Применяем настройки по очереди с правильными флагами!
docker exec 3x-ui /app/x-ui setting -username "${XUI_USER}" -password "${XUI_PASS}"
docker exec 3x-ui /app/x-ui setting -port "${XUI_PORT}"
docker exec 3x-ui /app/x-ui setting -webBasePath "${XUI_PATH}"
docker exec 3x-ui /app/x-ui setting -webCertFile "${DOCKER_CERT_PATH}" -webKeyFile "${DOCKER_KEY_PATH}"

docker restart 3x-ui >/dev/null 2>&1

echo -e "\n${GREEN}Установка полностью завершена!${NC}"
echo -e "Адрес панели: ${YELLOW}https://${DOMAIN}:${XUI_PORT}${XUI_PATH}${NC}"
echo -e "Логин:        ${YELLOW}${XUI_USER}${NC}"
echo -e "Пароль:       ${YELLOW}${XUI_PASS}${NC}"
