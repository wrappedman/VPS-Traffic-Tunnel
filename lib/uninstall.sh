#!/usr/bin/env bash
# uninstall.sh — remove everything the installer put on the machine.

cmd_uninstall() {
  if ! is_installed && [[ "$VT_FORCE" != "1" ]]; then
    die "no installation found. (force with: vt uninstall --force)"
  fi
  state_load

  cat <<BANNER

  ${C_YELLOW}Uninstall ${VT_PROJECT}${C_RESET}

  this will:
    * stop and remove the systemd units (xray, vt-health, vt-cert-renew)
    * remove the Xray binary and its configuration
    * remove the tunnel firewall rules
    * remove the certificate renewal cron/timer

BANNER
  if [[ "$VT_ASSUME_YES" != "1" ]]; then
    if confirm "continue?" n; then :; else
      log_info "cancelled."
      return 0
    fi
    # --purge already answered this question; do not ask (or overwrite) it.
    if [[ -z "${VT_UNINSTALL_KEEP_ETC:-}" ]]; then
      local keep="y"
      if confirm "also delete ${R_ETC} (certificates, users, state)?" n; then
        keep="n"
      fi
      VT_UNINSTALL_KEEP_ETC="$keep"
    fi
  fi
  VT_UNINSTALL_KEEP_ETC="${VT_UNINSTALL_KEEP_ETC:-y}"

  local remove_extra="n"
  if [[ "$VT_ASSUME_YES" != "1" ]]; then
    if confirm "also revert the system tuning (BBR/sysctl and swap)?" n; then
      remove_extra="y"
    fi
  fi

  log_step "stopping services"
  disable_services

  log_step "removing systemd units"
  local u f
  for u in "$R_XRAY_SERVICE" "$R_VT_HEALTH_SERVICE" "$R_VT_HEALTH_TIMER" \
           "$R_VT_CERT_SERVICE" "$R_VT_CERT_TIMER"; do
    f=$(p "$u")
    if [[ -f "$f" ]]; then rm -f "$f"; log_ok "removed: $u"; fi
  done
  sysd daemon-reload || true

  log_step "removing firewall rules"
  firewall_remove_vt_rules
  firewall_close_port 80

  log_step "removing automatic certificate renewal"
  if [[ -x "$(acme_bin)" ]]; then
    LE_WORKING_DIR="$(acme_home)" "$(acme_bin)" --home "$(acme_home)" \
      --remove-cron >/dev/null 2>&1 || true
  fi
  if crontab -l 2>/dev/null | grep -q 'acme.sh'; then
    crontab -l 2>/dev/null | grep -v 'acme.sh' | crontab - 2>/dev/null || true
    log_ok "acme.sh cron entry removed."
  fi

  log_step "removing Xray"
  rm -f "$(p "$R_XRAY_BIN")"
  rm -rf "$(p "$R_XRAY_CONF_DIR")"
  rm -rf "$(p "$R_XRAY_ASSETS")"
  log_ok "Xray removed."

  log_step "removing the logrotate rule"
  rm -f "$(p /etc/logrotate.d/vt-tunnel)"

  if [[ "$remove_extra" == "y" ]]; then
    log_step "reverting system tuning"
    sysprep_remove_bbr
    sysprep_remove_swap
  fi

  if [[ "$VT_UNINSTALL_KEEP_ETC" == "n" ]]; then
    log_step "removing ${R_ETC}"
    rm -rf "$(p "$R_ETC")"
    log_ok "removed."
  else
    log_note "${R_ETC} was kept (remove it manually with: rm -rf ${R_ETC})"
  fi

  rm -f "$(p "$R_LOG")"/xray-*.log 2>/dev/null || true

  cat <<DONE

  ${C_GREEN}uninstall complete.${C_RESET}
  ${C_DIM}the ${VT_PROJECT} program itself is still in ${R_INSTALL_DIR};
  to remove the program too: rm -rf ${R_INSTALL_DIR} /usr/local/bin/vt${C_RESET}

DONE
}
