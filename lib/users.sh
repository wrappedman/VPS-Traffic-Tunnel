#!/usr/bin/env bash
# users.sh — client (user) management commands.

cmd_add_user() {
  local email="${1:-}" uuid="${2:-}"
  if [[ -z "$email" ]]; then
    ask email "user name (letters, no spaces)" "user$(($(users_count) + 1))"
  fi
  if ! [[ "$email" =~ ^[a-zA-Z0-9._-]{1,32}$ ]]; then
    die "invalid user name (only a-z A-Z 0-9 . _ - and at most 32 characters)."
  fi
  if users_exists "$email"; then
    die "user '$email' already exists."
  fi
  [[ -n "$uuid" ]] || uuid=$(gen_uuid)

  users_add "$email" "$uuid" "$email" || die "failed to add the user."
  apply_config || die "failed to rebuild the configuration."

  log_ok "user '$email' added."
  local link; link=$(share_link "$email") || return 1
  printf '\n  %s\n\n' "${C_GREEN}${link}${C_RESET}"
  print_qr "$link"
}

cmd_remove_user() {
  local email="${1:-}"
  if [[ -z "$email" ]]; then
    local -a emails=()
    mapfile -t emails < <(users_list_emails)
    if (( ${#emails[@]} == 0 )); then
      die "there are no users."
    fi
    menu_pick idx "which user should be removed?" "${emails[@]}"
    email="${emails[$((idx - 1))]}"
  fi
  users_exists "$email" || die "user '$email' not found."
  if (( $(users_count) <= 1 )); then
    if ! confirm "this is the only user; removing it will disconnect you. Continue?" n; then
      return 0
    fi
  fi
  users_remove "$email" || die "failed to remove the user."
  apply_config || die "failed to rebuild the configuration."
  log_ok "user '$email' removed."
}

cmd_list_users() {
  print_users_table
  local email link
  while IFS= read -r email; do
    [[ -n "$email" ]] || continue
    link=$(share_link "$email") || continue
    printf '  %s\n    %s\n\n' "${C_BOLD}${email}${C_RESET}" "$link"
  done < <(users_list_emails)
}

cmd_rotate_uuid() {
  local email="${1:-${VT_EMAIL:-main}}"
  users_exists "$email" || die "user '$email' not found."
  local f; f=$(users_file)
  local new; new=$(gen_uuid)
  local tmp; tmp=$(mktemp)
  jq --arg e "$email" --arg u "$new" \
    '.users |= map(if .email == $e then .uuid = $u else . end)' "$f" >"$tmp" \
    && cat "$tmp" >"$f"
  rm -f "$tmp"
  chmod 600 "$f"
  apply_config || die "failed to rebuild the configuration."
  log_ok "UUID for user '$email' rotated: $new"
  local link; link=$(share_link "$email") && printf '\n  %s\n\n' "$link"
}

# --------------------------------------------------------------------------
# Traffic statistics through the Xray API
# --------------------------------------------------------------------------
_api_stat() {
  local name="$1" bin; bin=$(p "$R_XRAY_BIN")
  [[ -x "$bin" ]] || return 1
  [[ -n "${VT_API_PORT:-}" ]] || return 1
  
  local raw
  raw=$("$bin" api stats --server="127.0.0.1:${VT_API_PORT}" -name "$name" -reset 2>/dev/null)
  if have jq; then
    # Try parsing as JSON if Xray outputs JSON format
    local val
    val=$(jq -r '.stat.value // .value // empty' <<<"$raw" 2>/dev/null)
    if [[ -n "$val" && "$val" != "null" ]]; then
      printf '%s' "$val"
      return 0
    fi
  fi
  # Fallback to awk matching for text output (case-insensitive)
  awk 'IGNORECASE=1; /value:/ {print $2}' <<<"$raw" | head -n1
}

cmd_stats() {
  local email up down
  printf '\n%s\n' "${C_BOLD}  traffic used (since the counters were last reset)${C_RESET}"
  printf '  %s\n' "────────────────────────────────────────────────────"
  while IFS= read -r email; do
    [[ -n "$email" ]] || continue
    up=$(_api_stat "user>>>${email}>>>traffic>>>uplink")
    down=$(_api_stat "user>>>${email}>>>traffic>>>downlink")
    printf '  %-16s ↑ %-14s ↓ %s\n' "$email" \
      "$(fmt_bytes "${up:-0}")" "$(fmt_bytes "${down:-0}")"
  done < <(users_list_emails)
  printf '\n'
}

fmt_bytes() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  awk -v b="$b" 'BEGIN {
    split("B KB MB GB TB", u, " ");
    i = 1;
    while (b >= 1024 && i < 5) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.2f %s"), b, u[i];
  }'
}

# Number of currently established tunnel connections.
cmd_connections() {
  local port="${VT_PORT:-}"
  [[ -n "$port" ]] || { log_warn "no port recorded in state."; return 1; }
  if ! have ss; then
    log_warn "ss is not available."
    return 1
  fi
  printf '\n  established connections on port %s:\n' "$port"
  ss -Htn state established "( sport = :${port} )" 2>/dev/null | head -n 40 \
    | awk '{printf "    %-45s %s\n", $4, $5}'
  local n
  n=$(ss -Htn state established "( sport = :${port} )" 2>/dev/null | wc -l)
  printf '\n  total: %s connections\n\n' "$n"
}