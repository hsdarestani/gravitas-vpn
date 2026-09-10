#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-}"
STATE_DIR="/etc/gravitas-xray"
USER_DIR="$STATE_DIR/users"
CLIENT_DIR="/root/gravitas-vpn/xray-clients"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
DEFAULT_USERS=(hossein kiarash ahmad ehsan)
SERVER_NAME="speed.cloudflare.com"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

mkdir -p "$STATE_DIR" "$USER_DIR" "$CLIENT_DIR"
chmod 700 "$STATE_DIR" "$USER_DIR" "$CLIENT_DIR"

if [[ -n "$HOST" ]]; then
  printf '%s\n' "$HOST" > "$STATE_DIR/host"
  chmod 600 "$STATE_DIR/host"
elif [[ -s "$STATE_DIR/host" ]]; then
  HOST="$(cat "$STATE_DIR/host")"
else
  echo "Server host/IP is required on first run." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates openssl jq qrencode iproute2

# Official XTLS installer. It is idempotent and also upgrades an existing install.
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

XRAY_BIN="$(command -v xray || true)"
[[ -n "$XRAY_BIN" ]] || XRAY_BIN="/usr/local/bin/xray"
[[ -x "$XRAY_BIN" ]] || { echo "Xray installation failed." >&2; exit 1; }

if [[ ! -s "$STATE_DIR/port" ]]; then
  selected=""
  for candidate in 443 8443 2053 2083 9443; do
    if ! ss -ltnH "sport = :${candidate}" 2>/dev/null | grep -q .; then
      selected="$candidate"
      break
    fi
  done
  [[ -n "$selected" ]] || { echo "No preferred TCP port is free." >&2; exit 1; }
  printf '%s\n' "$selected" > "$STATE_DIR/port"
fi
PORT="$(cat "$STATE_DIR/port")"
chmod 600 "$STATE_DIR/port"

if [[ ! -s "$STATE_DIR/reality-private" || ! -s "$STATE_DIR/reality-password" ]]; then
  key_output="$($XRAY_BIN x25519)"
  private_key="$(printf '%s\n' "$key_output" | awk -F': *' '/^(PrivateKey|Private key):/ {print $2; exit}')"
  # Xray renamed the old public key to Password and newer versions print
  # "Password (PublicKey)". Accept all known formats without exposing the key.
  reality_password="$(printf '%s\n' "$key_output" | awk -F': *' '/^(Password( \(PublicKey\))?|PublicKey|Public key):/ {print $2; exit}')"
  [[ -n "$private_key" && -n "$reality_password" ]] || {
    echo "Could not parse Xray x25519 output." >&2
    exit 1
  }
  printf '%s\n' "$private_key" > "$STATE_DIR/reality-private"
  printf '%s\n' "$reality_password" > "$STATE_DIR/reality-password"
fi
chmod 600 "$STATE_DIR/reality-private" "$STATE_DIR/reality-password"
PRIVATE_KEY="$(cat "$STATE_DIR/reality-private")"
REALITY_PASSWORD="$(cat "$STATE_DIR/reality-password")"

if [[ ! -s "$STATE_DIR/short-id" ]]; then
  openssl rand -hex 8 > "$STATE_DIR/short-id"
fi
chmod 600 "$STATE_DIR/short-id"
SHORT_ID="$(cat "$STATE_DIR/short-id")"

# Create the initial team only once. A .disabled marker prevents a revoked default user
# from silently returning on a later deployment.
for user in "${DEFAULT_USERS[@]}"; do
  if [[ ! -e "$USER_DIR/$user.uuid" && ! -e "$USER_DIR/$user.disabled" ]]; then
    "$XRAY_BIN" uuid > "$USER_DIR/$user.uuid"
    chmod 600 "$USER_DIR/$user.uuid"
  fi
done

clients='[]'
for uuid_file in "$USER_DIR"/*.uuid; do
  [[ -e "$uuid_file" ]] || continue
  user="$(basename "$uuid_file" .uuid)"
  [[ -e "$USER_DIR/$user.disabled" ]] && continue
  uuid="$(tr -d '\r\n' < "$uuid_file")"
  clients="$(jq --arg id "$uuid" --arg email "$user" '. + [{id:$id, email:$email, flow:"xtls-rprx-vision"}]' <<<"$clients")"
done

[[ "$(jq 'length' <<<"$clients")" -gt 0 ]] || { echo "No enabled Xray users." >&2; exit 1; }

mkdir -p "$(dirname "$XRAY_CONFIG")"
jq -n \
  --argjson port "$PORT" \
  --argjson clients "$clients" \
  --arg sni "$SERVER_NAME" \
  --arg privateKey "$PRIVATE_KEY" \
  --arg shortId "$SHORT_ID" \
  '{
    log: {loglevel:"warning"},
    inbounds: [{
      listen:"0.0.0.0",
      port:$port,
      protocol:"vless",
      settings:{clients:$clients, decryption:"none"},
      streamSettings:{
        network:"tcp",
        security:"reality",
        realitySettings:{
          show:false,
          dest:($sni + ":443"),
          xver:0,
          serverNames:[$sni],
          privateKey:$privateKey,
          shortIds:[$shortId]
        }
      },
      sniffing:{enabled:true, destOverride:["http","tls","quic"], routeOnly:true}
    }],
    outbounds:[
      {protocol:"freedom", tag:"direct"},
      {protocol:"blackhole", tag:"block"}
    ],
    routing:{
      domainStrategy:"IPIfNonMatch",
      rules:[{ip:["geoip:private"], outboundTag:"block"}]
    }
  }' > "$XRAY_CONFIG.tmp"
install -m 644 "$XRAY_CONFIG.tmp" "$XRAY_CONFIG"
rm -f "$XRAY_CONFIG.tmp"

"$XRAY_BIN" run -test -config "$XRAY_CONFIG"
systemctl enable xray >/dev/null
systemctl restart xray
systemctl is-active --quiet xray

# Open only the selected Xray TCP port in host firewalls when present.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${PORT}/tcp" >/dev/null
fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
  firewall-cmd --reload >/dev/null
fi

# Build one importable VLESS share link, QR image, and native Xray client JSON per user.
for uuid_file in "$USER_DIR"/*.uuid; do
  [[ -e "$uuid_file" ]] || continue
  user="$(basename "$uuid_file" .uuid)"
  if [[ -e "$USER_DIR/$user.disabled" ]]; then
    rm -f "$CLIENT_DIR/$user.vless.txt" "$CLIENT_DIR/$user.png" "$CLIENT_DIR/$user.json"
    continue
  fi
  uuid="$(tr -d '\r\n' < "$uuid_file")"
  uri="vless://${uuid}@${HOST}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${REALITY_PASSWORD}&sid=${SHORT_ID}&type=tcp#Gravitas-${user}"
  printf '%s\n' "$uri" > "$CLIENT_DIR/$user.vless.txt"
  qrencode -o "$CLIENT_DIR/$user.png" -s 7 -m 2 "$uri"

  jq -n \
    --arg host "$HOST" \
    --argjson port "$PORT" \
    --arg id "$uuid" \
    --arg sni "$SERVER_NAME" \
    --arg password "$REALITY_PASSWORD" \
    --arg shortId "$SHORT_ID" \
    '{
      log:{loglevel:"warning"},
      inbounds:[{
        listen:"127.0.0.1",
        port:10808,
        protocol:"socks",
        settings:{udp:true},
        sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:true}
      }],
      outbounds:[{
        tag:"proxy",
        protocol:"vless",
        settings:{address:$host,port:$port,id:$id,encryption:"none",flow:"xtls-rprx-vision"},
        streamSettings:{
          network:"tcp",
          security:"reality",
          realitySettings:{fingerprint:"chrome",serverName:$sni,password:$password,shortId:$shortId,spiderX:"/"}
        }
      }]
    }' > "$CLIENT_DIR/$user.json"
done
chmod 600 "$CLIENT_DIR"/* 2>/dev/null || true

install -m 700 /opt/gravitas-vpn/scripts/manage_xray_user.sh /usr/local/sbin/gravitas-xray-user

printf 'Xray VLESS/REALITY active on TCP %s.\n' "$PORT"
printf 'Client material: %s\n' "$CLIENT_DIR"
