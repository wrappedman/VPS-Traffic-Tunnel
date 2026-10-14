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
  ${VT_PROJECT} v${VT_VERSION} - always-on VLESS tunnel for your VPS
${C_RESET}
BANNER
}

status_line() {
  if is_installed; then
    local st="${C_RED}stopped${C_RESET}"
    xray_is_active && st="${C_GREEN}running${C_RESET}"
    printf '  status: %s   |   mode: %s   |   endpoint: %s:%s\n\n' \
      "$st" "${VT_MODE:-?}" "${VT_HOST:-?}" "${VT_PORT:-?}"
  else
    printf '  status: %s\n\n' "${C_YELLOW}not installed${C_RESET}"
  fi
}

main_menu() {
  while true; do
    banner
    status_line
    cat <<MENU
  ${C_BOLD}Main${C_RESET}
   ${C_GREEN}1)${C_RESET} install      - install the tunnel + always-on service (asks about domain/SSL)
   ${C_GREEN}2)${C_RESET} viewConfig   - show the config, share link and QR code
   ${C_GREEN}3)${C_RESET} uninstall    - remove the tunnel completely

  ${C_BOLD}Management${C_RESET}
   ${C_CYAN}4)${C_RESET} add a new user
   ${C_CYAN}5)${C_RESET} remove a user
   ${C_CYAN}6)${C_RESET} list users and their links
   ${C_CYAN}7)${C_RESET} traffic stats and live connections
   ${C_CYAN}8)${C_RESET} change the tunnel port
   ${C_CYAN}9)${C_RESET} rotate a user's UUID
  ${C_CYAN}10)${C_RESET} switch mode (REALITY / WS-TLS / TCP-TLS)

  ${C_BOLD}TLS certificate${C_RESET}
  ${C_CYAN}11)${C_RESET} renew the certificate manually / show its status
  ${C_CYAN}12)${C_RESET} create a new self-signed certificate

  ${C_BOLD}Service and system${C_RESET}
  ${C_CYAN}13)${C_RESET} service status
  ${C_CYAN}14)${C_RESET} restart / stop / start
  ${C_CYAN}15)${C_RESET} show logs
  ${C_CYAN}16)${C_RESET} update Xray-core
  ${C_CYAN}17)${C_RESET} run diagnostics (doctor)
  ${C_CYAN}18)${C_RESET} backup / restore

   ${C_YELLOW}0)${C_RESET} quit

MENU
    local choice
    if [[ "$VT_ASSUME_YES" == "1" ]]; then
      return 0
    fi
    printf '%s' "${C_BOLD}your choice${C_RESET} [0]: "
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
      0|q|quit|exit) log_info "bye."; return 0 ;;
      *) log_warn "invalid choice."; sleep 1 ;;
    esac
  done
}

_guard_installed() {
  if is_installed; then
    log_warn "the tunnel is already installed."
    if confirm "wipe the existing config and install from scratch?" n; then
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
  log_warn "run the install option first."
  sleep 2
  return 1
}

_selfsigned_now() {
  local host="${VT_HOST:-$(detect_public_ipv4 || echo localhost)}"
  cert_issue_selfsigned "$host" 825 || return 1
  VT_CERT_MODE="selfsigned"; VT_SELF_SIGNED="1"; VT_REJECT_UNKNOWN_SNI="0"
  state_save
  apply_config || return 1
  log_ok "new certificate created and applied."
}

_svc_menu() {
  local c
  menu_pick c "service:" "restart" "stop" "start" "back"
  case "$c" in
    1) cmd_restart ;; 2) cmd_stop ;; 3) cmd_start ;; *) return 0 ;;
  esac
  pause
}

_log_menu() {
  local c
  menu_pick c "which log?" \
    "xray service (journalctl)" "xray errors" "health checks" \
    "certificate renewal" "installation" "follow live" "back"
  case "$c" in
    1) cmd_logs xray ;;    2) cmd_logs error ;;  3) cmd_logs health ;;
    4) cmd_logs cert ;;    5) cmd_logs install ;; 6) cmd_logs follow ;;
    *) return 0 ;;
  esac
  pause
}

_backup_menu() {
  local c
  menu_pick c "backup:" "create a backup" "restore from a file" "back"
  case "$c" in
    1) cmd_backup ;;
    2) local f; ask f "path to the backup file" ""
       if [[ -n "$f" ]]; then cmd_restore "$f"; fi ;;
    *) return 0 ;;
  esac
  pause
}

usage() {
  cat <<USAGE
${C_BOLD}${VT_PROJECT}${C_RESET} v${VT_VERSION} - always-on VLESS tunnel for your VPS

${C_BOLD}usage:${C_RESET}
  vt                         show the interactive menu
  vt <command> [options]

${C_BOLD}main commands:${C_RESET}
  install                    install the tunnel + always-on service
  viewconfig | config        show the config, share link and QR code
  uninstall                  remove everything

${C_BOLD}install options (for a fully unattended install):${C_RESET}
  --mode <reality|ws-tls|tcp-tls>
  --domain <domain>          use a domain (Let's Encrypt certificate)
  --acme <standalone|webroot|dns>
  --webroot <path>
  --dns-plugin <dns_cf> --dns-env <CF_Token> --dns-token <token>
  --cert <letsencrypt-domain|letsencrypt-ip|selfsigned|none>
  --sni <domain>             camouflage site for REALITY
  --port <n|random>
  --email <name>             name of the first user
  --email-acme <addr>        Let's Encrypt account e-mail
  --firewall <yes|no>
  --adblock <yes|no>
  --no-torrent <yes|no>
  --yes                      never prompt, use the defaults

${C_BOLD}management:${C_RESET}
  add-user [name]            rm-user [name]        users
  stats                      connections           rotate-uuid [name]
  rotate-keys                port <n|random>       switch-mode
  update                     renew-cert            selfsigned-cert

${C_BOLD}service:${C_RESET}
  status                     restart | stop | start
  logs [xray|error|health|cert|install|follow]
  doctor                     health [--quiet]
  backup [dir]               restore <file>
  self-install               install the program itself into ${R_INSTALL_DIR}

${C_BOLD}environment variables:${C_RESET}
  VT_ASSUME_YES=1            answer every prompt with its default
  VT_SKIP_DOWNLOADS=1        never touch the network (used by the tests)
  VT_SKIP_APT=1              never call apt-get
  VT_SKIP_SYSTEMD=1          never call systemctl
  VT_ROOT=/path              operate on an alternate root (used by the tests)

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
    log_ok "the program is already in $R_INSTALL_DIR."
  else
    log_info "copying the program to $R_INSTALL_DIR ..."
    mkdir -p "$dst"
    cp -a "$src/." "$dst/" || die "copy failed."
    chmod +x "$dst/vt"
    log_ok "copied."
  fi
  mkdir -p "$(dirname "$link")"
  ln -sf "$R_INSTALL_DIR/vt" "$link"
  log_ok "'vt' is now on PATH: $link"
  log_note "you can now run it from anywhere with: vt"
}
