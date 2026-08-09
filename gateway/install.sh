#!/usr/bin/env bash
set -Eeuo pipefail

umask 027

readonly APP_NAME="starly-gateway"
readonly APP_DIR="/opt/starly-gateway"
readonly DATA_DIR="/var/lib/starly-gateway"
readonly ACME_DIR="/opt/starly-acme"
readonly ACME_WEBROOT="/var/www/starly-acme"
readonly NGINX_CONFIG="/etc/nginx/conf.d/starly-gateway.conf"
readonly RENEW_SCRIPT="/usr/local/sbin/starly-renew-cert"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"

MODE=""
IDENTIFIER=""
EMAIL=""
STAGING=0
PYTHON_BIN=""

usage() {
  cat <<'EOF'
Starly Gateway 一键安装器

域名证书：
  sudo bash install.sh --domain starly.example.com --email admin@example.com

公网 IPv4 证书：
  sudo bash install.sh --ip 203.0.113.10 --email admin@example.com

选项：
  --staging    使用 Let's Encrypt 测试环境（证书不受客户端信任）
  -h, --help   显示帮助

安装前请确保：
  1. 服务器拥有公网 IPv4，80/443 端口可从互联网访问。
  2. 域名模式下，域名 A 记录已经指向本机公网 IP。
  3. install.sh 与 starly_gateway.py、requirements.txt 位于同一目录。
EOF
}

log() {
  printf '\n\033[1;34m[Starly]\033[0m %s\n' "$*"
}

fail() {
  printf '\n\033[1;31m[Starly] 安装失败：\033[0m %s\n' "$*" >&2
  exit 1
}

on_error() {
  local line="$1"
  printf '\n\033[1;31m[Starly] 第 %s 行执行失败。\033[0m\n' "$line" >&2
  printf '可查看：systemctl status starly-gateway nginx --no-pager\n' >&2
}
trap 'on_error "$LINENO"' ERR

while (($#)); do
  case "$1" in
    --domain)
      [[ $# -ge 2 ]] || fail "--domain 后缺少域名"
      [[ -z "$MODE" ]] || fail "--domain 和 --ip 只能选择一个"
      MODE="domain"
      IDENTIFIER="${2,,}"
      shift 2
      ;;
    --ip)
      [[ $# -ge 2 ]] || fail "--ip 后缺少公网 IPv4"
      [[ -z "$MODE" ]] || fail "--domain 和 --ip 只能选择一个"
      MODE="ip"
      IDENTIFIER="$2"
      shift 2
      ;;
    --email)
      [[ $# -ge 2 ]] || fail "--email 后缺少邮箱"
      EMAIL="$2"
      shift 2
      ;;
    --staging)
      STAGING=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "未知参数：$1"
      ;;
  esac
done

[[ $EUID -eq 0 ]] || fail "请使用 root 或 sudo 运行"
[[ -n "$MODE" && -n "$IDENTIFIER" ]] || { usage; fail "必须指定 --domain 或 --ip"; }
[[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail "邮箱格式不正确"
[[ -f "$SCRIPT_DIR/starly_gateway.py" ]] || fail "找不到 $SCRIPT_DIR/starly_gateway.py"
[[ -f "$SCRIPT_DIR/requirements.txt" ]] || fail "找不到 $SCRIPT_DIR/requirements.txt"

if [[ "$MODE" == "domain" ]]; then
  [[ "$IDENTIFIER" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || \
    fail "域名格式不正确：$IDENTIFIER"
else
  IFS=. read -r ip1 ip2 ip3 ip4 extra <<<"$IDENTIFIER"
  [[ -z "${extra:-}" && -n "${ip4:-}" ]] || fail "当前 IP 版本仅支持公网 IPv4"
  for octet in "$ip1" "$ip2" "$ip3" "$ip4"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ && 10#$octet -le 255 ]] || fail "IPv4 格式不正确：$IDENTIFIER"
  done
  case "$IDENTIFIER" in
    0.*|10.*|127.*|169.254.*|192.168.*) fail "必须使用可从互联网访问的公网 IPv4" ;;
    172.*)
      ((10#$ip2 < 16 || 10#$ip2 > 31)) || fail "必须使用可从互联网访问的公网 IPv4"
      ;;
  esac
fi

[[ -r /etc/os-release ]] || fail "无法识别操作系统"
# shellcheck disable=SC1091
source /etc/os-release
OS_ID="${ID,,}"
OS_LIKE="${ID_LIKE:-}"

install_packages() {
  log "安装系统依赖"
  if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" || "$OS_LIKE" == *debian* ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      ca-certificates curl nginx openssl python3 python3-pip python3-venv
  elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_LIKE" == *rhel* || "$OS_LIKE" == *fedora* ]]; then
    local manager=""
    if command -v dnf >/dev/null 2>&1; then
      manager="dnf"
    elif command -v yum >/dev/null 2>&1; then
      manager="yum"
    else
      fail "找不到 dnf 或 yum"
    fi
    "$manager" install -y ca-certificates curl nginx openssl python3 python3-pip policycoreutils
    # CentOS Stream 9 的系统 python3 是 3.9，而 Gateway 与 Certbot 5.4+ 需要 3.10+。
    "$manager" install -y python3.11 python3.11-pip || true
  else
    fail "不支持的系统：${PRETTY_NAME:-$OS_ID}；仅支持 CentOS/RHEL、Debian 和 Ubuntu"
  fi
}

create_venv() {
  local path="$1"
  if ! "$PYTHON_BIN" -m venv "$path"; then
    "$PYTHON_BIN" -m pip install --upgrade virtualenv
    "$PYTHON_BIN" -m virtualenv "$path"
  fi
}

open_firewall() {
  log "检查防火墙"
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow 80/tcp
    ufw allow 443/tcp
  fi
}

install_packages

for candidate in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1 && \
      "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)'; then
    PYTHON_BIN="$(command -v "$candidate")"
    break
  fi
done
[[ -n "$PYTHON_BIN" ]] || fail "需要 Python 3.10 或更高版本；请升级系统的软件源后重试"
PYTHON_VERSION="$($PYTHON_BIN -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
log "使用 Python $PYTHON_VERSION ($PYTHON_BIN)"

log "安装 Starly Gateway"
if ! id -u starly >/dev/null 2>&1; then
  useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin starly 2>/dev/null || \
    useradd --system --home-dir "$APP_DIR" --shell /sbin/nologin starly
fi
install -d -m 0755 "$APP_DIR/app"
install -d -o starly -g starly -m 0750 "$DATA_DIR"
install -m 0644 "$SCRIPT_DIR/starly_gateway.py" "$APP_DIR/app/starly_gateway.py"
install -m 0644 "$SCRIPT_DIR/requirements.txt" "$APP_DIR/app/requirements.txt"

if [[ ! -x "$APP_DIR/venv/bin/python" ]]; then
  create_venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/python" -m pip install --upgrade pip
"$APP_DIR/venv/bin/python" -m pip install --upgrade -r "$APP_DIR/app/requirements.txt"

PAIRING_CREATED=0
PAIRING_ID=""
PAIRING_TOKEN=""
if [[ ! -s "$DATA_DIR/pairings.json" ]]; then
  PAIRING_CREATED=1
  read -r PAIRING_ID PAIRING_TOKEN < <("$APP_DIR/venv/bin/python" - <<'PY'
import hashlib
import json
import secrets
from pathlib import Path

pairing_id = secrets.token_hex(16)
token = secrets.token_urlsafe(32)
path = Path("/var/lib/starly-gateway/pairings.json")
path.write_text(json.dumps({pairing_id: {
    "tokenSha256": hashlib.sha256(token.encode()).hexdigest()
}}, indent=2) + "\n", encoding="utf-8")
print(pairing_id, token)
PY
  )
  chown starly:starly "$DATA_DIR/pairings.json"
  chmod 0640 "$DATA_DIR/pairings.json"
fi

cat > /etc/systemd/system/starly-gateway.service <<EOF
[Unit]
Description=Starly encrypted WebSocket gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=starly
Group=starly
WorkingDirectory=$APP_DIR/app
Environment=PYTHONUNBUFFERED=1
Environment=STARLY_GATEWAY_HOST=127.0.0.1
Environment=STARLY_GATEWAY_PORT=8780
Environment=STARLY_GATEWAY_DATA=$DATA_DIR
Environment=STARLY_GATEWAY_PAIRINGS=$DATA_DIR/pairings.json
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/app/starly_gateway.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable starly-gateway
systemctl restart starly-gateway

log "安装 Certbot 5.4+"
install -d -m 0755 "$ACME_WEBROOT/.well-known/acme-challenge"
if [[ ! -x "$ACME_DIR/bin/certbot" ]]; then
  create_venv "$ACME_DIR"
fi
"$ACME_DIR/bin/python" -m pip install --upgrade pip
"$ACME_DIR/bin/python" -m pip install --upgrade 'certbot>=5.4,<6'

cat > "$NGINX_CONFIG" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $IDENTIFIER;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type text/plain;
    }

    location / {
        return 404;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t
systemctl enable --now nginx
systemctl reload nginx
open_firewall
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
  setsebool -P httpd_can_network_connect 1
fi

log "向 Let's Encrypt 申请 TLS 证书"
CERT_NAME="starly-${MODE}"
if ((STAGING)); then
  CERT_NAME="${CERT_NAME}-staging"
fi
CERTBOT_ARGS=(
  certonly --non-interactive --agree-tos --email "$EMAIL"
  --webroot --webroot-path "$ACME_WEBROOT"
  --cert-name "$CERT_NAME" --keep-until-expiring
)
if ((STAGING)); then
  CERTBOT_ARGS+=(--staging)
fi
if [[ "$MODE" == "domain" ]]; then
  CERTBOT_ARGS+=(-d "$IDENTIFIER")
else
  CERTBOT_ARGS+=(--preferred-profile shortlived --ip-address "$IDENTIFIER")
fi
"$ACME_DIR/bin/certbot" "${CERTBOT_ARGS[@]}"

[[ -s "/etc/letsencrypt/live/$CERT_NAME/fullchain.pem" ]] || fail "证书文件生成失败"
[[ -s "/etc/letsencrypt/live/$CERT_NAME/privkey.pem" ]] || fail "证书私钥生成失败"

cat > "$NGINX_CONFIG" <<EOF
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    listen [::]:80;
    server_name $IDENTIFIER;

    location ^~ /.well-known/acme-challenge/ {
        root $ACME_WEBROOT;
        default_type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $IDENTIFIER;

    ssl_certificate /etc/letsencrypt/live/$CERT_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$CERT_NAME/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:StarlyTLS:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    location = /health {
        access_log off;
        add_header Content-Type text/plain;
        return 200 'ok\n';
    }

    location /ws {
        proxy_pass http://127.0.0.1:8780;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }

    location / {
        return 404;
    }
}
EOF

nginx -t
systemctl reload nginx

log "配置自动续期"
cat > "$RENEW_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
"$ACME_DIR/bin/certbot" renew --quiet --deploy-hook "systemctl reload nginx"
EOF
chmod 0750 "$RENEW_SCRIPT"

cat > /etc/systemd/system/starly-cert-renew.service <<EOF
[Unit]
Description=Renew Starly Gateway TLS certificate
After=network-online.target nginx.service

[Service]
Type=oneshot
ExecStart=$RENEW_SCRIPT
EOF

cat > /etc/systemd/system/starly-cert-renew.timer <<'EOF'
[Unit]
Description=Check Starly Gateway TLS certificate renewal every 6 hours

[Timer]
OnBootSec=15min
OnUnitActiveSec=6h
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now starly-cert-renew.timer
systemctl is-active --quiet starly-gateway
systemctl is-active --quiet nginx

if ((PAIRING_CREATED)); then
  CREDENTIALS_FILE="/root/starly-gateway-credentials.txt"
  cat > "$CREDENTIALS_FILE" <<EOF
Gateway URL: wss://$IDENTIFIER/ws
Pairing ID: $PAIRING_ID
Token: $PAIRING_TOKEN
说明: Token 仅用于第一台 PC 首次安全登记；登记成功后改用设备专属凭据。
EOF
  chmod 0600 "$CREDENTIALS_FILE"
fi

printf '\n\033[1;32mStarly Gateway 安装完成。\033[0m\n'
printf 'Gateway URL: wss://%s/ws\n' "$IDENTIFIER"
printf '健康检查: https://%s/health\n' "$IDENTIFIER"
printf '证书模式: %s\n' "$MODE"
printf '自动续期: systemctl list-timers starly-cert-renew.timer\n'
if ((PAIRING_CREATED)); then
  printf '首次接入凭据已保存到：%s（权限 600，请妥善保管）\n' "$CREDENTIALS_FILE"
else
  printf '已保留现有配对数据：%s/pairings.json\n' "$DATA_DIR"
fi
