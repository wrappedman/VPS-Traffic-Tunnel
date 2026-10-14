# Troubleshooting

Always start here:

```bash
sudo vt doctor
```

It checks the binary, whether `config.json` parses, whether the service is
active, whether the port is listening, the certificate's validity, the system
clock, the congestion-control algorithm and the firewall rules — all at once.

---

## 1. Cannot connect

**Step 1 — is the service up on the server?**
```bash
sudo vt status
sudo vt logs error
```

**Step 2 — is the port reachable from outside?**
From another machine:
```bash
nc -vz <IP> <PORT>
```
If it is closed, check these in order:
1. the server's own firewall: `sudo ufw status numbered`
2. **the cloud provider's firewall** (Hetzner Cloud Firewall, AWS Security
   Group, DigitalOcean Firewall, Arvan, etc.) — this is the most common cause
   and it is invisible from inside the server.

**Step 3 — the port may be blocked upstream**
Some ISPs block particular ports. Get a fresh one with `sudo vt port random`
and try again.

---

## 2. REALITY will not connect

* The camouflage site (`SNI`) must support TLS 1.3 and must be reachable from
  the server:
  ```bash
  echo Q | openssl s_client -connect www.microsoft.com:443 -servername www.microsoft.com -tls1_3 | head -5
  ```
  If that fails, pick another site (`www.apple.com`, `www.cloudflare.com`, …)
  via menu option 10 (switch mode), or reinstall with `--sni`.
* `pbk` (the public key) in the client config must match the server's public
  key exactly. After rotating keys, fetch a new config: `sudo vt viewconfig`.
* The server's and the client's clocks must be roughly in sync.

---

## 3. TLS certificate errors

```bash
sudo vt logs cert
sudo vt renew-cert
```

**Domain certificate issuance failed**
* The domain's A record must point at the server's public IP. The installer
  checks this and reports the result.
* If the domain is behind Cloudflare with the orange cloud (proxy) enabled,
  either turn the proxy off or use the DNS method:
  ```bash
  sudo vt install --mode ws-tls --domain your.domain \
       --cert letsencrypt-domain --acme dns \
       --dns-plugin dns_cf --dns-token "TOKEN" --yes
  ```
* Port 80 must be open (standalone method).

**IP certificate issuance failed**
* Port 80 must be reachable from the internet.
* IP certificates are only issued with the `shortlived` profile and a ~6 day
  lifetime. If your acme.sh is old, upgrade it:
  ```bash
  sudo /etc/vt/acme.sh --upgrade --home /etc/vt/acme
  ```
* If it still fails the installer offers a self-signed certificate, or run
  `sudo vt selfsigned-cert` yourself.

**Self-signed: the client complains**
That is expected — `allowInsecure` must be on. The program already puts it in
the share link (`allowInsecure=1`); add it yourself if you wrote the config by
hand.

---

## 4. The service does not come back after a reboot

```bash
systemctl is-enabled xray.service      # should say enabled
systemctl status xray.service
sudo vt logs error
```
If it says `disabled`:
```bash
sudo systemctl enable --now xray.service
```

---

## 5. Slow

```bash
sysctl net.ipv4.tcp_congestion_control    # should say bbr
```
If it says `cubic`, BBR is not loaded in the kernel:
```bash
sudo modprobe tcp_bbr
lsmod | grep bbr
```
To make it permanent, add `tcp_bbr` to `/etc/modules-load.d/bbr.conf`.

Other things to check:
* MTU: if the VPS is itself inside another tunnel (e.g. WireGuard), lower the
  MTU.
* The installer already tunes `net.ipv4.tcp_notsent_lowat` and the socket
  buffers; if you changed sysctl by hand, review
  `/etc/sysctl.d/99-vt-tunnel.conf`.

---

## 6. The firewall cut off SSH

If you still have an open session, **do not close it**, and run:
```bash
sudo ufw allow 22/tcp        # or your real SSH port
sudo ufw status numbered
```
If you have no session left, log in through the cloud provider's console
(VNC/serial) and run:
```bash
sudo ufw disable
```

---

## 7. The install stopped halfway

The full install log is here:
```bash
sudo vt logs install
```
To start over:
```bash
sudo vt uninstall --purge --yes
sudo vt install
```

---

## 8. Containers without systemd (Railway, Docker, Fly.io, WSL)

`systemctl` does not exist inside these, so the tunnel is supervised by `vt`
itself instead of by a service:

```bash
sudo vt status                  # Managed by: vt run supervisor (pid N, no systemd)
sudo vt start                   # start it now
sudo vt logs                    # reads /var/log/vt/xray.log, not journalctl
sudo vt logs follow             # says that journald is missing
```

* **Nothing listens after a redeploy** - a background process dies with the
  container. Make `vt run` the start command (Railway: *Settings -> Deploy ->
  Custom Start Command*), or `... && vt run` after an install.
* **`vt run` exits immediately** - check that the binary and the config exist
  (`vt doctor`); the supervisor prints the child's exit status and points at
  the log.
* **`vt install --yes` prints "already installed"** - that is deliberate: an
  unattended install must not rotate the keys of a working tunnel. Add
  `--force` if you really want to rebuild it.
* **Every redeploy has a new UUID** - `/etc/vt` is not on a persistent volume,
  so attach a volume there (see the container section in the README).
* **`Auto renewal: none`** - without systemd only `vt run` renews the
  certificate; start it and the row changes to `vt run supervisor`.
* **The image does not start on Railway** - `docker/entrypoint.sh` prints why:
  either the install failed (`vt install ...` by hand inside a shell shows the
  detail) or the container has no `/etc/vt` volume, in which case the keys are
  regenerated on every redeploy.

---

## 9. Nothing gets through on a non-443 port (blocked by the network)

Symptom: the tunnel is running (`vt status` says active, the port is
listening), but the client times out while dialling your proxy address. A TCP
connect from outside dies without an answer, and the client log shows
`dial tcp <ip>:<port>: i/o timeout`.

That is a network in front of you dropping the port (or the whole address
range) - very common on mobile/ISP networks for anything that is not 443.

**Fix: put the tunnel behind the TLS edge of your platform.**

```bash
# Railway (RAILWAY_PUBLIC_DOMAIN is already in the environment):
sudo vt install --mode ws-edge --domain my-service.up.railway.app --yes
# or convert an existing install:
sudo vt switch-mode        # -> "WebSocket behind the platform edge"
```

Then point the platform's domain at the tunnel port (Railway: the domain's
target port in Settings -> Networking) and import the link `vt viewconfig`
prints: it is `wss://<domain>:443`, so it passes anywhere HTTPS passes.

Diagnosis you can do yourself:
* `nc -vz <domain> 443` from the client network - works? then the edge is fine.
* `nc -vz <domain> <non-443-port>` - fails while 443 works? then it is the
  port/network, not the server.
* `vt logs` on the server shows nothing at all when the client tries: the
  traffic never arrived, so the problem is outside the container.

---

## 10. Files that are useful in a bug report

```bash
sudo vt doctor
sudo vt logs error
sudo vt logs install
grep -v PRIVATE /etc/vt/vt.env
```

> Never send `REALITY_PRIVATE`, `privkey.pem` or `users.json` to anyone.
