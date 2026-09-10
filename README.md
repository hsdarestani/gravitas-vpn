# Gravitas Team VPN

Private team VPN infrastructure for Gravitas, based on WireGuard.

## Security model

- Client private keys are generated **on the VPN server**.
- Client configs are stored only under `/root/gravitas-vpn/clients/` with restrictive permissions.
- No WireGuard private keys or client configs are committed to GitHub.
- Each team member gets a separate peer, so access can be revoked independently.

> Important: keep this repository private before using GitHub Actions artifacts or any workflow that exports client configs. The current deployment workflow intentionally does **not** upload configs as artifacts.

## Required GitHub Actions secrets

- `HOST` — VPN server IPv4 address or hostname
- `PASS` — root SSH password

## Default peers

- `hossein`
- `kiarash`
- `ahmad`
- `ehsan`

## Server paths

- WireGuard interface: `wg0`
- Server config: `/etc/wireguard/wg0.conf`
- State: `/etc/wireguard/gravitas/`
- Client configs: `/root/gravitas-vpn/clients/`
- Management command: `/usr/local/sbin/gravitas-vpn-peer`

## Retrieve a client config securely

From an authorized machine, copy a config directly over SSH/SCP. Example:

```bash
scp root@YOUR_SERVER:/root/gravitas-vpn/clients/hossein.conf .
```

To show a QR code while logged in to the server:

```bash
qrencode -t ansiutf8 < /root/gravitas-vpn/clients/hossein.conf
```

## Peer management

```bash
sudo gravitas-vpn-peer list
sudo gravitas-vpn-peer add new-member
sudo gravitas-vpn-peer revoke new-member
sudo gravitas-vpn-peer show new-member
```

`show` prints a sensitive client configuration. Only use it in a trusted SSH session.
