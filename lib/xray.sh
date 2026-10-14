#!/usr/bin/env bash
# xray.sh — install / update the Xray-core binary, key generation, config I/O.

XRAY_REPO="XTLS/Xray-core"
GEOIP_URL="https://github.com/Loyalsoldier/geoip/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

xray_arch() {
  local m; m=$(uname -m)
  case "$m" in
    x86_64|amd64) printf '64' ;;
    i386|i686) printf '32' ;;
    armv8*|aarch64) printf 'arm64-v8a' ;;
    armv7*) printf 'arm32-v7a' ;;
    armv6*) printf 'arm32-v6' ;;
    armv5*) printf 'arm32-v5' ;;
    riscv64) printf 'riscv64' ;;
    *) fail "unsupported architecture: $m" ;;
  esac
}

xray_latest_tag() {
  local tag
  tag=$(curl -fsS --connect-timeout 8 --max-time 20 \
        -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${XRAY_REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null)
  [[ -n "$tag" ]] || return 1
  printf '%s' "$tag"
}

xray_installed_version() {
  local bin out
  bin=$(p "$R_XRAY_BIN")
  [[ -x "$bin" ]] || return 1
  out=$("$bin" version 2>/dev/null | head -n1 | awk '{print $2}' || true)
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

# download_and_install_xray [version-tag]
download_and_install_xray() {
  local tag="${1:-}" arch url tmp
  arch=$(xray_arch)

  if [[ -n "$tag" ]]; then
    log_info "requested Xray version: $tag"
  else
    log_info "looking up the latest Xray-core release ..."
    tag=$(xray_latest_tag) || fail "could not fetch the latest Xray release from GitHub."
  fi

  url="https://github.com/${XRAY_REPO}/releases/download/${tag}/Xray-linux-${arch}.zip"
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  log_info "downloading: $url"
  curl -fL --connect-timeout 10 --max-time 300 --retry 3 \
    -o "$tmp/xray.zip" "$url" || fail "failed to download Xray."

  log_info "extracting ..."
  if have unzip; then
    unzip -oq "$tmp/xray.zip" -d "$tmp/out" || fail "failed to extract the archive."
  elif have python3; then
    mkdir -p "$tmp/out"
    python3 - "$tmp/xray.zip" "$tmp/out" <<'PY' || fail "failed to extract the archive."
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
  else
    fail "unzip or python3 is required to extract the archive."
  fi

  mkdir -p "$(p "$R_XRAY_ASSETS")" "$(p "$(dirname "$R_XRAY_BIN")")"
  install -m 0755 "$tmp/out/xray" "$(p "$R_XRAY_BIN")" || fail "failed to install the Xray binary."
  if [[ -f "$tmp/out/geoip.dat" ]]; then install -m 0644 "$tmp/out/geoip.dat" "$(p "$R_XRAY_ASSETS/geoip.dat")"; fi
  if [[ -f "$tmp/out/geosite.dat" ]]; then install -m 0644 "$tmp/out/geosite.dat" "$(p "$R_XRAY_ASSETS/geosite.dat")"; fi

  log_ok "Xray installed: $(bin_or_installed_version)"
}

# helper used above so the log line survives the RETURN trap
bin_or_installed_version() {
  local v; v=$(xray_installed_version) || v="unknown"
  printf '%s' "$v"
}

# Optional geo rule databases (only needed when ad-blocking is enabled).
download_geo_assets() {
  local dir; dir=$(p "$R_XRAY_ASSETS")
  mkdir -p "$dir"
  local ok=1
  if [[ ! -s "$dir/geoip.dat" ]]; then
    log_info "downloading geoip.dat ..."
    curl -fL --max-time 180 -o "$dir/geoip.dat" "$GEOIP_URL" || ok=0
  fi
  if [[ ! -s "$dir/geosite.dat" ]]; then
    log_info "downloading geosite.dat ..."
    curl -fL --max-time 180 -o "$dir/geosite.dat" "$GEOSITE_URL" || ok=0
  fi
  [[ "$ok" == "1" ]] || { rm -f "$dir/geoip.dat" "$dir/geosite.dat"; return 1; }
  return 0
}

remove_geo_assets() {
  rm -f "$(p "$R_XRAY_ASSETS/geoip.dat")" "$(p "$R_XRAY_ASSETS/geosite.dat")"
}

# --------------------------------------------------------------------------
# Key material
# --------------------------------------------------------------------------

# X25519 keypair for REALITY. Prefers the Xray CLI (authoritative format),
# falls back to a pure-OpenSSL implementation so key generation still works
# before the binary is on disk or on a minimal image.
# Sets globals: X25519_PRIVATE, X25519_PUBLIC
gen_x25519() {
  local bin; bin=$(p "$R_XRAY_BIN")
  if [[ -x "$bin" ]]; then
    local out
    out=$("$bin" x25519 2>/dev/null) || out=""
    local priv pub
    # Support both legacy ("Private key:" / "Public key:") and modern
    # ("PrivateKey:" / "Password:") Xray-core CLI output formats.
    priv=$(awk -F': *' '/^[Pp]rivate ?[Kk]ey/ {print $2}' <<<"$out" | tr -d '[:space:]')
    pub=$(awk -F': *' '/^([Pp]ublic ?[Kk]ey|[Pp]assword)/ {print $2}' <<<"$out" | tr -d '[:space:]')
    if [[ -n "$priv" && -n "$pub" ]]; then
      X25519_PRIVATE="$priv"
      X25519_PUBLIC="$pub"
      return 0
    fi
  fi
  _gen_x25519_openssl
}

_b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

_gen_x25519_openssl() {
  local tmp; tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  openssl genpkey -algorithm X25519 -outform DER -out "$tmp/priv.der" 2>/dev/null \
    || fail "failed to generate an X25519 key (openssl too old?)"
  openssl pkey -inform DER -in "$tmp/priv.der" -pubout -outform DER \
    -out "$tmp/pub.der" 2>/dev/null || fail "failed to derive the public key."
  # PKCS#8 X25519 private key DER = 16 byte header + 32 byte raw key.
  # SubjectPublicKeyInfo X25519 DER  = 12 byte header + 32 byte public key.
  # Xray-core expects the 32-byte private key to be RFC 7748 clamped before
  # base64url encoding, whereas OpenSSL stores the unclamped seed in PKCS#8.
  if have python3; then
    X25519_PRIVATE=$(python3 - "$tmp/priv.der" <<'PY'
import sys, base64
b = bytearray(open(sys.argv[1], "rb").read()[-32:])
b[0] &= 248
b[31] &= 127
b[31] |= 64
print(base64.urlsafe_b64encode(bytes(b)).decode().rstrip("="), end="")
PY
)
  else
    X25519_PRIVATE=$(tail -c 32 "$tmp/priv.der" | _b64url)
  fi
  X25519_PUBLIC=$(tail -c 32 "$tmp/pub.der" | _b64url)
}

# --------------------------------------------------------------------------
# Config validation
# --------------------------------------------------------------------------
validate_json_file() {
  local f="$1"
  if have jq; then
    jq -e . "$f" >/dev/null 2>&1
  elif have python3; then
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null
  else
    return 0
  fi
}

# Ask the Xray binary itself whether the config is usable. Returns 0 when the
# binary is missing so the flow is not blocked on a partial install.
xray_test_config() {
  local f="$1" bin; bin=$(p "$R_XRAY_BIN")
  [[ -x "$bin" ]] || { log_note "Xray binary missing; skipping the config test."; return 0; }
  if XRAY_LOCATION_ASSET="$(p "$R_XRAY_ASSETS")" \
     "$bin" -test -config "$f" >/tmp/xray-test.$$ 2>&1; then
    rm -f /tmp/xray-test.$$
    log_ok "Xray accepted the configuration."
    return 0
  fi
  log_err "the Xray configuration is invalid:"
  sed 's/^/      /' /tmp/xray-test.$$ >&2
  rm -f /tmp/xray-test.$$
  return 1
}