#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/etc/gravitas-xray"
USER_DIR="$STATE_DIR/users"
CLIENT_DIR="/root/gravitas-vpn/xray-clients"
SETUP="/opt/gravitas-vpn/scripts/setup_xray.sh"
XRAY_BIN="$(command -v xray || echo /usr/local/bin/xray)"

usage() {
  cat <<'EOF'
Usage:
  gravitas-xray-user list
  gravitas-xray-user add <name>
  gravitas-xray-user revoke <name>
  gravitas-xray-user show <name>
  gravitas-xray-user qr <name>
EOF
}

validate_name() {
  [[ "$1" =~ ^[a-zA-Z0-9._-]{1,40}$ ]] || {
    echo "Invalid user name." >&2
    exit 1
  }
}

rerender() {
  [[ -s "$STATE_DIR/host" ]] || { echo "Missing saved host." >&2; exit 1; }
  "$SETUP" "$(cat "$STATE_DIR/host")" >/dev/null
}

cmd="${1:-}"
case "$cmd" in
  list)
    printf '%-24s %s\n' USER STATUS
    shopt -s nullglob
    names=()
    for f in "$USER_DIR"/*.uuid "$USER_DIR"/*.disabled; do
      n="$(basename "$f")"
      n="${n%.uuid}"
      n="${n%.disabled}"
      names+=("$n")
    done
    if [[ ${#names[@]} -eq 0 ]]; then exit 0; fi
    printf '%s\n' "${names[@]}" | sort -u | while read -r n; do
      if [[ -e "$USER_DIR/$n.disabled" ]]; then s="revoked"; else s="active"; fi
      printf '%-24s %s\n' "$n" "$s"
    done
    ;;
  add)
    name="${2:-}"; [[ -n "$name" ]] || { usage; exit 1; }; validate_name "$name"
    mkdir -p "$USER_DIR"
    if [[ ! -s "$USER_DIR/$name.uuid" ]]; then
      "$XRAY_BIN" uuid > "$USER_DIR/$name.uuid"
      chmod 600 "$USER_DIR/$name.uuid"
    fi
    rm -f "$USER_DIR/$name.disabled"
    rerender
    echo "Enabled: $name"
    echo "Share link: $CLIENT_DIR/$name.vless.txt"
    echo "QR image:   $CLIENT_DIR/$name.png"
    ;;
  revoke)
    name="${2:-}"; [[ -n "$name" ]] || { usage; exit 1; }; validate_name "$name"
    [[ -e "$USER_DIR/$name.uuid" || -e "$USER_DIR/$name.disabled" ]] || { echo "Unknown user: $name" >&2; exit 1; }
    touch "$USER_DIR/$name.disabled"
    chmod 600 "$USER_DIR/$name.disabled"
    rm -f "$CLIENT_DIR/$name.vless.txt" "$CLIENT_DIR/$name.png" "$CLIENT_DIR/$name.json"
    rerender
    echo "Revoked: $name"
    ;;
  show)
    name="${2:-}"; [[ -n "$name" ]] || { usage; exit 1; }; validate_name "$name"
    [[ ! -e "$USER_DIR/$name.disabled" ]] || { echo "User is revoked." >&2; exit 1; }
    cat "$CLIENT_DIR/$name.vless.txt"
    ;;
  qr)
    name="${2:-}"; [[ -n "$name" ]] || { usage; exit 1; }; validate_name "$name"
    [[ ! -e "$USER_DIR/$name.disabled" ]] || { echo "User is revoked." >&2; exit 1; }
    qrencode -t ansiutf8 < "$CLIENT_DIR/$name.vless.txt"
    ;;
  *)
    usage
    exit 1
    ;;
esac
