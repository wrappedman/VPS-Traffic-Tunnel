# VPS-Traffic-Tunnel

A single Bash program for Ubuntu/Debian VPS boxes that you reach **only over SSH — no GUI**. It installs an **always-on VLESS tunnel** and hands you a ready-to-use client config in a few minutes.

After you run it you get a simple menu:

```
  1) install      - install the tunnel and the always-on service
  2) viewConfig   - show the config, share link and QR code
  3) uninstall    - remove everything
```

`install` asks whether you have a domain, picks a random port, gets a free
SSL certificate with **automatic renewal**, creates a systemd service that
comes back on every reboot, and finally prints the config plus a QR code.

---

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/wrappedman/VPS-Traffic-Tunnel/main/bootstrap.sh | sudo bash
sudo vt
```

Or manually:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/wrappedman/VPS-Traffic-Tunnel.git
cd VPS-Traffic-Tunnel
sudo ./vt self-install     # puts the program in /opt/vt and `vt` on PATH
sudo vt
```

---

## What gets installed

| Component | Details |
|---|---|
| **Xray-core** | latest release from GitHub, at `/usr/local/bin/xray` |
| **systemd service** | `xray.service` with `Restart=always` and `WantedBy=multi-user.target` → always on, even after a reboot |
| **VLESS config** | `/usr/local/etc/xray/config.json` with a random port |
| **SSL certificate** | Let's Encrypt (domain or IP) or self-signed — all free, all auto-renewing |
| **Health timer** | checks the service and the port every 5 minutes and restarts on failure |
| **Cert renewal timer** | every 12 hours (plus acme.sh's own cron job) |
| **BBR + TCP tuning** | `/etc/sysctl.d/99-vt-tunnel.conf` |
| **Swap** | only when the box has less than 2 GB of RAM |
| **UFW firewall** | only the SSH port and the tunnel port stay open |
| **logrotate** | logs are rotated automatically |
| **The program itself** | copied to `/opt/vt` at the end of the install, with `vt` on PATH (the timers need that path) |

---

## Three tunnel modes

### 1) REALITY — recommended
```
VLESS + TCP + REALITY (XTLS Vision)
```
* Works on a bare IP with **no domain and no certificate**.
* Your traffic is hidden inside a real TLS handshake with a well-known site
  (e.g. `www.microsoft.com`), so from the outside it looks like an ordinary
  HTTPS connection to that site.
* The best choice when you have no domain.

### 2) WebSocket + TLS (port 443)
```
VLESS + WebSocket + TLS
```
* Closest to an ordinary HTTPS website.
* The WebSocket path is a random 32-character string (`/a3f9…/`).
* Needs a TLS certificate.

### 3) TCP + TLS (custom port)
```
VLESS + TCP + TLS (XTLS Vision)
```
* Like mode 1 but with real TLS instead of REALITY.
* Needs a TLS certificate.

---

## Free SSL with automatic renewal

There are three routes and the installer suggests the right one:

### a) You have a domain → Let's Encrypt
A trusted 90-day certificate, renewed automatically by acme.sh. Three
validation methods:

| Method | When to use it |
|---|---|
| **standalone** | simplest. The script binds port 80 briefly. Port 80 must be free and open. |
| **webroot** | when a web server (nginx/apache) is already listening on port 80. |
| **DNS API** | when the domain does not point at the server yet, or port 80 is closed. Works with a Cloudflare token (`dns_cf`) and any other acme.sh plugin. |

### b) No domain → Let's Encrypt certificate for the IP address
Since **15 January 2026** Let's Encrypt issues trusted certificates for IP
addresses. The conditions:

* the ACME `shortlived` profile — the certificate is valid for **160 hours**
  (a little over six days);
* only `http-01` or `tls-alpn-01`, i.e. **port 80 must be reachable**;
* the program requests it with `--cert-profile shortlived --days 3` and
  renews it automatically.

Result: a genuinely trusted certificate on a bare IP, with no `allowInsecure`.

### c) Self-signed
If you have no domain and do not want to open port 80:

* generated with OpenSSL (ECDSA P-256, valid 825 days);
* a systemd timer checks it every 12 hours and regenerates it at half its
  lifetime;
* **note:** clients must enable `allowInsecure` — the program puts that flag
  into the config and the share link for you.

---

## Routing *all* of your traffic through the VPS

On the server side, everything that arrives through the tunnel leaves from the
VPS (the default outbound is `freedom`). On the client side you have to turn on
the "all traffic" mode:

| Platform | What to do |
|---|---|
| **Android** | v2rayNG / Happ / Streisand → add the link → enable **TUN** or **Global** routing |
| **iOS/macOS** | Streisand / V2Box / Shadowrocket → **Set as system proxy** or **Global Routing** |
| **Windows** | v2rayN → Import from clipboard → set routing to **Global** and press **Set system proxy** |
| **Linux desktop** | run `/etc/vt/client.json` with `xray run -c client.json`, then point the system proxy at `127.0.0.1:10808` (SOCKS) or `10809` (HTTP) |

---

## Command reference

```bash
sudo vt                       # interactive menu
```

### Main
| Command | What it does |
|---|---|
| `vt install` | install (interactive) |
| `vt viewconfig` | show the config, share link and QR code |
| `vt uninstall [--purge]` | remove everything (`--purge` also deletes `/etc/vt`) |

### Unattended install
```bash
# REALITY on the IP with a random port
sudo vt install --mode reality --port random --email main --yes

# WebSocket+TLS with a domain and a Let's Encrypt certificate
sudo vt install --mode ws-tls --domain tunnel.example.com \
     --cert letsencrypt-domain --acme standalone --port 443 --yes

# Let's Encrypt certificate for the IP address
sudo vt install --mode tcp-tls --cert letsencrypt-ip --port random --yes

# A domain whose DNS is not set up yet, using a Cloudflare token
sudo vt install --mode ws-tls --domain tunnel.example.com \
     --cert letsencrypt-domain --acme dns \
     --dns-plugin dns_cf --dns-token "YOUR_CF_TOKEN" --yes
```

Options: `--mode --domain --cert --acme --webroot --dns-plugin --dns-env --dns-token --sni --port --email --email-acme --firewall --adblock --no-torrent --force --yes`

### User management
```bash
sudo vt add-user [name]     # new user + share link + QR
sudo vt rm-user [name]
sudo vt users               # list users and their links
sudo vt stats               # traffic per user
sudo vt connections         # established connections
sudo vt rotate-uuid [name]  # rotate a UUID
sudo vt rotate-keys         # rotate the REALITY keypair (invalidates all clients)
```

### Service and maintenance
```bash
sudo vt status
sudo vt restart | stop | start
sudo vt logs [xray|error|health|cert|install|follow]
sudo vt doctor              # automated diagnostics
sudo vt health              # exactly what the health timer runs
sudo vt update              # update Xray-core
sudo vt renew-cert          # renew the certificate manually
sudo vt selfsigned-cert     # create a fresh self-signed certificate
sudo vt port <n|random>     # change the port
sudo vt switch-mode         # change the tunnel mode
sudo vt backup [dir]        # create a backup
sudo vt restore <file>      # restore
```

---

## File layout

```
/etc/vt/                     state, users, certificates, text config   (0700)
├── vt.env                   install state (MODE, PORT, keys, ...)
├── users.json               user list
├── certs/                   fullchain.pem and privkey.pem
├── acme.sh + acme/          ACME client and account
├── config.txt               human-readable config
└── client.json              ready-to-run desktop client config

/usr/local/etc/xray/config.json      Xray configuration
/usr/local/bin/xray                  Xray binary
/usr/local/share/xray/               geoip.dat / geosite.dat (optional)
/var/log/vt/                         install, health, cert and Xray error logs

/etc/systemd/system/xray.service
/etc/systemd/system/vt-health.{service,timer}
/etc/systemd/system/vt-cert-renew.{service,timer}
/etc/sysctl.d/99-vt-tunnel.conf
/etc/logrotate.d/vt-tunnel
```

---

## Security properties

* The Xray stats/handler API listens on `127.0.0.1` only.
* Private ranges (`10/8`, `172.16/12`, `192.168/16`, `127/8`, `100.64/10`,
  `169.254/16`, `fc00::/7`, `fe80::/10`) are blackholed on the outbound side, so
  the tunnel cannot be used to scan the data centre's internal network.
* `/etc/vt` is `0700` and the private key is `0600`.
* `rejectUnknownSni` is on for TLS modes so unidentified probes are dropped
  (automatically off for IP certificates, because clients send no SNI for a
  bare IP).
* The SSH port is read from the live `$SSH_CONNECTION` and confirmed with you
  before UFW is enabled.
* WebSocket paths and REALITY short IDs are random.

---

## Tests

```bash
./tests/run_tests.sh
```

Six stages: syntax check, ShellCheck, unit tests, **full dry-run installs for
all four mode/certificate combinations** inside a throwaway root, Xray config
schema validation, and uninstall.

The dry-run works through the `VT_ROOT` variable: every path is prefixed, so
the real install flow executes end to end without touching the host.

```
PASS: 167   FAIL: 0
```

---

## Quick troubleshooting

| Problem | What to do |
|---|---|
| cannot connect | `sudo vt doctor`, then check the cloud provider's firewall |
| port is open but nothing connects | in REALITY mode, change the camouflage site (`--sni`) |
| `certificate has expired` | `sudo vt renew-cert`, then `sudo vt logs cert` |
| the service will not start | `sudo vt logs error` |
| slow | `sysctl net.ipv4.tcp_congestion_control` should say `bbr` |

More: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)

---

## License

GPL-3.0 — see [LICENSE](LICENSE).

A Persian translation of this document lives at [`docs/README.fa.md`](docs/README.fa.md).
