#!/usr/bin/env bash
# firewall.sh — UFW rules for the tunnel port, SSH and ACME validation.

detect_ssh_port() {
  local port=""
  # 1. The connection we are sitting on right now — the most reliable source.
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    port=$(awk '{print $4}' <<<"$SSH_CONNECTION")
  fi
  # 2. sshd_config
  if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]] && [[ -r /etc/ssh/sshd_config ]]; then
    port=$(awk '/^[[:space:]]*Port[[:space:]]+/ {print $2; exit}' /etc/ssh/sshd_config)
  fi
  # 3. Listening sshd
  if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]] && have ss; then
    port=$(ss -Htlnp 2>/dev/null | awk '/sshd/ {print $4}' | awk -F: '{print $NF}' | head -n1)
  fi
  [[ "$port" =~ ^[0-9]+$ ]] || port=22
  printf '%s' "$port"
}

# firewall_setup <ssh-port> <tunnel-port> [extra-port...]
firewall_setup() {
  local ssh_port="$1" tunnel_port="$2"; shift 2
  local extra=("$@")

  if ! have ufw; then
    log_warn "ufw is not installed; skipping firewall setup. (apt-get install ufw)"
    return 0
  fi
  if [[ "$VT_ASSUME_YES" != "1" ]]; then
    log_warn "enabling the firewall can cut off your SSH access."
    log_warn "detected SSH port: ${C_BOLD}${ssh_port}${C_RESET}"
    if ! confirm "is that SSH port correct, and should the firewall be enabled?" y; then
      log_warn "firewall left unchanged."
      return 0
    fi
  fi

  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming >/dev/null 2>&1 || true
  ufw default allow outgoing >/dev/null 2>&1 || true
  ufw allow "${ssh_port}/tcp" comment 'SSH' >/dev/null 2>&1 || true
  ufw limit "${ssh_port}/tcp" >/dev/null 2>&1 || true
  ufw allow "${tunnel_port}/tcp" comment 'VT tunnel' >/dev/null 2>&1 || true

  local port
  for port in "${extra[@]}"; do
    [[ -n "$port" ]] || continue
    ufw allow "${port}/tcp" comment 'VT extra' >/dev/null 2>&1 || true
  done

  ufw --force enable >/dev/null 2>&1 || log_warn "failed to enable ufw."
  log_ok "firewall configured: SSH=${ssh_port}, tunnel=${tunnel_port}${extra:+, extra=${extra[*]}}"
}

firewall_open_port() {
  local port="$1" comment="${2:-VT}"
  have ufw || return 0
  ufw status 2>/dev/null | grep -qi '^Status: active' || return 0
  ufw allow "${port}/tcp" comment "$comment" >/dev/null 2>&1 || true
}

firewall_close_port() {
  local port="$1"
  have ufw || return 0
  ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
}

firewall_remove_vt_rules() {
  have ufw || return 0
  local port
  for port in "${VT_PORT:-}" "${VT_API_PORT:-}"; do
    [[ -n "$port" ]] && ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
  done
  log_note "tunnel firewall rules removed."
}
