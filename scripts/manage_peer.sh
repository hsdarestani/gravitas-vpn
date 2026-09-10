#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

STATE_DIR="/etc/wireguard/gravitas"
PEER_DIR="${STATE_DIR}/peers"
CLIENT_DIR="/root/gravitas-vpn/clients"
SETUP_SCRIPT="/opt/gravitas-vpn/scripts/setup_wireguard.sh"
WG_PREFIX="10.77.0"

usage() {
  cat <<'EOF'
Usage:
  gravitas-vpn-peer list
  gravitas-vpn-peer add <name>
  gravitas-vpn-peer revoke <name>
  gravitas-vpn-peer show <name>
  gravitas-vpn-peer qr <name>
EOF
}

validate_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || {
    echo "Invalid peer name. Use lowercase letters, numbers, _ or - only." >&2
    exit 1
  }
}

rerender() {
  local endpoint
  endpoint="$(cat "${STATE_DIR}/endpoint")"
  "${SETUP_SCRIPT}" "${endpoint}"
}

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

cmd="${1:-}"
name="${2:-}"

case "${cmd}" in
  list)
    printf '%-20s %-18s %s\n' "NAME" "ADDRESS" "STATUS"
    printf '%-20s %-18s %s\n' "----" "-------" "------"
    while IFS= read -r dir; do
      peer="$(basename "${dir}")"
      address="$(cat "${dir}/address" 2>/dev/null || echo '-')"
      status="active"
      [[ -f "${dir}/revoked" ]] && status="revoked"
      printf '%-20s %-18s %s\n' "${peer}" "${address}" "${status}"
    done < <(find "${PEER_DIR}" -mindepth 1 -maxdepth 1 -type d | sort)
    ;;

  add)
    [[ -n "${name}" ]] || { usage; exit 1; }
    validate_name "${name}"
    dir="${PEER_DIR}/${name}"
    if [[ -d "${dir}" && ! -f "${dir}/revoked" ]]; then
      echo "Peer '${name}' already exists and is active." >&2
      exit 1
    fi

    mkdir -p "${dir}"
    chmod 700 "${dir}"
    rm -f "${dir}/revoked"
    umask 077
    wg genkey >"${dir}/private.key"
    wg pubkey <"${dir}/private.key" >"${dir}/public.key"
    wg genpsk >"${dir}/preshared.key"
    if [[ ! -s "${dir}/address" ]]; then
      octet="$(next_free_octet)" || { echo "No free client addresses." >&2; exit 1; }
      printf '%s\n' "${WG_PREFIX}.${octet}/32" >"${dir}/address"
    fi
    rerender >/dev/null
    echo "Added '${name}'. Config: ${CLIENT_DIR}/${name}.conf"
    ;;

  revoke)
    [[ -n "${name}" ]] || { usage; exit 1; }
    validate_name "${name}"
    dir="${PEER_DIR}/${name}"
    [[ -d "${dir}" ]] || { echo "Unknown peer '${name}'." >&2; exit 1; }
    touch "${dir}/revoked"
    chmod 600 "${dir}/revoked"
    rm -f "${CLIENT_DIR}/${name}.conf"
    rerender >/dev/null
    echo "Revoked '${name}'."
    ;;

  show)
    [[ -n "${name}" ]] || { usage; exit 1; }
    validate_name "${name}"
    file="${CLIENT_DIR}/${name}.conf"
    [[ -f "${file}" ]] || { echo "No active config for '${name}'." >&2; exit 1; }
    cat "${file}"
    ;;

  qr)
    [[ -n "${name}" ]] || { usage; exit 1; }
    validate_name "${name}"
    file="${CLIENT_DIR}/${name}.conf"
    [[ -f "${file}" ]] || { echo "No active config for '${name}'." >&2; exit 1; }
    qrencode -t ansiutf8 <"${file}"
    ;;

  *)
    usage
    exit 1
    ;;
esac
