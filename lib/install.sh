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
  log_step "system pre-flight"

  is_root || fail "this must run as root (sudo bash $0)."

  if [[ -r /etc/os-release ]]; then
    local pretty
    pretty=$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")
    log_info "OS: $pretty"
    if ! (. /etc/os-release && [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]]); then
      log_warn "this script targets Ubuntu/Debian; other distributions may need manual tweaks."
    fi
  fi
  log_info "architecture: $(uname -m) -> package Xray-linux-$(xray_arch)"
  log_info "kernel: $(uname -r)"

  local local_ip pub_ip
  local_ip=$(local_primary_ipv4); local_ip="${local_ip:-127.0.0.1}"
  pub_ip=$(detect_public_ipv4) || pub_ip=""
  if [[ -z "$pub_ip" ]]; then
    # Everything the client config needs (the share link, VT_HOST) is built
    # from this address, so on a NATed box a wrong guess breaks the tunnel.
    log_warn "could not detect the public IP automatically."
    if [[ "$VT_ASSUME_YES" != "1" ]]; then
      ask pub_ip "public IP (or hostname) your clients should connect to" "$local_ip"
    fi
    pub_ip="${pub_ip:-$local_ip}"
  fi
  log_info "local IP:  $local_ip"
  log_info "public IP: $pub_ip"
  if [[ -n "$local_ip" && "$local_ip" != "$pub_ip" && "$local_ip" != "127.0.0.1" ]]; then
    log_note "this server sits behind NAT (local IP != public IP). Connect using the public IP."
  fi
  VT_DETECTED_IP="$pub_ip"
  VT_DETECTED_IPV6="$(detect_public_ipv6 || true)"
  VT_SSH_PORT="$(detect_ssh_port)"
  log_info "SSH port: $VT_SSH_PORT"

  if [[ -f "$(p "$R_XRAY_CONF")" && "$VT_FORCE" != "1" ]]; then
    if confirm "an existing installation was found. Overwrite the current config?" n; then
      VT_FORCE=1
    else
      die "cancelled."
    fi
  fi
}

# --------------------------------------------------------------------------
# Question 1 — do you have a domain?
# --------------------------------------------------------------------------
wizard_ask_domain() {
  cat <<'TXT'

  ── step 1: domain ──────────────────────────────────────────────────────
  With a domain we can get a free, trusted Let's Encrypt certificate and
  the tunnel will look exactly like an ordinary HTTPS site (better
  camouflage).
  Without a domain you are still fine: REALITY works with no domain and no
  certificate, and Let's Encrypt can also issue a certificate for a bare IP.
  ───────────────────────────────────────────────────────────────────────
TXT
  local has_domain="n"
  if [[ -n "$WIZ_DOMAIN" ]]; then
    has_domain="y"
  elif [[ "$VT_ASSUME_YES" == "1" ]]; then
    has_domain="n"
  else
    if confirm "do you have a domain that points at this server?" n; then has_domain="y"; fi
  fi

  if [[ "$has_domain" == "y" ]]; then
    local domain="$WIZ_DOMAIN"
    if [[ -z "$domain" ]]; then
      ask domain "domain name (e.g. tunnel.example.com)" ""
    fi
    domain=$(normalise_domain "$domain")
    while ! is_valid_domain "$domain"; do
      log_err "'$domain' is not a valid domain name."
      ask domain "domain name" ""
      domain=$(normalise_domain "$domain")
    done

    log_info "checking the DNS record for $domain ..."
    local res; res=$(check_domain_points_here "$domain") || true
    case "$res" in
      ok)       log_ok "DNS is correct and points at this server." ;;
      nodns)
        log_warn "no A record found for $domain."
        log_note "if the domain is on Cloudflare (or similar) we can validate over the DNS API instead."
        ;;
      mismatch:*)
        log_warn "the domain points at ${res#mismatch:}, not at this server (${VT_DETECTED_IP})."
        ;;
    esac
    WIZ_DOMAIN="$domain"
  else
    WIZ_DOMAIN=""
  fi
}

# Lower-case a domain and strip a pasted scheme plus leading/trailing dots.
# Labels are never removed: tunnel.example.com must stay tunnel.example.com.
normalise_domain() {
  local d="${1,,}"
  d="${d#https://}"; d="${d#http://}"
  d="${d%%/*}"
  d="${d#.}"; d="${d%.}"
  printf '%s' "$d"
}

# --------------------------------------------------------------------------
# Question 2 — certificate strategy + tunnel mode
# --------------------------------------------------------------------------
wizard_ask_mode() {
  cat <<'TXT'

  ── step 2: transport and TLS certificate ───────────────────────────────
   1) REALITY  - no domain, no certificate, works on a bare IP. The traffic
                 looks like a real HTTPS site. (recommended)
   2) WebSocket + TLS on port 443 - closest to an ordinary website; needs a
                 TLS certificate (domain, or an IP-address certificate).
   3) TCP + TLS on a custom port - needs a TLS certificate.
  ───────────────────────────────────────────────────────────────────────
TXT
  local def=1
  if [[ -n "$WIZ_MODE" ]]; then
    case "$WIZ_MODE" in
      reality) def=1 ;;
      ws-tls)  def=2 ;;
      tcp-tls) def=3 ;;
      *) die "unknown --mode: $WIZ_MODE (expected reality, ws-tls or tcp-tls)" ;;
    esac
  fi
  local idx
  menu_pick idx "choose the tunnel mode:" \
    "REALITY (no certificate - recommended)" \
    "WebSocket + TLS (port 443)" \
    "TCP + TLS (custom port)"
  if [[ -n "$WIZ_MODE" ]]; then idx="$def"; fi

  case "$idx" in
    1) VT_MODE="reality"; VT_FLOW="xtls-rprx-vision" ;;
    2) VT_MODE="ws-tls";  VT_FLOW="" ;;
    3) VT_MODE="tcp-tls"; VT_FLOW="xtls-rprx-vision" ;;
  esac
  log_ok "selected mode: ${VT_MODE}"

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

  REALITY hides your traffic inside a TLS handshake with a real website.
  The site must support TLS 1.3 and must not be blocked in your region.
TXT
  local def="www.microsoft.com"
  if [[ -n "$WIZ_SNI" ]]; then def="$WIZ_SNI"; fi
  ask WIZ_SNI "camouflage domain (SNI)" "$def"
  WIZ_SNI="${WIZ_SNI,,}"
  WIZ_SNI="${WIZ_SNI#https://}"; WIZ_SNI="${WIZ_SNI#http://}"; WIZ_SNI="${WIZ_SNI%%/*}"

  log_info "checking $WIZ_SNI ..."
  local res; res=$(check_reality_target "$WIZ_SNI" 443) || true
  case "$res" in
    ok)         log_ok "$WIZ_SNI is suitable for REALITY (TLS 1.3 ok)" ;;
    offline)    log_note "offline mode: skipping the camouflage-site check." ;;
    no-openssl) log_warn "openssl is missing, so the check was skipped." ;;
    *)
      log_warn "$WIZ_SNI does not look suitable (${res})."
      if confirm "use it anyway?" n; then :
      else
        ask WIZ_SNI "camouflage domain" "www.apple.com"
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
    case "$WIZ_CERT" in
      none|selfsigned|letsencrypt-domain|letsencrypt-ip) cert="$WIZ_CERT" ;;
      *) die "unknown --cert: $WIZ_CERT (expected none, selfsigned, letsencrypt-domain or letsencrypt-ip)" ;;
    esac
  elif [[ -n "$WIZ_DOMAIN" ]]; then
    cert="letsencrypt-domain"
  else
    cat <<'TXT'

  ── TLS certificate for an IP address ───────────────────────────────────
   1) Let's Encrypt IP certificate - free and trusted, no domain needed.
      Generally available since January 2026; valid for ~6 days and renewed
      automatically every 3 days. Requires port 80 to be open.
   2) Self-signed - needs no open port 80, but clients must enable
      allowInsecure.
  ───────────────────────────────────────────────────────────────────────
TXT
    local cidx
    menu_pick cidx "which certificate?" \
      "Let's Encrypt for the IP (trusted, auto-renewing)" \
      "self-signed (simple, no port 80 needed)"
    case "$cidx" in
      1) cert="letsencrypt-ip" ;;
      2) cert="selfsigned" ;;
    esac
  fi
  if [[ "$VT_ASSUME_YES" == "1" && -z "$cert" ]]; then cert="selfsigned"; fi

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
  log_ok "certificate source: $cert   host: $VT_HOST"

  if [[ "$cert" == "letsencrypt-domain" ]]; then
    wizard_ask_acme_method
  fi
}

wizard_ask_acme_method() {
  cat <<'TXT'

  how should domain ownership be validated?
   1) Standalone - the script binds port 80 itself, briefly. Simplest, but
                   port 80 must be free and reachable.
   2) Webroot    - the challenge file is written into a running web server's
                   document root.
   3) DNS        - validated through a DNS provider API (e.g. Cloudflare).
                   Needs no open port and works even before the domain
                   points at this server.
  ───────────────────────────────────────────────────────────────────────
TXT
  local midx=1
  case "$WIZ_ACME_METHOD" in
    standalone) midx=1 ;; webroot) midx=2 ;; dns) midx=3 ;;
  esac
  if [[ -z "$WIZ_ACME_METHOD" && "$VT_ASSUME_YES" != "1" ]]; then
    menu_pick midx "which method?" "Standalone (port 80)" "Webroot" "DNS API"
  fi
  case "$midx" in
    1) WIZ_ACME_METHOD="standalone" ;;
    2) WIZ_ACME_METHOD="webroot"
       ask WIZ_WEBROOT "webroot path" "/var/www/html" ;;
    3) WIZ_ACME_METHOD="dns"
       ask WIZ_DNS_PROVIDER "acme.sh plugin name" "dns_cf"
       case "$WIZ_DNS_PROVIDER" in
         dns_cf) ask_secret WIZ_DNS_TOKEN "Cloudflare token (CF_Token)" ;;
         *) ask WIZ_DNS_ENV "environment variable the plugin expects" "CF_Token"
            ask_secret WIZ_DNS_TOKEN "value" ;;
       esac
       ;;
  esac
  log_ok "certificate method: $WIZ_ACME_METHOD"
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
      ask ans "tunnel port (a number, or random)" "$def"
    fi
  fi
  if [[ "$ans" == "random" ]]; then
    VT_PORT="$(random_port "${VT_API_PORT:-}" 80 443 "$VT_SSH_PORT")"
    log_ok "random port selected: ${VT_PORT}"
  elif [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= 65535 )); then
    VT_PORT="$ans"
    if port_in_use "$VT_PORT"; then
      log_warn "port $VT_PORT is already in use; picking a random one instead."
      VT_PORT="$(random_port "${VT_API_PORT:-}" 80 443 "$VT_SSH_PORT")"
    fi
  else
    log_warn "'$ans' is not a valid port; picking a random one instead."
    VT_PORT="$(random_port "${VT_API_PORT:-}" 80 443 "$VT_SSH_PORT")"
  fi

  # Internal API, only reachable from localhost.
  VT_API_PORT="$(random_port "$VT_PORT")"

  if [[ "$VT_MODE" == "ws-tls" ]]; then
    VT_WS_PATH="/$(rand_hex 16)/"
    log_ok "WebSocket path: ${VT_WS_PATH}"
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
    ask VT_EMAIL "name of the first user" "main"
  fi
  VT_EMAIL="${VT_EMAIL//[^a-zA-Z0-9._-]/}"
  if [[ -z "$VT_EMAIL" ]]; then VT_EMAIL="main"; fi
  log_ok "first user: $VT_EMAIL"
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
    if confirm "enable the UFW firewall and open only the required ports? (SSH=${VT_SSH_PORT})" y; then
      VT_FIREWALL="yes"
    else
      VT_FIREWALL="no"
    fi
  fi

  if [[ "$VT_ASSUME_YES" != "1" ]]; then
    if confirm "block ads and trackers? (downloads the geosite database)" n; then
      VT_AD_BLOCK="1"
    else
      VT_AD_BLOCK="0"
    fi
    if confirm "block BitTorrent / heavy download traffic?" n; then
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

  log_step "installing Xray-core"
  if [[ "$VT_SKIP_DOWNLOADS" == "1" ]]; then
    log_note "[dry] skipping the Xray download."
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

  log_step "generating keys"
  users_init
  users_add "$VT_EMAIL" "$(gen_uuid)" "$VT_EMAIL" || log_note "the user was already registered."

  case "$VT_MODE" in
    reality)
      gen_x25519 || fail "failed to generate the X25519 key."
      VT_REALITY_PRIVATE="$X25519_PRIVATE"
      VT_REALITY_PUBLIC="$X25519_PUBLIC"
      VT_REALITY_SHORTID="$(rand_hex 16)"
      log_ok "REALITY key generated."
      ;;
    ws-tls|tcp-tls)
      VT_REALITY_PRIVATE=""; VT_REALITY_PUBLIC=""; VT_REALITY_SHORTID=""
      obtain_certificate
      ;;
  esac

  if [[ "$VT_AD_BLOCK" == "1" ]]; then
    log_step "downloading the ad-blocking database"
    if [[ "$VT_SKIP_DOWNLOADS" == "1" ]]; then
      log_note "[dry] skipping the geo assets."
      VT_AD_BLOCK="0"
    elif download_geo_assets; then
      log_ok "geosite/geoip downloaded."
    else
      log_warn "download failed - ad blocking stays disabled."
      VT_AD_BLOCK="0"
    fi
  fi

  log_step "writing the configuration"
  sysprep_dirs
  build_xray_config "$VT_MODE" "$(p "$R_XRAY_CONF")"
  chmod 600 "$(p "$R_XRAY_CONF")"
  log_ok "configuration written: $R_XRAY_CONF"
  xray_test_config "$(p "$R_XRAY_CONF")" || fail "the Xray configuration is invalid."

  log_step "creating the always-on service"
  write_xray_unit
  write_health_units
  write_cert_timer_units

  log_step "saving the install state"
  VT_INSTALLED_AT="$(date -Is)"
  VT_XRAY_VERSION="$(xray_installed_version 2>/dev/null || echo unknown)"
  VT_PUBLIC_IP="$VT_DETECTED_IP"
  VT_PUBLIC_IPV6="${VT_DETECTED_IPV6:-}"
  VT_SSH_PORT="${VT_SSH_PORT:-22}"
  state_save || fail "failed to save the install state."

  enable_services

  if [[ "$VT_FIREWALL" == "yes" ]]; then
    log_step "configuring the firewall"
    local -a extra=()
    if [[ "${VT_CERT_MODE:-}" == "letsencrypt-ip" || "$WIZ_ACME_METHOD" == "standalone" ]]; then
      extra+=(80)
    fi
    firewall_setup "$VT_SSH_PORT" "$VT_PORT" "${extra[@]}"
  fi
  warn_about_cloud_firewall "$VT_PORT"

  # Make sure the tunnel really came up before we hand over the config.
  sleep 2
  if xray_is_active; then
    log_ok "the tunnel is running."
  else
    log_warn "the service did not come up - check the log with: vt logs"
  fi

  write_client_config "$VT_EMAIL" "$(p "$R_ETC")/client.json" >/dev/null \
    || log_warn "could not write the desktop client config to $R_ETC/client.json."

  # vt-health.timer and vt-cert-renew.timer call /opt/vt/vt, so the program
  # must actually live there.
  log_step "installing the program itself into $R_INSTALL_DIR"
  cmd_self_install || log_warn "copying the program to $R_INSTALL_DIR failed; the timers will not work."

  printf '%s === install finished ===\n' "$(_ts)" >>"$logfile"
  print_full_config yes
}

# Certificate acquisition for the TLS modes.
obtain_certificate() {
  log_step "obtaining a free TLS certificate"
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
        log_warn "certificate issuance failed."
        if confirm "create a self-signed certificate instead? (clients must set allowInsecure)" y; then
          cert_issue_selfsigned "$VT_HOST" 825
          VT_CERT_MODE="selfsigned"; VT_SELF_SIGNED="1"; VT_REJECT_UNKNOWN_SNI="0"
        else
          fail "cannot continue without a certificate."
        fi
      }
      ;;
    letsencrypt-ip)
      install_pkgs socat
      if ! cert_issue_ip "$VT_HOST" "$VT_ACME_EMAIL"; then
        log_warn "Let's Encrypt did not issue a certificate for the IP address"
        log_warn "(port 80 may be closed, or the account may not be eligible yet)."
        if confirm "create a self-signed certificate instead?" y; then
          cert_issue_selfsigned "$VT_HOST" 825
          VT_CERT_MODE="selfsigned"; VT_SELF_SIGNED="1"
        else
          fail "cannot continue without a certificate."
        fi
      fi
      ;;
    selfsigned)
      cert_issue_selfsigned "$VT_HOST" 825
      ;;
    none) : ;;
    *) fail "invalid certificate mode: $VT_CERT_MODE" ;;
  esac
}

# Ask once for the ACME account e-mail (Let's Encrypt sends expiry notices).
ask_acme_email() {
  [[ -z "${VT_ACME_EMAIL:-}" ]] || return 0
  local e=""
  if [[ "$VT_ASSUME_YES" == "1" ]]; then
    e="admin@${VT_HOST:-localhost}"
  else
    ask e "e-mail for the Let's Encrypt account (optional)" "admin@${VT_HOST:-localhost}"
  fi
  if [[ "$e" != *@*.* ]]; then e="admin@${VT_HOST:-localhost}"; fi
  VT_ACME_EMAIL="$e"
}
