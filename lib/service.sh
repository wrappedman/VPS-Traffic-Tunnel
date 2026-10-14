#!/usr/bin/env bash
# service.sh — systemd units, timers and the health check.

write_xray_unit() {
  local f; f=$(p "$R_XRAY_SERVICE")
  mkdir -p "$(dirname "$f")"
  cat >"$f" <<EOF
[Unit]
Description=${VT_PROJECT} — Xray-core (VLESS tunnel)
Documentation=${VT_HOME_URL}
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_TIME
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_TIME
NoNewPrivileges=true
ExecStart=$R_XRAY_BIN run -config $R_XRAY_CONF
Restart=always
RestartSec=3
LimitNOFILE=1048576
LimitNPROC=512000
Environment=XRAY_LOCATION_ASSET=$R_XRAY_ASSETS
StandardOutput=journal
StandardError=journal
SyslogIdentifier=xray

[Install]
WantedBy=multi-user.target
EOF
  log_ok "systemd unit written: $R_XRAY_SERVICE"
}

write_health_units() {
  local svc; svc=$(p "$R_VT_HEALTH_SERVICE")
  local tmr; tmr=$(p "$R_VT_HEALTH_TIMER")
  mkdir -p "$(dirname "$svc")"
  cat >"$svc" <<EOF
[Unit]
Description=${VT_PROJECT} health check
After=xray.service

[Service]
Type=oneshot
ExecStart=$R_INSTALL_DIR/vt health --quiet
EOF
  cat >"$tmr" <<EOF
[Unit]
Description=Run the ${VT_PROJECT} health check every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
  log_ok "health-check timer installed (every 5 minutes)."
}

write_cert_timer_units() {
  local svc; svc=$(p "$R_VT_CERT_SERVICE")
  local tmr; tmr=$(p "$R_VT_CERT_TIMER")
  mkdir -p "$(dirname "$svc")"
  cat >"$svc" <<EOF
[Unit]
Description=Renew the ${VT_PROJECT} TLS certificate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$R_INSTALL_DIR/vt renew-cert --quiet
EOF
  cat >"$tmr" <<EOF
[Unit]
Description=Check for ${VT_PROJECT} certificate renewal twice a day

[Timer]
OnBootSec=5min
OnUnitActiveSec=12h
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  log_ok "certificate renewal timer installed (every 12 hours)."
}

enable_services() {
  sysd daemon-reload || true
  sysd enable xray.service >/dev/null 2>&1 || true
  sysd restart xray.service || log_warn "xray did not start; check the log with: vt logs"
  sysd enable --now vt-health.timer >/dev/null 2>&1 || true
  sysd enable --now vt-cert-renew.timer >/dev/null 2>&1 || true
  log_ok "services enabled; they will start on boot."
}

disable_services() {
  local u
  for u in vt-cert-renew.timer vt-cert-renew.service \
           vt-health.timer vt-health.service xray.service; do
    sysd disable --now "$u" >/dev/null 2>&1 || true
  done
  sysd daemon-reload || true
}

xray_is_active() {
  if systemd_running; then
    systemctl is-active --quiet xray.service
  else
    # No systemd (containers, tests): fall back to a process check.
    pgrep -x xray >/dev/null 2>&1
  fi
}

# The health check itself: service up, port listening, certificate valid.
# Invoked by vt-health.timer and by `vt health`.
run_health_check() {
  local quiet="${1:-no}"
  local logf; logf="$(p "$R_LOG")/health.log"
  mkdir -p "$(p "$R_LOG")"
  state_load
  local rc=0

  {
    printf '%s health check\n' "$(_ts)"

    if xray_is_active; then
      printf '  [ok]   xray service is active\n'
    else
      printf '  [FAIL] xray service is not active — restarting\n'
      sysd restart xray.service || true
      rc=1
    fi

    if [[ -n "${VT_PORT:-}" ]]; then
      if port_in_use "$VT_PORT"; then
        printf '  [ok]   port %s is listening\n' "$VT_PORT"
      else
        printf '  [FAIL] port %s is not listening\n' "$VT_PORT"
        rc=1
      fi
    fi

    if [[ "${VT_CERT_MODE:-none}" != "none" ]]; then
      local summary days
      summary=$(cert_summary)
      days="${summary##*|}"
      if [[ "$days" =~ ^-?[0-9]+$ ]] && (( days < 7 )); then
        printf '  [warn] certificate expires in %s days — renewing\n' "$days"
        cert_renew || true
      else
        printf '  [ok]   certificate: %s\n' "$summary"
      fi
    fi
    printf '  result: %s\n' "$([[$rc -eq 0 ]] && printf 'healthy' || printf 'DEGRADED')"
  } >>"$logf" 2>&1

  if [[ "$quiet" != "yes" ]]; then
    tail -n 20 "$logf"
  fi
  return $rc
}

# Show service status in a compact form.
show_service_status() {
  local state="inactive"
  if xray_is_active; then state="${C_GREEN}active${C_RESET}"; else state="${C_RED}inactive${C_RESET}"; fi
  local uptime="—"
  if systemd_running; then
    uptime=$(systemctl show xray.service -p ActiveEnterTimestamp --value 2>/dev/null)
    uptime="${uptime:-—}"
  fi
  local listening="no"
  if [[ -n "${VT_PORT:-}" ]] && port_in_use "${VT_PORT}"; then listening="yes"; fi

  printf '  %-22s %s\n' "Service:" "$state"
  printf '  %-22s %s\n' "Started:" "$uptime"
  printf '  %-22s %s\n' "Port listening:" "$listening (${VT_PORT:-?})"
  printf '  %-22s %s\n' "Xray version:" "$(xray_installed_version 2>/dev/null || echo '—')"
  printf '  %-22s %s\n' "Mode:" "${VT_MODE:-?}"
  printf '  %-22s %s\n' "Certificate:" "$(cert_summary)"
  printf '  %-22s %s\n' "Auto renewal:" "$(cert_renewal_job_active || echo '—')"
  printf '  %-22s %s\n' "Users:" "$(users_count)"
}