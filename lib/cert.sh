#!/usr/bin/env bash
# cert.sh — free TLS certificates with automatic renewal.
#
# Three sources, all free:
#   1. letsencrypt-domain : Let's Encrypt for a domain (http-01 standalone,
#                           http-01 webroot, or dns-01 via a DNS API).
#   2. letsencrypt-ip     : Let's Encrypt certificate issued for the bare IP
#                           address. Generally available since 2026-01-15,
#                           requires the "shortlived" ACME profile (160 h
#                           validity) and http-01 validation.
#   3. selfsigned         : OpenSSL self-signed certificate. Not trusted by
#                           clients (they must set allowInsecure) but needs
#                           no domain and no open port 80.
#
# Renewal is automatic: acme.sh installs a cron job for (1) and (2), and
# vt-cert-renew.timer re-checks daily for everything, including (3).

ACME_RAW_URL="https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh"
ACME_TARBALL_URL="https://codeload.github.com/acmesh-official/acme.sh/tar.gz/refs/heads/master"

acme_bin() { p "$R_ACME_BIN"; }
acme_home() { p "$R_ACME_HOME"; }
cert_file() { p "$R_CERT_DIR/fullchain.pem"; }
key_file()  { p "$R_CERT_DIR/privkey.pem"; }

# Runtime (unprefixed) paths, used for strings that live inside config files.
R_CERT_FILE="$R_CERT_DIR/fullchain.pem"
R_KEY_FILE="$R_CERT_DIR/privkey.pem"

cert_install_acme() {
  local bin home
  bin=$(acme_bin); home=$(acme_home)
  if [[ -x "$bin" ]]; then
    log_ok "acme.sh از قبل موجود است."
    return 0
  fi
  mkdir -p "$home" "$(dirname "$bin")"
  log_info "دریافت acme.sh ..."
  if [[ "$VT_SKIP_DOWNLOADS" != "1" ]]; then
    if curl -fsSL --connect-timeout 10 --max-time 60 -o "$bin" "$ACME_RAW_URL"; then
      :
    else
      log_note "raw.githubusercontent در دسترس نبود، از آرشیو GitHub استفاده می‌کنم."
      local tmp; tmp=$(mktemp -d)
      # shellcheck disable=SC2064
      trap "rm -rf '$tmp'" RETURN
      curl -fsSL --max-time 120 -o "$tmp/a.tgz" "$ACME_TARBALL_URL" \
        || fail "دانلود acme.sh ناموفق بود."
      tar xzf "$tmp/a.tgz" -C "$tmp" || fail "استخراج acme.sh ناموفق بود."
      local src
      src=$(find "$tmp" -maxdepth 2 -name acme.sh -type f | head -n1)
      [[ -n "$src" ]] || fail "acme.sh داخل آرشیو پیدا نشد."
      cp "$src" "$bin"
    fi
    chmod +x "$bin"
  else
    log_note "[dry] acme.sh دانلود نشد (VT_SKIP_DOWNLOADS=1)"
    printf '#!/bin/sh\nexit 0\n' >"$bin"
    chmod +x "$bin"
  fi
  # acme.sh keeps account keys and per-domain state here.
  export LE_WORKING_DIR="$home"
  log_ok "acme.sh آماده است: $bin"
}

# Build the acme.sh invocation prefix.
_acme() {
  local bin home
  bin=$(acme_bin); home=$(acme_home)
  LE_WORKING_DIR="$home" "$bin" --home "$home" "$@"
}

# --------------------------------------------------------------------------
# 1. Domain certificate
# --------------------------------------------------------------------------
# cert_issue_domain <domain> <email> <method: standalone|webroot|dns> [args...]
cert_issue_domain() {
  local domain="$1" email="$2" method="$3"
  local -a extra=()
  shift 3
  extra=("$@")

  cert_install_acme
  local cert_dir; cert_dir=$(p "$R_CERT_DIR")
  mkdir -p "$cert_dir"

  local -a cmd=(--issue -d "$domain" --server letsencrypt
                --keylength ec-256 -m "$email")
  case "$method" in
    standalone) cmd+=(--standalone) ;;
    webroot)    cmd+=(--webroot "${extra[0]:-/var/www/html}") ;;
    dns)        # extra = (dns-plugin, env-name, env-value)
      cmd+=(--dns "${extra[0]}")
      export "${extra[1]}=${extra[2]}"
      ;;
    *) fail "روش ناشناخته صدور گواهی: $method" ;;
  esac

  log_info "صدور گواهی Let's Encrypt برای $domain (روش: $method) ..."
  if [[ "$VT_SKIP_DOWNLOADS" == "1" ]]; then
    log_note "[dry] acme.sh ${cmd[*]}"
    _write_placeholder_cert "$domain"
  else
    _acme "${cmd[@]}" || {
      log_err "صدور گواهی ناموفق بود."
      log_warn "دلایل رایج: رکورد DNS به این سرور اشاره نمی‌کند، پورت 80 بسته است،"
      log_warn "یا فایروال پنل ابری بسته است. می‌توانید روش DNS را انتخاب کنید."
      return 1
    }
  fi
  _install_cert "$domain" "--ecc"
}

# --------------------------------------------------------------------------
# 2. Certificate for a bare IP address (shortlived profile, ~6 days)
# --------------------------------------------------------------------------
cert_issue_ip() {
  local ip="$1" email="$2"
  cert_install_acme
  local cert_dir; cert_dir=$(p "$R_CERT_DIR")
  mkdir -p "$cert_dir"

  local -a cmd=(--issue -d "$ip" --server letsencrypt
                --cert-profile shortlived --days 3
                --keylength ec-256 --standalone -m "$email")

  log_info "صدور گواهی Let's Encrypt برای آی‌پی $ip (پروفایل shortlived) ..."
  log_note "پورت 80 باید در زمان صدور و هر ~3 روز برای تمدید باز باشد."
  if [[ "$VT_SKIP_DOWNLOADS" == "1" ]]; then
    log_note "[dry] acme.sh ${cmd[*]}"
    _write_placeholder_cert "$ip"
  else
    _acme "${cmd[@]}" || {
      log_err "صدور گواهی برای آی‌پی ناموفق بود."
      return 1
    }
  fi
  _install_cert "$ip" "--ecc"
}

# Copy the issued certificate to our own directory and register the reload hook.
_install_cert() {
  local ident="$1" ecc="${2:-}"
  local cert_dir; cert_dir=$(p "$R_CERT_DIR")
  local reload="systemctl reload-or-restart xray"
  if [[ "$VT_SKIP_DOWNLOADS" == "1" ]]; then
    log_note "[dry] acme.sh --install-cert $ident"
    return 0
  fi
  # shellcheck disable=SC2086
  _acme --install-cert -d "$ident" $ecc \
    --key-file "$(key_file)" \
    --fullchain-file "$(cert_file)" \
    --reloadcmd "$reload" \
    || fail "کپی گواهی به $R_CERT_DIR ناموفق بود."
  chmod 600 "$(key_file)"
  chmod 644 "$(cert_file)"
  VT_TLS_CERT_FILE="$R_CERT_FILE"
  VT_TLS_KEY_FILE="$R_KEY_FILE"
  log_ok "گواهی در $R_CERT_FILE ذخیره شد و تمدید خودکار فعال است."
}

# --------------------------------------------------------------------------
# 3. Self-signed certificate (no domain, no port 80)
# --------------------------------------------------------------------------
# cert_issue_selfsigned <host> [days]
cert_issue_selfsigned() {
  local host="$1" days="${2:-825}"
  local cert_dir; cert_dir=$(p "$R_CERT_DIR")
  mkdir -p "$cert_dir"
  local tmp; tmp=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  local san="subjectAltName="
  if is_ip "$host"; then
    if [[ "$host" == *:* ]]; then san+="IP:${host}"
    else san+="IP:${host}"; fi
  else
    san+="DNS:${host},DNS:www.${host}"
  fi

  cat >"$tmp" <<EOF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = ${host}
O  = ${VT_PROJECT}
[v3]
basicConstraints       = critical, CA:TRUE, pathlen:0
keyUsage               = critical, digitalSignature, keyEncipherment, keyCertSign
extendedKeyUsage       = serverAuth
${san}
subjectKeyIdentifier   = hash
EOF

  log_info "ساخت گواهی خودامضا برای $host (اعتبار ${days} روز) ..."
  openssl req -x509 -new -newkey ec \
    -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$(key_file)" -out "$(cert_file)" \
    -days "$days" -config "$tmp" -sha256 >/dev/null 2>&1 \
    || openssl req -x509 -newkey rsa:2048 -nodes \
         -keyout "$(key_file)" -out "$(cert_file)" \
         -days "$days" -config "$tmp" -sha256 >/dev/null 2>&1 \
    || fail "ساخت گواهی خودامضا ناموفق بود."

  chmod 600 "$(key_file)"
  chmod 644 "$(cert_file)"
  VT_TLS_CERT_FILE="$R_CERT_FILE"
  VT_TLS_KEY_FILE="$R_KEY_FILE"
  log_ok "گواهی خودامضا ساخته شد: $R_CERT_FILE"
  log_warn "گواهی خودامضا توسط کلاینت‌ها معتبر شناخته نمی‌شود؛"
  log_warn "در تنظیمات کلاینت باید allowInsecure / «رد کردن اعتبارسنجی» فعال باشد."
}

_write_placeholder_cert() {
  cert_issue_selfsigned "${1:-localhost}" 7 >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------
# Renewal (invoked by vt-cert-renew.timer and by `vt renew-cert`)
# --------------------------------------------------------------------------
cert_renew() {
  local mode="${VT_CERT_MODE:-none}"
  local logf; logf="$(p "$R_LOG")/cert-renew.log"
  mkdir -p "$(dirname "$logf")"
  {
    printf '%s --- cert renewal run (mode=%s)\n' "$(_ts)" "$mode"
    case "$mode" in
      letsencrypt-domain|letsencrypt-ip)
        if [[ -x "$(acme_bin)" ]]; then
          _acme --cron --home "$(acme_home)" 2>&1 || true
        else
          printf 'acme.sh not found at %s\n' "$(acme_bin)"
        fi
        ;;
      selfsigned)
        _selfsigned_renew_if_old 2>&1 || true
        ;;
      none|"")
        printf 'nothing to do (no certificate in use)\n'
        ;;
      *)
        printf 'unknown cert mode: %s\n' "$mode"
        ;;
    esac
  } >>"$logf" 2>&1
  log_ok "بررسی تمدید گواهی انجام شد (لاگ: $R_LOG/cert-renew.log)"
}

# Regenerate the self-signed certificate once it is past half its lifetime.
_selfsigned_renew_if_old() {
  local f; f=$(cert_file)
  [[ -f "$f" ]] || { cert_issue_selfsigned "${VT_HOST:-localhost}" 825; return; }
  local maxage=$(( 825 * 86400 / 2 ))
  local mtime now
  mtime=$(stat -c %Y "$f" 2>/dev/null || printf '0')
  now=$(date +%s)
  if (( now - mtime > maxage )); then
    printf 'self-signed certificate is older than %ss, regenerating\n' "$maxage"
    cert_issue_selfsigned "${VT_HOST:-localhost}" 825
    sysd reload-or-restart xray || true
  else
    printf 'self-signed certificate still fresh (%ss old)\n' "$((now - mtime))"
  fi
}

# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------
# Prints "issuer|notAfter|daysLeft" or "none" when no certificate is installed.
cert_summary() {
  local f; f=$(cert_file)
  if [[ ! -f "$f" ]]; then printf 'none'; return; fi
  local issuer end end_epoch days
  issuer=$(openssl x509 -in "$f" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
  end=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
  if [[ -n "$end" ]]; then
    end_epoch=$(date -d "$end" +%s 2>/dev/null || printf '0')
    days=$(( (end_epoch - $(date +%s)) / 86400 ))
  else
    days="?"
  fi
  local short="${issuer##*O=}"
  printf '%s|%s|%s' "${short:0:40}" "${end:-unknown}" "$days"
}

cert_renewal_job_active() {
  if crontab -l 2>/dev/null | grep -q 'acme.sh'; then
    printf 'acme.sh cron'
    return 0
  fi
  if systemd_running && systemctl list-timers 2>/dev/null | grep -q 'vt-cert-renew'; then
    printf 'systemd timer'
    return 0
  fi
  if [[ -f "$(p "$R_VT_CERT_TIMER")" ]]; then
    printf 'systemd timer (unit installed)'
    return 0
  fi
  printf 'none'
  return 1
}
