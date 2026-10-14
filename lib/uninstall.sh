#!/usr/bin/env bash
# uninstall.sh — remove everything the installer put on the machine.

cmd_uninstall() {
  if ! is_installed && [[ "$VT_FORCE" != "1" ]]; then
    die "نصبی پیدا نشد. (برای حذف اجباری: vt uninstall --force)"
  fi
  state_load

  cat <<BANNER

  ${C_YELLOW}حذف ${VT_PROJECT}${C_RESET}

  این کار انجام می‌شود:
    • توقف و حذف سرویس‌های systemd (xray, vt-health, vt-cert-renew)
    • حذف باینری Xray و پیکربندی آن
    • حذف قوانین فایروال مربوط به تونل
    • حذف cron/timer تمدید گواهی

BANNER
  if [[ "$VT_ASSUME_YES" != "1" ]]; then
    if confirm "ادامه می‌دهید؟" n; then :; else
      log_info "لغو شد."
      return 0
    fi
    local keep="y"
    if confirm "پوشه ${R_ETC} (گواهی‌ها، کاربران، state) هم حذف شود؟" n; then
      keep="n"
    fi
    VT_UNINSTALL_KEEP_ETC="$keep"
  fi
  VT_UNINSTALL_KEEP_ETC="${VT_UNINSTALL_KEEP_ETC:-y}"

  local remove_extra="n"
  if [[ "$VT_ASSUME_YES" != "1" ]]; then
    if confirm "تنظیمات سیستمی (BBR/sysctl و swap) هم برگردانده شود؟" n; then
      remove_extra="y"
    fi
  fi

  log_step "توقف سرویس‌ها"
  disable_services

  log_step "حذف واحدهای systemd"
  local u f
  for u in "$R_XRAY_SERVICE" "$R_VT_HEALTH_SERVICE" "$R_VT_HEALTH_TIMER" \
           "$R_VT_CERT_SERVICE" "$R_VT_CERT_TIMER"; do
    f=$(p "$u")
    if [[ -f "$f" ]]; then rm -f "$f"; log_ok "حذف شد: $u"; fi
  done
  sysd daemon-reload || true

  log_step "حذف فایروال"
  firewall_remove_vt_rules
  firewall_close_port 80

  log_step "حذف تمدید خودکار گواهی"
  if [[ -x "$(acme_bin)" ]]; then
    LE_WORKING_DIR="$(acme_home)" "$(acme_bin)" --home "$(acme_home)" \
      --remove-cron >/dev/null 2>&1 || true
  fi
  if crontab -l 2>/dev/null | grep -q 'acme.sh'; then
    crontab -l 2>/dev/null | grep -v 'acme.sh' | crontab - 2>/dev/null || true
    log_ok "cron مربوط به acme.sh حذف شد."
  fi

  log_step "حذف Xray"
  rm -f "$(p "$R_XRAY_BIN")"
  rm -rf "$(p "$R_XRAY_CONF_DIR")"
  rm -rf "$(p "$R_XRAY_ASSETS")"
  log_ok "Xray حذف شد."

  log_step "حذف logrotate"
  rm -f "$(p /etc/logrotate.d/vt-tunnel)"

  if [[ "$remove_extra" == "y" ]]; then
    log_step "بازگرداندن تنظیمات سیستمی"
    sysprep_remove_bbr
    sysprep_remove_swap
  fi

  if [[ "$VT_UNINSTALL_KEEP_ETC" == "n" ]]; then
    log_step "حذف ${R_ETC}"
    rm -rf "$(p "$R_ETC")"
    log_ok "حذف شد."
  else
    log_note "${R_ETC} نگه داشته شد (برای حذف دستی: rm -rf ${R_ETC})"
  fi

  rm -f "$(p "$R_LOG")"/xray-*.log 2>/dev/null || true

  cat <<DONE

  ${C_GREEN}حذف کامل شد.${C_RESET}
  ${C_DIM}برنامه‌ی ${VT_PROJECT} همچنان در ${R_INSTALL_DIR} باقی است؛
  برای حذف خودِ برنامه: rm -rf ${R_INSTALL_DIR} /usr/local/bin/vt${C_RESET}

DONE
}
