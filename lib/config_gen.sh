#!/usr/bin/env bash
# config_gen.sh — builds /usr/local/etc/xray/config.json for the selected mode.
#
# Supported modes:
#   reality  : VLESS + TCP + REALITY (XTLS Vision). No certificate needed,
#              works on a bare IP, hardest to detect. Recommended default.
#   ws-tls   : VLESS + WebSocket + TLS on port 443. Needs a certificate and
#              looks like ordinary HTTPS traffic.
#   tcp-tls  : VLESS + TCP + TLS on a random port. Needs a certificate.

# Private address ranges. Proxied connections to these are dropped so the
# tunnel cannot be abused to scan the VPS provider's internal network.
PRIVATE_CIDRS_JSON='["10.0.0.0/8","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","100.64.0.0/10","::1/128","fc00::/7","fe80::/10"]'

# --------------------------------------------------------------------------
# build_xray_config <mode> <outfile>
# --------------------------------------------------------------------------
build_xray_config() {
  local mode="$1" out="$2"

  local port="${VT_PORT:?VT_PORT is not set}"
  local api_port="${VT_API_PORT:-62789}"
  local clients flow=""

  case "$mode" in
    reality|tcp-tls) flow="${VT_FLOW:-xtls-rprx-vision}" ;;
    ws-tls) flow="" ;;
    *) fail "unknown mode: $mode" ;;
  esac
  clients=$(users_clients_json "$flow")
  if [[ -z "$clients" || "$clients" == "[]" ]]; then
    fail "no users defined; add a user first."
  fi

  local stream
  case "$mode" in
    reality)  stream=$(_stream_reality) ;;
    tcp-tls)  stream=$(_stream_tls_tcp) ;;
    ws-tls)   stream=$(_stream_tls_ws) ;;
  esac

  local rules
  rules=$(_routing_rules)

  local tor_rule=""
  if [[ "${VT_BLOCK_TORRENT:-0}" == "1" ]]; then
    tor_rule=',
      {
        "type": "field",
        "outboundTag": "block",
        "protocol": ["bittorrent"]
      }'
  fi

  mkdir -p "$(dirname "$out")"
  cat >"$out" <<EOF
{
  "log": {
    "loglevel": "warning",
    "dnsLog": false,
    "error": "$R_LOG/xray-error.log"
  },
  "api": {
    "tag": "api",
    "services": ["HandlerService", "StatsService", "LoggerService"]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "statsUserUplink": true,
        "statsUserDownlink": true,
        "bufferSize": 512
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "ip": $PRIVATE_CIDRS_JSON,
        "outboundTag": "block"
      }${tor_rule}${rules:+,
$rules}
    ]
  },
  "inbounds": [
    {
      "tag": "vt-in",
      "listen": "0.0.0.0",
      "port": $port,
      "protocol": "vless",
      "settings": {
        "clients": $clients,
        "decryption": "none"
      },
      "streamSettings": $stream,
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": false,
        "routeOnly": false
      }
    },
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": $api_port,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {
        "response": {
          "type": "http"
        }
      }
    }
  ]
}
EOF
  validate_json_file "$out" || fail "generated config is not valid JSON: $out"
}

# --------------------------------------------------------------------------
# streamSettings builders
# --------------------------------------------------------------------------
_stream_reality() {
  local sni="${VT_REALITY_SNI:?}" dest="${VT_REALITY_DEST:?}"
  local priv="${VT_REALITY_PRIVATE:?}" shortid="${VT_REALITY_SHORTID:?}"
  cat <<EOF
{
        "network": "tcp",
        "security": "reality",
        "tcpSettings": {
          "acceptProxyProtocol": false,
          "header": { "type": "none" }
        },
        "realitySettings": {
          "show": false,
          "dest": "$dest",
          "xver": 0,
          "serverNames": ["$sni"],
          "privateKey": "$priv",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": ["", "$shortid"]
        }
      }
EOF
}

_stream_tls_tcp() {
  local reject="false"
  if [[ "${VT_REJECT_UNKNOWN_SNI:-0}" == "1" && "${VT_SELF_SIGNED:-0}" != "1" ]]; then
    reject="true"
  fi
  cat <<EOF
{
        "network": "tcp",
        "security": "tls",
        "tcpSettings": {
          "acceptProxyProtocol": false,
          "header": { "type": "none" }
        },
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "$R_CERT_FILE",
              "keyFile": "$R_KEY_FILE",
              "ocspStapling": 3600
            }
          ],
          "alpn": ["h2", "http/1.1"],
          "minVersion": "1.2",
          "maxVersion": "1.3",
          "rejectUnknownSni": $reject
        }
      }
EOF
}

_stream_tls_ws() {
  local path="${VT_WS_PATH:-/}"
  local reject="false"
  if [[ "${VT_REJECT_UNKNOWN_SNI:-0}" == "1" && "${VT_SELF_SIGNED:-0}" != "1" ]]; then
    reject="true"
  fi
  cat <<EOF
{
        "network": "ws",
        "security": "tls",
        "wsSettings": {
          "acceptProxyProtocol": false,
          "path": "$path"
        },
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "$R_CERT_FILE",
              "keyFile": "$R_KEY_FILE",
              "ocspStapling": 3600
            }
          ],
          "alpn": ["http/1.1"],
          "minVersion": "1.2",
          "maxVersion": "1.3",
          "rejectUnknownSni": $reject
        }
      }
EOF
}

# Extra routing rules that depend on downloaded geo databases.
_routing_rules() {
  local out=""
  if [[ "${VT_AD_BLOCK:-0}" == "1" && -s "$(p "$R_XRAY_ASSETS/geosite.dat")" ]]; then
    out+='      {
        "type": "field",
        "outboundTag": "block",
        "domain": ["geosite:category-ads-all"]
      }'
  fi
  printf '%s' "$out"
}

# --------------------------------------------------------------------------
# Regenerate + validate + reload. Used by every mutating command.
# --------------------------------------------------------------------------
apply_config() {
  local mode="${VT_MODE:?VT_MODE is not set}"
  local out; out=$(p "$R_XRAY_CONF")
  local backup="${out}.bak"
  if [[ -f "$out" ]]; then cp -f "$out" "$backup"; fi
  build_xray_config "$mode" "$out"
  chmod 600 "$out"
  if ! xray_test_config "$out"; then
    if [[ -f "$backup" ]]; then
      cp -f "$backup" "$out"
      log_warn "previous configuration restored."
    fi
    return 1
  fi
  if [[ -n "${VT_EMAIL:-}" ]] && users_exists "${VT_EMAIL}"; then
    write_client_config "$VT_EMAIL" "$(p "$R_ETC")/client.json" >/dev/null 2>&1 || true
  fi
  sysd restart xray.service || log_warn "failed to restart the xray service."
  return 0
}

# Client-side configuration (v2ray-core / Xray-core compatible).
# The SOCKS/HTTP listeners let the user route *all* of their system traffic
# through the tunnel (TUN mode or a system-wide proxy).
build_client_config() {
  local out="$1"
  local mode="${VT_MODE:?}" host="${VT_HOST:?}" port="${VT_PORT:?}"
  local email uuid flow="" user_json stream_json insecure="false"
  email="${VT_EMAIL:-main}"
  uuid=$(users_get_uuid "$email")
  [[ -n "$uuid" ]] || fail "user '$email' not found."
  if [[ "${VT_SELF_SIGNED:-0}" == "1" ]]; then insecure="true"; fi
  case "$mode" in
    reality|tcp-tls) flow="${VT_FLOW:-xtls-rprx-vision}" ;;
    *) flow="" ;;
  esac
  case "$mode" in
    reality)
      user_json=$(_client_user "$uuid" "$flow")
      stream_json=$(_client_stream_reality)
      ;;
    tcp-tls)
      user_json=$(_client_user "$uuid" "$flow")
      stream_json=$(_client_stream_tls "$insecure")
      ;;
    ws-tls)
      user_json=$(_client_user "$uuid" "")
      stream_json=$(_client_stream_ws "$insecure")
      ;;
  esac

  cat >"$out" <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "ip": $PRIVATE_CIDRS_JSON, "outboundTag": "direct" }
    ]
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": 10808,
      "protocol": "socks",
      "settings": { "udp": true, "auth": "noauth" },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    },
    {
      "tag": "http-in",
      "listen": "127.0.0.1",
      "port": 10809,
      "protocol": "http"
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "$host",
            "port": $port,
            "users": [ $user_json ]
          }
        ]
      },
      "streamSettings": $stream_json
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ]
}
EOF
  validate_json_file "$out" || log_warn "client config is not valid JSON"
}

_client_user() {
  local uuid="$1" flow="$2"
  if [[ -n "$flow" ]]; then
    printf '{ "id": "%s", "flow": "%s", "encryption": "none", "level": 0 }' "$uuid" "$flow"
  else
    printf '{ "id": "%s", "encryption": "none", "level": 0 }' "$uuid"
  fi
}

_client_stream_reality() {
  cat <<EOF
{
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "${VT_REALITY_SNI}",
          "fingerprint": "chrome",
          "publicKey": "${VT_REALITY_PUBLIC}",
          "shortId": "${VT_REALITY_SHORTID}",
          "spiderX": "/"
        }
      }
EOF
}

_client_stream_tls() {
  local insecure="$1"
  cat <<EOF
{
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${VT_HOST}",
          "allowInsecure": $insecure,
          "fingerprint": "chrome",
          "alpn": ["h2", "http/1.1"]
        }
      }
EOF
}

_client_stream_ws() {
  local insecure="$1"
  cat <<EOF
{
        "network": "ws",
        "security": "tls",
        "wsSettings": {
          "path": "${VT_WS_PATH:-/}",
          "headers": { "Host": "${VT_HOST}" }
        },
        "tlsSettings": {
          "serverName": "${VT_HOST}",
          "allowInsecure": $insecure,
          "fingerprint": "chrome",
          "alpn": ["http/1.1"]
        }
      }
EOF
}