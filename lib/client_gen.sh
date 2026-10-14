#!/usr/bin/env bash
# client_gen.sh — share links, QR codes and human-readable output.

# vless://<uuid>@<host>:<port>?<params>#<remark>
share_link() {
  local email="${1:-${VT_EMAIL:-main}}"
  local uuid remark host port mode url_host
  uuid=$(users_get_uuid "$email")
  [[ -n "$uuid" ]] \vert{}\vert{} { log_err "user '$email' not found."; return 1; }
  remark=$(jq -r --arg e "$email" '.users[] \vert{} select(.email==$e) | (.remark // .email)' \
            "$(users_file)" 2>/dev/null)
  [[ -n "$remark" && "$remark" != "null" ]] \vert{}\vert{} remark="$email"
  host="${VT_HOST:?}"; port="${VT_PORT:?}"; mode="${VT_MODE:?}"

  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    url_host="[${host}]"
  else
    url_host="$host"
  fi

  local -a q=()
  case "$mode" in
    reality)
      q+=("type=tcp" "security=reality" "flow=${VT_FLOW:-xtls-rprx-vision}")
      q+=("sni=$(urlencode "${VT_REALITY_SNI}")")
      q+=("pbk=$(urlencode "${VT_REALITY_PUBLIC}")")
      q+=("sid=${VT_REALITY_SHORTID}")
      q+=("fp=chrome" "encryption=none")
      ;;
    tcp-tls)
      q+=("type=tcp" "security=tls" "flow=${VT_FLOW:-xtls-rprx-vision}")
      q+=("sni=$(urlencode "$host")" "alpn=h2%2Chttp%2F1.1" "fp=chrome" "encryption=none")
      if [[ "${VT_SELF_SIGNED:-0}" == "1" ]]; then q+=("allowInsecure=1"); fi
      ;;
    ws-tls)
      q+=("type=ws" "security=tls")
      q+=("sni=$(urlencode "$host")" "host=$(urlencode "$host")")
      q+=("path=$(urlencode "${VT_WS_PATH:-/}")")
      q+=("alpn=http%2F1.1" "fp=chrome" "encryption=none")
      if [[ "${VT_SELF_SIGNED:-0}" == "1" ]]; then q+=("allowInsecure=1"); fi
      ;;
    *) log_err "unknown mode: $mode"; return 1 ;;
  esac

  local qs=""
  local IFS='&'
  qs="${q[*]}"
  unset IFS
  printf 'vless://%s@%s:%s?%s#%s' "$uuid" "$url_host" "$port" "$qs" "$(urlencode "$remark")"
}

# Print the share link as a QR code in the terminal when qrencode exists.
print_qr() {
  local text="$1"
  if ! have qrencode; then
    log_note "qrencode is not installed - no QR code (apt-get install qrencode)."
    return 0
  fi
  printf '\n'
  qrencode -t ANSIUTF8 -m 1 "$text" 2>/dev/null \
    || qrencode -t UTF8 "$text" 2>/dev/null \
    || { log_note "could not render the QR code."; return 0; }
}

# One-line summary per user, for `vt users list`.
print_users_table() {
  local f; f=$(users_file)
  [[ -f "$f" ]] || { log_warn "no users registered."; return; }
  local email uuid remark created
  printf '\n%s\n' "${C_BOLD}  user              UUID                                    created${C_RESET}"
  printf '  %s\n' "────────────────────────────────────────────────────────────────────────"
  while IFS='|' read -r email uuid remark created; do
    [[ -z "$email" ]] && continue
    printf '  %-16s %-38s %s\n' "$email" "$uuid" "${created:0:10}"
  done < <(jq -r '.users[] | [.email, .uuid, (.remark // ""), (.created // "")] | @tsv' "$f" \
            | tr '\t' '|')
  printf '\n'
}

# Everything a human needs, in one screen. Also written to $R_ETC/config.txt.
print_full_config() {
  local show_qr="${1:-yes}"
  local host="${VT_HOST:-?}" port="${VT_PORT:-?}" mode="${VT_MODE:-?}"
  local link email
  email="${VT_EMAIL:-main}"
  link=$(share_link "$email") || return 1

  local -a lines=()
  lines+=("protocol      : VLESS (${mode})")
  lines+=("server        : ${host}")
  lines+=("port          : ${port}")
  lines+=("UUID          : $(users_get_uuid "$email")")
  case "$mode" in
    reality)
      lines+=("security      : REALITY")
      lines+=("flow          : ${VT_FLOW:-xtls-rprx-vision}")
      lines+=("sni / public  : ${VT_REALITY_SNI} /${VT_REALITY_PUBLIC}")
      lines+=("short id      : ${VT_REALITY_SHORTID}")
      lines+=("fingerprint   : chrome")
      ;;
    tcp-tls|ws-tls)
      lines+=("security      : TLS")
      [[ "$mode" == "ws-tls" ]] && lines+=("network/path  : ws ${VT_WS_PATH:-/}")
      lines+=("flow          : ${VT_FLOW:-n/a}")
      lines+=("sni           : ${host}")
      if [[ "${VT_SELF_SIGNED:-0}" == "1" ]]; then
        lines+=("certificate   : self-signed -> allowInsecure required")
      else
        lines+=("certificate   : Let's Encrypt (auto-renewing)")
      fi
      ;;
  esac
  lines+=(" ")
  lines+=("share link:")
  lines+=("  ${link}")

  box "connection config (${email})" "${lines[@]}"

  local out; out=$(p "$R_ETC/config.txt")
  {
    printf '%s\n' "${lines[@]#  }"
    printf '\n'
  } >"$out" 2>/dev/null || true
  chmod 600 "$out" 2>/dev/null || true

  if [[ "$show_qr" == "yes" ]]; then
    print_qr "$link"
  fi

  cat <<'HINT'

  ── how to route ALL of your traffic through this server ───────────────
   Android  : v2rayNG / Happ / Streisand -> add the link above, then enable
              "TUN" mode or "Global / all traffic" routing.
   Windows  : v2rayN -> Import from clipboard -> set routing to "Global"
              and press "Set system proxy".
   macOS/iOS: Streisand or V2Box -> add the link -> Set as system proxy.
   Linux    : run the generated client.json with xray/v2ray and point the
              system proxy at 127.0.0.1:10808 (SOCKS) or :10809 (HTTP).
  ───────────────────────────────────────────────────────────────────────
HINT
}

# Write a ready-to-run client config for the given user.
write_client_config() {
  local email="${1:-${VT_EMAIL:-main}}" out="${2:-}"
  local prev="${VT_EMAIL:-}"
  VT_EMAIL="$email"
  if [[ -z "$out" ]]; then
    out=$(p "$R_ETC")/client-${email}.json
  fi
  build_client_config "$out"
  VT_EMAIL="$prev"
  chmod 600 "$out"
  log_ok "client config written: $out"
  printf '%s\n' "$out"
}