#!/usr/bin/env bash
# net.sh — public IP discovery, DNS checks, reachability probes.

# Cached public IP so a single run does not hammer the metadata services.
_PUBLIC_IPV4=""
_PUBLIC_IPV6=""

# HTTP GET with a short timeout; prints the body, returns non-zero on failure.
_http_get() {
  local url="$1" t="${2:-8}"
  curl -fsS --connect-timeout 5 --max-time "$t" \
    -H 'User-Agent: vt/1.0' "$url" 2>/dev/null
}

detect_public_ipv4() {
  if [[ -n "$_PUBLIC_IPV4" ]]; then
    printf '%s' "$_PUBLIC_IPV4"; return 0
  fi
  if [[ "$VT_SKIP_DOWNLOADS" == "1" ]]; then
    # Offline / test mode: use the address behind the default route.
    local_primary_ipv4
    return 0
  fi
  local ip=""
  local svc
  for svc in \
    "https://api.ipify.org" \
    "https://ifconfig.io/ip" \
    "https://ipv4.icanhazip.com" \
    "https://checkip.amazonaws.com" \
    "http://ifconfig.me/ip"
  do
    ip=$(_http_get "$svc" 6 | tr -d '[:space:]')
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      _PUBLIC_IPV4="$ip"
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

detect_public_ipv6() {
  if [[ -n "$_PUBLIC_IPV6" ]]; then
    printf '%s' "$_PUBLIC_IPV6"; return 0
  fi
  if [[ "$VT_SKIP_DOWNLOADS" == "1" ]]; then
    return 1
  fi
  local ip=""
  local svc
  for svc in \
    "https://api64.ipify.org" \
    "https://ipv6.icanhazip.com"
  do
    ip=$(_http_get "$svc" 6 | tr -d '[:space:]')
    if [[ "$ip" == *:* ]]; then
      _PUBLIC_IPV6="$ip"
      printf '%s' "$ip"
      return 0
    fi
  done
  return 1
}

# The address that actually carries our default route — useful on NATed VPS.
local_primary_ipv4() {
  if have ip; then
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
  fi
}

is_ip() {
  local s="$1"
  if [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then return 0; fi
  if [[ "$s" == *:* ]]; then return 0; fi
  return 1
}

is_valid_ipv4() {
  local s="$1" o
  [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  # shellcheck disable=SC2206
  local parts=($s)
  for o in "${parts[@]}"; do
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

is_valid_domain() {
  local s="$1"
  [[ "$s" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]
}

# Resolve a name to IPv4 addresses (one per line).
resolve_a() {
  local host="$1"
  if [[ "$VT_SKIP_DOWNLOADS" == "1" ]]; then
    printf '%s' "${VT_FAKE_DNS:-}"
    return 0
  fi
  if have getent; then
    getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u
  elif have host; then
    host -t A "$host" 2>/dev/null | awk '/has address/ {print $NF}' | sort -u
  elif have python3; then
    python3 - "$host" <<'PY' 2>/dev/null
import socket, sys
try:
    for info in socket.getaddrinfo(sys.argv[1], None, socket.AF_INET):
        print(info[4][0])
except Exception:
    pass
PY
  fi
}

# Does the given domain already point at this machine?
# Echoes "ok" / "mismatch:<resolved>" / "nodns".
check_domain_points_here() {
  local domain="$1" myip resolved
  myip=$(detect_public_ipv4) || myip=""
  resolved=$(resolve_a "$domain" | head -n1 || true)
  if [[ -z "$resolved" ]]; then
    printf 'nodns'
    return 1
  fi
  if [[ -n "$myip" && "$resolved" == "$myip" ]]; then
    printf 'ok'
    return 0
  fi
  printf 'mismatch:%s' "$resolved"
  return 1
}

# Verify a REALITY camouflage target: it must speak TLS 1.3 and present a
# certificate for the SNI we intend to use. Without this the tunnel still
# works but handshakes can be fingerprinted as bogus.
# Echoes "ok" or a reason string.
check_reality_target() {
  local sni="$1" port="${2:-443}"
  if [[ "$VT_SKIP_DOWNLOADS" == "1" ]]; then
    printf 'offline'
    return 1
  fi
  if ! have openssl; then
    printf 'no-openssl'
    return 1
  fi
  local out
  out=$(printf 'Q' | timeout 10 openssl s_client \
        -connect "${sni}:${port}" -servername "$sni" -tls1_3 2>/dev/null) || {
    printf 'no-tls13'
    return 1
  }
  if ! grep -q "BEGIN CERTIFICATE" <<<"$out"; then
    printf 'no-cert'
    return 1
  fi
  if ! grep -Eq "TLSv1\.3|TLS 1\.3" <<<"$out"; then
    printf 'no-tls13'
    return 1
  fi
  printf 'ok'
  return 0
}

# Best-effort check that the outside world can reach us on a port. We cannot
# truly test inbound from inside the VPS, so we report what we can and let the
# user confirm the cloud firewall.
warn_about_cloud_firewall() {
  local port="$1"
  log_warn "if your provider has a cloud firewall (Hetzner/AWS/DigitalOcean/Arvan/...),"
  log_warn "you must also open port ${port} there."
}
