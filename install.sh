#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}Установщик 3x-ui в Docker${NC}"
echo "Параметры: Swap 2G, BBR, Fail2ban, UFW (22, 80, 443, 2055), SQLite"
echo ""

read -rp "Начать установку? (y/n): " START_INSTALL
if [[ ! "$START_INSTALL" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Установка отменена.${NC}"
    exit 1
fi

# ================= 1. ВОПРОСЫ ПО SSL И ПАНЕЛИ =================
echo ""
read -rp "Создавать / использовать SSL-сертификат? (y/n) [y]: " ASK_SSL
ASK_SSL=${ASK_SSL:-y}

USE_SSL=false
BIND_CERT=false
NEED_NEW_CERT=false
DOMAIN=""

if [[ "$ASK_SSL" =~ ^[Yy]$ ]]; then
    USE_SSL=true

    # Проверяем, есть ли уже сертификат
    EXISTING_DOMAIN=""
    RECREATE_CERT="n"

    if [ -d "/opt/3x-ui/cert/live" ]; then
        for d in /opt/3x-ui/cert/live/*; do
            if [ -d "$d" ] && [ -f "$d/fullchain.pem" ]; then
                EXISTING_DOMAIN=$(basename "$d")
                break
            fi
        done
    fi

    if [ -n "$EXISTING_DOMAIN" ]; then
        EXP_DATE=$(openssl x509 -enddate -noout -in "/opt/3x-ui/cert/live/$EXISTING_DOMAIN/fullchain.pem" 2>/dev/null | cut -d= -f2 || echo "действителен")
        echo -e "\n${YELLOW}Обнаружен существующий сертификат:${NC}"
        echo -e "Домен:          ${GREEN}${EXISTING_DOMAIN}${NC}"
        echo -e "Действует до:   ${GREEN}${EXP_DATE}${NC}"
        read -rp "Пересоздать его? (y - пересоздать / n - оставить текущий) [n]: " RECREATE_CERT
        RECREATE_CERT=${RECREATE_CERT:-n}
    fi

    if [[ "$RECREATE_CERT" =~ ^[Yy]$ ]] || [ -z "$EXISTING_DOMAIN" ]; then
        read -rp "Введите домен: " DOMAIN
        read -rp "Введите email (для Let's Encrypt): " EMAIL
        NEED_NEW_CERT=true
    else
        DOMAIN="$EXISTING_DOMAIN"
        NEED_NEW_CERT=false
        echo -e "${GREEN}Используем существующий сертификат для ${DOMAIN}.${NC}"
    fi

    # Спрашиваем про привязку к панели
    echo ""
    read -rp "Привязать SSL к веб-панели? (y - HTTPS в панели / n - голый HTTP для Nginx) [n]: " ASK_BIND
    ASK_BIND=${ASK_BIND:-n}
    if [[ "$ASK_BIND" =~ ^[Yy]$ ]]; then
        BIND_CERT=true
    fi
else
    echo -e "${YELLOW}SSL отключен. Панель будет работать по чистому HTTP.${NC}"
fi

# Получаем внешний IP сервера на случай, если домен не используется
SERVER_IP=$(curl -s4 https://ifconfig.me || hostname -I | awk '{print $1}')

XUI_USER="admin"
XUI_PASS=$(LC_ALL=C tr -dc 'A-Z0-9!@#' < /dev/urandom | head -c 15)
XUI_PORT="2055"
XUI_PATH="/black/"

# ================= 2. НАСТРОЙКА СИСТЕМЫ =================
echo -e "\n${GREEN}Обновление пакетов и настройка системы...${NC}"
apt-get update -y >/dev/null 2>&1

if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab >/dev/null 2>&1
fi

if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" | tee -a /etc/sysctl.conf >/dev/null 2>&1
    echo "net.ipv4.tcp_congestion_control=bbr" | tee -a /etc/sysctl.conf >/dev/null 2>&1
    sysctl -p >/dev/null 2>&1
fi

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

apt-get install -y ufw >/dev/null 2>&1
ufw allow ssh >/dev/null 2>&1
ufw allow 22/tcp >/dev/null 2>&1
ufw allow "${XUI_PORT}"/tcp >/dev/null 2>&1
ufw allow 80/tcp >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1

if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | bash >/dev/null 2>&1
    systemctl enable docker && systemctl start docker
fi
if ! docker compose version &> /dev/null; then
    apt-get install -y docker-compose-plugin >/dev/null 2>&1
fi

mkdir -p /opt/3x-ui/cert
mkdir -p /opt/3x-ui/db

# ================= 3. ВЫПУСК СЕРТИФИКАТА (ЕСЛИ ВКЛЮЧЕН) =================
if [ "$USE_SSL" = true ] && [ "$NEED_NEW_CERT" = true ]; then
    echo -e "${GREEN}Выпуск сертификата через Certbot...${NC}"
    if docker run --rm -p 80:80 -v /opt/3x-ui/cert:/etc/letsencrypt certbot/certbot certonly --standalone --agree-tos --no-eff-email --non-interactive --force-renewal -d "$DOMAIN" -m "$EMAIL" >/dev/null 2>&1; then
        echo -e "${GREEN}Сертификат успешно получен!${NC}"
    else
        echo -e "${RED}Ошибка выпуска SSL! Проверьте привязку домена к IP и порт 80.${NC}"
        exit 1
    fi
fi

# ================= 4. ЗАПУСК 3X-UI =================
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

echo -e "${GREEN}Ожидание инициализации базы данных...${NC}"
sleep 8

# ================= 5. ПРИМЕНЕНИЕ НАСТРОЕК =================
echo -e "${GREEN}Применение настроек панели...${NC}"
docker exec 3x-ui /app/x-ui setting -username "${XUI_USER}" -password "${XUI_PASS}" >/dev/null 2>&1
docker exec 3x-ui /app/x-ui setting -port "${XUI_PORT}" >/dev/null 2>&1
docker exec 3x-ui /app/x-ui setting -webBasePath "${XUI_PATH}" >/dev/null 2>&1

# ================= 6. ПРИВЯЗКА SSL (ТОЛЬКО ЕСЛИ ВЫБРАНО) =================
if [ "$BIND_CERT" = true ]; then
    DOCKER_CERT_PATH="/cert/live/$DOMAIN/fullchain.pem"
    DOCKER_KEY_PATH="/cert/live/$DOMAIN/privkey.pem"

    echo -e "${GREEN}Привязка сертификата через меню панели (HTTPS)...${NC}"
    docker exec -i 3x-ui x-ui <<EOF >/dev/null 2>&1
20
5
2
${DOCKER_CERT_PATH}
${DOCKER_KEY_PATH}
0
0
EOF
    PANEL_PROTO="https"
    PANEL_HOST="${DOMAIN}"
else
    echo -e "${YELLOW}Панель оставлена на чистом HTTP (без привязки SSL к панели).${NC}"
    PANEL_PROTO="http"
    if [ -n "$DOMAIN" ]; then
        PANEL_HOST="${DOMAIN}"
    else
        PANEL_HOST="${SERVER_IP}"
    fi
fi

docker restart 3x-ui >/dev/null 2>&1

# Автопродление certbot настраиваем только если создавался SSL
if [ "$USE_SSL" = true ]; then
    echo -e "${GREEN}Настройка автопродления сертификата...${NC}"
    cat << 'EOF' > /etc/cron.d/certbot-3xui
0 3 1 */2 * root docker run --rm -p 80:80 -v /opt/3x-ui/cert:/etc/letsencrypt certbot/certbot renew --quiet && docker restart 3x-ui >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/certbot-3xui
fi

# ================= 7. ИТОГ =================
echo ""
echo -e "${GREEN}Установка полностью завершена!${NC}"
echo -e "Адрес панели:      ${YELLOW}${PANEL_PROTO}://${PANEL_HOST}:${XUI_PORT}${XUI_PATH}${NC}"
echo -e "Логин:             ${YELLOW}${XUI_USER}${NC}"
echo -e "Пароль:            ${YELLOW}${XUI_PASS}${NC}"

if [ "$BIND_CERT" = true ]; then
    echo -e "Режим панели:      ${GREEN}HTTPS (SSL привязан)${NC}"
    echo -e "Автопродление SSL: ${GREEN}Включено${NC}"
elif [ "$USE_SSL" = true ]; then
    echo -e "Режим панели:      ${YELLOW}Голый HTTP (сертификат сохранен в /opt/3x-ui/cert для Nginx)${NC}"
    echo -e "Автопродление SSL: ${GREEN}Включено${NC}"
else
    echo -e "Режим панели:      ${YELLOW}Голый HTTP (без SSL)${NC}"
fi
