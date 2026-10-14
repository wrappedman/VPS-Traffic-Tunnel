#!/usr/bin/env bash
# menu.sh — the interactive menu shown when `vt` runs with no arguments.

banner() {
  clear 2>/dev/null || true
  cat <<BANNER
${C_CYAN}${C_BOLD}
  ██╗   ██╗████████╗    ████████╗██████╗  █████╗  ██████╗ ██████╗
  ██║   ██║╚══██╔══╝    ╚══██╔══╝██╔══██╗██╔══██╗██╔════╝ ██╔══██╗
  ██║   ██║   ██║          ██║   ██████╔╝███████║██║  ███╗██████╔╝
  ╚██╗ ██╔╝   ██║          ██║   ██╔══██╗██╔══██║██║   ██║██╔══██╗
   ╚████╔╝    ██║          ██║   ██║  ██║██║  ██║╚██████╔╝██║  ██║
    ╚═══╝     ╚═╝          ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝
${C_RESET}${C_DIM}
  ${VT_PROJECT} v${VT_VERSION} — تونل VLESS همیشه‌فعال برای VPS
${C_RESET}
BANNER
}

status_line() {
  if is_installed; then
    local st="${C_RED}متوقف${C_RESET}"
    xray_is_active && st="${C_GREEN}در حال اجرا${C_RESET}"
    printf '  وضعیت: %s   |   حالت: %s   |   آدرس: %s:%s\n\n' \
      "$st" "${VT_MODE:-?}" "${VT_HOST:-?}" "${VT_PORT:-?}"
  else
    printf '  وضعیت: %s\n\n' "${C_YELLOW}نصب نشده${C_RESET}"
  fi
}

main_menu() {
  while true; do
    banner
    status_line
    cat <<MENU
  ${C_BOLD}گزینه‌های اصلی${C_RESET}
   ${C_GREEN}1)${C_RESET} install      — نصب تونل و سرویس همیشه‌فعال (با پرسش دامنه و SSL)
   ${C_GREEN}2)${C_RESET} viewConfig   — نمایش کانفیگ، لینک اشتراک و کد QR
   ${C_GREEN}3)${C_RESET} uninstall    — حذف کامل تونل از سیستم

  ${C_BOLD}مدیریت${C_RESET}
   ${C_CYAN}4)${C_RESET} افزودن کاربر جدید
   ${C_CYAN}5)${C_RESET} حذف کاربر
   ${C_CYAN}6)${C_RESET} لیست کاربران و لینک‌ها
   ${C_CYAN}7)${C_RESET} ترافیک مصرفی و اتصالات فعال
   ${C_CYAN}8)${C_RESET} تغییر پورت تونل
   ${C_CYAN}9)${C_RESET} تغییر UUID کاربر
  ${C_CYAN}10)${C_RESET} تغییر حالت (REALITY / WS-TLS / TCP-TLS)

  ${C_BOLD}گواهی SSL${C_RESET}
  ${C_CYAN}11)${C_RESET} تمدید دستی گواهی و نمایش وضعیت
  ${C_CYAN}12)${C_RESET} ساخت گواهی خودامضای جدید

  ${C_BOLD}سرویس و سیستم${C_RESET}
  ${C_CYAN}13)${C_RESET} وضعیت سرویس (status)
  ${C_CYAN}14)${C_RESET} راه‌اندازی مجدد / توقف / اجرا
  ${C_CYAN}15)${C_RESET} نمایش لاگ‌ها
  ${C_CYAN}16)${C_RESET} به‌روزرسانی Xray-core
  ${C_CYAN}17)${C_RESET} عیب‌یابی (doctor)
  ${C_CYAN}18)${C_RESET} پشتیبان‌گیری / بازگردانی

   ${C_YELLOW}0)${C_RESET} خروج

MENU
    local choice
    if [[ "$VT_ASSUME_YES" == "1" ]]; then
      return 0
    fi
    printf '%s' "${C_BOLD}انتخاب شما${C_RESET} [0]: "
    IFS= read -r choice || choice=0
    choice="${choice:-0}"
    case "$choice" in
      1)  _guard_installed && { do_install; pause; } || true ;;
      2)  _need_installed && { cmd_view_config; pause; } ;;
      3)  _need_installed && { cmd_uninstall; pause; } ;;
      4)  _need_installed && { cmd_add_user; pause; } ;;
      5)  _need_installed && { cmd_remove_user; pause; } ;;
      6)  _need_installed && { cmd_list_users; pause; } ;;
      7)  _need_installed && { cmd_stats || true; cmd_connections || true; pause; } ;;
      8)  _need_installed && { cmd_change_port; pause; } ;;
      9)  _need_installed && { cmd_rotate_uuid; pause; } ;;
      10) _need_installed && { cmd_switch_mode; pause; } ;;
      11) _need_installed && { cmd_renew_cert; pause; } ;;
      12) _need_installed && { _selfsigned_now; pause; } ;;
      13) _need_installed && { cmd_status; pause; } ;;
      14) _need_installed && { _svc_menu; } ;;
      15) _need_installed && { _log_menu; } ;;
      16) _need_installed && { cmd_update; pause; } ;;
      17) _need_installed && { cmd_doctor; pause; } ;;
      18) _need_installed && { _backup_menu; } ;;
      0|q|quit|exit) log_info "خداحافظ."; return 0 ;;
      *) log_warn "گزینه نامعتبر."; sleep 1 ;;
    esac
  done
}

_guard_installed() {
  if is_installed; then
    log_warn "سیستم از قبل نصب شده است."
    if confirm "کانفیگ موجود پاک و نصب از نو انجام شود؟" n; then
      cmd_uninstall || return 1
      return 0
    fi
    return 1
  fi
  return 0
}

_need_installed() {
  if is_installed; then
    return 0
  fi
  log_warn "ابتدا گزینه‌ی install را اجرا کنید."
  sleep 2
  return 1
}

_selfsigned_now() {
  local host="${VT_HOST:-$(detect_public_ipv4 || echo localhost)}"
  cert_issue_selfsigned "$host" 825 || return 1
  VT_CERT_MODE="selfsigned"; VT_SELF_SIGNED="1"; VT_REJECT_UNKNOWN_SNI="0"
  state_save
  apply_config || return 1
  log_ok "گواهی جدید ساخته و اعمال شد."
}

_svc_menu() {
  local c
  menu_pick c "سرویس:" "راه‌اندازی مجدد (restart)" "توقف (stop)" "اجرا (start)" "بازگشت"
  case "$c" in
    1) cmd_restart ;; 2) cmd_stop ;; 3) cmd_start ;; *) return 0 ;;
  esac
  pause
}

_log_menu() {
  local c
  menu_pick c "کدام لاگ؟" \
    "سرویس Xray (journalctl)" "خطاهای Xray" "بررسی سلامت" \
    "تمدید گواهی" "نصب" "پیگیری زنده (follow)" "بازگشت"
  case "$c" in
    1) cmd_logs xray ;;    2) cmd_logs error ;;  3) cmd_logs health ;;
    4) cmd_logs cert ;;    5) cmd_logs install ;; 6) cmd_logs follow ;;
    *) return 0 ;;
  esac
  pause
}

_backup_menu() {
  local c
  menu_pick c "پشتیبان‌گیری:" "ساخت پشتیبان" "بازگردانی از فایل" "بازگشت"
  case "$c" in
    1) cmd_backup ;;
    2) local f; ask f "مسیر فایل پشتیبان" ""
       [[ -n "$f" ]] && cmd_restore "$f" ;;
    *) return 0 ;;
  esac
  pause
}

usage() {
  cat <<USAGE
${C_BOLD}${VT_PROJECT}${C_RESET} v${VT_VERSION} — تونل VLESS همیشه‌فعال روی VPS

${C_BOLD}روش استفاده:${C_RESET}
  vt                         نمایش منوی تعاملی
  vt <command> [options]

${C_BOLD}دستورات اصلی:${C_RESET}
  install                    نصب تونل + سرویس همیشه‌فعال
  viewconfig | config        نمایش کانفیگ، لینک اشتراک و QR
  uninstall                  حذف کامل

${C_BOLD}گزینه‌های install (برای نصب خودکار بدون پرسش):${C_RESET}
  --mode <reality|ws-tls|tcp-tls>
  --domain <domain>          استفاده از دامنه (گواهی Let's Encrypt)
  --acme <standalone|webroot|dns>
  --webroot <path>
  --dns-plugin <dns_cf> --dns-env <CF_Token> --dns-token <token>
  --cert <letsencrypt-domain|letsencrypt-ip|selfsigned|none>
  --sni <domain>             سایت استتار برای REALITY
  --port <n|random>
  --email <name>             نام کاربر اول
  --email-acme <addr>        ایمیل حساب Let's Encrypt
  --firewall <yes|no>
  --adblock <yes|no>
  --no-torrent <yes|no>
  --yes                      بدون پرسش، با مقادیر پیش‌فرض

${C_BOLD}مدیریت:${C_RESET}
  add-user [name]            rm-user [name]        users
  stats                      connections           rotate-uuid [name]
  rotate-keys                port <n|random>       switch-mode
  update                     renew-cert            selfsigned-cert

${C_BOLD}سرویس:${C_RESET}
  status                     restart | stop | start
  logs [xray|error|health|cert|install|follow]
  doctor                     health [--quiet]
  backup [dir]               restore <file>
  self-install               نصب خودِ برنامه در ${R_INSTALL_DIR}

${C_BOLD}متغیرهای محیطی:${C_RESET}
  VT_ASSUME_YES=1            پاسخ پیش‌فرض به همه‌ی پرسش‌ها
  VT_SKIP_DOWNLOADS=1        بدون دسترسی به اینترنت (برای تست)
  VT_SKIP_APT=1              بدون apt-get
  VT_SKIP_SYSTEMD=1          بدون systemctl
  VT_ROOT=/path              نصب در یک ریشه‌ی جایگزین (برای تست)

USAGE
}

# Copy the program itself to /opt/vt so the systemd timers can call it.
cmd_self_install() {
  local src dst link
  # VT_DIR is resolved by the `vt` entry point; BASH_SOURCE here would point at
  # lib/menu.sh instead of the program itself.
  src="${VT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  dst="$(p "$R_INSTALL_DIR")"
  link="$(p /usr/local/bin/vt)"
  if [[ "$src" == "$dst" ]]; then
    log_ok "برنامه از قبل در $R_INSTALL_DIR است."
  else
    log_info "کپی برنامه به $R_INSTALL_DIR ..."
    mkdir -p "$dst"
    cp -a "$src/." "$dst/" || die "کپی ناموفق بود."
    chmod +x "$dst/vt"
    log_ok "کپی شد."
  fi
  mkdir -p "$(dirname "$link")"
  ln -sf "$R_INSTALL_DIR/vt" "$link"
  log_ok "دستور «vt» در PATH قرار گرفت: $link"
  log_note "حالا می‌توانید از هر مسیری فقط بنویسید: vt"
}
