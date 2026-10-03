#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-}"
STATE_DIR="/etc/gravitas-xray"
TLS_DIR="$STATE_DIR/tls"

[[ -n "$HOST" ]] || { echo "Server IPv4 is required." >&2; exit 1; }
[[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected IPv4 address." >&2; exit 1; }

DOMAIN="${HOST//./-}.sslip.io"
mkdir -p "$TLS_DIR"
chmod 700 "$STATE_DIR" "$TLS_DIR"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y certbot ca-certificates

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 80/tcp >/dev/null
fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http >/dev/null
  firewall-cmd --reload >/dev/null
fi

need_cert=1
if [[ -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" && -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]]; then
  if openssl x509 -checkend $((30*24*3600)) -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" >/dev/null 2>&1; then
    need_cert=0
  fi
fi

if [[ "$need_cert" -eq 1 ]]; then
  certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email \
    --preferred-challenges http -d "$DOMAIN"
fi

install -m 644 "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$TLS_DIR/fullchain.pem"
install -m 640 "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$TLS_DIR/privkey.pem"
chown root:nogroup "$TLS_DIR/privkey.pem"
printf '%s\n' "$DOMAIN" > "$STATE_DIR/tls-domain"
chmod 600 "$STATE_DIR/tls-domain"

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/gravitas-xray-cert.sh <<HOOK
#!/usr/bin/env bash
set -e
install -m 644 "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$TLS_DIR/fullchain.pem"
install -m 640 "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$TLS_DIR/privkey.pem"
chown root:nogroup "$TLS_DIR/privkey.pem"
systemctl restart xray
HOOK
chmod 700 /etc/letsencrypt/renewal-hooks/deploy/gravitas-xray-cert.sh
systemctl enable --now certbot.timer >/dev/null 2>&1 || true

echo "TLS certificate ready for $DOMAIN"
