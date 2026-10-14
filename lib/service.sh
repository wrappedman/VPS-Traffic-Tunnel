#!/usr/bin/env bash
# service.sh — systemd units, timers, the health check, and the process
# supervisor used on machines without systemd (containers: Docker, Railway,
# Fly.io, LXC, WSL ...).

# --------------------------------------------------------------------------
# Service backend
#
# On a normal VPS systemd owns the tunnel. Inside a container PID 1 is not
# systemd, `systemctl` does not exist, and every service call used to become a
# silent no-op: the install "succeeded" while nothing was ever started.
# Without systemd we supervise the binary ourselves instead.
# --------------------------------------------------------------------------
service_backend() {
  if systemd_running; then printf 'systemd'; else printf 'process'; fi
}

_xray_pid_file() { p "$R_XRAY_PID"; }
_run_pid_file()  { p "$R_RUN_PID"; }

# Echoes the pid of a running `vt run` supervisor, if any.
run_supervisor_pid() {
  local f pid
  f=$(_run_pid_file)
  [[ -f "$f" ]] || return 1
  read -r pid <"$f" 2>/dev/null || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

# Echoes the pid of a running unsupervised Xray instance, if any.
xray_pid() {
  local f pid
  f=$(_xray_pid_file)
  [[ -f "$f" ]] || return 1
  read -r pid <"$f" 2>/dev/null || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

xray_start_process() {
  local bin conf logf pidf
  bin=$(p "$R_XRAY_BIN"); conf=$(p "$R_XRAY_CONF")
  logf=$(p "$R_XRAY_LOG"); pidf=$(_xray_pid_file)

  if xray_pid >/dev/null; then
    log_ok "xray is already running (pid $(xray_pid))."
    return 0
  fi
  [[ -x "$bin" ]] || { log_err "the Xray binary is missing ($R_XRAY_BIN)."; return 1; }
  [[ -f "$conf" ]] || { log_err "the Xray config is missing ($R_XRAY_CONF)."; return 1; }

  mkdir -p "$(dirname "$logf")" "$(dirname "$pidf")"
  # The child must not inherit our stdout: callers capture the output of the
  # CLI, and a background process holding that pipe open would hang them.
  XRAY_LOCATION_ASSET="$(p "$R_XRAY_ASSETS")" \
    nohup "$bin" run -config "$conf" >>"$logf" 2>&1 </dev/null &
  local pid=$!
  printf '%s\n' "$pid" >"$pidf"
  sleep 1
  if kill -0 "$pid" 2>/dev/null; then
    log_ok "xray started in the background (pid $pid, log: $R_XRAY_LOG)."
    return 0
  fi
  local rc=0
  wait "$pid" 2>/dev/null; rc=$?
  rm -f "$pidf"
  log_err "xray exited immediately (status $rc)."
  if [[ -s "$logf" ]]; then
    log_note "the last lines of $R_XRAY_LOG:"
    tail -n 15 "$logf" | sed 's/^/      /' >&2 || true
  else
    log_note "it wrote nothing to $R_XRAY_LOG - run 'vt logs error' or start it by hand:"
    log_note "      $bin run -config $conf"
  fi
  return 1
}

# Pids of processes that are running *our* Xray binary.
#
# Matching the binary path instead of the process name matters: with a VT_ROOT
# (the test suite, a chroot) the binary lives somewhere else, and a
# name-based pkill would happily kill the real tunnel of the machine vt runs
# on. /proc answers exactly the question "is this process our binary?" - the
# executable for a real Xray, argv[1] for the offline stub, which is a shell
# script and therefore shows up as /bin/sh <path> run ... .
_owns_xray_pid() {
  local pid="$1" bin real
  bin=$(p "$R_XRAY_BIN")
  real=$(readlink -f "$bin" 2>/dev/null || true)
  [[ -n "$real" ]] || real="$bin"
  [[ "$(readlink "/proc/$pid/exe" 2>/dev/null || true)" == "$real" ]] && return 0
  local -a args=() r
  # The group redirect keeps a "No such file or directory" away from the user
  # when the process disappears between the readdir and the open.
  { while IFS= read -r -d '' r; do args+=("$r"); done <"/proc/$pid/cmdline"; } 2>/dev/null || true
  [[ "${args[0]:-}" == "$bin" || "${args[1]:-}" == "$bin" ]]
}

xray_process_pids() {
  local d pid
  for d in /proc/[0-9]*; do
    pid=${d#/proc/}
    _owns_xray_pid "$pid" && printf '%s\n' "$pid"
  done
  # Without this the function would return the status of its last loop
  # iteration (a process that is not ours) even after printing pids.
  return 0
}

xray_stop_process() {
  local pid i sup
  # A `vt run` supervisor owns the tunnel: killing its child alone would just
  # make it start a new one three seconds later, so stop the supervisor.
  # ($$ guard: health checks and certificate renewals run *inside* that
  # supervisor and must not shut down their own parent.)
  if sup=$(run_supervisor_pid) && [[ "$sup" != "$$" ]]; then
    kill "$sup" 2>/dev/null || true
    for i in 1 2 3 4 5; do
      kill -0 "$sup" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$sup" 2>/dev/null || true
    rm -f "$(_run_pid_file)"
    log_ok "the vt run supervisor was stopped (pid $sup)."
  fi
  _xray_kill_child
}

# Kill the supervised Xray process itself (never the `vt run` supervisor).
_xray_kill_child() {
  local pid i
  if pid=$(xray_pid); then
    kill "$pid" 2>/dev/null || true
    for i in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$(_xray_pid_file)"
    log_ok "xray stopped (pid $pid)."
    return 0
  fi
  # No pid file: clean up an instance started outside of vt (or by an older
  # version of it) before reporting that there is nothing to stop.
  local pids
  if pids=$(xray_process_pids) && [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086  # a whitespace-separated pid list
    kill $pids 2>/dev/null || true
    sleep 1
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
    log_ok "xray stopped."
    return 0
  fi
  log_note "xray was not running."
  return 0
}

xray_restart_process() {
  local sup
  # Under `vt run` the supervisor owns the process: it notices the child's
  # death by itself and starts a new one within three seconds. Starting a
  # second Xray here would race with it for the port.
  if sup=$(run_supervisor_pid); then
    _xray_kill_child
    log_ok "xray will be restarted by the vt run supervisor (pid $sup)."
    return 0
  fi
  xray_stop_process
  xray_start_process
}

# service_xray start|stop|restart — works on a VPS and in a container.
service_xray() {
  local action="$1"
  if [[ "$VT_SKIP_SERVICE" == "1" ]]; then
    log_note "[dry] $action the xray service"
    return 0
  fi
  if [[ "$(service_backend)" == "systemd" ]]; then
    sysd "$action" xray.service
  else
    case "$action" in
      start)   xray_start_process ;;
      stop)    xray_stop_process ;;
      restart) xray_restart_process ;;
      *)       die "service_xray: unknown action '$action'" ;;
    esac
  fi
}

# --------------------------------------------------------------------------
# vt run — the container start command.
#
# systemd is not there to restart Xray or to run the health/certificate
# timers, so this single foreground process does both: it keeps the tunnel
# up and performs the periodic work. Point the container's start command at
# `vt run` (Railway/Docker CMD) and the platform restarts it with the
# container.
# --------------------------------------------------------------------------
cmd_run() {
  local bin conf interval child="" now last=0
  bin=$(p "$R_XRAY_BIN"); conf=$(p "$R_XRAY_CONF")

  # A machine with systemd already has a supervisor (xray.service). Running a
  # second one here would fight it for the port - and this command would even
  # take over (and kill) the process systemd owns. Refuse, unless the user
  # really means it.
  if systemd_running && [[ "${VT_RUN_FORCE:-0}" != "1" ]]; then
    log_err "this machine uses systemd: the tunnel is already supervised by xray.service."
    log_note "use 'vt restart' / 'vt status' / 'vt logs' instead."
    log_note "'vt run' is for containers without systemd (Docker/Railway/Fly.io);"
    log_note "if you really want it here, start it with VT_RUN_FORCE=1."
    return 1
  fi

  is_installed || log_warn "no install state found - running anyway."

  state_load   # VT_CERT_MODE / VT_PORT for the periodic check
  [[ -x "$bin" ]]  || die "the Xray binary is missing ($R_XRAY_BIN). Run: vt install"
  [[ -f "$conf" ]] || die "the Xray config is missing ($R_XRAY_CONF). Run: vt install"
  interval="${VT_SUPERVISE_INTERVAL:-1800}"

  local runpid sup
  runpid=$(_run_pid_file)
  if sup=$(run_supervisor_pid) && [[ "$sup" != "$$" ]]; then
    die "vt run is already supervising the tunnel (pid $sup). Stop it first: vt stop"
  fi
  mkdir -p "$(dirname "$runpid")"
  printf '%s\n' "$$" >"$runpid"

  # An Xray left running by `vt start` (or by an older version of this
  # supervisor) would fight for the port, so take the tunnel over from it.
  if xray_pid >/dev/null || [[ -n "$(xray_process_pids)" ]]; then
    log_note "taking over the tunnel from an instance that was already running."
    xray_stop_process
  fi

  log_step "supervising Xray (foreground); periodic check every ${interval}s"
  if [[ "$(service_backend)" == "process" ]]; then
    log_note "no systemd here: this process is what keeps the tunnel alive."
    log_note "stop it from another shell with: vt stop"
  fi

  trap '_run_teardown' TERM INT HUP
  while :; do
    XRAY_LOCATION_ASSET="$(p "$R_XRAY_ASSETS")" "$bin" run -config "$conf" &
    child=$!
    log_ok "xray started (pid $child)"
    while kill -0 "$child" 2>/dev/null; do
      sleep 2
      now=$(date +%s)
      if (( now - last >= interval )); then
        last=$now
        if [[ "${VT_CERT_MODE:-none}" != "none" ]]; then
          cert_renew quiet 2>/dev/null \
            || log_warn "certificate renewal failed (see $R_LOG/cert-renew.log)."
        fi
        log_note "alive: pid $child, port ${VT_PORT:-?}, certificate $(cert_summary)"
      fi
    done
    local rc=0
    wait "$child" 2>/dev/null; rc=$?
    child=""
    if [[ "$rc" == "0" ]]; then
      # A deliberate restart (new config, renewed certificate): the caller
      # killed the child, so this is not a crash.
      log_note "xray exited - starting it again in 3 seconds."
    else
      log_warn "xray exited (status $rc) - restarting in 3 seconds."
    fi
    sleep 3
  done
}

# Stop the child and leave, so `docker stop` / a platform SIGTERM is clean.
_run_teardown() {
  trap - TERM INT HUP
  if [[ -n "${child:-}" && "$child" != "0" ]]; then
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  rm -f "$(_run_pid_file)"
  log_info "supervisor stopped."
  exit 0
}

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
  if [[ "$(service_backend)" == "systemd" ]]; then
    sysd daemon-reload || true
    sysd enable xray.service >/dev/null 2>&1 || true
    service_xray restart || log_warn "xray did not start; check the log with: vt logs"
    sysd enable --now vt-health.timer >/dev/null 2>&1 || true
    sysd enable --now vt-cert-renew.timer >/dev/null 2>&1 || true
    log_ok "services enabled; they will start on boot."
    return 0
  fi
  # Container: no init to enable anything with, so start the process directly.
  log_warn "no systemd on this machine (container) - the tunnel runs as a plain"
  log_warn "background process instead of a service."
  log_note "start | stop | restart and 'vt status' work as usual; the log is"
  log_note "$R_XRAY_LOG and 'vt logs' reads it."
  service_xray restart || log_warn "xray did not start; check the log with: vt logs"
  log_step "how to keep it alive on a container platform"
  log_note "a background process dies with the container, so put this in the"
  log_note "platform's start command (Railway: Settings > Deploy > Custom Start"
  log_note "Command, Docker: CMD):"
  log_note ""
  log_note "    vt run"
  log_note ""
  log_note "'vt run' keeps Xray in the foreground, restarts it after a crash and"
  log_note "renews the certificate on a schedule - the job the systemd timers do"
  log_note "on a VPS."
}

disable_services() {
  local u
  for u in vt-cert-renew.timer vt-cert-renew.service \
           vt-health.timer vt-health.service xray.service; do
    sysd disable --now "$u" >/dev/null 2>&1 || true
  done
  sysd daemon-reload || true
  service_xray stop
}

xray_is_active() {
  if systemd_running; then
    systemctl is-active --quiet xray.service
    return
  fi
  # No systemd: our own pid file is authoritative, and the process check
  # covers an instance started as `vt run` in the foreground.
  xray_pid >/dev/null 2>&1 && return 0
  [[ -n "$(xray_process_pids)" ]]
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
      service_xray restart || true
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
    printf '  result: %s\n' "$([[ $rc -eq 0 ]] && printf 'healthy' || printf 'DEGRADED')"
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
  local uptime="—" sup=""
  if systemd_running; then
    uptime=$(systemctl show xray.service -p ActiveEnterTimestamp --value 2>/dev/null)
    uptime="${uptime:-—}"
  elif sup=$(run_supervisor_pid); then
    uptime=$(ps -o lstart= -p "$sup" 2>/dev/null)
    uptime="${uptime:-—}"
  fi
  local listening="no"
  if [[ -n "${VT_PORT:-}" ]] && port_in_use "${VT_PORT}"; then listening="yes"; fi

  printf '  %-22s %s\n' "Service:" "$state"
  if [[ "$(service_backend)" == "systemd" ]]; then
    printf '  %-22s %s\n' "Managed by:" "systemd (xray.service)"
  elif sup=$(run_supervisor_pid); then
    printf '  %-22s %s\n' "Managed by:" "vt run supervisor (pid $sup, no systemd)"
  else
    printf '  %-22s %s\n' "Managed by:" "background process (no systemd)"
  fi
  printf '  %-22s %s\n' "Started:" "$uptime"
  printf '  %-22s %s\n' "Port listening:" "$listening (${VT_PORT:-?})"
  printf '  %-22s %s\n' "Xray version:" "$(xray_installed_version 2>/dev/null || echo '—')"
  if [[ "${VT_MODE:-}" == "ws-edge" && -n "${VT_HOST:-}" ]]; then
    printf '  %-22s %s\n' "Clients connect to:" "${VT_HOST}:${VT_EDGE_PORT:-443} (wss)"
  fi
  printf '  %-22s %s\n' "Mode:" "${VT_MODE:-?}"
  printf '  %-22s %s\n' "Certificate:" "$(cert_summary)"
  printf '  %-22s %s\n' "Auto renewal:" "$(cert_renewal_job_active || echo '—')"
  printf '  %-22s %s\n' "Users:" "$(users_count)"
}
