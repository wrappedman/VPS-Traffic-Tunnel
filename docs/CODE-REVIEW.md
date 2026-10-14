# Code review - why the install broke, and what was fixed

**Date:** 2026-10-14
**Scope:** every file under `lib/`, the `vt` entry point and the test suite.
**Verified with:** `./tests/run_tests.sh` -> `PASS: 303   FAIL: 0`, ShellCheck clean.

---

## خلاصه فارسی

مشکل اصلی این بود که فایل‌ها در یک مرحله ویرایش دستی از ابزاری عبور کرده بودند
که کاراکترهای ویژهٔ شل را به سبک LaTeX escape کرده بود:

* «لوله» (`|`) به `\vert{}` تبدیل شده بود — در Bash و jq هر دو خطا می‌دهد.
* علامت درصد (`%`) به `\%` تبدیل شده بود — Bash آن را متن ساده می‌بیند، پس
  `printf '\%s'` به‌جای مقدار متغیر، خودِ رشتهٔ `\%s` را می‌نویسد.

نتیجه این بود که:

1. فایل‌های `lib/cert.sh` و `lib/client_gen.sh` کلاً **لود نمی‌شدند** (خطای
   syntax)، پس توابعشان وجود نداشت: گواهی ساخته نمی‌شد، `write_client_config`
   و `print_full_config` پیدا نمی‌شدند و نصب با شکست تمام می‌شد یا لینک اتصال
   هرگز چاپ نمی‌شد.
2. فایل `vt.env` با مقدارهای `\%s` نوشته می‌شد و `users_remove` /
   `users_get_uuid` هم کار نمی‌کردند (پس نه کاربر حذف می‌شد و نه لینک ساخته).

همهٔ آن escape‌ها برداشته شد و علاوه بر آن چند باگ واقعی دیگر که در بازبینی
پیدا شد هم اصلاح شد (فهرست کامل پایین‌تر). برای اینکه این اتفاق دیگر تکرار
نشود، تست‌هایی اضافه شد که هم escape بودن را تشخیص می‌دهند و هم مطمئن می‌شوند
هر فایل کتابخانه واقعاً لود شده است.

**دور دوم (کانتینرها):** روی Railway هیچ systemd وجود ندارد، پس `sysd()` فقط
خط `[dry] systemctl restart xray.service` را چاپ می‌کرد و **هیچ کاری نمی‌کرد**؛
نصب «موفق» گزارش می‌شد ولی تونل هرگز بالا نمی‌آمد. حالا بدون systemd خودِ
برنامه پروسه را نگه می‌دارد، دستور `vt run` به‌عنوان Start Command کانتینر
اضافه شده، و `vt install --yes` روی نصب موجود دست نمی‌برد (تا خط
`vt install --yes && vt run` در هر ری‌دیپلوی امن باشد). جزئیات در بخش ۶.

---

## 1. Root cause: LaTeX-style escaping (fatal)

The sources had been through a formatter that wrote shell metacharacters the
LaTeX way. Both forms are *valid* bash, so `bash -n` stays quiet - one of them
even runs "successfully" while writing the wrong bytes.

| File | Was | Effect |
|---|---|---|
| `lib/cert.sh` | `[[ -f "$f" ]] \vert{}\vert{} { ... }` | **syntax error -> the whole file is not sourced**: `cert_issue_selfsigned`, `cert_issue_domain`, `cert_summary`, `cert_renew` ... all undefined |
| `lib/client_gen.sh` | `\vert{}\vert{}` (2x), jq `'.users[] \vert{} ...'` | **syntax error -> file not sourced**: `share_link`, `print_qr`, `print_full_config`, `write_client_config` undefined |
| `lib/state.sh` | `val="${val\%\"}"` | `bad substitution` on every `state_load` |
| `lib/state.sh` | `printf -v "VT_${key}" '\%s'` | wrote the literal text `\%s` instead of the value - every state variable came back as `\%s` |
| `lib/state.sh` | `state_get() { printf '\%s' ... }` | same |
| `lib/state.sh` | jq `'.users \vert{}= map(...)'` | `vt rm-user` could never update the store |
| `lib/state.sh` | jq `'.users[] ... \vert{} .uuid'` | `users_get_uuid` always empty -> no share links, no client config |
| `lib/cert.sh` | `stat -c \%Y` | `stat` got the literal `\%Y`; the self-signed certificate age check always failed |

These are fixed, and `tests/run_tests.sh` now greps the tree for the same
pattern so it cannot silently come back.

## 2. Bugs that broke the install flow even with clean syntax

| # | File | Bug | Fix |
|---|---|---|---|
| 1 | `lib/service.sh` | `$([[` + `$rc -eq 0 ]] && ...)` - missing space after `[[`; the health check ran a command called `[[0` and logged `DEGRADED` | `[[ $rc -eq 0 ]]` |
| 2 | `lib/config_gen.sh` | REALITY `shortIds` contained `""` next to the real id (`["", "$shortid"]`); Xray then also accepts a client without a shortId, and the shipped schema validator + e2e test reject it | `["$shortid"]` |
| 3 | `lib/users.sh` | `awk 'IGNORECASE=1; /value:/ {print $2}'` - `IGNORECASE` is a **gawk** extension. Ubuntu/Debian ship `mawk`, where a leading assignment is a *pattern*: it printed every line, so `vt stats` showed `0 B` for everyone | `awk 'tolower($0) ~ /value:/ {print $2; exit}'`, and the JSON path now requires non-empty input |
| 4 | `lib/status.sh` | `vt backup` wrote the tarball into `${R_ETC}/backup`, i.e. **inside the tree it was archiving** (the archive contained a copy of itself; `tar` warns "file changed as we read it") | the archive is built in a scratch directory and moved into place; the default destination is now `/var/lib/vt/backup` |
| 5 | `lib/status.sh`, `vt` | `vt restore` asked "continue? [y/N]" and answered it with the default **no** whenever `VT_ASSUME_YES=1`, so an unattended restore silently did nothing | `--force` (or `VT_FORCE=1`) skips the prompt; `vt restore <file> [--force]` is parsed properly |
| 6 | `lib/uninstall.sh` | `--purge` was overwritten by the interactive answer: the wizard set `VT_UNINSTALL_KEEP_ETC=y` *after* the CLI had set `n` | the question is only asked when the flag did not already answer it |
| 7 | `vt` | `vt health --quiet` (what `vt-health.service` runs) printed the whole report: only the literal `--quiet` was special-cased | new `_quiet_flag` helper; `--quiet`/`-q` are honoured by `health` and `renew-cert`, both of which are now silent for systemd |
| 8 | `lib/cert.sh` | `vt renew-cert --quiet` still printed "certificate renewal check done" from inside `cert_renew` | `cert_renew [quiet]` keeps stdout clean |
| 9 | `lib/install.sh` | a typo in `--mode` / `--cert` was silently replaced by the default mode (a `--mode ws-tls` typo installed REALITY) | both are validated and abort with a clear message |
| 10 | `lib/config_gen.sh` | `build_client_config` with an unknown `VT_MODE` emitted a config with an empty `streamSettings` (invalid JSON) | explicit `fail "unknown mode"` |
| 11 | `lib/install.sh` | on a NATed box where public-IP detection fails, `VT_HOST` silently became the **private** address, so the share link pointed somewhere unreachable | the wizard now asks for the public IP/hostname in that case |

## 3. Cosmetic / robustness fixes

* `lib/common.sh` `box()`: a line wider than the 76-column frame pushed the
  right border out (`printf '%*s' -3 ''` pads instead of shrinking). Long lines
  are truncated with `...` and the frame is always aligned. The share link - by
  far the longest value - is now printed *below* the box, where it is easy to
  select and copy, and `+---+` is closed with the correct corner glyph.
* `lib/client_gen.sh`: `sni / public  : host /key` lost a space.
* `lib/cert.sh`: `(valid` + `${days} days)` lost a space.
* `lib/xray.sh`: the comment now names the real `xray x25519` output
  (`PrivateKey:` / `Password (PublicKey):` / `Hash32:`), which the parser
  already handles on current releases.
* `lib/install.sh`: a failed client-config write is reported instead of being
  swallowed by `|| true`, and the "open this port in your provider's cloud
  firewall" warning is actually called (it existed but was never used).
* `tests/e2e_lib.sh`: the dry-runs no longer go through `sudo` (the suite
  already re-executes itself as root), which also keeps `PATH` intact.

## 4. Tests added (167 -> 196 assertions)

* `no LaTeX-style escaping in the sources` - greps for the exact artefact.
* `every library entry point is defined` - sources all of `lib/` and asserts
  that every public function exists, so a syntax error in a library can no
  longer pass unnoticed.
* `_api_stat` against a fake `xray` binary: the current JSON output **and** the
  legacy `Value: N` text output, on `mawk`.
* `box` rendering: equal line widths, never wider than 80 columns, truncation.
* `_quiet_flag` for every accepted spelling.
* Per e2e case: `renew-cert --quiet` and `health --quiet` produce no output.
* Per e2e case: backup -> wipe -> restore round-trip (archive integrity, rooted
  member names, state file and rebuilt `config.json`).

## 5. Not changed (checked and left alone on purpose)

* `policy.levels."0".bufferSize = 512` is Xray's own default on x86_64, so the
  explicit value neither helps nor hurts.
* `--cert-profile shortlived` for Let's Encrypt IP certificates is correct:
  acme.sh accepts `--cert-profile` as an alias of `--certificate-profile`, and
  the `shortlived` profile is mandatory for IP identifiers.
* The `api` routing rule `inboundTag: [api] -> outboundTag: api` matches the
  upstream Xray documentation for the stats API.
* `_install_cert` intentionally restarts `xray.service` (a reload is only safe
  for hot-reloadable listeners) and the unit therefore has no `ExecReload`.

---

## 6. Containers: no systemd (Railway, Docker, Fly.io, LXC, WSL)

Reported from a Railway deploy: the panel said the service was stopped, the
restart printed `[dry] systemctl restart xray.service`, and the check right
after it said `[✗] the service did not come up.`

**The fault was in the program, not in Railway.** `sysd()` silently fell back
to printing the `systemctl` line when systemd is unavailable, so *every*
service action was a no-op: the install reported success while nothing was
ever started, and `vt start|stop|restart` did nothing at all. The suite never
caught it because it forces `VT_SKIP_SYSTEMD=1` and therefore exercised the
same silent path (and it only asserted that the install finished).

### What changed

| Area | Behaviour now |
|---|---|
| `lib/service.sh` | `service_backend()` returns `systemd` or `process`. Without systemd, `vt start|stop|restart` supervise the binary directly: pid in `/var/lib/vt/xray.pid`, stdout/stderr in `/var/log/vt/xray.log`, `xray_is_active` falls back to that pid file and then to `pgrep -x xray`. |
| `vt run` (new) | The container start command. Foreground supervisor: starts `xray run -config ...` with `XRAY_LOCATION_ASSET`, restarts it 3 s after a crash, renews the certificate when due and logs an `alive:` line every `VT_SUPERVISE_INTERVAL` seconds (default 1800), and shuts the child down cleanly on `SIGTERM`/`SIGINT`/`SIGHUP` (`docker stop`). It records its own pid in `/var/lib/vt/vt-run.pid` and refuses to run twice. |
| `service_xray` | One dispatcher (`start|stop|restart`) used by `lib/cert.sh`, `lib/config_gen.sh`, `lib/service.sh` and `lib/status.sh`; the old `sysd <action> xray.service` call sites are gone, so a container can no longer silently skip a restart. |
| `xray_stop_process` | Stops a running `vt run` supervisor first (it would otherwise just start a new child), then the child. `$$` is excluded so the supervisor's own health check / renewal never kills its parent. |
| Process detection | `xray_process_pids`/`_owns_xray_pid` ask `/proc` whether a process really *is* this install's binary (its `exe`, or `argv[1]` for the offline stub, which is a shell script). The old `pkill -x xray` matched by name, so a test run inside a `VT_ROOT` could have killed the host's real tunnel - and `xray_is_active` could report a foreign process as ours. |
| `xray_restart_process` | When a supervisor is running it only kills the child and lets the supervisor respawn it - starting a second Xray there would race it for the port. |
| `lib/status.sh` | `vt logs` reads `/var/log/vt/xray.log` where journald does not exist; `vt logs follow` says so instead of running `journalctl`. `doctor` prints `unavailable` instead of `?` for the congestion control on a container. |
| `cert_renewal_job_active` | Reports `vt run supervisor` without systemd, and no longer claims `systemd timer (unit installed)` on a machine where timers cannot tick. Also stopped printing `none`, which leaked into `Auto renewal: none—`. |
| `lib/install.sh` | Tunnel port defaults to `$PORT` when the platform sets it; the UFW prompt defaults to *no* (the platform owns port mapping); `vt install --yes` keeps an existing installation and exits 0 instead of dying with `cancelled.` - that is what makes `vt install ... --yes && vt run` a safe start command on every redeploy. |
| `enable_services` | Warns that a plain background process does not survive a redeploy and points at `vt run`. |
| `xray_start_process` | On failure it now reports the child's real exit status, and says so when the log is empty (instead of an empty "the last lines of the log say why:"). |
| `docker/Dockerfile`, `docker/entrypoint.sh` | The image: Debian bookworm plus the tools the program actually calls (`curl jq openssl procps iproute2 python3 socat unzip tar cron`). The entrypoint installs on the first start (adding `--yes --firewall no` itself, never twice), keeps an existing installation on later starts so the keys and UUIDs survive a redeploy, and then `exec`s `vt run`. Arguments before `--` go to the install, after it to `vt run`; `VT_INSTALL_ARGS`, `VT_RUN_ARGS` and `VT_FORCE_INSTALL` (which bypasses the "keep it" branch, not just appends `--force`) are honoured. |

### Tests (`PASS: 196` -> `303`)

A new stage, `6/7 container services (no systemd)`, installs with
`VT_SKIP_SYSTEMD=1` and the real service layer, then drives it end to end:

* install on a machine without systemd, with the warning and a valid config;
* a repeated unattended install is a no-op and keeps the keys;
* `vt start` -> pid file written, `vt status` active, `vt logs`/`vt logs follow`
  behave; `vt stop` -> inactive; `vt restart` -> active again;
* `vt health` restarts a dead tunnel and the tunnel is up afterwards;
* `vt run` starts the child in the foreground and stops it on `SIGTERM`;
* a background supervisor is visible in `vt status`, `vt stop` shuts the
  supervisor (not just the child) down, a second `vt run` refuses to start, and
  a configuration change (`add-user`) defers to the running supervisor instead
  of racing it for the port;
* uninstall still removes everything.

And `docker/entrypoint.sh` is driven directly (no Docker needed - it honours
`VT_ROOT`/`VT_BIN`): first start installs and execs the supervisor, a second
start keeps the install and its keys, `VT_FORCE_INSTALL=1` rebuilds with the
options from the command line, anything after `--` reaches `vt run`, a
half-written install (state without config) is repaired, and an install that
fails does not leave a supervisor running behind it - the bug this test found
in the first draft of the entrypoint.

Unit tests also assert `service_backend`, `run_supervisor_pid` (missing / stale
/ garbage / live pid file) and that `cmd_run` and the rest of the service layer
are actually defined after sourcing.

---

## 7. A fourth mode for platforms that terminate TLS: `ws-edge`

Reported while deploying on Railway: the tunnel ran, the port listened, and
the client still could not connect - `dial tcp <ip>:<port>: i/o timeout` on a
TCP-proxy address, while port 443 to the same host answered. That is the
network in front of the client dropping everything that is not 443, which no
amount of server-side fixing can change.

`ws-edge` moves the TLS to whatever terminates it already:

| Piece | ws-tls (was) | ws-edge (new) |
|---|---|---|
| Container inbound | WebSocket **+ TLS**, own certificate, own port | WebSocket only, no `security`, no `tlsSettings`, no certificate |
| TLS terminator | the container | the platform domain / CDN |
| Client link | `wss://<host>:<port>` with the container's cert | `wss://<domain>:443` - passes wherever HTTPS passes |
| Extra setup | open the port in every firewall | point the platform's domain at the tunnel port |

* `lib/config_gen.sh`: `_stream_ws_plain` (no `security` key at all - newer Xray
  accepts `"none"`, older versions do not) and `_client_stream_ws_edge`; the
  client's `vnext` port becomes `VT_EDGE_PORT` (443) instead of the local port.
* `lib/client_gen.sh`: the share link switches to `security=tls` on port 443,
  and `config.txt` says where clients connect and on which port the container
  listens.
* `lib/install.sh`: wizard option 4, `--mode ws-edge`, no certificate step at
  all, and the host defaults to `RAILWAY_PUBLIC_DOMAIN` when the platform sets
  it, so `vt install --mode ws-edge --yes` needs no arguments on Railway.
* `lib/status.sh` / `vt switch-mode`: converting an existing install, and a
  `Clients connect to:` row in `vt status`.
* `cmd_run` now refuses to start where systemd runs: it would have taken the
  tunnel over from `xray.service` (killing a process systemd owns) and raced
  it for the port. A normal VPS is therefore never touched by `vt run`.
* `tests/`: a new e2e case (`ws-edge-railway-domain`), per-mode assertions
  (no certificate file, no `tlsSettings`, client on 443) and unit tests for the
  link; `tests/validate_config.py` now accepts a security-less ws inbound.
