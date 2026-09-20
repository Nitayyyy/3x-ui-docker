#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${YELLOW}====================================================${NC}"
echo -e "${YELLOW}  Установщик 3x-ui + Nginx (Турбо-обфускация) в Docker${NC}"
echo -e "${YELLOW}====================================================${NC}"
echo "Параметры: BBR, TCP Fast Open, BDP буферы 64M, Swap 2G, Fail2ban, UFW"
echo ""

read -rp "Начать установку? (y/n) [y]: " START_INSTALL
START_INSTALL=${START_INSTALL:-y}
if [[ ! "$START_INSTALL" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Установка отменена.${NC}"
    exit 1
fi

# ================= 1. ИНТЕРАКТИВНЫЕ ВОПРОСЫ =================
echo ""
read -rp "Создавать / использовать SSL-сертификат? (y/n) [y]: " ASK_SSL
ASK_SSL=${ASK_SSL:-y}

USE_SSL=false
INSTALL_NGINX=false
BIND_CERT=false
NEED_NEW_CERT=false
DOMAIN=""

if [[ "$ASK_SSL" =~ ^[Yy]$ ]]; then
    USE_SSL=true

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
        read -rp "Введите ваш домен (например, sub.domain.com): " DOMAIN
        read -rp "Введите email (для Let's Encrypt): " EMAIL
        NEED_NEW_CERT=true
    else
        DOMAIN="$EXISTING_DOMAIN"
        NEED_NEW_CERT=false
        echo -e "${GREEN}Используем существующий сертификат для ${DOMAIN}.${NC}"
    fi

    echo ""
    echo -e "${CYAN}Установить Nginx в Docker (443 порт, маскировка VLESS/Trojan, L4 SNI-роутер, защита от сканеров РКН)?${NC}"
    read -rp "Установить Nginx? (y/n) [y]: " ASK_NGINX
    ASK_NGINX=${ASK_NGINX:-y}
    if [[ "$ASK_NGINX" =~ ^[Yy]$ ]]; then
        INSTALL_NGINX=true
        BIND_CERT=false # TLS расшифровывает Nginx, панель остается на чистом HTTP
    else
        INSTALL_NGINX=false
        read -rp "Привязать SSL напрямую к панели 3x-ui? (y - HTTPS / n - голый HTTP) [y]: " ASK_BIND
        ASK_BIND=${ASK_BIND:-y}
        if [[ "$ASK_BIND" =~ ^[Yy]$ ]]; then
            BIND_CERT=true
        fi
    fi
else
    echo -e "${YELLOW}SSL отключен. Сервисы будут работать без шифрования TLS.${NC}"
fi

SERVER_IP=$(curl -s4 https://ifconfig.me || hostname -I | awk '{print $1}')

XUI_USER="admin"
XUI_PASS=$(LC_ALL=C tr -dc 'A-Z0-9!@#' < /dev/urandom | head -c 15)
XUI_PORT="2055"
XUI_PATH="/black/"

# ================= 2. СИСТЕМНЫЙ ТЮНИНГ И УСКОРЕНИЕ =================
echo -e "\n${GREEN}[1/6] Системная оптимизация Linux (BBR, TCP Fast Open, BDP буферы 64M)...${NC}"
apt-get update -y >/dev/null 2>&1

if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab >/dev/null 2>&1
fi

cat << 'EOF' > /etc/sysctl.d/99-vless-speed.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_mtu_probing = 1
fs.file-max = 1000000
EOF
sysctl --system >/dev/null 2>&1

# Быстрый и чистый DNS для самого сервера
cat << 'EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

apt-get install -y fail2ban ufw >/dev/null 2>&1
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

# Настройка UFW
ufw allow ssh >/dev/null 2>&1
ufw allow 22/tcp >/dev/null 2>&1
ufw allow 80/tcp >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
ufw allow 443/udp >/dev/null 2>&1    # Hysteria 2
ufw allow 56100/udp >/dev/null 2>&1  # AmneziaWG

if [ "$INSTALL_NGINX" = false ]; then
    ufw allow "${XUI_PORT}"/tcp >/dev/null 2>&1
else
    ufw delete allow "${XUI_PORT}"/tcp >/dev/null 2>&1 || true
fi
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

# ================= 3. ВЫПУСК СЕРТИФИКАТА =================
if [ "$USE_SSL" = true ] && [ "$NEED_NEW_CERT" = true ]; then
    echo -e "\n${GREEN}[2/6] Выпуск SSL-сертификата Let's Encrypt через Certbot...${NC}"
    if docker run --rm -p 80:80 -v /opt/3x-ui/cert:/etc/letsencrypt certbot/certbot certonly --standalone --agree-tos --no-eff-email --non-interactive --force-renewal -d "$DOMAIN" -m "$EMAIL" >/dev/null 2>&1; then
        echo -e "${GREEN}Сертификат успешно получен!${NC}"
    else
        echo -e "${RED}Ошибка выпуска SSL! Проверьте привязку домена к IP ($SERVER_IP) и порт 80.${NC}"
        exit 1
    fi
fi

# ================= 4. ЗАПУСК 3X-UI =================
echo -e "\n${GREEN}[3/6] Запуск контейнера 3x-ui в Docker...${NC}"
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
sleep 8

echo -e "\n${GREEN}[4/6] Применение настроек учетной записи и портов...${NC}"
docker exec 3x-ui /app/x-ui setting -username "${XUI_USER}" -password "${XUI_PASS}" >/dev/null 2>&1
docker exec 3x-ui /app/x-ui setting -port "${XUI_PORT}" >/dev/null 2>&1
docker exec 3x-ui /app/x-ui setting -webBasePath "${XUI_PATH}" >/dev/null 2>&1

if [ "$BIND_CERT" = true ]; then
    DOCKER_CERT_PATH="/cert/live/$DOMAIN/fullchain.pem"
    DOCKER_KEY_PATH="/cert/live/$DOMAIN/privkey.pem"
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
    PANEL_HOST="${DOMAIN}:${XUI_PORT}"
else
    docker exec 3x-ui /app/x-ui setting -webCert "" -webKey "" >/dev/null 2>&1
    PANEL_PROTO="http"
    if [ -n "$DOMAIN" ]; then
        PANEL_HOST="${DOMAIN}:${XUI_PORT}"
    else
        PANEL_HOST="${SERVER_IP}:${XUI_PORT}"
    fi
fi
docker restart 3x-ui >/dev/null 2>&1

# ================= 5. УСТАНОВКА NGINX (ЕСЛИ ВЫБРАНО) =================
if [ "$INSTALL_NGINX" = true ]; then
    echo -e "\n${GREEN}[5/6] Настройка и запуск Nginx с обфускацией и маскировкой...${NC}"
    mkdir -p /opt/nginx
    cd /opt/nginx

    cat << 'EOF' > docker-compose.yml
services:
  nginx:
    image: nginx:latest
    container_name: nginx
    network_mode: host
    restart: unless-stopped
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - /opt/3x-ui/cert:/etc/letsencrypt:ro
    environment:
      - TZ=Europe/Moscow
EOF

    cat << EOF > nginx.conf
user  nginx;
worker_processes  auto;
worker_rlimit_nofile 100000;
error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

events {
    worker_connections 8192;
    use epoll;
    multi_accept on;
}

# --- 1. L4 SNI МАРШРУТИЗАТОР ---
stream {
    map \$ssl_preread_server_name \$backend {
        ${DOMAIN}   main_service;
        default     block_scanner;
    }

    upstream main_service {
        server 127.0.0.1:10443;
    }

    upstream block_scanner {
        server 127.0.0.1:8011;
    }

    server {
        listen 443;
        ssl_preread on;
        proxy_pass \$backend;
        proxy_buffer_size 64k;
        proxy_connect_timeout 5s;
        proxy_timeout 12h;
    }
}

# --- 2. L7 ОБРАБОТЧИКИ СЕРВИСОВ ---
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    server_tokens off;

    sendfile on;
    tcp_nopush off;
    tcp_nodelay on;
    keepalive_timeout 300s;
    keepalive_requests 100000;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ""      close;
    }

    server {
        listen 80;
        server_name ${DOMAIN};
        return 301 https://\$host\$request_uri;
    }

    server {
        listen 127.0.0.1:10443 ssl http2;
        server_name ${DOMAIN};

        ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;
        ssl_session_cache   shared:SSL:50m;
        ssl_session_timeout 1d;
        ssl_session_tickets on;

        # Веб-панель 3X-UI
        location ${XUI_PATH} {
            proxy_pass http://127.0.0.1:${XUI_PORT};
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
        }

        # VLESS XHTTP gRPC (порт 36490)
        location /secret-vpn {
            client_max_body_size 0;
            client_body_timeout 10m;
            grpc_read_timeout 3600s;
            grpc_send_timeout 3600s;
            grpc_buffer_size 256k;
            grpc_socket_keepalive on;
            grpc_pass grpc://127.0.0.1:36490;
        }

        # Trojan gRPC (порт 36491)
        location /trojan-grpc {
            client_max_body_size 0;
            client_body_timeout 10m;
            grpc_read_timeout 3600s;
            grpc_send_timeout 3600s;
            grpc_buffer_size 256k;
            grpc_socket_keepalive on;
            grpc_pass grpc://127.0.0.1:36491;
        }

        # Заглушка (маскировка под закрытый API)
        location / {
            return 401;
        }
    }

    server {
        listen 127.0.0.1:8011 ssl;
        ssl_reject_handshake on;
    }
}
EOF

    docker compose pull >/dev/null 2>&1
    docker compose up -d >/dev/null 2>&1
    PANEL_PROTO="https"
    PANEL_HOST="${DOMAIN}"
fi

# ================= 6. СОЗДАНИЕ XRAY-PASTE.TXT =================
echo -e "\n${GREEN}[6/6] Создание эталонного файла конфигурации ядра /opt/3x-ui/xray-paste.txt...${NC}"
cat << 'EOF' > /opt/3x-ui/xray-paste.txt
{
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "https+local://8.8.8.8/dns-query",
      "1.1.1.1",
      "8.8.8.8"
    ],
    "queryStrategy": "UseIPv4",
    "disableCache": false
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "tunnel",
      "settings": {
        "rewriteAddress": "127.0.0.1"
      },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "finalRules": [
          {
            "action": "block",
            "ip": [
              "geoip:private"
            ]
          },
          {
            "action": "allow"
          }
        ]
      },
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "UseIP",
          "tcpNoDelay": true,
          "tcpFastOpen": true,
          "tcpKeepAliveInterval": 15
        }
      }
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "blocked"
      }
    ]
  },
  "log": {
    "access": "none",
    "dnsLog": false,
    "loglevel": "error"
  },
  "policy": {
    "system": {
      "statsInboundDownlink": true,
      "statsInboundUplink": true,
      "statsOutboundDownlink": false,
      "statsOutboundUplink": false
    },
    "levels": {
      "0": {
        "handshake": 2,
        "connIdle": 300,
        "uplinkOnly": 1,
        "downlinkOnly": 1,
        "bufferSize": 10240,
        "statsUserDownlink": true,
        "statsUserUplink": true
      }
    }
  },
  "api": {
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService",
      "RoutingService"
    ],
    "tag": "api"
  },
  "metrics": {
    "listen": "127.0.0.1:11111",
    "tag": "metrics_out"
  },
  "stats": {}
}
EOF

# Настройка автопродления SSL
if [ "$USE_SSL" = true ]; then
    if [ "$INSTALL_NGINX" = true ]; then
        RELOAD_CMD="docker restart nginx 3x-ui >/dev/null 2>&1"
    else
        RELOAD_CMD="docker restart 3x-ui >/dev/null 2>&1"
    fi
    cat << EOF > /etc/cron.d/certbot-3xui
0 3 1 */2 * root docker run --rm -p 80:80 -v /opt/3x-ui/cert:/etc/letsencrypt certbot/certbot renew --quiet && ${RELOAD_CMD}
EOF
    chmod 644 /etc/cron.d/certbot-3xui
fi

# ================= 7. ФИНАЛЬНЫЙ ОТЧЁТ =================
echo ""
echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}       УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                 ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "Адрес панели:      ${YELLOW}${PANEL_PROTO}://${PANEL_HOST}${XUI_PATH}${NC}"
echo -e "Логин:             ${YELLOW}${XUI_USER}${NC}"
echo -e "Пароль:            ${YELLOW}${XUI_PASS}${NC}"
echo ""

if [ "$INSTALL_NGINX" = true ]; then
    echo -e "Режим работы:      ${GREEN}Nginx Frontend (Порт 443 HTTPS, Защита от сканеров включена)${NC}"
    echo -e "Готовые пути Nginx:"
    echo -e "  - VLESS XHTTP:   ${CYAN}127.0.0.1:36490${NC} ➔ путь ${CYAN}/secret-vpn${NC}"
    echo -e "  - Trojan gRPC:   ${CYAN}127.0.0.1:36491${NC} ➔ путь ${CYAN}/trojan-grpc${NC}"
    echo -e "  - Hysteria 2:    ${CYAN}0.0.0.0:443 (UDP)${NC} (напрямую в Xray)"
    echo -e "  - AmneziaWG:     ${CYAN}0.0.0.0:56100 (UDP)${NC} (напрямую в Xray)"
else
    echo -e "Режим работы:      ${YELLOW}Автономный 3X-UI (без Nginx)${NC}"
fi

echo ""
echo -e "${YELLOW}ВАЖНЫЙ ШАГ ПОСЛЕ ВХОДА В ПАНЕЛЬ:${NC}"
echo -e "1. Откройте файл конфига ядра на сервере: ${CYAN}cat /opt/3x-ui/xray-paste.txt${NC}"
echo -e "2. Скопируйте всё содержимое."
echo -e "3. Вставьте его в панели: ${GREEN}Конфигурации Xray ➔ Расширенный шаблон${NC} и сохраните."
echo -e "${GREEN}====================================================${NC}"
