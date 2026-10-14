# Code review - why the install broke, and what was fixed

**Date:** 2026-10-14
**Scope:** every file under `lib/`, the `vt` entry point and the test suite.
**Verified with:** `./tests/run_tests.sh` -> `PASS: 196   FAIL: 0`, ShellCheck clean.

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
