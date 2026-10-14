#!/usr/bin/env bash
# sysprep.sh — kernel tuning (BBR), swap, clock sync. All of it optional and
# all of it reversible on uninstall.

sysprep_packages() {
  install_pkgs curl ca-certificates unzip jq openssl socat cron qrencode ufw
}

# --------------------------------------------------------------------------
# TCP / BBR
# --------------------------------------------------------------------------
sysprep_enable_bbr() {
  if [[ "$VT_SKIP_SYSTEMD" == "1" ]]; then
    log_note "[dry] BBR/sysctl not applied."
    return 0
  fi
  local f; f=$(p "$R_SYSCTL")
  mkdir -p "$(dirname "$f")"
  cat >"$f" <<'EOF'
# Managed by VPS-Traffic-Tunnel — remove this file to revert.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10
net.ipv4.ip_local_port_range = 10000 65535
fs.file-max = 1048576
vm.swappiness = 10
EOF
  sysctl --system >/dev/null 2>&1 || true

  local cur
  cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')
  if [[ "$cur" == "bbr" ]]; then
    log_ok "BBR is active."
  else
    log_warn "BBR could not be enabled (current algorithm: $cur)."
    log_note "if the kernel is old, BBR is unavailable; the other settings still applied."
  fi
}

sysprep_remove_bbr() {
  local f; f=$(p "$R_SYSCTL")
  if [[ -f "$f" ]]; then
    rm -f "$f"
    sysctl --system >/dev/null 2>&1 || true
    log_ok "sysctl settings removed."
  fi
}

# --------------------------------------------------------------------------
# Swap — Xray is light, but a 512 MB VPS can still OOM-kill it.
# --------------------------------------------------------------------------
sysprep_swap() {
  local size_mb="${1:-1024}"
  if swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
    log_note "swap is already active."
    return 0
  fi
  local mem_kb total_mb
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  total_mb=$((mem_kb / 1024))
  if (( total_mb >= 2048 )); then
    log_note "enough memory (${total_mb}MB) - no swap created."
    return 0
  fi
  if [[ "$VT_SKIP_SYSTEMD" == "1" ]]; then
    log_note "[dry] swap not created."
    return 0
  fi
  log_info "low memory (${total_mb}MB) - creating ${size_mb}MB of swap ..."
  local f; f=$(p "$R_SWAPFILE")
  fallocate -l "${size_mb}M" "$f" 2>/dev/null \
    || dd if=/dev/zero of="$f" bs=1M count="$size_mb" status=none || return 1
  chmod 600 "$f"
  mkswap "$f" >/dev/null 2>&1 || return 1
  swapon "$f" >/dev/null 2>&1 || true
  if ! grep -qs "^$R_SWAPFILE" /etc/fstab; then
    printf '%s none swap sw 0 0\n' "$R_SWAPFILE" >>/etc/fstab
  fi
  log_ok "swap enabled."
}

sysprep_remove_swap() {
  local f; f=$(p "$R_SWAPFILE")
  [[ -f "$f" ]] || return 0
  swapoff "$f" >/dev/null 2>&1 || true
  rm -f "$f"
  if [[ -w /etc/fstab ]]; then
    sed -i "\|^$R_SWAPFILE |d" /etc/fstab
  fi
  log_ok "swap removed."
}

# --------------------------------------------------------------------------
# Clock sync — TLS handshakes fail on a drifting clock.
# --------------------------------------------------------------------------
sysprep_time_sync() {
  if systemd_running; then
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
      log_ok "time synchronisation is active (timesyncd)."
      return 0
    fi
    systemctl enable --now systemd-timesyncd >/dev/null 2>&1 && {
      log_ok "timesyncd enabled."
      return 0
    }
  fi
  if have chronyc || have ntpd; then
    log_ok "a time service (chrony/ntp) is already running."
    return 0
  fi
  log_warn "no time synchronisation service found."
  log_note "without NTP a drifting clock will break TLS handshakes:"
  log_note "  apt-get install -y chrony && systemctl enable --now chrony"
}

# --------------------------------------------------------------------------
# Directories + log rotation
# --------------------------------------------------------------------------
sysprep_dirs() {
  local d
  for d in "$R_ETC" "$R_LOG" "$R_LIB" "$R_XRAY_CONF_DIR" "$R_XRAY_ASSETS" "$R_CERT_DIR"; do
    mkdir -p "$(p "$d")"
  done
  chmod 700 "$(p "$R_ETC")"

  local lr; lr=$(p "/etc/logrotate.d/vt-tunnel")
  if [[ -d "$(p /etc/logrotate.d)" ]]; then
    cat >"$lr" <<EOF
$R_LOG/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
  fi
}

# One-shot preparation used by the installer.
sysprep_all() {
  log_step "preparing the system"
  sysprep_packages
  sysprep_dirs
  sysprep_time_sync
  sysprep_swap 1024
  sysprep_enable_bbr
}
