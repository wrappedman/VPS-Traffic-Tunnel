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
# Never start or stop anything from the unit tests.
export VT_SKIP_SERVICE=1
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
# shellcheck source=/dev/null
. "$REPO/lib/sysprep.sh"
# shellcheck source=/dev/null
. "$REPO/lib/firewall.sh"
# shellcheck source=/dev/null
. "$REPO/lib/service.sh"
# shellcheck source=/dev/null
. "$REPO/lib/uninstall.sh"
# shellcheck source=/dev/null
. "$REPO/lib/status.sh"
# shellcheck source=/dev/null
. "$REPO/lib/menu.sh"

# --- path prefixing -------------------------------------------------------
eq "p() prefixes with VT_ROOT" "$VT_ROOT/etc/vt" "$(p "$R_ETC")"
VT_ROOT_SAVE="$VT_ROOT"
VT_ROOT=""
eq "p() is identity when VT_ROOT empty" "/etc/vt" "$(p "$R_ETC")"
VT_ROOT="$VT_ROOT_SAVE"

# --- --quiet handling -----------------------------------------------------
# The systemd units call `vt health --quiet` / `vt renew-cert --quiet`; a
# missing space anywhere in that path used to be silently ignored.
eq "_quiet_flag --quiet"     "yes" "$(_quiet_flag --quiet)"
eq "_quiet_flag -q"          "yes" "$(_quiet_flag -q)"
eq "_quiet_flag quiet"       "yes" "$(_quiet_flag quiet)"
eq "_quiet_flag yes"         "yes" "$(_quiet_flag yes)"
eq "_quiet_flag (empty arg)" "no"  "$(_quiet_flag '')"
eq "_quiet_flag (no arg)"    "no"  "$(_quiet_flag)"
eq "_quiet_flag junk"        "no"  "$(_quiet_flag --verbose)"

# --- the ASCII box --------------------------------------------------------
# Regression: a line wider than the frame used to push the right border out,
# so `vt viewconfig` printed a broken box whenever a value was long (the
# share link is printed outside the box for exactly that reason).
boxout=$(box "title" "short" \
  "a line that is deliberately much longer than the seventy-six column frame ....................")
# python counts characters (its len() is UTF-8 aware), which is what the
# terminal shows; awk's length() would count the frame glyphs as 3 bytes each.
eq "box keeps every line the same width" "1" \
  "$(printf '%s\n' "$boxout" | python3 -c 'import sys; print(len({len(l.rstrip(chr(10))) for l in sys.stdin}))')"
eq "box never exceeds 80 columns" "80" \
  "$(printf '%s\n' "$boxout" | python3 -c 'import sys; print(max(len(l.rstrip(chr(10))) for l in sys.stdin))')"
case "$boxout" in
  *"..."*) ok "box truncates over-long lines" ;;
  *)       bad "box truncates over-long lines" "no ellipsis in the rendered box" ;;
esac

# --- urlencode ------------------------------------------------------------
eq "urlencode plain"        "abcXYZ019._-"  "$(urlencode 'abcXYZ019._-')"
eq "urlencode slash"        "a%2Fb"         "$(urlencode 'a/b')"
eq "urlencode space"        "a%20b"         "$(urlencode 'a b')"
eq "urlencode utf8"         "%C3%A9t%C3%A9" "$(urlencode 'été')"
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
ask ans "port" "random" <<<"random"
eq "ask writes into a caller variable named ans" "random" "$ans"
ans="untouched"
ask ans "port" "random" <<<""
eq "ask falls back to the default on empty input" "random" "$ans"
MYVAR=""
ask MYVAR "name" "main" <<<""
eq "ask default" "main" "$MYVAR"
ask MYVAR "name" "main" <<<""
eq "ask default is idempotent" "main" "$MYVAR"

# Regression: `confirm` used to return 0 for empty input no matter what the
# declared default was, so "[y/N] + Enter" meant yes.
confirm "dangerous?" n <<<"" && bad "confirm honours default n on empty input" "returned yes" || ok "confirm honours default n on empty input"
confirm "continue?" y <<<"" && ok "confirm honours default y on empty input" || bad "confirm honours default y on empty input" "returned no"
confirm "continue?" n <<<"y" && ok "confirm accepts explicit y" || bad "confirm accepts explicit y" "returned no"
confirm "continue?" y <<<"n" && bad "confirm accepts explicit n" "returned yes" || ok "confirm accepts explicit n"
confirm "continue?" y <<<"no" && bad "confirm accepts the word no" "returned yes" || ok "confirm accepts the word no"
confirm "continue?" n <<<"yes" && ok "confirm accepts the word yes" || bad "confirm accepts the word yes" "returned no"
confirm "continue?" y <<<"garbage" && ok "confirm garbage falls back to default y" || bad "confirm garbage falls back to default y" "no"
confirm "continue?" n <<<"garbage" && bad "confirm garbage falls back to default n" "yes" || ok "confirm garbage falls back to default n"

idx=0
menu_pick idx "title" "alpha" "beta" "gamma" <<<""
eq "menu_pick default on empty input" "1" "$idx"
menu_pick idx "title" "alpha" "beta" "gamma" <<<"2"
eq "menu_pick picks the chosen entry" "2" "$idx"
menu_pick idx "title" "alpha" "beta" "gamma" <<<"9"
eq "menu_pick clamps out-of-range to the default" "1" "$idx"
menu_pick idx "title" "alpha" "beta" "gamma" <<<"abc"
eq "menu_pick clamps non-numeric to the default" "1" "$idx"

# ask_secret must not echo, but must still store the value.
SECRET=""
ask_secret SECRET "token" <<<"s3cr3t"
eq "ask_secret stores the value" "s3cr3t" "$SECRET"

VT_ASSUME_YES=1
confirm "with VT_ASSUME_YES, default n must answer no" n && bad "VT_ASSUME_YES honours default n" "yes" || ok "VT_ASSUME_YES honours default n"

# --- domain normalisation -------------------------------------------------
# Regression: the wizard used to strip the first label, turning
# tunnel.example.com into example.com.
. "$REPO/lib/install.sh"
eq "normalise_domain keeps subdomains" "tunnel.example.com" "$(normalise_domain tunnel.example.com)"
eq "normalise_domain lowercases"       "tunnel.example.com" "$(normalise_domain TUNNEL.Example.COM)"
eq "normalise_domain strips a scheme"  "tunnel.example.com" "$(normalise_domain https://tunnel.example.com/some/path)"
eq "normalise_domain strips http too"  "a.example.com"      "$(normalise_domain http://a.example.com)"
eq "normalise_domain strips dots"      "example.com"        "$(normalise_domain .example.com.)"
eq "normalise_domain keeps deep hosts" "x.y.example.co.uk"  "$(normalise_domain x.y.example.co.uk)"

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

# --- traffic counters -----------------------------------------------------
# `_api_stat` has to cope with the current JSON output *and* with the legacy
# "Value: N" text output, on any awk. Ubuntu/Debian ship mawk, where a leading
# `IGNORECASE=1;` is a *pattern* (not a setting) and prints every input line,
# so `vt stats` used to report 0 B for every user.
FAKE_XRAY="$VT_ROOT/usr/local/bin/xray"
mkdir -p "$(dirname "$FAKE_XRAY")"
cat >"$FAKE_XRAY" <<'FAKE'
#!/bin/sh
if [ "${FAKE_TEXT:-0}" = "1" ]; then
  echo "Value: 4242"
else
  echo '{"stat":{"name":"counter","value":1234}}'
fi
FAKE
chmod +x "$FAKE_XRAY"
VT_API_PORT="62789"
if have jq; then
  eq "_api_stat reads the JSON output" "1234" \
    "$(_api_stat 'user>>>main>>>traffic>>>uplink')"
fi
eq "_api_stat reads the text output" "4242" \
  "$(FAKE_TEXT=1 _api_stat 'user>>>main>>>traffic>>>uplink')"
eq "fmt_bytes on _api_stat output" "4.14 KB" "$(fmt_bytes "$(FAKE_TEXT=1 _api_stat x)")"

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

# --- state file round-trip ------------------------------------------------
# The LaTeX-escape bug wrote a stray backslash before the printf placeholder
# instead of the value; make sure characters a formatter likes to escape
# survive verbatim.
VT_TLS_SNI="a%b&c_d-e"; state_save
eq "state keeps % & _ in a value" "a%b&c_d-e" "$(state_load >/dev/null; state_get TLS_SNI)"
grep -q '^TLS_SNI="a%b&c_d-e"$' "$VT_ROOT$R_STATE" \
  && ok "state file is not escaped on disk" \
  || bad "state file is not escaped on disk" "$(grep '^TLS_SNI=' "$VT_ROOT$R_STATE")"
VT_TLS_SNI=""

# --- container service backend --------------------------------------------
# Without systemd the tunnel is supervised by vt itself; every service call
# must go to the process backend instead of becoming a systemctl no-op.
eq "service_backend is process without systemd" "process" "$(service_backend)"
if run_supervisor_pid >/dev/null 2>&1; then
  bad "run_supervisor_pid fails without a pid file" "it returned 0"
else
  ok "run_supervisor_pid fails without a pid file"
fi
mkdir -p "$VT_ROOT$R_LIB"
printf '%s\n' "999999" >"$VT_ROOT$R_RUN_PID"
if run_supervisor_pid >/dev/null 2>&1; then
  bad "run_supervisor_pid ignores a stale pid" "it returned 0"
else
  ok "run_supervisor_pid ignores a stale pid"
fi
printf '%s\n' "$$" >"$VT_ROOT$R_RUN_PID"
eq "run_supervisor_pid reads a live pid" "$$" "$(run_supervisor_pid)"
printf '%s\n' "not-a-pid" >"$VT_ROOT$R_RUN_PID"
if run_supervisor_pid >/dev/null 2>&1; then
  bad "run_supervisor_pid ignores garbage" "it returned 0"
else
  ok "run_supervisor_pid ignores garbage"
fi
rm -f "$VT_ROOT$R_RUN_PID"

# --- every library must actually load -------------------------------------
# A syntax error anywhere in a sourced file makes the shell abandon that file
# entirely, so all of its functions stay undefined and the caller only notices
# much later ("write_client_config: command not found"). Assert that the
# entry points the program relies on are all defined.
MISSING=""
for fn in \
  log_info log_warn die fail have require_root systemd_running sysd confirm ask \
  ask_secret menu_pick urlencode gen_uuid rand_hex random_port port_in_use \
  install_pkgs pkg_installed apt_update_once box pause _quiet_flag \
  detect_public_ipv4 detect_public_ipv6 local_primary_ipv4 is_ip is_valid_ipv4 \
  is_valid_domain resolve_a check_domain_points_here check_reality_target \
  warn_about_cloud_firewall \
  state_load state_save state_get is_installed users_file users_init users_count \
  users_exists users_add users_remove users_get_uuid users_list_emails \
  users_clients_json \
  xray_arch xray_latest_tag xray_installed_version download_and_install_xray \
  download_geo_assets gen_x25519 validate_json_file xray_test_config \
  acme_bin acme_home cert_install_acme cert_issue_domain cert_issue_ip \
  cert_issue_selfsigned cert_renew cert_summary cert_renewal_job_active \
  build_xray_config apply_config build_client_config \
  share_link print_qr print_users_table print_full_config write_client_config \
  sysprep_all sysprep_dirs sysprep_swap sysprep_enable_bbr sysprep_time_sync \
  detect_ssh_port firewall_setup firewall_open_port firewall_close_port \
  firewall_remove_vt_rules \
  write_xray_unit write_health_units write_cert_timer_units enable_services \
  disable_services xray_is_active run_health_check show_service_status \
  service_backend service_xray xray_pid xray_start_process xray_stop_process \
  xray_restart_process run_supervisor_pid cmd_run \
  cmd_uninstall \
  cmd_status cmd_view_config cmd_logs cmd_restart cmd_stop cmd_start \
  cmd_change_port cmd_renew_cert cmd_update cmd_switch_mode cmd_rotate_keys \
  cmd_backup cmd_restore cmd_doctor \
  cmd_add_user cmd_remove_user cmd_list_users cmd_stats cmd_connections \
  cmd_rotate_uuid fmt_bytes \
  banner status_line main_menu usage cmd_self_install \
  normalise_domain preflight wizard_ask_domain wizard_ask_mode wizard_ask_cert \
  wizard_ask_acme_method wizard_ask_port wizard_ask_email wizard_ask_extras \
  do_install obtain_certificate
do
  type -t "$fn" >/dev/null 2>&1 || MISSING+=" $fn"
done
eq "every library entry point is defined" "" "$MISSING"

printf '\n  unit: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
