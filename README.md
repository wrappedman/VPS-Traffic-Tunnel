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

## Behind a platform edge: wss on port 443 (Railway, Fly.io, Cloudflare)

Platforms that give you a domain and terminate TLS themselves (Railway's
`*.up.railway.app`, a Cloudflare-proxied hostname, an nginx in front) can carry
the tunnel **on port 443** like ordinary HTTPS. That matters when the network
in front of the server blocks everything except 443 - a very common situation -
and it needs no TCP proxy, no open port and no certificate:

```bash
# run inside the container (Railway injects RAILWAY_PUBLIC_DOMAIN itself)
sudo vt install --mode ws-edge --domain my-service.up.railway.app --yes
sudo vt run
```

`ws-edge` creates a plain WebSocket inbound on the port the platform gave you
(`$PORT`, or `--port`), without any TLS: the edge terminates TLS and forwards
WebSocket to the container. The client config and the share link it prints are
`wss://` on **port 443 of your domain**, so nothing else has to be opened.

* Point the platform's domain at the tunnel port. On Railway the generated
  domain has a target port (Settings -> Networking, or
  `railway domain update <domain> --port <n>`); set it to the tunnel port.
* `vt status` shows `Clients connect to: <domain>:443 (wss)`.
* If the platform asks for a health-check path, leave it at `/` - the tunnel
  answers WebSocket upgrades on its own random path and nothing else.
* Switching an existing install: `vt switch-mode` -> "WebSocket behind the
  platform edge".

---

## Containers without systemd (Railway, Docker, Fly.io, LXC, WSL)

There is no systemd inside a container, so there is nothing to register a
service with. The installer notices this, says so, and supervises the tunnel
itself instead of quietly doing nothing:

```
[!] no systemd on this machine (container) - running the tunnel as a
    plain background process instead of a service.
```

* `vt start` / `vt stop` / `vt restart` start, stop and restart the Xray
  process directly (pid in `/var/lib/vt/xray.pid`, output in
  `/var/log/vt/xray.log`). `vt status` shows `Managed by: background process`.
* `vt logs` reads that log file instead of `journalctl`.
* `vt health`, `vt restart` and certificate renewal work exactly as on a VPS,
  so the usual commands keep working.

A plain background process **does not survive a redeploy**: the platform
throws the container away and starts a new one. Give the platform a start
command that stays in the foreground, `vt run`:

```bash
vt run      # supervisor: keeps Xray alive in the foreground
```

`vt run` is for containers: on a machine with systemd it refuses to start
(systemd already supervises `xray.service`; `VT_RUN_FORCE=1` overrides).

`vt run` starts Xray, restarts it 3 seconds after a crash, and every
`VT_SUPERVISE_INTERVAL` seconds (default 1800) renews the certificate when one
is due and logs an `alive:` line. `SIGTERM`/`SIGINT` (what a platform sends
when it stops the container) shut the child down cleanly. It refuses to start
twice, and `vt stop` from another shell stops it.

If the platform can build from a git repository (Railway, Fly.io, Docker), use
the ready-made image instead - it wires all of this up by itself:

```bash
docker build -f docker/Dockerfile -t vt-tunnel .
```
(see *Docker (image included)* below for the run command and the variables).

### Railway

1. Deploy the repository (Railway runs the container as root, which this
   installer needs).
2. **Settings → Deploy → Custom Start Command:** `vt run`
3. Install once — either from the **Railway shell** (`vt install --yes` builds
   a REALITY + random-port tunnel), or put the exact command you want in the
   start command, e.g.
   `vt install --mode reality --port random --email main --sni www.microsoft.com --yes && vt run`
   (`vt install` exits immediately, keeping everything, when the tunnel is
   already installed, so this line is safe on every redeploy). Deploying this
   repository as-is already does the equivalent: `docker/entrypoint.sh` is the
   image's entrypoint, so Railway needs no start command at all unless you
   want different install options.
4. If the image has no persistent volume, `/etc/vt` is recreated on every
   redeploy; with the command above the tunnel is reinstalled automatically,
   but **user UUIDs and keys change**. Attach a volume at `/etc/vt` if you
   want to keep them.
5. Give the service a public way in: Railway's HTTP proxy only speaks HTTP, so
   add a **TCP Proxy** (service → *Networking* / *Public Networking*) and set its
   target port to the tunnel port. Railway sets `$PORT`, and when that variable
   is present the installer offers it as the default tunnel port, so the target
   port usually matches out of the box (`vt port <n>` changes it later).

### Docker (image included)

The repository ships `docker/Dockerfile` and `docker/entrypoint.sh`, so there
is nothing to write:

```bash
docker build -f docker/Dockerfile -t vt-tunnel .
docker run -d --name vt --restart unless-stopped -p 24443:24443 \
  -v vt-etc:/etc/vt vt-tunnel \
  --mode reality --port 24443 --sni www.microsoft.com
```

The entrypoint installs the tunnel on the first start (unattended: it adds
`--yes --firewall no`), keeps an existing installation on the next ones - so
the REALITY keys and the UUIDs survive a restart - and then `exec`s `vt run`.
Arguments before `--` go to `vt install`, everything after it to `vt run`:

```bash
docker run ... vt-tunnel --mode reality --port 24443 -- --interval-anything
```

Useful variables: `VT_INSTALL_ARGS` / `VT_RUN_ARGS` set the defaults,
`VT_FORCE_INSTALL=1` rebuilds an existing installation (new keys - every
client has to be updated).

`--restart unless-stopped` plus the foreground `vt run` is the same always-on
behaviour `xray.service` gives on a VPS. Mount a volume at `/etc/vt` (as
above) or the keys are regenerated with every new container.

---

## Tunnel modes

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

`--yes` never overwrites an existing installation: it prints `already installed`
and exits 0, so a start command like `vt install ... --yes && vt run` is safe on
every redeploy. Add `--force` to rebuild (that rotates the REALITY keypair and
the UUIDs, and every configured client has to be updated).

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
sudo vt run                 # foreground supervisor (container start command)
sudo vt logs [xray|error|health|cert|install|follow]
sudo vt doctor              # automated diagnostics
sudo vt health              # exactly what the health timer runs
sudo vt update              # update Xray-core
sudo vt renew-cert          # renew the certificate manually
sudo vt selfsigned-cert     # create a fresh self-signed certificate
sudo vt port <n|random>     # change the port
sudo vt switch-mode         # change the tunnel mode
sudo vt backup [dir]        # create a backup
sudo vt restore <file>      # restore (--force skips the prompt)
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
/var/log/vt/xray.log                 stdout/stderr of the supervised process (no systemd)
/var/lib/vt/xray.pid                 pid of that process
/var/lib/vt/vt-run.pid               pid of the `vt run` supervisor

/etc/systemd/system/xray.service
/etc/systemd/system/vt-health.{service,timer}
/etc/systemd/system/vt-cert-renew.{service,timer}
/etc/sysctl.d/99-vt-tunnel.conf
/etc/logrotate.d/vt-tunnel
/opt/vt/docker/entrypoint.sh          container entrypoint (installs on first start)
/opt/vt/docker/Dockerfile             the image itself
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

Seven stages: syntax check, a stale-LaTeX-escape guard, ShellCheck, unit
tests, **full dry-run installs for all four mode/certificate combinations**
inside a throwaway root, Xray config schema validation, a **container run**
without systemd (install → start/stop/restart → `vt run` → `vt stop` →
`docker/entrypoint.sh` → uninstall) and uninstall.

The dry-run works through the `VT_ROOT` variable: every path is prefixed, so
the real install flow executes end to end without touching the host.

```
PASS: 303   FAIL: 0
```

The findings behind the latest round of fixes are written up in
[`docs/CODE-REVIEW.md`](docs/CODE-REVIEW.md).

---

## Quick troubleshooting

| Problem | What to do |
|---|---|
| cannot connect | `sudo vt doctor`, then check the cloud provider's firewall |
| port is open but nothing connects | in REALITY mode, change the camouflage site (`--sni`) |
| `certificate has expired` | `sudo vt renew-cert`, then `sudo vt logs cert` |
| the service will not start | `sudo vt logs error` |
| container: nothing listens after a deploy | use `vt run` as the start command; `vt start` alone dies with the container |
| container: `vt status` says inactive | `sudo vt start`, then `sudo vt logs` (journald does not exist there) |
| client cannot reach the server on a non-443 port | use `--mode ws-edge` (wss on 443 through the platform domain) instead of a TCP proxy |
| Railway: 502 / "application failed to respond" | the domain's target port is not the port the tunnel listens on - set it (`railway domain update`) |
| slow | `sysctl net.ipv4.tcp_congestion_control` should say `bbr` |

More: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)

---

## License

GPL-3.0 — see [LICENSE](LICENSE).

A Persian translation of this document lives at [`docs/README.fa.md`](docs/README.fa.md).
