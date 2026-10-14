#!/usr/bin/env bash
# tests/unit_test.sh — unit tests for the pure helpers in lib/.
# Runs in its own process; exit code 0 means everything passed.
#
# shellcheck disable=SC2015  # `cond && ok || bad` is deliberate here: ok/bad
#                            # always succeed, so the A&&B||C idiom is safe.

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "${G:-}" "${R:-}" "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  %s✗%s %s — %s\n' "${RD:-}" "${R:-}" "$1" "$2"; }
eq()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

VT_ROOT=$(mktemp -d)
export VT_ROOT
export VT_ASSUME_YES=1 VT_NO_COLOR=1 VT_SKIP_DOWNLOADS=1 VT_SKIP_APT=1 VT_SKIP_SYSTEMD=1
mkdir -p "$VT_ROOT"
# shellcheck disable=SC2064
trap 'rm -rf "$VT_ROOT"' EXIT

# shellcheck source=/dev/null
. "$REPO/lib/common.sh"
# shellcheck source=/dev/null
. "$REPO/lib/net.sh"
# shellcheck source=/dev/null
. "$REPO/lib/state.sh"
# shellcheck source=/dev/null
. "$REPO/lib/xray.sh"
# shellcheck source=/dev/null
. "$REPO/lib/cert.sh"
# shellcheck source=/dev/null
. "$REPO/lib/config_gen.sh"
# shellcheck source=/dev/null
. "$REPO/lib/client_gen.sh"
# shellcheck source=/dev/null
. "$REPO/lib/users.sh"

# --- path prefixing -------------------------------------------------------
eq "p() prefixes with VT_ROOT" "$VT_ROOT/etc/vt" "$(p "$R_ETC")"
VT_ROOT_SAVE="$VT_ROOT"
VT_ROOT=""
eq "p() is identity when VT_ROOT empty" "/etc/vt" "$(p "$R_ETC")"
VT_ROOT="$VT_ROOT_SAVE"

# --- urlencode ------------------------------------------------------------
eq "urlencode plain"        "abcXYZ019._-"  "$(urlencode 'abcXYZ019._-')"
eq "urlencode slash"        "a%2Fb"         "$(urlencode 'a/b')"
eq "urlencode space"        "a%20b"         "$(urlencode 'a b')"
eq "urlencode utf8"         "%D8%B3%D9%84%D8%A7%D9%85" "$(urlencode 'سلام')"
eq "urlencode ws path"      "%2Fabc%2F"     "$(urlencode '/abc/')"

# --- uuid / hex -----------------------------------------------------------
u=$(gen_uuid)
if [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
  ok "gen_uuid is RFC4122 v4"
else
  bad "gen_uuid is RFC4122 v4" "got $u"
fi
eq "two uuids differ" "yes" "$([[ "$(gen_uuid)" != "$(gen_uuid)" ]] && echo yes || echo no)"
h16=$(rand_hex 16)
eq "rand_hex 16 is 16 hex chars" 16 "${#h16}"
if [[ "$(rand_hex 8)" =~ ^[0-9a-f]{8}$ ]]; then ok "rand_hex charset"; else bad "rand_hex charset" "$(rand_hex 8)"; fi

# --- interactive prompt helpers -------------------------------------------
# These must be tested with VT_ASSUME_YES off, otherwise they take the default
# path and never touch stdin.
VT_ASSUME_YES=0

# Regression: `ask` used to keep its answer in a local called `ans`, which
# shadowed a caller variable of the same name, so the answer was lost.
ans="untouched"
ask ans "پورت" "random" <<<"random"
eq "ask writes into a caller variable named ans" "random" "$ans"
ans="untouched"
ask ans "پورت" "random" <<<""
eq "ask falls back to the default on empty input" "random" "$ans"
MYVAR=""
ask MYVAR "نام" "main" <<<""
eq "ask default" "main" "$MYVAR"
ask MYVAR "نام" "main" <<<""
eq "ask default is idempotent" "main" "$MYVAR"

# Regression: `confirm` used to return 0 for empty input no matter what the
# declared default was, so "[y/N] + Enter" meant yes.
confirm "خطرناک؟" n <<<"" && bad "confirm honours default n on empty input" "returned yes" || ok "confirm honours default n on empty input"
confirm "ادامه؟" y <<<"" && ok "confirm honours default y on empty input" || bad "confirm honours default y on empty input" "returned no"
confirm "ادامه؟" n <<<"y" && ok "confirm accepts explicit y" || bad "confirm accepts explicit y" "returned no"
confirm "ادامه؟" y <<<"n" && bad "confirm accepts explicit n" "returned yes" || ok "confirm accepts explicit n"
confirm "ادامه؟" y <<<"نه" && bad "confirm accepts Persian no" "returned yes" || ok "confirm accepts Persian no"
confirm "ادامه؟" n <<<"بله" && ok "confirm accepts Persian yes" || bad "confirm accepts Persian yes" "returned no"
confirm "ادامه؟" y <<<"garbage" && ok "confirm garbage falls back to default y" || bad "confirm garbage falls back to default y" "no"
confirm "ادامه؟" n <<<"garbage" && bad "confirm garbage falls back to default n" "yes" || ok "confirm garbage falls back to default n"

idx=0
menu_pick idx "عنوان" "الف" "ب" "پ" <<<""
eq "menu_pick default on empty input" "1" "$idx"
menu_pick idx "عنوان" "الف" "ب" "پ" <<<"2"
eq "menu_pick picks the chosen entry" "2" "$idx"
menu_pick idx "عنوان" "الف" "ب" "پ" <<<"9"
eq "menu_pick clamps out-of-range to the default" "1" "$idx"
menu_pick idx "عنوان" "الف" "ب" "پ" <<<"abc"
eq "menu_pick clamps non-numeric to the default" "1" "$idx"

# ask_secret must not echo, but must still store the value.
SECRET=""
ask_secret SECRET "توکن" <<<"s3cr3t"
eq "ask_secret stores the value" "s3cr3t" "$SECRET"

VT_ASSUME_YES=1
confirm "با فرض بله، پیش‌فرض n باید نه بدهد" n && bad "VT_ASSUME_YES honours default n" "yes" || ok "VT_ASSUME_YES honours default n"

# --- validators -----------------------------------------------------------
eq "is_ip v4"        yes "$(is_ip 1.2.3.4 && echo yes || echo no)"
eq "is_ip v6"        yes "$(is_ip 2001:db8::1 && echo yes || echo no)"
eq "is_ip domain"    no  "$(is_ip example.com && echo yes || echo no)"
eq "is_valid_ipv4 ok"    yes "$(is_valid_ipv4 203.0.113.9 && echo yes || echo no)"
eq "is_valid_ipv4 bad"   no  "$(is_valid_ipv4 999.1.1.1 && echo yes || echo no)"
eq "is_valid_domain ok"  yes "$(is_valid_domain tunnel.example.com && echo yes || echo no)"
eq "is_valid_domain tld" no  "$(is_valid_domain localhost && echo yes || echo no)"
eq "is_valid_domain bad" no  "$(is_valid_domain 'exa mple.com' && echo yes || echo no)"

# --- x25519 key generation (OpenSSL fallback) -----------------------------
X25519_PRIVATE=""; X25519_PUBLIC=""
gen_x25519
eq "x25519 private is 43 chars" 43 "${#X25519_PRIVATE}"
eq "x25519 public is 43 chars"  43 "${#X25519_PUBLIC}"
if [[ "$X25519_PRIVATE" =~ ^[A-Za-z0-9_-]+$ ]]; then ok "x25519 is base64url"; else bad "x25519 is base64url" "$X25519_PRIVATE"; fi
p1="$X25519_PRIVATE"
gen_x25519
eq "x25519 keys rotate" yes "$([[ "$p1" != "$X25519_PRIVATE" ]] && echo yes || echo no)"

# --- user store -----------------------------------------------------------
users_init
eq "users start empty" 0 "$(users_count)"
users_add "main" "$(gen_uuid)" "main"
users_add "alice" "$(gen_uuid)" "Alice"
eq "users_count after 2 adds" 2 "$(users_count)"
eq "users_exists main"  yes "$(users_exists main && echo yes || echo no)"
eq "users_exists ghost" no  "$(users_exists ghost && echo yes || echo no)"
eq "uuid round-trip" "same" \
  "$([[ "$(users_get_uuid alice)" == "$(jq -r '.users[]|select(.email=="alice").uuid' "$(users_file)")" ]] && echo same || echo diff)"
users_remove "alice"
eq "users_count after remove" 1 "$(users_count)"
eq "alice gone" no "$(users_exists alice && echo yes || echo no)"
users_add "alice" "$(gen_uuid)" "Alice"
eq "re-add works" 2 "$(users_count)"
clients=$(users_clients_json "xtls-rprx-vision")
eq "clients json length" 2 "$(jq 'length' <<<"$clients")"
eq "clients carry flow" "xtls-rprx-vision" "$(jq -r '.[0].flow' <<<"$clients")"
eq "clients no-flow variant" "null" "$(jq -r '.[0].flow' <<<"$(users_clients_json "")")"
eq "fmt_bytes 0"     "0 B"      "$(fmt_bytes 0)"
eq "fmt_bytes 1024"  "1.00 KB"  "$(fmt_bytes 1024)"
eq "fmt_bytes 5MB"   "5.00 MB"  "$(fmt_bytes 5242880)"

# --- state round-trip -----------------------------------------------------
VT_MODE="reality"; VT_PORT="54321"; VT_HOST="203.0.113.7"; VT_API_PORT="60001"
VT_REALITY_SNI="www.microsoft.com"; VT_EMAIL="main"
state_save
assert_f="$VT_ROOT$R_STATE"
[[ -f "$assert_f" ]] && ok "state file written" || bad "state file written" "$assert_f"
VT_MODE=""; VT_PORT=""
state_load
eq "state round-trip MODE" "reality" "$VT_MODE"
eq "state round-trip PORT" "54321"   "$VT_PORT"
eq "state file is 0600" "600" "$(stat -c %a "$assert_f")"

# --- share links ----------------------------------------------------------
VT_MODE="reality"; VT_PORT="44311"; VT_HOST="203.0.113.7"
VT_REALITY_SNI="www.microsoft.com"; VT_REALITY_PUBLIC="PUBKEYPUBKEYPUBKEYPUBKEYPUBKEYPUBKEYPUBKEY"
VT_REALITY_SHORTID="abc123"; VT_FLOW="xtls-rprx-vision"
VT_REALITY_DEST="www.microsoft.com:443"; VT_REALITY_PRIVATE="PRIVKEYPRIVKEYPRIVKEYPRIVKEYPRIVKEYPRIVKE"
link=$(share_link main)
if [[ "$link" == vless://* ]]; then ok "reality link scheme"; else bad "reality link scheme" "$link"; fi
for frag in "security=reality" "flow=xtls-rprx-vision" "sni=www.microsoft.com" \
            "pbk=" "sid=abc123" "fp=chrome" "@203.0.113.7:44311?"; do
  [[ "$link" == *"$frag"* ]] && ok "reality link has $frag" || bad "reality link has $frag" "$link"
done

VT_MODE="ws-tls"; VT_PORT="443"; VT_HOST="tunnel.example.com"; VT_WS_PATH="/a1b2/"
VT_SELF_SIGNED="1"
link=$(share_link main)
for frag in "type=ws" "security=tls" "sni=tunnel.example.com" "path=%2Fa1b2%2F" \
            "allowInsecure=1" "@tunnel.example.com:443?"; do
  [[ "$link" == *"$frag"* ]] && ok "ws link has $frag" || bad "ws link has $frag" "$link"
done
[[ "$link" == *"security=reality"* ]] && bad "ws link must not carry reality" "$link" || ok "ws link has no reality params"

VT_MODE="tcp-tls"; VT_SELF_SIGNED="0"
link=$(share_link main)
for frag in "type=tcp" "security=tls" "flow=xtls-rprx-vision"; do
  [[ "$link" == *"$frag"* ]] && ok "tcp-tls link has $frag" || bad "tcp-tls link has $frag" "$link"
done
[[ "$link" == *"allowInsecure"* ]] && bad "valid cert must not set allowInsecure" "$link" || ok "tcp-tls link has no allowInsecure"

# --- config generation for every mode -------------------------------------
VT_API_PORT="62789"
VT_PORT="44311"
for m in reality tcp-tls ws-tls; do
  VT_MODE="$m"
  out="$VT_ROOT/config-$m.json"
  if ( build_xray_config "$m" "$out" ) 2>"$VT_ROOT/err"; then
    ok "build_xray_config $m"
    jq -e . "$out" >/dev/null && ok "config $m is valid JSON" || bad "config $m is valid JSON" ""
    eq "config $m port" "44311" "$(jq '.inbounds[0].port' "$out")"
    eq "config $m protocol" "vless" "$(jq -r '.inbounds[0].protocol' "$out")"
    eq "config $m clients" 2 "$(jq '.inbounds[0].settings.clients|length' "$out")"
    sec=$(jq -r '.inbounds[0].streamSettings.security' "$out")
    case "$m" in
      reality) eq "config reality security" "reality" "$sec"
               eq "config reality shortId" "abc123" "$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$out")" ;;
      *)       eq "config $m security" "tls" "$sec" ;;
    esac
    net=$(jq -r '.inbounds[0].streamSettings.network' "$out")
    case "$m" in
      ws-tls) eq "config ws network" "ws" "$net" ;;
      *)      eq "config $m network" "tcp" "$net" ;;
    esac
    eq "config $m api is loopback" "127.0.0.1" "$(jq -r '.inbounds[1].listen' "$out")"
  else
    bad "build_xray_config $m" "$(cat "$VT_ROOT/err")"
  fi
done

# --- client config --------------------------------------------------------
VT_MODE="reality"; VT_SELF_SIGNED="0"
VT_EMAIL="main"
if ( build_client_config "$VT_ROOT/client.json" ) 2>"$VT_ROOT/err2"; then
  ok "build_client_config"
  eq "client has socks inbound" "socks" "$(jq -r '.inbounds[0].protocol' "$VT_ROOT/client.json")"
  eq "client vnext port" "44311" "$(jq '.outbounds[0].settings.vnext[0].port' "$VT_ROOT/client.json")"
  eq "client reality pubkey" "$VT_REALITY_PUBLIC" \
    "$(jq -r '.outbounds[0].streamSettings.realitySettings.publicKey' "$VT_ROOT/client.json")"
else
  bad "build_client_config" "$(cat "$VT_ROOT/err2")"
fi

# --- self-signed certificate ----------------------------------------------
if cert_issue_selfsigned "203.0.113.7" 825 >/dev/null 2>&1; then
  ok "cert_issue_selfsigned"
  assert_f="$VT_ROOT$R_CERT_DIR/fullchain.pem"
  [[ -f "$assert_f" ]] && ok "certificate file exists" || bad "certificate file exists" "$assert_f"
  san=$(openssl x509 -in "$assert_f" -noout -ext subjectAltName 2>/dev/null)
  [[ "$san" == *"203.0.113.7"* ]] && ok "certificate SAN has the IP" || bad "certificate SAN has the IP" "$san"
  days=$(cert_summary); days="${days##*|}"
  if (( days > 800 )); then ok "certificate lifetime ~825d ($days)"; else bad "certificate lifetime" "$days"; fi
  [[ "$(stat -c %a "$VT_ROOT$R_CERT_DIR/privkey.pem")" == "600" ]] \
    && ok "private key is 0600" || bad "private key is 0600" "$(stat -c %a "$VT_ROOT$R_CERT_DIR/privkey.pem")"
else
  bad "cert_issue_selfsigned" "openssl failed"
fi

if cert_issue_selfsigned "tunnel.example.com" 825 >/dev/null 2>&1; then
  san=$(openssl x509 -in "$VT_ROOT$R_CERT_DIR/fullchain.pem" -noout -ext subjectAltName 2>/dev/null)
  [[ "$san" == *"tunnel.example.com"* ]] && ok "certificate SAN has the domain" || bad "certificate SAN has the domain" "$san"
else
  bad "cert_issue_selfsigned domain" "openssl failed"
fi

printf '\n  unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
