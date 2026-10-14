#!/usr/bin/env bash
# client_gen.sh — share links, QR codes and human-readable output.

# vless://<uuid>@<host>:<port>?<params>#<remark>
share_link() {
  local email="${1:-${VT_EMAIL:-main}}"
  local uuid remark host port mode
  uuid=$(users_get_uuid "$email")
  [[ -n "$uuid" ]] || { log_err "کاربر «$email» پیدا نشد."; return 1; }
  remark=$(jq -r --arg e "$email" '.users[] | select(.email==$e) | (.remark // .email)' \
            "$(users_file)" 2>/dev/null)
  [[ -n "$remark" && "$remark" != "null" ]] || remark="$email"
  host="${VT_HOST:?}"; port="${VT_PORT:?}"; mode="${VT_MODE:?}"

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
    *) log_err "حالت ناشناخته: $mode"; return 1 ;;
  esac

  local qs=""
  local IFS='&'
  qs="${q[*]}"
  unset IFS
  printf 'vless://%s@%s:%s?%s#%s' "$uuid" "$host" "$port" "$qs" "$(urlencode "$remark")"
}

# Print the share link as a QR code in the terminal when qrencode exists.
print_qr() {
  local text="$1"
  if ! have qrencode; then
    log_note "qrencode نصب نیست — کد QR نمایش داده نمی‌شود (apt-get install qrencode)."
    return 0
  fi
  printf '\n'
  qrencode -t ANSIUTF8 -m 1 "$text" 2>/dev/null \
    || qrencode -t UTF8 "$text" 2>/dev/null \
    || { log_note "نمایش QR ناموفق بود."; return 0; }
}

# One-line summary per user, for `vt users list`.
print_users_table() {
  local f; f=$(users_file)
  [[ -f "$f" ]] || { log_warn "هیچ کاربری ثبت نشده."; return; }
  local email uuid remark created
  printf '\n%s\n' "${C_BOLD}  کاربر            UUID                                    ساخت${C_RESET}"
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
  lines+=("پروتکل        : VLESS (${mode})")
  lines+=("آدرس سرور     : ${host}")
  lines+=("پورت          : ${port}")
  lines+=("UUID          : $(users_get_uuid "$email")")
  case "$mode" in
    reality)
      lines+=("Security      : REALITY")
      lines+=("Flow          : ${VT_FLOW:-xtls-rprx-vision}")
      lines+=("SNI / Public  : ${VT_REALITY_SNI} / ${VT_REALITY_PUBLIC}")
      lines+=("ShortId       : ${VT_REALITY_SHORTID}")
      lines+=("Fingerprint   : chrome")
      ;;
    tcp-tls|ws-tls)
      lines+=("Security      : TLS")
      [[ "$mode" == "ws-tls" ]] && lines+=("Network/Path  : ws ${VT_WS_PATH:-/}")
      lines+=("Flow          : ${VT_FLOW:-—}")
      lines+=("SNI           : ${host}")
      if [[ "${VT_SELF_SIGNED:-0}" == "1" ]]; then
        lines+=("گواهی         : خودامضا → allowInsecure لازم است")
      else
        lines+=("گواهی         : Let's Encrypt (تمدید خودکار)")
      fi
      ;;
  esac
  lines+=(" ")
  lines+=("لینک اشتراک:")
  lines+=("  ${link}")

  box "کانفیگ اتصال (${email})" "${lines[@]}"

  local out; out=$(p "$R_ETC/config.txt")
  {
    printf '%s\n' "${lines[@]#"  "}" | sed 's/^لینک اشتراک:/لینک اشتراک:/'
    printf '\n'
  } >"$out" 2>/dev/null || true
  chmod 600 "$out" 2>/dev/null || true

  if [[ "$show_qr" == "yes" ]]; then
    print_qr "$link"
  fi

  cat <<'HINT'

  ── چطور «تمام» ترافیک سیستم را از این سرور عبور دهیم؟ ──────────────────
   موبایل   : v2rayNG / Happ / Streisand → لینک بالا را وارد کنید و حالت
              «TUN» یا «Global / تمام ترافیک» را فعال کنید.
   ویندوز   : v2rayN → Import from clipboard → Routing را روی
              «Global» بگذارید و «Set system proxy» را بزنید.
   macOS    : Streisand یا V2Box → لینک را اضافه کنید → Set as system proxy.
   لینوکس   : فایل client.json ساخته‌شده را با xray/v2ray اجرا کنید و
              پروکسی سیستم را روی 127.0.0.1:10808 تنظیم کنید.
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
  log_ok "کانفیگ کلاینت نوشته شد: $out"
  printf '%s\n' "$out"
}
