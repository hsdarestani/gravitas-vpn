#!/usr/bin/env bash
set -euo pipefail

PUBLIC_IP="${1:-}"
BASE_DIR="/etc/gravitas-panel"
DATA_DIR="/var/lib/gravitas-panel"
APP_SRC="/opt/gravitas-vpn/panel/app.py"
APP_DST="/opt/gravitas-panel/app.py"
PORT=9443
USER_NAME="admin"
SERVICE_USER="gravitas-panel"
USERS_CSV="hossein,kiarash,ahmad,ehsan,sajjad"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -n "$PUBLIC_IP" ]] || { echo 'Public IP/host is required.' >&2; exit 1; }
[[ -s "$APP_SRC" ]] || { echo "Missing panel app: $APP_SRC" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y python3 openssl curl jq >/dev/null

if ! id "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin "$SERVICE_USER"
fi

install -d -m 750 -o root -g "$SERVICE_USER" "$BASE_DIR"
install -d -m 750 -o "$SERVICE_USER" -g "$SERVICE_USER" "$DATA_DIR"
install -d -m 755 -o root -g root /opt/gravitas-panel
install -m 755 -o root -g root "$APP_SRC" "$APP_DST"

if [[ ! -s "$BASE_DIR/admin_password" ]]; then
  openssl rand -base64 36 | tr -d '\n/=+' | cut -c1-28 > "$BASE_DIR/admin_password"
fi
chown root:"$SERVICE_USER" "$BASE_DIR/admin_password"
chmod 640 "$BASE_DIR/admin_password"

if [[ ! -s "$BASE_DIR/tls.key" || ! -s "$BASE_DIR/tls.crt" ]]; then
  cat > "$BASE_DIR/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = $PUBLIC_IP
[v3_req]
subjectAltName = @alt_names
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
[alt_names]
IP.1 = $PUBLIC_IP
EOF
  openssl req -x509 -nodes -newkey rsa:3072 -sha256 -days 825 \
    -keyout "$BASE_DIR/tls.key" -out "$BASE_DIR/tls.crt" \
    -config "$BASE_DIR/openssl.cnf" >/dev/null 2>&1
fi
chown root:"$SERVICE_USER" "$BASE_DIR/tls.key" "$BASE_DIR/tls.crt"
chmod 640 "$BASE_DIR/tls.key" "$BASE_DIR/tls.crt"

cat > "$BASE_DIR/panel.env" <<EOF
PANEL_HOST=0.0.0.0
PANEL_PORT=$PORT
PANEL_USER=$USER_NAME
PANEL_PASSWORD_FILE=$BASE_DIR/admin_password
PANEL_CERT_FILE=$BASE_DIR/tls.crt
PANEL_KEY_FILE=$BASE_DIR/tls.key
PANEL_DB_FILE=$DATA_DIR/usage.db
XRAY_BIN=/usr/local/bin/xray
XRAY_API=127.0.0.1:10085
GRAVITAS_USERS=$USERS_CSV
POLL_SECONDS=30
ONLINE_WINDOW=180
EOF
chown root:"$SERVICE_USER" "$BASE_DIR/panel.env"
chmod 640 "$BASE_DIR/panel.env"

cat > /etc/systemd/system/gravitas-panel.service <<EOF
[Unit]
Description=Gravitas VPN monitoring panel
After=network-online.target xray.service
Wants=network-online.target
Requires=xray.service

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
EnvironmentFile=$BASE_DIR/panel.env
ExecStart=/usr/bin/python3 $APP_DST
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/usr/local/bin/xray $BASE_DIR
ReadWritePaths=$DATA_DIR
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now gravitas-panel >/dev/null

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${PORT}/tcp" >/dev/null
fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
  firewall-cmd --reload >/dev/null
fi

PASS="$(cat "$BASE_DIR/admin_password")"
for _ in {1..30}; do
  if curl -ksSf -u "${USER_NAME}:${PASS}" "https://127.0.0.1:${PORT}/api/data" | jq -e '.system.panel_active == true' >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
curl -ksSf -u "${USER_NAME}:${PASS}" "https://127.0.0.1:${PORT}/api/data" | jq -e '.system.panel_active == true' >/dev/null

cat > "$BASE_DIR/credentials.txt" <<EOF
Gravitas VPN Monitoring Panel
URL: https://${PUBLIC_IP}:${PORT}/
Username: ${USER_NAME}
Password: ${PASS}

Note: the TLS certificate is self-signed, so the browser will show a certificate warning on first visit.
EOF
chown root:"$SERVICE_USER" "$BASE_DIR/credentials.txt"
chmod 640 "$BASE_DIR/credentials.txt"

echo "Gravitas panel active on https://${PUBLIC_IP}:${PORT}/"
