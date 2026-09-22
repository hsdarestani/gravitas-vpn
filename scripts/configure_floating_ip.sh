#!/usr/bin/env bash
set -euo pipefail

FLOATING_IP="${1:-}"
STATE_DIR="/etc/gravitas-xray"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ -n "$FLOATING_IP" ]] || { echo "Usage: configure_floating_ip.sh <ipv4>" >&2; exit 1; }
[[ "$FLOATING_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "Invalid IPv4 address." >&2; exit 1; }

IFS=. read -r a b c d <<<"$FLOATING_IP"
for octet in "$a" "$b" "$c" "$d"; do
  (( octet >= 0 && octet <= 255 )) || { echo "Invalid IPv4 address." >&2; exit 1; }
done

IFACE="$(ip -4 route show default | awk '/^default/ {print $5; exit}')"
[[ -n "$IFACE" ]] || { echo "Could not detect the primary IPv4 interface." >&2; exit 1; }

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
printf '%s\n' "$FLOATING_IP" > "$STATE_DIR/egress-ip"
printf '%s\n' "$IFACE" > "$STATE_DIR/egress-interface"
chmod 600 "$STATE_DIR/egress-ip" "$STATE_DIR/egress-interface"

# Apply immediately without restarting the primary network connection.
ip address replace "$FLOATING_IP/32" dev "$IFACE"

# Older Gravitas WireGuard setup installed a broad MASQUERADE rule that rewrote
# every outbound source IP to the server primary address. Remove only that exact
# legacy rule, keep WireGuard NAT scoped to its own client subnet, and patch the
# persistent wg0 config so a later WireGuard restart cannot bring it back.
if command -v iptables >/dev/null 2>&1; then
  while iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -o "$IFACE" -j MASQUERADE
  done

  if ip link show wg0 >/dev/null 2>&1; then
    if ! iptables -t nat -C POSTROUTING -s 10.77.0.0/24 -o "$IFACE" -j MASQUERADE 2>/dev/null; then
      iptables -t nat -A POSTROUTING -s 10.77.0.0/24 -o "$IFACE" -j MASQUERADE
    fi
  fi
fi

if [[ -f /etc/wireguard/wg0.conf ]]; then
  sed -i \
    -e "s|iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE|iptables -t nat -A POSTROUTING -s 10.77.0.0/24 -o $IFACE -j MASQUERADE|g" \
    -e "s|iptables -t nat -D POSTROUTING -o $IFACE -j MASQUERADE|iptables -t nat -D POSTROUTING -s 10.77.0.0/24 -o $IFACE -j MASQUERADE|g" \
    /etc/wireguard/wg0.conf
fi

cat > /usr/local/sbin/gravitas-floating-ip <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IP="$(cat /etc/gravitas-xray/egress-ip)"
IFACE="$(cat /etc/gravitas-xray/egress-interface)"
exec /usr/sbin/ip address replace "$IP/32" dev "$IFACE"
EOF
chmod 700 /usr/local/sbin/gravitas-floating-ip

cat > /etc/systemd/system/gravitas-floating-ip.service <<'EOF'
[Unit]
Description=Configure Gravitas Hetzner Floating IPv4
Wants=network-online.target
After=network-online.target
Before=xray.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gravitas-floating-ip
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now gravitas-floating-ip.service >/dev/null
systemctl is-active --quiet gravitas-floating-ip.service

ip -4 addr show dev "$IFACE" | grep -F "$FLOATING_IP/32" >/dev/null

# Verify that Hetzner routing accepts the floating IP as the real source address.
EGRESS="$(curl --interface "$FLOATING_IP" -4 -fsS --max-time 20 https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p' | head -n1)"
[[ "$EGRESS" == "$FLOATING_IP" ]] || {
  echo "Floating IP is configured locally but internet egress is '$EGRESS', expected '$FLOATING_IP'." >&2
  exit 1
}

echo "Floating IPv4 $FLOATING_IP is active on $IFACE and verified for outbound traffic."
