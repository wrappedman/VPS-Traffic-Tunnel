#!/usr/bin/env bash
# install.sh — the interactive (and fully scriptable) installer wizard.

# Defaults for the wizard; every one of them can be overridden on the CLI.
WIZ_MODE=""
WIZ_DOMAIN=""
WIZ_CERT=""          # none | letsencrypt-domain | letsencrypt-ip | selfsigned
WIZ_PORT=""
WIZ_EMAIL=""
WIZ_ACME_METHOD="standalone"
WIZ_WEBROOT="/var/www/html"
WIZ_DNS_PROVIDER=""
WIZ_DNS_TOKEN=""
WIZ_DNS_ENV="CF_Token"
WIZ_SNI=""
WIZ_FIREWALL="ask"
WIZ_AD_BLOCK="0"
WIZ_BLOCK_TORRENT="0"

# --------------------------------------------------------------------------
# Pre-flight
# --------------------------------------------------------------------------
preflight() {
  log_step "بررسی اولیه سیستم"

  is_root || fail "باید با root اجرا شود (sudo bash $0)."

  if [[ -r /etc/os-release ]]; then
    local pretty
    pretty=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")
    log_info "سیستم‌عامل: $pretty"
    if ! (. /etc/os-release && [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]]); then
      log_warn "این اسکریپت برای Ubuntu/Debian نوشته شده؛ ممکن است نیاز به تنظیم دستی داشته باشد."
    fi
  fi
  log_info "معماری: $(uname -m) → بسته Xray-linux-$(xray_arch)"
  log_info "هسته: $(uname -r)"

  local local_ip pub_ip
  local_ip=$(local_primary_ipv4); local_ip="${local_ip:-127.0.0.1}"
  pub_ip=$(detect_public_ipv4) || pub_ip=""
  if [[ -z "$pub_ip" ]]; then
    log_warn "آی‌پی عمومی تشخیص داده نشد؛ از آی‌پی محلی استفاده می‌شود."
    pub_ip="$local_ip"
  fi
  log_info "آی‌پی محلی: $local_ip"
  log_info "آی‌پی عمومی: $pub_ip"
  if [[ -n "$local_ip" && "$local_ip" != "$pub_ip" && "$local_ip" != "127.0.0.1" ]]; then
    log_note "سرور پشت NAT است (آی‌پی محلی ≠ عمومی). برای اتصال از آی‌پی عمومی استفاده کنید."
  fi
  VT_DETECTED_IP="$pub_ip"
  VT_DETECTED_IPV6="$(detect_public_ipv6 || true)"
  VT_SSH_PORT="$(detect_ssh_port)"
  log_info "پورت SSH: $VT_SSH_PORT"

  if [[ -f "$(p "$R_XRAY_CONF")" && "$VT_FORCE" != "1" ]]; then
    if confirm "یک نصب موجود پیدا شد. پیکربندی فعلی بازنویسی شود؟" n; then
      VT_FORCE=1
    else
      die "لغو شد."
    fi
  fi
}

# --------------------------------------------------------------------------
# Question 1 — do you have a domain?
# --------------------------------------------------------------------------
wizard_ask_domain() {
  cat <<'TXT'

  ── گام ۱: دامنه ────────────────────────────────────────────────────────
  اگر دامنه دارید، می‌توانیم گواهی SSL رایگان و معتبر Let's Encrypt بگیریم
  و تونل دقیقاً مثل یک سایت HTTPS واقعی دیده شود (پنهان‌سازی بهتر).
  اگر دامنه ندارید هم مشکلی نیست: حالت REALITY بدون دامنه و بدون گواهی
  کار می‌کند، و برای آی‌پی هم می‌توان گواهی معتبر Let's Encrypt گرفت.
  ───────────────────────────────────────────────────────────────────────
TXT
  local has_domain="n"
  if [[ -n "$WIZ_DOMAIN" ]]; then
    has_domain="y"
  elif [[ "$VT_ASSUME_YES" == "1" ]]; then
    has_domain="n"
  else
    if confirm "دامنه دارید و به این سرور اشاره می‌کند؟" n; then has_domain="y"; fi
  fi

  if [[ "$has_domain" == "y" ]]; then
    local domain="$WIZ_DOMAIN"
    if [[ -z "$domain" ]]; then
      ask domain "نام دامنه (مثلاً tunnel.example.com)" ""
    fi
    domain="${domain,,}"; domain="${domain#*.}"; domain="${domain%.}"
    while ! is_valid_domain "$domain"; do
      log_err "«$domain» یک دامنه معتبر نیست."
      ask domain "نام دامنه" ""
      domain="${domain,,}"
    done

    log_info "بررسی رکورد DNS برای $domain ..."
    local res; res=$(check_domain_points_here "$domain") || true
    case "$res" in
      ok)       log_ok "DNS درست است و به همین سرور اشاره می‌کند." ;;
      nodns)
        log_warn "رکورد A برای $domain پیدا نشد."
        log_note "اگر از Cloudflare/... استفاده می‌کنید می‌توانیم با روش DNS گواهی بگیریم."
        ;;
      mismatch:*)
        log_warn "دامنه به ${res#mismatch:} اشاره می‌کند، نه به این سرور (${VT_DETECTED_IP})."
        ;;
    esac
    WIZ_DOMAIN="$domain"
  else
    WIZ_DOMAIN=""
  fi
}

# --------------------------------------------------------------------------
# Question 2 — certificate strategy + tunnel mode
# --------------------------------------------------------------------------
wizard_ask_mode() {
  cat <<'TXT'

  ── گام ۲: نوع اتصال و گواهی SSL ───────────────────────────────────────
   1) REALITY  — بدون دامنه، بدون گواهی، روی آی‌پی کار می‌کند.
                 ترافیک شبیه یک سایت HTTPS واقعی است. (پیشنهاد ما)
   2) WebSocket + TLS روی پورت 443 — شبیه‌ترین حالت به وب‌سایت معمولی؛
                 نیاز به گواهی SSL دارد (دامنه یا گواهی مخصوص آی‌پی).
   3) TCP + TLS روی پورت دلخواه — نیاز به گواهی SSL دارد.
  ───────────────────────────────────────────────────────────────────────
TXT
  local def=1
  if [[ -n "$WIZ_MODE" ]]; then
    case "$WIZ_MODE" in
      reality) def=1 ;; ws-tls) def=2 ;; tcp-tls) def=3 ;;
    esac
  fi
  local idx
  menu_pick idx "حالت تونل را انتخاب کنید:" \
    "REALITY (بدون گواهی — پیشنهادی)" \
    "WebSocket + TLS (پورت 443)" \
    "TCP + TLS (پورت دلخواه)"
  if [[ -n "$WIZ_MODE" ]]; then idx="$def"; fi

  case "$idx" in
    1) VT_MODE="reality"; VT_FLOW="xtls-rprx-vision" ;;
    2) VT_MODE="ws-tls";  VT_FLOW="" ;;
    3) VT_MODE="tcp-tls"; VT_FLOW="xtls-rprx-vision" ;;
  esac
  log_ok "حالت انتخاب‌شده: ${VT_MODE}"

  if [[ "$VT_MODE" == "reality" ]]; then
    VT_CERT_MODE="none"
    VT_SELF_SIGNED="0"
    wizard_ask_reality_target
    return 0
  fi

  wizard_ask_cert
}

wizard_ask_reality_target() {
  cat <<'TXT'

  REALITY ترافیک شما را پشت دست‌دادن TLS با یک سایت واقعی پنهان می‌کند.
  سایت انتخابی باید TLS 1.3 پشتیبانی کند و در منطقه شما فیلتر نباشد.
TXT
  local def="www.microsoft.com"
  if [[ -n "$WIZ_SNI" ]]; then def="$WIZ_SNI"; fi
  ask WIZ_SNI "دامنه‌ی استتار (SNI)" "$def"
  WIZ_SNI="${WIZ_SNI,,}"
  WIZ_SNI="${WIZ_SNI#https://}"; WIZ_SNI="${WIZ_SNI#http://}"; WIZ_SNI="${WIZ_SNI%%/*}"

  log_info "بررسی $WIZ_SNI ..."
  local res; res=$(check_reality_target "$WIZ_SNI" 443) || true
  case "$res" in
    ok) log_ok "$WIZ_SNI برای REALITY مناسب است (TLS 1.3 ✓)" ;;
    offline)    log_note "حالت آفلاین: بررسی سایت استتار رد شد." ;;
    no-openssl) log_warn "openssl نیست، بررسی انجام نشد." ;;
    *)
      log_warn "$WIZ_SNI مناسب به نظر نمی‌رسد (${res})."
      if confirm "با این حال از همین استفاده شود؟" n; then :
      else
        ask WIZ_SNI "دامنه‌ی استتار" "www.apple.com"
        WIZ_SNI="${WIZ_SNI,,}"
      fi
      ;;
  esac
  VT_REALITY_SNI="$WIZ_SNI"
  VT_REALITY_DEST="${WIZ_SNI}:443"
  VT_HOST="${VT_DETECTED_IP}"
  VT_TLS_SNI="$WIZ_SNI"
}

wizard_ask_cert() {
  local cert=""
  if [[ -n "$WIZ_CERT" ]]; then
    cert="$WIZ_CERT"
  elif [[ -n "$WIZ_DOMAIN" ]]; then
    cert="letsencrypt-domain"
  else
    cat <<'TXT'

  ── گواهی SSL برای آی‌پی ───────────────────────────────────────────────
   1) Let's Encrypt مخصوص آی‌پی — گواهی معتبر و رایگان، بدون دامنه.
      از ژانویه ۲۰۲۶ در دسترس عموم است؛ اعتبارش ~۶ روز است و هر ۳ روز
      خودکار تمدید می‌شود. نیاز دارد پورت 80 باز باشد.
   2) گواهی خودامضا — بدون نیاز به پورت 80، ولی کلاینت باید
      allowInsecure را فعال کند.
  ───────────────────────────────────────────────────────────────────────
TXT
    local cidx
    menu_pick cidx "کدام گواهی؟" \
      "Let's Encrypt برای آی‌پی (معتبر، تمدید خودکار)" \
      "خودامضا (ساده، بدون پورت 80)"
    case "$cidx" in
      1) cert="letsencrypt-ip" ;;
      2) cert="selfsigned" ;;
    esac
  fi
  [[ "$VT_ASSUME_YES" == "1" && -z "$cert" ]] && cert="selfsigned"

  VT_CERT_MODE="$cert"
  VT_HOST="${WIZ_DOMAIN:-${VT_DETECTED_IP}}"
  VT_TLS_SNI="$VT_HOST"
  if is_ip "$VT_HOST"; then
    # Clients do not send SNI for a bare IP address.
    VT_REJECT_UNKNOWN_SNI="0"
  else
    VT_REJECT_UNKNOWN_SNI="1"
  fi
  if [[ "$cert" == "selfsigned" ]]; then VT_SELF_SIGNED="1"; else VT_SELF_SIGNED="0"; fi
  log_ok "منبع گواهی: $cert   میزبان: $VT_HOST"

  if [[ "$cert" == "letsencrypt-domain" ]]; then
    wizard_ask_acme_method
  fi
}

wizard_ask_acme_method() {
  cat <<'TXT'

  روش تأیید مالکیت دامنه:
   1) Standalone — اسکریپت خودش موقتاً پورت 80 را باز می‌کند.
                   ساده‌ترین حالت؛ پورت 80 باید آزاد و باز باشد.
   2) Webroot    — فایل تأیید داخل پوشه یک وب‌سرور در حال اجرا گذاشته می‌شود.
   3) DNS        — از طریق API سرویس DNS (مثل Cloudflare). پورت 80 لازم نیست
                   و حتی اگر دامنه هنوز به این سرور اشاره نکند کار می‌کند.
  ───────────────────────────────────────────────────────────────────────
TXT
  local midx=1
  case "$WIZ_ACME_METHOD" in
    standalone) midx=1 ;; webroot) midx=2 ;; dns) midx=3 ;;
  esac
  if [[ -z "$WIZ_ACME_METHOD" && "$VT_ASSUME_YES" != "1" ]]; then
    menu_pick midx "کدام روش؟" "Standalone (پورت 80)" "Webroot" "DNS API"
  fi
  case "$midx" in
    1) WIZ_ACME_METHOD="standalone" ;;
    2) WIZ_ACME_METHOD="webroot"
       ask WIZ_WEBROOT "مسیر webroot" "/var/www/html" ;;
    3) WIZ_ACME_METHOD="dns"
       ask WIZ_DNS_PROVIDER "نام پلاگین acme.sh" "dns_cf"
       case "$WIZ_DNS_PROVIDER" in
         dns_cf) ask_secret WIZ_DNS_TOKEN "توکن Cloudflare (CF_Token)" ;;
         *) ask WIZ_DNS_ENV "نام متغیر محیطی موردنیاز پلاگین" "CF_Token"
            ask_secret WIZ_DNS_TOKEN "مقدار متغیر" ;;
       esac
       ;;
  esac
  log_ok "روش صدور گواهی: $WIZ_ACME_METHOD"
}

# --------------------------------------------------------------------------
# Question 3 — port
# --------------------------------------------------------------------------
wizard_ask_port() {
  local def=""
  case "$VT_MODE" in
    ws-tls) def=443 ;;
    *) def="random" ;;
  esac
  local ans="$WIZ_PORT"
  if [[ -z "$ans" ]]; then
    if [[ "$VT_ASSUME_YES" == "1" ]]; then
      ans="$def"
    else
      ask ans "پورت تونل (عدد یا random)" "$def"
    fi
  fi
  if [[ "$ans" == "random" || "$ans" == "رندم" ]]; then
    VT_PORT="$(random_port "${VT_API_PORT:-}" 80 443 "$VT_SSH_PORT")"
    log_ok "پورت تصادفی انتخاب شد: ${VT_PORT}"
  elif [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= 65535 )); then
    VT_PORT="$ans"
    if port_in_use "$VT_PORT"; then
      log_warn "پورت $VT_PORT در حال استفاده است؛ یک پورت تصادفی انتخاب می‌شود."
      VT_PORT="$(random_port "${VT_API_PORT:-}" 80 443 "$VT_SSH_PORT")"
    fi
  else
    log_warn "«$ans» پورت معتبری نیست؛ پورت تصادفی انتخاب می‌شود."
    VT_PORT="$(random_port "${VT_API_PORT:-}" 80 443 "$VT_SSH_PORT")"
  fi

  # Internal API, only reachable from localhost.
  VT_API_PORT="$(random_port "$VT_PORT")"

  if [[ "$VT_MODE" == "ws-tls" ]]; then
    VT_WS_PATH="/$(rand_hex 16)/"
    log_ok "مسیر WebSocket: ${VT_WS_PATH}"
  else
    VT_WS_PATH=""
  fi
}

# --------------------------------------------------------------------------
# Question 4 — first user
# --------------------------------------------------------------------------
wizard_ask_email() {
  if [[ -n "$WIZ_EMAIL" ]]; then
    VT_EMAIL="$WIZ_EMAIL"
  else
    ask VT_EMAIL "نام کاربر اول" "main"
  fi
  VT_EMAIL="${VT_EMAIL//[^a-zA-Z0-9._-]/}"
  [[ -n "$VT_EMAIL" ]] || VT_EMAIL="main"
  log_ok "کاربر اول: $VT_EMAIL"
}

# --------------------------------------------------------------------------
# Question 5 — extras
# --------------------------------------------------------------------------
wizard_ask_extras() {
  if [[ -n "$WIZ_FIREWALL" && "$WIZ_FIREWALL" != "ask" ]]; then
    VT_FIREWALL="$WIZ_FIREWALL"
  elif [[ "$VT_ASSUME_YES" == "1" ]]; then
    VT_FIREWALL="no"
  else
    if confirm "فایروال UFW فعال و فقط پورت‌های لازم باز شود؟ (SSH=${VT_SSH_PORT})" y; then
      VT_FIREWALL="yes"
    else
      VT_FIREWALL="no"
    fi
  fi

  if [[ "$VT_ASSUME_YES" != "1" ]]; then
    if confirm "تبلیغات و ردیاب‌ها مسدود شود؟ (نیاز به دانلود geosite)" n; then
      VT_AD_BLOCK="1"
    else
      VT_AD_BLOCK="0"
    fi
    if confirm "ترافیک BitTorrent/دانلود سنگین مسدود شود؟" n; then
      VT_BLOCK_TORRENT="1"
    else
      VT_BLOCK_TORRENT="0"
    fi
  else
    VT_AD_BLOCK="$WIZ_AD_BLOCK"
    VT_BLOCK_TORRENT="$WIZ_BLOCK_TORRENT"
  fi
}

# --------------------------------------------------------------------------
# The install itself
# --------------------------------------------------------------------------
do_install() {
  local logfile; logfile="$(p "$R_LOG")/install.log"
  mkdir -p "$(dirname "$logfile")"
  VT_LOG_FILE="$logfile"
  printf '%s === install started ===\n' "$(_ts)" >>"$logfile"

  preflight
  sysprep_all

  wizard_ask_domain
  wizard_ask_mode
  wizard_ask_port
  wizard_ask_email
  wizard_ask_extras

  log_step "نصب Xray-core"
  if [[ "$VT_SKIP_DOWNLOADS" == "1" ]]; then
    log_note "[dry] دانلود Xray رد شد."
    mkdir -p "$(p "$(dirname "$R_XRAY_BIN")")" "$(p "$R_XRAY_ASSETS")"
    if [[ ! -e "$(p "$R_XRAY_BIN")" ]]; then
      cat >"$(p "$R_XRAY_BIN")" <<'STUB'
#!/bin/sh
# Placeholder used by the offline test-suite; replaced by the real binary on
# a machine with internet access.
case "$1" in
  version) echo "Xray 0.0.0 (stub)"; exit 0 ;;
  -test)   exit 0 ;;
  # Everything else (x25519, api, ...) exits non-zero on purpose so the
  # caller falls back to its own implementation.
esac
exit 1
STUB
      chmod +x "$(p "$R_XRAY_BIN")"
    fi
  else
    download_and_install_xray
  fi

  log_step "ساخت کلیدها"
  users_init
  users_add "$VT_EMAIL" "$(gen_uuid)" "$VT_EMAIL" || log_note "کاربر از قبل ثبت شده بود."

  case "$VT_MODE" in
    reality)
      gen_x25519 || fail "ساخت کلید X25519 ناموفق بود."
      VT_REALITY_PRIVATE="$X25519_PRIVATE"
      VT_REALITY_PUBLIC="$X25519_PUBLIC"
      VT_REALITY_SHORTID="$(rand_hex 16)"
      log_ok "کلید REALITY ساخته شد."
      ;;
    ws-tls|tcp-tls)
      VT_REALITY_PRIVATE=""; VT_REALITY_PUBLIC=""; VT_REALITY_SHORTID=""
      obtain_certificate
      ;;
  esac

  if [[ "$VT_AD_BLOCK" == "1" ]]; then
    log_step "دریافت پایگاه‌داده مسدودسازی تبلیغات"
    if [[ "$VT_SKIP_DOWNLOADS" == "1" ]]; then
      log_note "[dry] geo assets رد شد."
      VT_AD_BLOCK="0"
    elif download_geo_assets; then
      log_ok "geosite/geoip دریافت شد."
    else
      log_warn "دریافت ناموفق بود — مسدودسازی تبلیغات غیرفعال می‌ماند."
      VT_AD_BLOCK="0"
    fi
  fi

  log_step "نوشتن پیکربندی"
  sysprep_dirs
  build_xray_config "$VT_MODE" "$(p "$R_XRAY_CONF")"
  chmod 600 "$(p "$R_XRAY_CONF")"
  log_ok "پیکربندی نوشته شد: $R_XRAY_CONF"
  xray_test_config "$(p "$R_XRAY_CONF")" || fail "پیکربندی Xray نامعتبر است."

  log_step "ساخت سرویس همیشه‌فعال"
  write_xray_unit
  write_health_units
  write_cert_timer_units

  log_step "ذخیره وضعیت نصب"
  VT_INSTALLED_AT="$(date -Is)"
  VT_XRAY_VERSION="$(xray_installed_version 2>/dev/null || echo unknown)"
  VT_PUBLIC_IP="$VT_DETECTED_IP"
  VT_PUBLIC_IPV6="${VT_DETECTED_IPV6:-}"
  VT_SSH_PORT="${VT_SSH_PORT:-22}"
  state_save || fail "ذخیره وضعیت نصب ناموفق بود."

  enable_services

  if [[ "$VT_FIREWALL" == "yes" ]]; then
    log_step "تنظیم فایروال"
    local -a extra=()
    if [[ "${VT_CERT_MODE:-}" == "letsencrypt-ip" || "$WIZ_ACME_METHOD" == "standalone" ]]; then
      extra+=(80)
    fi
    firewall_setup "$VT_SSH_PORT" "$VT_PORT" "${extra[@]}"
  fi

  # Make sure the tunnel really came up before we hand over the config.
  sleep 2
  if xray_is_active; then
    log_ok "تونل در حال اجراست."
  else
    log_warn "سرویس فعال نشد — با «vt logs» لاگ را ببینید."
  fi

  write_client_config "$VT_EMAIL" "$(p "$R_ETC")/client.json" >/dev/null || true

  # vt-health.timer and vt-cert-renew.timer call /opt/vt/vt, so the program
  # must actually live there.
  log_step "نصب خودِ برنامه در $R_INSTALL_DIR"
  cmd_self_install || log_warn "کپی برنامه به $R_INSTALL_DIR ناموفق بود؛ تایمرها کار نخواهند کرد."

  printf '%s === install finished ===\n' "$(_ts)" >>"$logfile"
  print_full_config yes
}

# Certificate acquisition for the TLS modes.
obtain_certificate() {
  log_step "تهیه گواهی SSL رایگان"
  if [[ "$VT_CERT_MODE" == letsencrypt-* ]]; then
    ask_acme_email
  fi
  case "$VT_CERT_MODE" in
    letsencrypt-domain)
      install_pkgs socat
      case "$WIZ_ACME_METHOD" in
        standalone) cert_issue_domain "$VT_HOST" "$VT_ACME_EMAIL" standalone ;;
        webroot)    cert_issue_domain "$VT_HOST" "$VT_ACME_EMAIL" webroot "${WIZ_WEBROOT:-/var/www/html}" ;;
        dns)        cert_issue_domain "$VT_HOST" "$VT_ACME_EMAIL" dns \
                      "$WIZ_DNS_PROVIDER" "${WIZ_DNS_ENV:-CF_Token}" "$WIZ_DNS_TOKEN" ;;
      esac || {
        log_warn "صدور گواهی ناموفق بود."
        if confirm "به‌جایش گواهی خودامضا بسازیم؟ (کلاینت باید allowInsecure بزند)" y; then
          cert_issue_selfsigned "$VT_HOST" 825
          VT_CERT_MODE="selfsigned"; VT_SELF_SIGNED="1"; VT_REJECT_UNKNOWN_SNI="0"
        else
          fail "بدون گواهی نمی‌توان ادامه داد."
        fi
      }
      ;;
    letsencrypt-ip)
      install_pkgs socat
      if ! cert_issue_ip "$VT_HOST" "$VT_ACME_EMAIL"; then
        log_warn "گواهی Let's Encrypt برای آی‌پی صادر نشد (ممکن است حساب شما هنوز"
        log_warn "مجاز به گواهی آی‌پی نباشد یا پورت 80 بسته باشد)."
        if confirm "به‌جایش گواهی خودامضا بسازیم؟" y; then
          cert_issue_selfsigned "$VT_HOST" 825
          VT_CERT_MODE="selfsigned"; VT_SELF_SIGNED="1"
        else
          fail "بدون گواهی نمی‌توان ادامه داد."
        fi
      fi
      ;;
    selfsigned)
      cert_issue_selfsigned "$VT_HOST" 825
      ;;
    none) : ;;
    *) fail "حالت گواهی نامعتبر: $VT_CERT_MODE" ;;
  esac
}

# Ask once for the ACME account e-mail (Let's Encrypt sends expiry notices).
ask_acme_email() {
  [[ -z "${VT_ACME_EMAIL:-}" ]] || return 0
  local e=""
  if [[ "$VT_ASSUME_YES" == "1" ]]; then
    e="admin@${VT_HOST:-localhost}"
  else
    ask e "ایمیل برای ثبت‌نام Let's Encrypt (اختیاری)" "admin@${VT_HOST:-localhost}"
  fi
  [[ "$e" == *@*.* ]] || e="admin@${VT_HOST:-localhost}"
  VT_ACME_EMAIL="$e"
}
