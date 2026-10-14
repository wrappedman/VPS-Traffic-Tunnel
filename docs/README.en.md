# VPS-Traffic-Tunnel (English)

A single Bash program for Ubuntu/Debian VPS boxes that are reachable **only over
SSH**. It installs an always-on **VLESS tunnel** and hands you a ready-to-use
client config.

```
  1) install      — install the tunnel and the always-on service
  2) viewConfig   — show the config, share link and QR code
  3) uninstall    — remove everything
```

> The program's UI is in Persian. This document is the English reference.

---

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/wrappedman/VPS-Traffic-Tunnel/main/bootstrap.sh | sudo bash
sudo vt
```

Manual:

```bash
git clone https://github.com/wrappedman/VPS-Traffic-Tunnel.git
cd VPS-Traffic-Tunnel
sudo ./vt self-install   # installs to /opt/vt and puts `vt` on PATH
sudo vt
```

---

## What gets installed

| Component | Where |
|---|---|
| Xray-core (latest release) | `/usr/local/bin/xray` |
| Xray config | `/usr/local/etc/xray/config.json` |
| systemd service (`Restart=always`, enabled at boot) | `/etc/systemd/system/xray.service` |
| Health-check timer (every 5 min, auto-restarts on failure) | `vt-health.timer` |
| Certificate renewal timer (every 12 h) | `vt-cert-renew.timer` |
| TLS certificate | `/etc/vt/certs/` |
| State, user list, text config | `/etc/vt/` (mode `0700`) |
| BBR + TCP tuning | `/etc/sysctl.d/99-vt-tunnel.conf` |
| Swap (only when RAM < 2 GB) | `/swapfile.vt` |
| UFW rules for SSH + the tunnel port | `ufw` |
| Log rotation | `/etc/logrotate.d/vt-tunnel` |

---

## Tunnel modes

| Mode | Transport | Certificate | Best for |
|---|---|---|---|
| `reality` | VLESS + TCP + REALITY (XTLS Vision) | **none** | Bare IP, no domain. Handshake is camouflaged as a TLS session with a real website. |
| `ws-tls` | VLESS + WebSocket + TLS on 443 | required | Looking exactly like an ordinary HTTPS site. |
| `tcp-tls` | VLESS + TCP + TLS on a custom port | required | Direct TLS without WebSocket framing. |

---

## Free TLS with automatic renewal

**With a domain** — Let's Encrypt, 90-day certificate, renewed by acme.sh.
Three validation methods:

* `standalone` — acme.sh briefly binds port 80. Port 80 must be free and open.
* `webroot` — writes the challenge into a running web server's docroot.
* `dns` — validates through a DNS provider API (e.g. `dns_cf` with a
  Cloudflare token). Works even when the domain does not point at the server
  yet and needs no open port.

**Without a domain** — Let's Encrypt **IP address certificates**, generally
available since 2026-01-15. They require the ACME `shortlived` profile
(160-hour validity) and `http-01` validation, so port 80 must be reachable.
The program requests them with `--cert-profile shortlived --days 3` and
renews automatically. The result is a genuinely trusted certificate on a bare
IP — no `allowInsecure` on the client.

**Fallback** — a self-signed certificate (OpenSSL ECDSA P-256, 825 days),
regenerated automatically at half its lifetime by `vt-cert-renew.timer`.
Clients must enable `allowInsecure`; the program sets that flag for you.

---

## Routing *all* traffic through the VPS

Server side, the default outbound is `freedom`, so everything that arrives
through the tunnel leaves from the VPS. Client side, enable the "all traffic"
mode of your app:

| Platform | Setting |
|---|---|
| Android | v2rayNG / Happ / Streisand → **TUN** or **Global** routing |
| iOS / macOS | Streisand / V2Box / Shadowrocket → **Set as system proxy** or **Global** |
| Windows | v2rayN → routing **Global** + **Set system proxy** |
| Linux desktop | run `/etc/vt/client.json` with `xray run -c client.json`, then point the system proxy at `127.0.0.1:10808` (SOCKS) or `10809` (HTTP) |

---

## Commands

```
vt install [--mode reality|ws-tls|tcp-tls] [--domain D] [--cert ...] [--yes]
vt viewconfig | config
vt uninstall [--purge] [--yes]

vt add-user [name] | rm-user [name] | users | stats | connections
vt rotate-uuid [name] | rotate-keys | port <n|random> | switch-mode | update

vt status | restart | stop | start
vt logs [xray|error|health|cert|install|follow]
vt doctor | health | renew-cert | selfsigned-cert
vt backup [dir] | restore <file> | self-install
```

Fully non-interactive example:

```bash
sudo vt install --mode ws-tls --domain tunnel.example.com \
     --cert letsencrypt-domain --acme standalone --port 443 --yes
```

---

## Layout

```
/etc/vt/                     state, users, certificates, text config  (0700)
├── vt.env                   install state (mode, port, keys, ...)
├── users.json               user list
├── certs/                   fullchain.pem, privkey.pem
├── acme.sh + acme/          ACME client and account
├── config.txt               human-readable config
└── client.json              ready-to-run desktop client config

/usr/local/etc/xray/config.json
/usr/local/bin/xray
/usr/local/share/xray/       geoip.dat / geosite.dat (optional)
/var/log/vt/                 install, health, cert and Xray error logs
```

---

## Security properties

* The Xray stats/handler API listens on `127.0.0.1` only.
* Private ranges (`10/8`, `172.16/12`, `192.168/16`, `127/8`, `100.64/10`,
  `169.254/16`, `fc00::/7`, `fe80::/10`) are blackholed on the outbound side so
  the tunnel cannot be used to scan the data centre's internal network.
* `/etc/vt` is `0700`, the private key is `0600`.
* `rejectUnknownSni` is on for TLS modes (automatically off for IP
  certificates, because clients send no SNI for a bare IP).
* The SSH port is read from the live `$SSH_CONNECTION` and confirmed with you
  before UFW is enabled.
* WebSocket paths and REALITY short IDs are random.

---

## Tests

```bash
./tests/run_tests.sh
```

Six stages: syntax check, ShellCheck, unit tests, **full dry-run installs for
all four mode/certificate combinations** inside a throwaway `VT_ROOT`, Xray
config schema validation, and uninstall. The dry-run works because every path
in the program goes through one prefixing function, so the real install flow
executes end to end without touching the host.

---

## License

GPL-3.0 — see [LICENSE](../LICENSE).
