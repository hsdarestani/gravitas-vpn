# Gravitas Team VPN

Primary team proxy infrastructure for Gravitas, based on **Xray VLESS + REALITY**. The previous WireGuard installation is intentionally left untouched as a fallback.

## Why this setup

- Works with common V2Ray clients such as v2rayN and v2rayNG.
- No domain or TLS certificate is required because REALITY is used.
- Each team member has a separate VLESS UUID and can be revoked independently.
- Client secrets are generated on the VPN server and are not committed to GitHub.
- The deploy script automatically selects the first free preferred TCP port: `443`, `8443`, `2053`, `2083`, then `9443`.

## Required GitHub Actions secrets

- `HOST` — VPN server IPv4 address or hostname
- `PASS` — root SSH password

## Default users

- `hossein`
- `kiarash`
- `ahmad`
- `ehsan`

## Xray server paths

- Xray config: `/usr/local/etc/xray/config.json`
- Xray state: `/etc/gravitas-xray/`
- Client share links and QR images: `/root/gravitas-vpn/xray-clients/`
- User management command: `/usr/local/sbin/gravitas-xray-user`

For every active member the server creates:

- `<name>.vless.txt` — one-click VLESS import link
- `<name>.png` — QR code for mobile clients
- `<name>.json` — native Xray client config

## Client usage

### Android — v2rayNG

1. Install/open v2rayNG.
2. Use `Import config from Clipboard` after copying the member's `.vless.txt` link, or scan the member's QR code.
3. Select the imported `Gravitas-<name>` profile.
4. Connect.

### Windows — v2rayN

1. Install/open v2rayN.
2. Copy the member's `.vless.txt` link.
3. Use `Import share links from clipboard`.
4. Select the imported `Gravitas-<name>` profile and enable the system proxy/TUN mode as desired.

## Retrieve a client securely

Copy files directly over SSH/SCP from an authorized machine, for example:

```bash
scp root@YOUR_SERVER:/root/gravitas-vpn/xray-clients/kiarash.vless.txt .
scp root@YOUR_SERVER:/root/gravitas-vpn/xray-clients/kiarash.png .
```

To print a member's link or terminal QR while logged into the server:

```bash
gravitas-xray-user show kiarash
gravitas-xray-user qr kiarash
```

## User management

```bash
gravitas-xray-user list
gravitas-xray-user add new-member
gravitas-xray-user revoke new-member
gravitas-xray-user show new-member
gravitas-xray-user qr new-member
```

Revoking a user disables that UUID and removes its generated share files. Re-adding the same name re-enables its existing UUID unless the state file itself is deleted.

## WireGuard fallback

The earlier WireGuard service/config remains on the server as a fallback and is not removed by the Xray deployment.
