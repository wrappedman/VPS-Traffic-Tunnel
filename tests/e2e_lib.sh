#!/usr/bin/env bash
# tests/e2e_lib.sh — end-to-end install/uninstall dry-runs.
# Sourced by run_tests.sh; uses ok()/bad()/assert_*() from there.

_e2e_env() {
  # usage: _e2e_env <VT_ROOT> <command> [args...]
  #
  # run_tests.sh re-executes itself with sudo when it is not already root, so
  # by the time we get here we are root and a plain `env` is enough. Going
  # through sudo would needlessly require sudo to be installed on a box where
  # the suite already runs as root.
  local root="$1"; shift
  env \
    VT_ROOT="$root" \
    VT_ASSUME_YES=1 \
    VT_SKIP_DOWNLOADS=1 \
    VT_SKIP_APT=1 \
    VT_SKIP_SYSTEMD=1 \
    VT_NO_COLOR=1 \
    PATH="$PATH" \
    "$@"
}

# e2e_case <name> [vt install options...]
e2e_case() {
  local name="$1"; shift
  local args="$*"
  local root="$WORK/root-$name"
  mkdir -p "$root"
  # A real Ubuntu has /etc/logrotate.d; the installer only writes a rotation
  # rule when that directory already exists, so mimic the target system.
  mkdir -p "$root/etc/logrotate.d"

  if _e2e_env "$root" "$REPO/vt" install "$@" >"$root/install.out" 2>&1; then
    ok "install: $name"
  else
    bad "install: $name" "$(tail -n 25 "$root/install.out")"
    return 1
  fi

  local etc="$root/etc/vt"
  local sysd_dir="$root/etc/systemd/system"
  local conf="$root/usr/local/etc/xray/config.json"

  assert_file "$name: state file"        "$etc/vt.env"
  assert_file "$name: user store"        "$etc/users.json"
  assert_file "$name: xray config"       "$conf"
  assert_file "$name: text config"       "$etc/config.txt"
  assert_file "$name: client config"     "$etc/client.json"
  assert_file "$name: logrotate"         "$root/etc/logrotate.d/vt-tunnel"
  assert_file "$name: program in /opt/vt" "$root/opt/vt/vt"
  if [[ -L "$root/usr/local/bin/vt" ]]; then
    ok "$name: vt is on PATH"
  else
    bad "$name: vt is on PATH" "no /usr/local/bin/vt symlink"
  fi

  assert_file "$name: xray.service"      "$sysd_dir/xray.service"
  assert_file "$name: vt-health.service" "$sysd_dir/vt-health.service"
  assert_file "$name: vt-health.timer"   "$sysd_dir/vt-health.timer"
  assert_file "$name: vt-cert-renew.service" "$sysd_dir/vt-cert-renew.service"
  assert_file "$name: vt-cert-renew.timer"   "$sysd_dir/vt-cert-renew.timer"

  # Unit files must contain real (unprefixed) paths, otherwise systemd on the
  # target machine would point at a directory that does not exist.
  if grep -q "$root" "$sysd_dir/xray.service"; then
    bad "$name: unit file has no test prefix" "found $root inside xray.service"
  else
    ok "$name: unit file uses real paths"
  fi
  assert_contains "$name: unit ExecStart" "$(cat "$sysd_dir/xray.service")" \
    "ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json"
  assert_contains "$name: unit WantedBy" "$(cat "$sysd_dir/xray.service")" "WantedBy=multi-user.target"
  assert_contains "$name: unit Restart"  "$(cat "$sysd_dir/xray.service")" "Restart=always"
  assert_contains "$name: timer target"  "$(cat "$sysd_dir/vt-cert-renew.timer")" "WantedBy=timers.target"

  # state contents
  local mode port users
  mode=$(sed -n 's/^MODE="\(.*\)"$/\1/p' "$etc/vt.env")
  port=$(sed -n 's/^PORT="\(.*\)"$/\1/p' "$etc/vt.env")
  users=$(jq '.users | length' "$etc/users.json")
  # The host we publish must be exactly the domain the user typed.
  if [[ "$args" == *"--domain "* ]]; then
    local want_dom
    want_dom=$(printf '%s' "$args" | sed -n 's/.*--domain \([^ ]*\).*/\1/p')
    assert_eq "$name: host keeps the full domain" "$want_dom" \
      "$(sed -n 's/^HOST="\(.*\)"$/\1/p' "$etc/vt.env")"
    assert_contains "$name: share link uses the full domain" \
      "$(jq -r '.outbounds[0].settings.vnext[0].address' "$root/etc/vt/client.json")" "$want_dom"
  fi

  assert_eq "$name: state MODE" "$(printf '%s' "$*" | sed -n 's/.*--mode \([a-z-]*\).*/\1/p')" "$mode"
  assert_eq "$name: one user created" "1" "$users"
  if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
    ok "$name: port is numeric ($port)"
  else
    bad "$name: port is numeric" "got [$port]"
  fi
  assert_eq "$name: config port matches state" "$port" "$(jq '.inbounds[0].port' "$conf")"
  assert_json "$name: config JSON is well formed" ".inbounds | length > 0" "$conf"

  local uuid_conf uuid_store
  uuid_conf=$(jq -r '.inbounds[0].settings.clients[0].id' "$conf")
  uuid_store=$(jq -r '.users[0].uuid' "$etc/users.json")
  assert_eq "$name: uuid in config == uuid in store" "$uuid_store" "$uuid_conf"

  # per-mode expectations
  case "$mode" in
    reality)
      assert_json "$name: reality security" \
        '.inbounds[0].streamSettings.security == "reality"' "$conf"
      assert_json "$name: reality has a private key" \
        '.inbounds[0].streamSettings.realitySettings.privateKey | length == 43' "$conf"
      assert_json "$name: reality has a shortId" \
        '.inbounds[0].streamSettings.realitySettings.shortIds | length > 0' "$conf"
      assert_json "$name: reality clients use vision flow" \
        '.inbounds[0].settings.clients[0].flow == "xtls-rprx-vision"' "$conf"
      assert_contains "$name: share link is reality" "$(cat "$etc/config.txt")" "vless://"
      ;;
    ws-tls)
      assert_json "$name: ws network" '.inbounds[0].streamSettings.network == "ws"' "$conf"
      assert_json "$name: ws path starts with /" \
        '.inbounds[0].streamSettings.wsSettings.path | startswith("/")' "$conf"
      assert_json "$name: ws clients have no flow" \
        '.inbounds[0].settings.clients[0] | has("flow") | not' "$conf"
      assert_file "$name: tls certificate" "$etc/certs/fullchain.pem"
      assert_file "$name: tls private key" "$etc/certs/privkey.pem"
      assert_contains "$name: cert path recorded in state" "$(cat "$etc/vt.env")" \
        'TLS_CERT_FILE="/etc/vt/certs/fullchain.pem"'
      ;;
    tcp-tls)
      assert_json "$name: tcp-tls network" '.inbounds[0].streamSettings.network == "tcp"' "$conf"
      assert_json "$name: tcp-tls security" '.inbounds[0].streamSettings.security == "tls"' "$conf"
      assert_file "$name: tls certificate" "$etc/certs/fullchain.pem"
      assert_contains "$name: cert path recorded in state" "$(cat "$etc/vt.env")" \
        'TLS_CERT_FILE="/etc/vt/certs/fullchain.pem"'
      ;;
  esac

  # The API must never be exposed publicly.
  assert_json "$name: api bound to loopback" '.inbounds[1].listen == "127.0.0.1"' "$conf"

  # ---- day-2 operations on the finished install --------------------------
  if [[ "$mode" == "reality" ]]; then
    local pub_before sid_after
    pub_before=$(sed -n 's/^REALITY_PUBLIC="\(.*\)"$/\1/p' "$etc/vt.env")
    if _e2e_env "$root" "$REPO/vt" rotate-keys >>"$root/install.out" 2>&1; then
      local pub_after
      pub_after=$(sed -n 's/^REALITY_PUBLIC="\(.*\)"$/\1/p' "$etc/vt.env")
      if [[ -n "$pub_after" && "$pub_before" != "$pub_after" ]]; then
        ok "$name: rotate-keys changes the keypair"
      else
        bad "$name: rotate-keys changes the keypair" "before=$pub_before after=$pub_after"
      fi
      sid_after=$(sed -n 's/^REALITY_SHORTID="\(.*\)"$/\1/p' "$etc/vt.env")
      assert_eq "$name: rotate-keys rewrites config.json" "$sid_after" \
        "$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$conf")"
    else
      bad "$name: rotate-keys" "$(tail -n 15 "$root/install.out")"
    fi
  fi

  if _e2e_env "$root" "$REPO/vt" add-user e2euser >>"$root/install.out" 2>&1; then
    assert_eq "$name: add-user updates the store" "2" "$(jq '.users|length' "$etc/users.json")"
    assert_eq "$name: add-user updates config.json" "2" \
      "$(jq '.inbounds[0].settings.clients|length' "$conf")"
  else
    bad "$name: add-user" "$(tail -n 15 "$root/install.out")"
  fi

  if _e2e_env "$root" "$REPO/vt" rm-user e2euser >>"$root/install.out" 2>&1; then
    assert_eq "$name: rm-user updates config.json" "1" \
      "$(jq '.inbounds[0].settings.clients|length' "$conf")"
  else
    bad "$name: rm-user" "$(tail -n 15 "$root/install.out")"
  fi

  if _e2e_env "$root" "$REPO/vt" renew-cert --quiet >>"$root/install.out" 2>&1; then
    ok "$name: renew-cert runs"
  else
    bad "$name: renew-cert runs" "$(tail -n 15 "$root/install.out")"
  fi

  # vt-cert-renew.service and vt-health.service call `vt ... --quiet` from
  # systemd, so those invocations must not print anything to stdout/stderr.
  local quiet_out
  quiet_out=$(_e2e_env "$root" "$REPO/vt" renew-cert --quiet 2>&1) || true
  if [[ -z "$quiet_out" ]]; then
    ok "$name: renew-cert --quiet is silent"
  else
    bad "$name: renew-cert --quiet is silent" "$quiet_out"
  fi
  quiet_out=$(_e2e_env "$root" "$REPO/vt" health --quiet 2>&1) || true
  if [[ -z "$quiet_out" ]]; then
    ok "$name: health --quiet is silent"
  else
    bad "$name: health --quiet is silent" "$quiet_out"
  fi

  # ---- backup / restore -------------------------------------------------
  # `vt backup` used to write the tarball into the very directory it was
  # archiving, and `vt restore` answered its own prompt with "no" whenever
  # VT_ASSUME_YES was set, so an unattended restore silently did nothing.
  local bk
  # Mark the state file *before* the backup so the restore has something to
  # bring back that the installer itself would not recreate.
  grep -q '^REVIEW_MARKER=' "$etc/vt.env" 2>/dev/null \
    || printf 'REVIEW_MARKER="1"\n' >>"$etc/vt.env"
  if bk=$(_e2e_env "$root" "$REPO/vt" backup 2>>"$root/install.out" | tail -n1) \
     && [[ -f "$bk" ]]; then
    ok "$name: backup creates an archive"
    if tar tzf "$bk" >/dev/null 2>&1; then
      ok "$name: the archive is not corrupt"
    else
      bad "$name: the archive is not corrupt" "tar tzf $bk failed"
    fi
    if tar tzf "$bk" | grep -q '^etc/vt/'; then
      ok "$name: the archive keeps rooted member names"
    else
      bad "$name: the archive keeps rooted member names" "$(tar tzf "$bk" | head -5)"
    fi
    # Wipe what the backup holds, restore, and check it all came back.
    rm -f "$conf" "$etc/vt.env"
    if _e2e_env "$root" "$REPO/vt" restore "$bk" --force >>"$root/install.out" 2>&1; then
      assert_contains "$name: restore brings the state file back" "$(cat "$etc/vt.env")" "REVIEW_MARKER="
      assert_file "$name: restore rebuilds the xray config" "$conf"
    else
      bad "$name: restore" "$(tail -n 15 "$root/install.out")"
    fi
    rm -f "$bk" "$etc/vt.env.bak"
  else
    bad "$name: backup creates an archive" "$(tail -n 15 "$root/install.out")"
  fi

  # Second run over the same root must be refused politely, not crash.
  if _e2e_env "$root" "$REPO/vt" status >>"$root/install.out" 2>&1; then
    ok "$name: vt status after install"
  else
    bad "$name: vt status after install" "$(tail -n 10 "$root/install.out")"
  fi
}

e2e_uninstall() {
  local name="$1"
  local root="$WORK/root-$name"
  [[ -d "$root" ]] || { bad "uninstall: $name" "no such install root"; return 1; }

  if _e2e_env "$root" "$REPO/vt" uninstall --force --yes >>"$root/uninstall.out" 2>&1; then
    ok "uninstall: $name"
  else
    bad "uninstall: $name" "$(tail -n 25 "$root/uninstall.out")"
    return 1
  fi

  for gone in \
    "$root/usr/local/bin/xray" \
    "$root/usr/local/etc/xray/config.json" \
    "$root/etc/systemd/system/xray.service" \
    "$root/etc/systemd/system/vt-health.timer" \
    "$root/etc/systemd/system/vt-cert-renew.timer" \
    "$root/etc/logrotate.d/vt-tunnel"
  do
    if [[ -e "$gone" ]]; then bad "uninstall removed $(basename "$gone")" "still present"; else ok "uninstall removed $(basename "$gone")"; fi
  done
  # /etc/vt is kept unless --purge is given.
  if [[ -d "$root/etc/vt" ]]; then
    ok "uninstall keeps /etc/vt by default"
  else
    bad "uninstall keeps /etc/vt by default" "it was deleted"
  fi

  if _e2e_env "$root" "$REPO/vt" uninstall --force --yes --purge >>"$root/uninstall2.out" 2>&1; then
    if [[ -d "$root/etc/vt" ]]; then
      bad "uninstall --purge removes /etc/vt" "still present"
    else
      ok "uninstall --purge removes /etc/vt"
    fi
  else
    bad "uninstall --purge" "$(tail -n 15 "$root/uninstall2.out")"
  fi
}
