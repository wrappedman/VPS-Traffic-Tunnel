#!/usr/bin/env bash
# state.sh — persistent install state (/etc/vt/vt.env) and the user list.

# Load the state file into the shell as VT_* variables. Missing file is fine.
state_load() {
  local f; f=$(p "$R_STATE")
  [[ -f "$f" ]] || return 0
  # Only accept KEY=VALUE lines with our own key names, never `source` blindly.
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*# ]]; then continue; fi
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    # strip surrounding quotes
    val="${val%\"}"; val="${val#\"}"
    printf -v "VT_${key}" '%s' "$val"
  done <"$f"
  export VT_STATE_LOADED=1
}

state_save() {
  local f; f=$(p "$R_STATE")
  mkdir -p "$(p "$R_ETC")"
  local tmp="${f}.tmp.$$"
  {
    printf '# %s state — generated %s\n' "$VT_PROJECT" "$(date -Is)"
    printf '# Edit only if you know what you are doing; prefer the vt menu.\n'
    local key
    for key in "${_STATE_KEYS[@]}"; do
      local var="VT_${key}"
      printf '%s="%s"\n' "$key" "${!var-}"
    done
  } >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$f"
}

# Keys persisted between runs.
_STATE_KEYS=(
  MODE HOST PORT EMAIL DOMAIN CERT_MODE CERT_KIND
  REALITY_SNI REALITY_DEST REALITY_PRIVATE REALITY_PUBLIC REALITY_SHORTID
  TLS_SNI REJECT_UNKNOWN_SNI
  TLS_CERT_FILE TLS_KEY_FILE WS_PATH
  API_PORT SSH_PORT PUBLIC_IP PUBLIC_IPV6 AD_BLOCK BLOCK_TORRENT
  INSTALLED_AT XRAY_VERSION FLOW SELF_SIGNED
)

state_get() { local v="VT_$1"; printf '%s' "${!v-}"; }

is_installed() {
  local f; f=$(p "$R_STATE")
  [[ -f "$f" ]] || return 1
  [[ -n "$(state_get INSTALLED_AT)" ]] || return 1
  return 0
}

# --------------------------------------------------------------------------
# User list — /etc/vt/users.json
#   {"users":[{"email":"main","uuid":"...","remark":"...","created":"..."}]}
# --------------------------------------------------------------------------
users_file() { p "$R_USERS"; }

users_init() {
  local f; f=$(users_file)
  if [[ ! -f "$f" ]]; then
    mkdir -p "$(dirname "$f")"
    printf '{"users":[]}\n' >"$f"
    chmod 600 "$f"
  fi
}

users_count() {
  local f; f=$(users_file)
  [[ -f "$f" ]] || { printf '0'; return; }
  jq '.users | length' "$f" 2>/dev/null || printf '0'
}

users_exists() {
  local f email="$1"; f=$(users_file)
  [[ -n "$email" ]] || return 1
  [[ -f "$f" ]] || return 1
  [[ "$(jq -r --arg e "$email" '.users | map(.email) | index($e) // empty' "$f" 2>/dev/null)" != "" ]]
}

users_add() {
  # users_add <email> <uuid> <remark>
  local email="$1" uuid="$2" remark="${3:-}" f
  [[ -n "$email" && -n "$uuid" ]] || return 1
  users_init
  f=$(users_file)
  if users_exists "$email"; then
    log_warn "user '$email' already exists."
    return 1
  fi
  local tmp; tmp=$(mktemp)
  if jq --arg e "$email" --arg u "$uuid" --arg r "$remark" --arg c "$(date -Is)" \
    '.users += [{"email":$e,"uuid":$u,"remark":$r,"created":$c}]' "$f" >"$tmp" 2>/dev/null; then
    cat "$tmp" >"$f"
    rm -f "$tmp"
    chmod 600 "$f"
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

users_remove() {
  local email="$1" f tmp; f=$(users_file)
  [[ -n "$email" ]] || return 1
  [[ -f "$f" ]] || return 1
  tmp=$(mktemp)
  if jq --arg e "$email" '.users |= map(select(.email != $e))' "$f" >"$tmp" 2>/dev/null; then
    cat "$tmp" >"$f"
    rm -f "$tmp"
    return 0
  else
    rm -f "$tmp"
    return 1
  fi
}

users_get_uuid() {
  local email="$1" f; f=$(users_file)
  [[ -n "$email" ]] || return 1
  [[ -f "$f" ]] || return 1
  jq -r --arg e "$email" '.users[] | select(.email==$e) | .uuid' "$f" 2>/dev/null
}

users_list_emails() {
  local f; f=$(users_file)
  [[ -f "$f" ]] || return 0
  jq -r '.users[].email' "$f" 2>/dev/null
}

# Emit the "clients" array for the Xray inbound.
users_clients_json() {
  local flow="${1:-}" f; f=$(users_file)
  users_init
  if [[ -n "$flow" ]]; then
    jq -c --arg flow "$flow" \
      '[.users[] | {id:.uuid, email:.email, level:0, flow:$flow}]' "$f" 2>/dev/null || printf '[]'
  else
    jq -c '[.users[] | {id:.uuid, email:.email, level:0}]' "$f" 2>/dev/null || printf '[]'
  fi
}