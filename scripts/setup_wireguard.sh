#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must run as root." >&2
  exit 1
fi

ENDPOINT="${1:-}"
if [[ -z "${ENDPOINT}" ]]; then
  echo "Usage: $0 <public-ip-or-hostname>" >&2
  exit 1
fi

WG_IF="wg0"
WG_PORT="51820"
WG_ADDR="10.77.0.1/24"
WG_PREFIX="10.77.0"
WG_DIR="/etc/wireguard"
STATE_DIR="${WG_DIR}/gravitas"
PEER_DIR="${STATE_DIR}/peers"
CLIENT_DIR="/root/gravitas-vpn/clients"
DEFAULT_PEERS=(hossein kiarash ahmad ehsan)

export DEBIAN_FRONTEND=noninteractive

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y wireguard wireguard-tools qrencode iptables curl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wireguard-tools qrencode iptables curl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y wireguard-tools qrencode iptables curl
  else
    echo "Unsupported package manager. Install WireGuard manually." >&2
    exit 1
  fi
}

install_packages

mkdir -p "${WG_DIR}" "${STATE_DIR}" "${PEER_DIR}" "${CLIENT_DIR}"
chmod 700 "${WG_DIR}" "${STATE_DIR}" "${PEER_DIR}" "${CLIENT_DIR}"

cat >/etc/sysctl.d/99-gravitas-wireguard.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

WAN_IF="$(ip route show default | awk '/default/ {print $5; exit}')"
if [[ -z "${WAN_IF}" ]]; then
  echo "Could not determine the server's default network interface." >&2
  exit 1
fi

umask 077
if [[ ! -s "${STATE_DIR}/server_private.key" ]]; then
  wg genkey >"${STATE_DIR}/server_private.key"
  wg pubkey <"${STATE_DIR}/server_private.key" >"${STATE_DIR}/server_public.key"
fi

SERVER_PRIVATE="$(cat "${STATE_DIR}/server_private.key")"
SERVER_PUBLIC="$(cat "${STATE_DIR}/server_public.key")"
printf '%s\n' "${ENDPOINT}" >"${STATE_DIR}/endpoint"

next_free_octet() {
  local n used
  for n in $(seq 2 254); do
    used=0
    while IFS= read -r address_file; do
      [[ -f "${address_file}" ]] || continue
      if [[ "$(cat "${address_file}")" == "${WG_PREFIX}.${n}/32" ]]; then
        used=1
        break
      fi
    done < <(find "${PEER_DIR}" -mindepth 2 -maxdepth 2 -name address -type f 2>/dev/null || true)
    if [[ "${used}" -eq 0 ]]; then
      echo "${n}"
      return 0
    fi
  done
  return 1
}

ensure_peer() {
  local name="$1"
  local dir="${PEER_DIR}/${name}"
  mkdir -p "${dir}"
  chmod 700 "${dir}"

  if [[ ! -s "${dir}/private.key" ]]; then
    wg genkey >"${dir}/private.key"
    wg pubkey <"${dir}/private.key" >"${dir}/public.key"
    wg genpsk >"${dir}/preshared.key"
  fi

  if [[ ! -s "${dir}/address" ]]; then
    local octet
    octet="$(next_free_octet)" || {
      echo "No free WireGuard client addresses remain." >&2
      exit 1
    }
    printf '%s\n' "${WG_PREFIX}.${octet}/32" >"${dir}/address"
  fi
}

for peer in "${DEFAULT_PEERS[@]}"; do
  ensure_peer "${peer}"
done

write_server_config() {
  local tmp
  tmp="$(mktemp)"
  chmod 600 "${tmp}"

  cat >"${tmp}" <<EOF
[Interface]
Address = ${WG_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE}
SaveConfig = false
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WAN_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN_IF} -j MASQUERADE
EOF

  while IFS= read -r dir; do
    [[ -f "${dir}/revoked" ]] && continue
    local name pub psk addr
    name="$(basename "${dir}")"
    pub="$(cat "${dir}/public.key")"
    psk="$(cat "${dir}/preshared.key")"
    addr="$(cat "${dir}/address")"
    cat >>"${tmp}" <<EOF

# ${name}
[Peer]
PublicKey = ${pub}
PresharedKey = ${psk}
AllowedIPs = ${addr}
EOF
  done < <(find "${PEER_DIR}" -mindepth 1 -maxdepth 1 -type d | sort)

  install -m 600 "${tmp}" "${WG_DIR}/${WG_IF}.conf"
  rm -f "${tmp}"
}

write_client_configs() {
  while IFS= read -r dir; do
    local name private psk addr client_ip
    name="$(basename "${dir}")"
    if [[ -f "${dir}/revoked" ]]; then
      rm -f "${CLIENT_DIR}/${name}.conf"
      continue
    fi
    private="$(cat "${dir}/private.key")"
    psk="$(cat "${dir}/preshared.key")"
    addr="$(cat "${dir}/address")"
    client_ip="${addr%/32}/32"
    cat >"${CLIENT_DIR}/${name}.conf" <<EOF
[Interface]
PrivateKey = ${private}
Address = ${client_ip}
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${SERVER_PUBLIC}
PresharedKey = ${psk}
Endpoint = ${ENDPOINT}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 600 "${CLIENT_DIR}/${name}.conf"
  done < <(find "${PEER_DIR}" -mindepth 1 -maxdepth 1 -type d | sort)
}

write_server_config
write_client_configs

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow "${WG_PORT}/udp" >/dev/null
fi

if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${WG_PORT}/udp" >/dev/null
  firewall-cmd --reload >/dev/null
fi

systemctl enable wg-quick@"${WG_IF}" >/dev/null
if systemctl is-active --quiet wg-quick@"${WG_IF}"; then
  systemctl restart wg-quick@"${WG_IF}"
else
  systemctl start wg-quick@"${WG_IF}"
fi

install -m 755 "$(dirname "$0")/manage_peer.sh" /usr/local/sbin/gravitas-vpn-peer

printf '\nGravitas VPN is configured.\n'
printf 'Interface: %s\n' "${WG_IF}"
printf 'Endpoint: %s:%s/udp\n' "${ENDPOINT}" "${WG_PORT}"
printf 'Client configs: %s\n\n' "${CLIENT_DIR}"
wg show "${WG_IF}"
