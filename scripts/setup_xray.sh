#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-}"
STATE_DIR="/etc/gravitas-xray"
USER_DIR="$STATE_DIR/users"
CLIENT_DIR="/root/gravitas-vpn/xray-clients"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
EGRESS_IP=""
CLIENT_HOST=""
DEFAULT_USERS=(hossein kiarash ahmad ehsan sajjad)
SERVER_NAME="speed.cloudflare.com"
FALLBACK_SERVER_NAME=""
FALLBACK_DEST="1.1.1.1:443"
XHTTP_SERVER_NAME="speed.cloudflare.com"
TLS_CERT="$STATE_DIR/tls/fullchain.pem"
TLS_KEY="$STATE_DIR/tls/privkey.pem"
TLS_WS_PATH="/gravitas-ws"

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

# Keep a second REALITY listener for networks where the primary 443 path is
# filtered or degraded. Persist the selected port so client configs stay stable.
if [[ ! -s "$STATE_DIR/fallback-port" ]]; then
  fallback_selected=""
  for candidate in 2053 8443 2083 9443; do
    [[ "$candidate" == "$PORT" ]] && continue
    if ! ss -ltnH "sport = :${candidate}" 2>/dev/null | grep -q .; then
      fallback_selected="$candidate"
      break
    fi
  done
  [[ -n "$fallback_selected" ]] || { echo "No fallback TCP port is free." >&2; exit 1; }
  printf '%s\n' "$fallback_selected" > "$STATE_DIR/fallback-port"
fi
FALLBACK_PORT="$(cat "$STATE_DIR/fallback-port")"
chmod 600 "$STATE_DIR/fallback-port"

# Dedicated XHTTP + REALITY listener. Keep it separate from the existing
# Vision/RAW listeners so older client profiles continue to work unchanged.
if [[ ! -s "$STATE_DIR/xhttp-port" ]]; then
  xhttp_selected=""
  for candidate in 2083 8443 2096 2087; do
    [[ "$candidate" == "$PORT" || "$candidate" == "$FALLBACK_PORT" ]] && continue
    if ! ss -ltnH "sport = :${candidate}" 2>/dev/null | grep -q .; then
      xhttp_selected="$candidate"
      break
    fi
  done
  [[ -n "$xhttp_selected" ]] || { echo "No XHTTP TCP port is free." >&2; exit 1; }
  printf '%s\n' "$xhttp_selected" > "$STATE_DIR/xhttp-port"
fi
XHTTP_PORT="$(cat "$STATE_DIR/xhttp-port")"
chmod 600 "$STATE_DIR/xhttp-port"

XHTTP_PATH="/gravitas-xhttp"
printf '%s\n' "$XHTTP_PATH" > "$STATE_DIR/xhttp-path"
chmod 600 "$STATE_DIR/xhttp-path"

[[ -s "$STATE_DIR/tls-domain" && -s "$TLS_CERT" && -s "$TLS_KEY" ]] || {
  echo "Trusted TLS material is missing; run setup_ws_tls.sh first." >&2
  exit 1
}
TLS_DOMAIN="$(tr -d '\r\n' < "$STATE_DIR/tls-domain")"

if [[ ! -s "$STATE_DIR/ws-tls-port" ]]; then
  ws_tls_selected=""
  for candidate in 2096 2087 8443 2053; do
    [[ "$candidate" == "$PORT" || "$candidate" == "$FALLBACK_PORT" || "$candidate" == "$XHTTP_PORT" ]] && continue
    if ! ss -ltnH "sport = :${candidate}" 2>/dev/null | grep -q .; then
      ws_tls_selected="$candidate"
      break
    fi
  done
  [[ -n "$ws_tls_selected" ]] || { echo "No TLS WebSocket TCP port is free." >&2; exit 1; }
  printf '%s\n' "$ws_tls_selected" > "$STATE_DIR/ws-tls-port"
fi
WS_TLS_PORT="$(cat "$STATE_DIR/ws-tls-port")"
chmod 600 "$STATE_DIR/ws-tls-port"

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

# XHTTP must not use xtls-rprx-vision flow. Reuse the same UUIDs/emails with
# a flow-less client list dedicated to the XHTTP inbound.
xhttp_clients="$(jq '[.[] | {id:.id, email:.email}]' <<<"$clients")"
ws_tls_clients="$xhttp_clients"

CLIENT_HOST="$HOST"
if [[ -s "$STATE_DIR/egress-ip" ]]; then
  EGRESS_IP="$(tr -d '\\r\\n' < "$STATE_DIR/egress-ip")"
  CLIENT_HOST="$EGRESS_IP"
  ip -4 addr show | grep -F "$EGRESS_IP/32" >/dev/null || {
    echo "Configured egress IP $EGRESS_IP is not present on the server." >&2
    exit 1
  }
fi

mkdir -p "$(dirname "$XRAY_CONFIG")"
jq -n \
  --argjson port "$PORT" \
  --argjson fallbackPort "$FALLBACK_PORT" \
  --argjson xhttpPort "$XHTTP_PORT" \
  --argjson wsTlsPort "$WS_TLS_PORT" \
  --argjson clients "$clients" \
  --argjson xhttpClients "$xhttp_clients" \
  --argjson wsTlsClients "$ws_tls_clients" \
  --arg sni "$SERVER_NAME" \
  --arg fallbackSni "$FALLBACK_SERVER_NAME" \
  --arg fallbackDest "$FALLBACK_DEST" \
  --arg xhttpSni "$XHTTP_SERVER_NAME" \
  --arg xhttpPath "$XHTTP_PATH" \
  --arg tlsDomain "$TLS_DOMAIN" \
  --arg tlsCert "$TLS_CERT" \
  --arg tlsKey "$TLS_KEY" \
  --arg tlsWsPath "$TLS_WS_PATH" \
  --arg privateKey "$PRIVATE_KEY" \
  --arg shortId "$SHORT_ID" \
  --arg egressIp "$EGRESS_IP" \
  '{
    log: {loglevel:"warning"},
    inbounds: [
      {
        tag:"vless-primary",
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
      },
      {
        tag:"vless-fallback",
        listen:"0.0.0.0",
        port:$fallbackPort,
        protocol:"vless",
        settings:{clients:$clients, decryption:"none"},
        streamSettings:{
          network:"tcp",
          security:"reality",
          realitySettings:{
            show:false,
            dest:$fallbackDest,
            xver:0,
            serverNames:[""],
            privateKey:$privateKey,
            shortIds:[$shortId]
          }
        },
        sniffing:{enabled:true, destOverride:["http","tls","quic"], routeOnly:true}
      },
      {
        tag:"vless-xhttp",
        listen:"0.0.0.0",
        port:$xhttpPort,
        protocol:"vless",
        settings:{clients:$xhttpClients, decryption:"none"},
        streamSettings:{
          network:"xhttp",
          security:"reality",
          xhttpSettings:{
            mode:"auto",
            path:$xhttpPath
          },
          realitySettings:{
            show:false,
            dest:($xhttpSni + ":443"),
            xver:0,
            serverNames:[$xhttpSni],
            privateKey:$privateKey,
            shortIds:[$shortId]
          }
        },
        sniffing:{enabled:true, destOverride:["http","tls","quic"], routeOnly:true}
      },
      {
        tag:"vless-ws-tls",
        listen:"0.0.0.0",
        port:$wsTlsPort,
        protocol:"vless",
        settings:{clients:$wsTlsClients, decryption:"none"},
        streamSettings:{
          network:"ws",
          security:"tls",
          tlsSettings:{
            minVersion:"1.2",
            certificates:[{
              certificateFile:$tlsCert,
              keyFile:$tlsKey
            }]
          },
          wsSettings:{
            path:$tlsWsPath
          }
        },
        sniffing:{enabled:true, destOverride:["http","tls"], routeOnly:true}
      }
    ],
    outbounds:[
      ({protocol:"freedom", tag:"direct"} +
        (if $egressIp != "" then
          {sendThrough:$egressIp, streamSettings:{sockopt:{domainStrategy:"UseIPv4"}}}
        else {} end)),
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
  ufw allow "${FALLBACK_PORT}/tcp" >/dev/null
  ufw allow "${XHTTP_PORT}/tcp" >/dev/null
  ufw allow "${WS_TLS_PORT}/tcp" >/dev/null
fi
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
  firewall-cmd --permanent --add-port="${FALLBACK_PORT}/tcp" >/dev/null
  firewall-cmd --permanent --add-port="${XHTTP_PORT}/tcp" >/dev/null
  firewall-cmd --permanent --add-port="${WS_TLS_PORT}/tcp" >/dev/null
  firewall-cmd --reload >/dev/null
fi

# Build one importable VLESS share link, QR image, and native Xray client JSON per user.
for uuid_file in "$USER_DIR"/*.uuid; do
  [[ -e "$uuid_file" ]] || continue
  user="$(basename "$uuid_file" .uuid)"
  if [[ -e "$USER_DIR/$user.disabled" ]]; then
    rm -f "$CLIENT_DIR/$user.vless.txt" "$CLIENT_DIR/$user.png" "$CLIENT_DIR/$user.json" \
      "$CLIENT_DIR/$user-fallback.vless.txt" "$CLIENT_DIR/$user-fallback.png" "$CLIENT_DIR/$user-fallback.json" \
      "$CLIENT_DIR/$user-xhttp.vless.txt" "$CLIENT_DIR/$user-xhttp.png" "$CLIENT_DIR/$user-xhttp.json" \
      "$CLIENT_DIR/$user-ws-tls.vless.txt" "$CLIENT_DIR/$user-ws-tls.png" "$CLIENT_DIR/$user-ws-tls.json"
    continue
  fi
  uuid="$(tr -d '\r\n' < "$uuid_file")"
  uri="vless://${uuid}@${CLIENT_HOST}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${REALITY_PASSWORD}&sid=${SHORT_ID}&spx=%2F&type=tcp&headerType=none#Gravitas-${user}"
  printf '%s\n' "$uri" > "$CLIENT_DIR/$user.vless.txt"
  qrencode -o "$CLIENT_DIR/$user.png" -s 7 -m 2 "$uri"

  fallback_uri="vless://${uuid}@${CLIENT_HOST}:${FALLBACK_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&fp=chrome&pbk=${REALITY_PASSWORD}&sid=${SHORT_ID}&spx=%2F&type=tcp&headerType=none#Gravitas-${user}-iran-fallback"
  printf '%s\n' "$fallback_uri" > "$CLIENT_DIR/$user-fallback.vless.txt"
  qrencode -o "$CLIENT_DIR/$user-fallback.png" -s 7 -m 2 "$fallback_uri"

  xhttp_path_encoded="$(printf '%s' "$XHTTP_PATH" | jq -sRr @uri)"
  xhttp_uri="vless://${uuid}@${CLIENT_HOST}:${XHTTP_PORT}?encryption=none&security=reality&sni=${XHTTP_SERVER_NAME}&fp=chrome&pbk=${REALITY_PASSWORD}&sid=${SHORT_ID}&spx=%2F&type=xhttp&mode=stream-one&path=${xhttp_path_encoded}#Gravitas-${user}-XHTTP"
  printf '%s\n' "$xhttp_uri" > "$CLIENT_DIR/$user-xhttp.vless.txt"
  qrencode -o "$CLIENT_DIR/$user-xhttp.png" -s 7 -m 2 "$xhttp_uri"

  tls_ws_path_encoded="$(printf '%s' "$TLS_WS_PATH" | jq -sRr @uri)"
  ws_tls_uri="vless://${uuid}@${TLS_DOMAIN}:${WS_TLS_PORT}?encryption=none&security=tls&sni=${TLS_DOMAIN}&type=ws&host=${TLS_DOMAIN}&path=${tls_ws_path_encoded}#Gravitas-${user}-WS-TLS"
  printf '%s\n' "$ws_tls_uri" > "$CLIENT_DIR/$user-ws-tls.vless.txt"
  qrencode -o "$CLIENT_DIR/$user-ws-tls.png" -s 7 -m 2 "$ws_tls_uri"

  jq -n \
    --arg host "$CLIENT_HOST" \
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
          realitySettings:{fingerprint:"chrome",serverName:$sni,publicKey:$password,shortId:$shortId,spiderX:"/"}
        }
      }]
    }' > "$CLIENT_DIR/$user.json"

  jq --argjson fallbackPort "$FALLBACK_PORT" --arg fallbackSni "$FALLBACK_SERVER_NAME" \
    '.outbounds[0].settings.port = $fallbackPort | .outbounds[0].streamSettings.realitySettings.serverName = $fallbackSni' \
    "$CLIENT_DIR/$user.json" > "$CLIENT_DIR/$user-fallback.json"

  jq -n \
    --arg host "$CLIENT_HOST" \
    --argjson port "$XHTTP_PORT" \
    --arg id "$uuid" \
    --arg sni "$XHTTP_SERVER_NAME" \
    --arg password "$REALITY_PASSWORD" \
    --arg shortId "$SHORT_ID" \
    --arg path "$XHTTP_PATH" \
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
        settings:{address:$host,port:$port,id:$id,encryption:"none"},
        streamSettings:{
          network:"xhttp",
          security:"reality",
          xhttpSettings:{mode:"stream-one",path:$path},
          realitySettings:{fingerprint:"chrome",serverName:$sni,publicKey:$password,shortId:$shortId,spiderX:"/"}
        }
      }]
    }' > "$CLIENT_DIR/$user-xhttp.json"

  jq -n \
    --arg host "$TLS_DOMAIN" \
    --argjson port "$WS_TLS_PORT" \
    --arg id "$uuid" \
    --arg sni "$TLS_DOMAIN" \
    --arg path "$TLS_WS_PATH" \
    '{
      log:{loglevel:"warning"},
      inbounds:[{
        listen:"127.0.0.1",
        port:10808,
        protocol:"socks",
        settings:{udp:true},
        sniffing:{enabled:true,destOverride:["http","tls"],routeOnly:true}
      }],
      outbounds:[{
        tag:"proxy",
        protocol:"vless",
        settings:{address:$host,port:$port,id:$id,encryption:"none"},
        streamSettings:{
          network:"ws",
          security:"tls",
          tlsSettings:{serverName:$sni,allowInsecure:false},
          wsSettings:{path:$path,headers:{Host:$sni}}
        }
      }]
    }' > "$CLIENT_DIR/$user-ws-tls.json"
done
chmod 600 "$CLIENT_DIR"/* 2>/dev/null || true

install -m 700 /opt/gravitas-vpn/scripts/manage_xray_user.sh /usr/local/sbin/gravitas-xray-user

printf 'Xray transports active: REALITY %s:%s, fallback %s, XHTTP %s, WS+TLS %s:%s.\n' "$CLIENT_HOST" "$PORT" "$FALLBACK_PORT" "$XHTTP_PORT" "$TLS_DOMAIN" "$WS_TLS_PORT"
printf 'Client material: %s\n' "$CLIENT_DIR"
