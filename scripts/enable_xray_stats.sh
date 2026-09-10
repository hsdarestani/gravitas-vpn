#!/usr/bin/env bash
set -euo pipefail

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="${XRAY_BIN:-/usr/local/bin/xray}"
API_LISTEN="127.0.0.1:10085"

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ -s "$XRAY_CONFIG" ]] || { echo "Missing Xray config: $XRAY_CONFIG" >&2; exit 1; }
[[ -x "$XRAY_BIN" ]] || { echo "Missing Xray binary: $XRAY_BIN" >&2; exit 1; }
command -v jq >/dev/null || { echo 'jq is required.' >&2; exit 1; }

cp -a "$XRAY_CONFIG" "${XRAY_CONFIG}.pre-stats.bak"

jq '
  .stats = {} |
  .policy = ((.policy // {}) * {
    levels: (((.policy // {}).levels // {}) * {
      "0": ((((.policy // {}).levels // {})["0"] // {}) * {
        statsUserUplink: true,
        statsUserDownlink: true
      })
    }),
    system: (((.policy // {}).system // {}) * {
      statsInboundUplink: true,
      statsInboundDownlink: true,
      statsOutboundUplink: true,
      statsOutboundDownlink: true
    })
  }) |
  .api = {
    tag: "api",
    listen: "127.0.0.1:10085",
    services: ["StatsService"]
  }
' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp"

install -m 644 "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
rm -f "${XRAY_CONFIG}.tmp"

"$XRAY_BIN" run -test -config "$XRAY_CONFIG"
systemctl restart xray
systemctl is-active --quiet xray

for _ in {1..20}; do
  if "$XRAY_BIN" api statsquery --server="$API_LISTEN" -pattern 'user>>>' >/dev/null 2>&1; then
    echo "Xray StatsService active on $API_LISTEN"
    exit 0
  fi
  sleep 0.5
done

echo 'Xray is active but StatsService did not become reachable.' >&2
exit 1
