#!/usr/bin/env bash
# status.sh — reporting and day-2 operations.

cmd_status() {
  if ! is_installed; then
    log_warn "هنوز نصبی انجام نشده. با «vt install» شروع کنید."
    return 0
  fi
  printf '\n'
  box "وضعیت ${VT_PROJECT}" \
    "نسخه برنامه   : ${VT_VERSION}" \
    "نصب‌شده در    : ${VT_INSTALLED_AT:-?}" \
    "آی‌پی عمومی   : ${VT_PUBLIC_IP:-?}" \
    "پورت SSH      : ${VT_SSH_PORT:-?}"
  printf '\n'
  show_service_status
  printf '\n'
  if xray_is_active; then
    cmd_stats 2>/dev/null || true
  fi
}

cmd_view_config() {
  if ! is_installed; then
    die "هنوز نصبی انجام نشده. با «vt install» شروع کنید."
  fi
  print_full_config "${1:-yes}"
  log_note "کانفیگ متنی در این مسیر هم ذخیره است: $R_ETC/config.txt"
  log_note "کانفیگ آماده‌ی کلاینت دسکتاپ:  $R_ETC/client.json"
}

cmd_logs() {
  local what="${1:-xray}"
  case "$what" in
    xray|service)
      if systemd_running; then
        journalctl -u xray.service -n "${VT_LOG_LINES:-100}" --no-pager
      elif [[ -f "$(p "$R_LOG")/xray-error.log" ]]; then
        tail -n "${VT_LOG_LINES:-100}" "$(p "$R_LOG")/xray-error.log"
      else
        log_warn "لاگی پیدا نشد."
      fi
      ;;
    error)
      tail -n "${VT_LOG_LINES:-100}" "$(p "$R_LOG")/xray-error.log" 2>/dev/null \
        || log_warn "لاگ خطا پیدا نشد."
      ;;
    health)
      tail -n "${VT_LOG_LINES:-100}" "$(p "$R_LOG")/health.log" 2>/dev/null \
        || log_warn "لاگ سلامت پیدا نشد."
      ;;
    cert)
      tail -n "${VT_LOG_LINES:-100}" "$(p "$R_LOG")/cert-renew.log" 2>/dev/null \
        || log_warn "لاگ گواهی پیدا نشد."
      ;;
    install)
      tail -n "${VT_LOG_LINES:-200}" "$(p "$R_LOG")/install.log" 2>/dev/null \
        || log_warn "لاگ نصب پیدا نشد."
      ;;
    follow|-f)
      systemd_running || die "journalctl فقط با systemd کار می‌کند."
      journalctl -u xray.service -f
      ;;
    *)
      die "لاگ ناشناخته: $what (مقادیر: xray|error|health|cert|install|follow)"
      ;;
  esac
}

cmd_restart() {
  sysd restart xray.service || die "راه‌اندازی مجدد ناموفق بود."
  sleep 1
  if xray_is_active; then log_ok "سرویس دوباره اجرا شد."; else log_err "سرویس بالا نیامد."; fi
}

cmd_stop()   { sysd stop xray.service;    log_ok "سرویس متوقف شد."; }
cmd_start()  {
  sysd start xray.service
  sleep 1
  if xray_is_active; then log_ok "سرویس اجرا شد."; else log_err "سرویس بالا نیامد."; fi
}

cmd_change_port() {
  local newport="${1:-}"
  local old="${VT_PORT}"
  if [[ -z "$newport" ]]; then
    ask newport "پورت جدید (عدد یا random)" "random"
  fi
  if [[ "$newport" == "random" ]]; then
    newport="$(random_port "$VT_API_PORT" 80 443 "$VT_SSH_PORT")"
  fi
  if ! [[ "$newport" =~ ^[0-9]+$ ]] || (( newport < 1 || newport > 65535 )); then
    die "پورت نامعتبر: $newport"
  fi
  if port_in_use "$newport"; then
    die "پورت $newport در حال استفاده است."
  fi
  VT_PORT="$newport"
  apply_config || die "اعمال پیکربندی ناموفق بود."
  firewall_close_port "$old"
  firewall_open_port "$newport" 'VT tunnel'
  state_save
  log_ok "پورت از $old به $newport تغییر کرد."
  log_warn "کانفیگ کلاینت‌ها را به‌روزرسانی کنید."
}

cmd_renew_cert() {
  local quiet="no"
  [[ "${1:-}" == "--quiet" ]] && quiet="yes"
  if [[ "${VT_CERT_MODE:-none}" == "none" ]]; then
    if [[ "$quiet" != "yes" ]]; then
      log_info "این نصب از REALITY استفاده می‌کند و گواهی SSL ندارد."
    fi
    return 0
  fi
  cert_renew
  if [[ "$quiet" != "yes" ]]; then
    log_info "وضعیت گواهی: $(cert_summary)"
  fi
}

cmd_update() {
  log_step "به‌روزرسانی Xray-core"
  local old new
  old="$(xray_installed_version 2>/dev/null || echo none)"
  if [[ "$VT_SKIP_DOWNLOADS" == "1" ]]; then
    log_note "[dry] به‌روزرسانی رد شد."
    return 0
  fi
  download_and_install_xray
  new="$(xray_installed_version 2>/dev/null || echo unknown)"
  VT_XRAY_VERSION="$new"
  state_save
  if xray_test_config "$(p "$R_XRAY_CONF")"; then
    sysd restart xray.service || true
    log_ok "به‌روزرسانی انجام شد: ${old} → ${new}"
  else
    log_err "پیکربندی با نسخه جدید سازگار نیست؛ سرویس راه‌اندازی مجدد نشد."
  fi
}

cmd_switch_mode() {
  cat <<'TXT'

  تغییر حالت، کانفیگ همه‌ی کلاینت‌ها را باطل می‌کند.
TXT
  local cur="${VT_MODE:-?}"
  local idx
  menu_pick idx "حالت فعلی: ${cur} — حالت جدید:" \
    "REALITY" "WebSocket + TLS" "TCP + TLS"
  local new
  case "$idx" in
    1) new="reality" ;; 2) new="ws-tls" ;; 3) new="tcp-tls" ;;
  esac
  VT_MODE="$new"
  case "$new" in
    reality)
      VT_FLOW="xtls-rprx-vision"
      [[ -n "${VT_REALITY_PRIVATE:-}" ]] || {
        gen_x25519 || die "ساخت کلید ناموفق بود."
        VT_REALITY_PRIVATE="$X25519_PRIVATE"
        VT_REALITY_PUBLIC="$X25519_PUBLIC"
        VT_REALITY_SHORTID="$(rand_hex 16)"
      }
      [[ -n "${VT_REALITY_SNI:-}" ]] || VT_REALITY_SNI="www.microsoft.com"
      VT_REALITY_DEST="${VT_REALITY_SNI}:443"
      VT_HOST="${VT_PUBLIC_IP:-$(detect_public_ipv4 || echo 127.0.0.1)}"
      ;;
    ws-tls|tcp-tls)
      [[ "$new" == "ws-tls" ]] && VT_FLOW="" || VT_FLOW="xtls-rprx-vision"
      [[ -n "${VT_WS_PATH:-}" ]] || VT_WS_PATH="/$(rand_hex 16)/"
      if [[ -z "${VT_TLS_CERT_FILE:-}" || ! -f "$(cert_file)" ]]; then
        die "برای این حالت ابتدا گواهی SSL لازم است (vt renew-cert یا نصب دوباره)."
      fi
      ;;
  esac
  apply_config || die "اعمال ناموفق بود."
  state_save
  log_ok "حالت به ${new} تغییر کرد."
  print_full_config yes
}

cmd_rotate_keys() {
  if [[ "${VT_MODE:-}" != "reality" ]]; then
    die "این نصب از REALITY استفاده نمی‌کند؛ کلیدی برای چرخش وجود ندارد."
  fi
  gen_x25519 || die "ساخت کلید X25519 ناموفق بود."
  VT_REALITY_PRIVATE="$X25519_PRIVATE"
  VT_REALITY_PUBLIC="$X25519_PUBLIC"
  VT_REALITY_SHORTID="$(rand_hex 16)"
  apply_config || die "اعمال پیکربندی ناموفق بود."
  state_save
  log_ok "کلیدهای REALITY چرخش کردند."
  log_warn "کانفیگ همه‌ی کلاینت‌ها باطل شد — کانفیگ تازه را بگیرید."
  print_full_config yes
}

cmd_backup() {
  local dir="${1:-$(p "$R_ETC")/backup}"
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  local out="${dir}/vt-backup-${stamp}.tar.gz"
  mkdir -p "$dir"
  tar czf "$out" \
    -C "$(dirname "$(p "$R_ETC")")" "$(basename "$(p "$R_ETC")")" \
    -C "$(dirname "$(p "$R_XRAY_CONF")")" "$(basename "$(p "$R_XRAY_CONF")")" \
    2>/dev/null || tar czf "$out" -C "$(dirname "$(p "$R_ETC")")" "$(basename "$(p "$R_ETC")")"
  chmod 600 "$out"
  log_ok "پشتیبان ساخته شد: $out"
  printf '%s\n' "$out"
}

cmd_restore() {
  local file="$1"
  [[ -f "$file" ]] || die "فایل پیدا نشد: $file"
  if ! confirm "بازگردانی از $file — تنظیمات فعلی بازنویسی می‌شود. ادامه؟" n; then
    return 0
  fi
  disable_services
  tar xzf "$file" -C "$(dirname "$(p "$R_ETC")")" || die "بازگردانی ناموفق بود."
  state_load
  sysd daemon-reload || true
  enable_services
  log_ok "بازگردانی انجام شد."
}

cmd_doctor() {
  log_step "عیب‌یابی"
  local issues=0
  is_root || { log_err "با root اجرا نشده."; issues=$((issues + 1)); }

  if [[ -x "$(p "$R_XRAY_BIN")" ]]; then
    log_ok "باینری Xray: $($(p "$R_XRAY_BIN") version 2>/dev/null | head -n1)"
  else
    log_err "باینری Xray پیدا نشد ($R_XRAY_BIN)"; issues=$((issues + 1))
  fi

  if [[ -f "$(p "$R_XRAY_CONF")" ]]; then
    if validate_json_file "$(p "$R_XRAY_CONF")"; then
      log_ok "config.json JSON معتبری است."
      xray_test_config "$(p "$R_XRAY_CONF")" || issues=$((issues + 1))
    else
      log_err "config.json معتبر نیست."; issues=$((issues + 1))
    fi
  else
    log_err "config.json پیدا نشد."; issues=$((issues + 1))
  fi

  if xray_is_active; then log_ok "سرویس xray فعال است."
  else log_err "سرویس xray فعال نیست."; issues=$((issues + 1)); fi

  if [[ -n "${VT_PORT:-}" ]]; then
    if port_in_use "$VT_PORT"; then
      log_ok "پورت ${VT_PORT} در حال شنود است."
    else
      log_err "پورت ${VT_PORT} در حال شنود نیست."; issues=$((issues + 1))
    fi
  fi

  if have openssl && [[ "${VT_CERT_MODE:-none}" != "none" ]]; then
    local summary; summary=$(cert_summary)
    local days="${summary##*|}"
    if [[ "$days" =~ ^-?[0-9]+$ ]] && (( days > 0 )); then
      log_ok "گواهی معتبر است ($summary)"
    else
      log_err "گواهی مشکل دارد یا منقضی شده ($summary)"; issues=$((issues + 1))
    fi
  fi

  if [[ "$(date -u +%Y)" -lt 2020 ]]; then
    log_err "ساعت سیستم اشتباه است — TLS کار نخواهد کرد."; issues=$((issues + 1))
  else
    log_ok "ساعت سیستم: $(date -u '+%Y-%m-%d %H:%M UTC')"
  fi

  local ccur; ccur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')
  log_info "الگوریتم کنترل ازدحام: $ccur"

  if have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    log_info "فایروال فعال است:"
    ufw status numbered 2>/dev/null | sed 's/^/      /'
  else
    log_info "فایروال ufw فعال نیست."
  fi

  printf '\n'
  if (( issues == 0 )); then
    log_ok "همه‌چیز سالم به نظر می‌رسد."
  else
    log_warn "${issues} مورد نیاز به بررسی دارد. «vt logs error» را ببینید."
  fi
  return 0
}
