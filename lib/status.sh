#!/usr/bin/env bash
# status.sh — reporting and day-2 operations.

cmd_status() {
  if ! is_installed; then
    log_warn "nothing is installed yet. Start with: vt install"
    return 0
  fi
  printf '\n'
  box "${VT_PROJECT} status" \
    "version       : ${VT_VERSION}" \
    "installed at  : ${VT_INSTALLED_AT:-?}" \
    "public IP     : ${VT_PUBLIC_IP:-?}" \
    "SSH port      : ${VT_SSH_PORT:-?}"
  printf '\n'
  show_service_status
  printf '\n'
  if xray_is_active; then
    cmd_stats 2>/dev/null || true
  fi
}

cmd_view_config() {
  if ! is_installed; then
    die "nothing is installed yet. Start with: vt install"
  fi
  print_full_config "${1:-yes}"
  log_note "the text config is also saved at: $R_ETC/config.txt"
  log_note "ready-to-run desktop client config: $R_ETC/client.json"
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
        log_warn "no log found."
      fi
      ;;
    error)
      tail -n "${VT_LOG_LINES:-100}" "$(p "$R_LOG")/xray-error.log" 2>/dev/null \
        || log_warn "no error log found."
      ;;
    health)
      tail -n "${VT_LOG_LINES:-100}" "$(p "$R_LOG")/health.log" 2>/dev/null \
        || log_warn "no health log found."
      ;;
    cert)
      tail -n "${VT_LOG_LINES:-100}" "$(p "$R_LOG")/cert-renew.log" 2>/dev/null \
        || log_warn "no certificate log found."
      ;;
    install)
      tail -n "${VT_LOG_LINES:-200}" "$(p "$R_LOG")/install.log" 2>/dev/null \
        || log_warn "no install log found."
      ;;
    follow|-f)
      systemd_running || die "journalctl only works under systemd."
      journalctl -u xray.service -f
      ;;
    *)
      die "unknown log: $what (one of: xray|error|health|cert|install|follow)"
      ;;
  esac
}

cmd_restart() {
  sysd restart xray.service || die "restart failed."
  sleep 1
  if xray_is_active; then log_ok "service restarted."; else log_err "the service did not come up."; fi
}

cmd_stop()   { sysd stop xray.service;    log_ok "service stopped."; }
cmd_start()  {
  sysd start xray.service
  sleep 1
  if xray_is_active; then log_ok "service started."; else log_err "the service did not come up."; fi
}

cmd_change_port() {
  local newport="${1:-}"
  local old="${VT_PORT}"
  if [[ -z "$newport" ]]; then
    ask newport "new port (a number, or random)" "random"
  fi
  if [[ "$newport" == "random" ]]; then
    newport="$(random_port "$VT_API_PORT" 80 443 "$VT_SSH_PORT")"
  fi
  if ! [[ "$newport" =~ ^[0-9]+$ ]] || (( newport < 1 || newport > 65535 )); then
    die "invalid port: $newport"
  fi
  if port_in_use "$newport"; then
    die "port $newport is already in use."
  fi
  VT_PORT="$newport"
  apply_config || die "failed to apply the configuration."
  firewall_close_port "$old"
  firewall_open_port "$newport" 'VT tunnel'
  state_save
  log_ok "port changed from $old to $newport."
  log_warn "update your client configs."
}

cmd_renew_cert() {
  local quiet="no"
  [[ "${1:-}" == "--quiet" ]] && quiet="yes"
  if [[ "${VT_CERT_MODE:-none}" == "none" ]]; then
    if [[ "$quiet" != "yes" ]]; then
      log_info "this install uses REALITY and has no TLS certificate."
    fi
    return 0
  fi
  cert_renew
  if [[ "$quiet" != "yes" ]]; then
    log_info "certificate status: $(cert_summary)"
  fi
}

cmd_update() {
  log_step "updating Xray-core"
  local old new
  old="$(xray_installed_version 2>/dev/null || echo none)"
  if [[ "$VT_SKIP_DOWNLOADS" == "1" ]]; then
    log_note "[dry] update skipped."
    return 0
  fi
  download_and_install_xray
  new="$(xray_installed_version 2>/dev/null || echo unknown)"
  VT_XRAY_VERSION="$new"
  state_save
  if xray_test_config "$(p "$R_XRAY_CONF")"; then
    sysd restart xray.service || true
    log_ok "updated: ${old} -> ${new}"
  else
    log_err "the config is not compatible with the new version; the service was not restarted."
  fi
}

cmd_switch_mode() {
  cat <<'TXT'

  switching modes invalidates every client config.
TXT
  local cur="${VT_MODE:-?}"
  local idx
  menu_pick idx "current mode: ${cur} - new mode:" \
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
        gen_x25519 || die "failed to generate a key."
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
        die "this mode needs a TLS certificate first (vt renew-cert, or reinstall)."
      fi
      ;;
  esac
  apply_config || die "apply failed."
  state_save
  log_ok "mode changed to ${new}."
  print_full_config yes
}

cmd_rotate_keys() {
  if [[ "${VT_MODE:-}" != "reality" ]]; then
    die "this install does not use REALITY; there are no keys to rotate."
  fi
  gen_x25519 || die "failed to generate an X25519 key."
  VT_REALITY_PRIVATE="$X25519_PRIVATE"
  VT_REALITY_PUBLIC="$X25519_PUBLIC"
  VT_REALITY_SHORTID="$(rand_hex 16)"
  apply_config || die "failed to apply the configuration."
  state_save
  log_ok "REALITY keys rotated."
  log_warn "every client config is now invalid - fetch a fresh one."
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
  log_ok "backup created: $out"
  printf '%s\n' "$out"
}

cmd_restore() {
  local file="$1"
  [[ -f "$file" ]] || die "file not found: $file"
  if ! confirm "restore from $file - current settings will be overwritten. Continue?" n; then
    return 0
  fi
  disable_services
  tar xzf "$file" -C "$(dirname "$(p "$R_ETC")")" || die "restore failed."
  state_load
  sysd daemon-reload || true
  enable_services
  log_ok "restore complete."
}

cmd_doctor() {
  log_step "diagnostics"
  local issues=0
  is_root || { log_err "not running as root."; issues=$((issues + 1)); }

  if [[ -x "$(p "$R_XRAY_BIN")" ]]; then
    log_ok "Xray binary: $($(p "$R_XRAY_BIN") version 2>/dev/null | head -n1)"
  else
    log_err "Xray binary not found ($R_XRAY_BIN)"; issues=$((issues + 1))
  fi

  if [[ -f "$(p "$R_XRAY_CONF")" ]]; then
    if validate_json_file "$(p "$R_XRAY_CONF")"; then
      log_ok "config.json is valid JSON."
      xray_test_config "$(p "$R_XRAY_CONF")" || issues=$((issues + 1))
    else
      log_err "config.json is invalid."; issues=$((issues + 1))
    fi
  else
    log_err "config.json not found."; issues=$((issues + 1))
  fi

  if xray_is_active; then log_ok "the xray service is active."
  else log_err "the xray service is not active."; issues=$((issues + 1)); fi

  if [[ -n "${VT_PORT:-}" ]]; then
    if port_in_use "$VT_PORT"; then
      log_ok "port ${VT_PORT} is listening."
    else
      log_err "port ${VT_PORT} is not listening."; issues=$((issues + 1))
    fi
  fi

  if have openssl && [[ "${VT_CERT_MODE:-none}" != "none" ]]; then
    local summary; summary=$(cert_summary)
    local days="${summary##*|}"
    if [[ "$days" =~ ^-?[0-9]+$ ]] && (( days > 0 )); then
      log_ok "certificate is valid ($summary)"
    else
      log_err "certificate is broken or expired ($summary)"; issues=$((issues + 1))
    fi
  fi

  if [[ "$(date -u +%Y)" -lt 2020 ]]; then
    log_err "the system clock is wrong - TLS will not work."; issues=$((issues + 1))
  else
    log_ok "system clock: $(date -u '+%Y-%m-%d %H:%M UTC')"
  fi

  local ccur; ccur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')
  log_info "congestion control: $ccur"

  if have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    log_info "firewall is active:"
    ufw status numbered 2>/dev/null | sed 's/^/      /'
  else
    log_info "the ufw firewall is not active."
  fi

  printf '\n'
  if (( issues == 0 )); then
    log_ok "everything looks healthy."
  else
    log_warn "${issues} item(s) need attention. See: vt logs error"
  fi
  return 0
}
