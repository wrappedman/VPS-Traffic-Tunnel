#!/usr/bin/env bash
# common.sh — logging, prompts, path layout, small helpers.
# Sourced by `vt`. Not meant to be executed directly.

# --------------------------------------------------------------------------
# Version / identity
# --------------------------------------------------------------------------
VT_VERSION="1.0.0"
VT_PROJECT="VPS-Traffic-Tunnel"
VT_HOME_URL="https://github.com/wrappedman/VPS-Traffic-Tunnel"

# --------------------------------------------------------------------------
# Path layout
#
# R_*  = "runtime" paths: absolute paths on the real machine. These are the
#        strings that end up inside systemd units and inside the Xray config.
# $(p <path>) = the same path on the filesystem we are operating on. It is
#        prefixed with $VT_ROOT, which is empty on a real machine and points
#        at a scratch directory during the test suite. That single indirection
#        is what makes a full install dry-run possible without a container.
# --------------------------------------------------------------------------
VT_ROOT="${VT_ROOT:-}"

R_ETC="/etc/vt"
R_STATE="$R_ETC/vt.env"
R_USERS="$R_ETC/users.json"
R_CERT_DIR="$R_ETC/certs"
R_ACME_HOME="$R_ETC/acme"
R_ACME_BIN="$R_ETC/acme.sh"
R_LIB="/var/lib/vt"
R_LOG="/var/log/vt"
R_XRAY_BIN="/usr/local/bin/xray"
R_XRAY_ASSETS="/usr/local/share/xray"
R_XRAY_CONF_DIR="/usr/local/etc/xray"
R_XRAY_CONF="$R_XRAY_CONF_DIR/config.json"
R_XRAY_SERVICE="/etc/systemd/system/xray.service"
R_VT_HEALTH_SERVICE="/etc/systemd/system/vt-health.service"
R_VT_HEALTH_TIMER="/etc/systemd/system/vt-health.timer"
R_VT_CERT_SERVICE="/etc/systemd/system/vt-cert-renew.service"
R_VT_CERT_TIMER="/etc/systemd/system/vt-cert-renew.timer"
R_SYSCTL="/etc/sysctl.d/99-vt-tunnel.conf"
R_SWAPFILE="/swapfile.vt"
R_INSTALL_DIR="/opt/vt"

# Map a runtime path onto the filesystem we are writing to.
p() { printf '%s%s' "$VT_ROOT" "$1"; }

# --------------------------------------------------------------------------
# Runtime knobs (overridable from the environment, mostly for the test suite)
# --------------------------------------------------------------------------
VT_ASSUME_YES="${VT_ASSUME_YES:-0}"     # never prompt, take the default
VT_SKIP_DOWNLOADS="${VT_SKIP_DOWNLOADS:-0}"  # do not fetch anything from the net
VT_SKIP_APT="${VT_SKIP_APT:-0}"         # do not call apt-get
VT_SKIP_SYSTEMD="${VT_SKIP_SYSTEMD:-0}" # do not talk to systemd
VT_FORCE="${VT_FORCE:-0}"               # ignore "already installed" guard
VT_NO_COLOR="${VT_NO_COLOR:-0}"

# --------------------------------------------------------------------------
# Terminal colours (disabled when not a tty, when NO_COLOR is set, or when
# the caller asked for plain output).
# --------------------------------------------------------------------------
if [[ -t 1 && "$VT_NO_COLOR" != "1" && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';   C_DIM=$'\033[2m'
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()  { printf '%s\n' "${C_BLUE}[i]${C_RESET} $*"; }
log_ok()    { printf '%s\n' "${C_GREEN}[✓]${C_RESET} $*"; }
log_warn()  { printf '%s\n' "${C_YELLOW}[!]${C_RESET} $*" >&2; }
log_err()   { printf '%s\n' "${C_RED}[✗]${C_RESET} $*" >&2; }
log_step()  { printf '\n%s\n' "${C_BOLD}${C_CYAN}==> $*${C_RESET}"; }
log_note()  { printf '%s\n' "${C_DIM}    $*${C_RESET}"; }

die() {
  log_err "$*"
  exit 1
}

# Fatal error that also gets written to the install log when we have one.
fail() {
  log_err "$*"
  if [[ -n "${VT_LOG_FILE:-}" && -w "$(dirname "$VT_LOG_FILE")" ]]; then
    printf '%s FATAL: %s\n' "$(_ts)" "$*" >>"$VT_LOG_FILE" 2>/dev/null || true
  fi
  exit 1
}

# --------------------------------------------------------------------------
# Small utilities
# --------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

is_root() { [[ "$(id -u)" -eq 0 ]]; }

require_root() {
  if ! is_root; then
    die "this script must run as root. (Run with: sudo $0 $*)"
  fi
}

# Is a real systemd instance managing this machine?
systemd_running() {
  [[ "$VT_SKIP_SYSTEMD" != "1" ]] || return 1
  [[ -d /run/systemd/system ]] || return 1
  have systemctl || return 1
}

sysd() {
  # systemctl wrapper: silently no-ops where systemd is unavailable (tests).
  if systemd_running; then
    systemctl "$@"
  else
    log_note "[dry] systemctl $*"
    return 0
  fi
}

confirm() {
  # confirm "question" [default: y|n]
  #
  # Internals use __-prefixed names on purpose: `printf -v "$__var"` and
  # `read` write to the innermost matching scope, so a plain name like `ans`
  # here would silently shadow a caller variable called `ans`.
  local __q="$1" __def="${2:-y}" __ans __hint
  if [[ "$VT_ASSUME_YES" == "1" ]]; then
    [[ "$__def" == "y" ]]
    return $?
  fi
  __hint="[Y/n]"
  if [[ "$__def" == "n" ]]; then __hint="[y/N]"; fi
  printf '%s' "${C_BOLD}${__q}${C_RESET} ${__hint} "
  IFS= read -r __ans || __ans=""
  __ans="${__ans,,}"
  case "$__ans" in
    y|yes) return 0 ;;
    n|no)  return 1 ;;
    *)         [[ "$__def" == "y" ]] ;;   # empty / unrecognised -> the default
  esac
}

ask() {
  # ask VARNAME "question" "default"
  local __var="$1" __q="$2" __def="${3:-}" __ans
  if [[ "$VT_ASSUME_YES" == "1" ]]; then
    printf -v "$__var" '%s' "$__def"
    return 0
  fi
  if [[ -n "$__def" ]]; then
    printf '%s' "${C_BOLD}${__q}${C_RESET} [${C_GREEN}${__def}${C_RESET}]: "
  else
    printf '%s' "${C_BOLD}${__q}${C_RESET}: "
  fi
  IFS= read -r __ans || __ans=""
  if [[ -z "$__ans" ]]; then __ans="$__def"; fi
  printf -v "$__var" '%s' "$__ans"
}

ask_secret() {
  local __var="$1" __q="$2" __ans
  printf '%s' "${C_BOLD}${__q}${C_RESET}: "
  if read -r -s __ans; then printf '\n'; fi
  printf -v "$__var" '%s' "$__ans"
}

# Choose from a numbered list. menu_pick VARNAME "title" "a" "b" "c" -> index
menu_pick() {
  local __var="$1" __title="$2"; shift 2
  local opts=("$@") i __def=1 __ans
  printf '\n%s\n' "${C_BOLD}${__title}${C_RESET}"
  for i in "${!opts[@]}"; do
    printf '  %s%d)%s %s\n' "$C_CYAN" "$((i + 1))" "$C_RESET" "${opts[$i]}"
  done
  if [[ "$VT_ASSUME_YES" == "1" ]]; then
    printf -v "$__var" '%s' "$__def"
    return 0
  fi
  printf '%s' "${C_BOLD}Choose${C_RESET} [${C_GREEN}${__def}${C_RESET}]: "
  IFS= read -r __ans || __ans=""
  if [[ -z "$__ans" ]]; then __ans="$__def"; fi
  if ! [[ "$__ans" =~ ^[0-9]+$ ]] || (( __ans < 1 || __ans > ${#opts[@]} )); then
    __ans="$__def"
  fi
  printf -v "$__var" '%s' "$__ans"
}

# Percent-encode a string (UTF-8 safe: LC_ALL=C makes the loop byte-wise).
urlencode() {
  local s="$1" i c o=""
  local LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [a-zA-Z0-9.~_-]) o+=$c ;;
      *) printf -v c '%%%02X' "'$c"; o+=$c ;;
    esac
  done
  printf '%s' "$o"
}

# RFC4122 v4 UUID without depending on uuidgen.
gen_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif have uuidgen; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    local h
    h=$(openssl rand -hex 16)
    printf '%s-%s-4%s-%s-%s\n' \
      "${h:0:8}" "${h:8:4}" "${h:13:3}" "8${h:17:3}" "${h:20:12}"
  fi
}

# N random hex chars.
rand_hex() { openssl rand -hex $(( ${1:-8} / 2 )); }

# Random port in a range, avoiding the ports passed in as arguments.
random_port() {
  local lo="${VT_PORT_MIN:-10000}" hi="${VT_PORT_MAX:-60000}"
  local avoid=" $* " p tries=0
  while (( tries < 200 )); do
    p=$(( lo + RANDOM % (hi - lo + 1) ))
    if [[ "$avoid" == *" $p "* ]]; then
      tries=$((tries + 1)); continue
    fi
    if ! port_in_use "$p"; then
      printf '%s' "$p"
      return 0
    fi
    tries=$((tries + 1))
  done
  fail "could not find a free port"
}

port_in_use() {
  local port="$1"
  if have ss; then
    ss -Htuln 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}\$" && return 0
  elif have netstat; then
    netstat -tuln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}\$" && return 0
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
  fi
  return 1
}

# --------------------------------------------------------------------------
# Package installation
# --------------------------------------------------------------------------
APT_UPDATED=0
apt_update_once() {
  if [[ "$APT_UPDATED" == "1" ]]; then return 0; fi
  if have apt-get; then
    log_note "apt-get update ..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
  fi
  APT_UPDATED=1
}

# A package counts as present when its command is on PATH *or* dpkg knows it
# (ca-certificates, ufw-config etc. do not always provide a matching binary).
pkg_installed() {
  have "$1" && return 0
  have dpkg && dpkg -s "$1" >/dev/null 2>&1
}

install_pkgs() {
  local missing=() pkg
  for pkg in "$@"; do
    pkg_installed "$pkg" || missing+=("$pkg")
  done
  (( ${#missing[@]} == 0 )) && return 0
  if [[ "$VT_SKIP_APT" == "1" ]]; then
    log_note "[dry] apt-get install ${missing[*]}"
    return 0
  fi
  if ! have apt-get; then
    log_warn "apt-get not found - please install manually: ${missing[*]}"
    return 1
  fi
  apt_update_once
  log_info "installing packages: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" \
    || fail "failed to install packages: ${missing[*]}"
}

# --------------------------------------------------------------------------
# Misc helpers
# --------------------------------------------------------------------------
box() {
  # box "title" "line1" "line2" ...
  local title="$1"; shift
  local longest=${#title} l
  for l in "$@"; do
    (( ${#l} > longest )) && longest=${#l}
  done
  (( longest > 76 )) && longest=76
  local bar
  bar=$(printf '─%.0s' $(seq 1 $((longest + 2))))
  printf '%s\n' "${C_CYAN}┌${bar}┐${C_RESET}"
  printf '%s\n' "${C_CYAN}│${C_RESET} ${C_BOLD}${title}$(printf '%*s' $((longest - ${#title})) '') ${C_CYAN}│${C_RESET}"
  printf '%s\n' "${C_CYAN}├${bar}┼${C_RESET}"
  for l in "$@"; do
    printf '%s\n' "${C_CYAN}│${C_RESET} $l$(printf '%*s' $((longest - ${#l})) '') ${C_CYAN}│${C_RESET}"
  done
  printf '%s\n' "${C_CYAN}└${bar}┘${C_RESET}"
}

pause() {
  if [[ "$VT_ASSUME_YES" == "1" ]]; then return 0; fi
  printf '\n%s' "${C_DIM}press Enter to continue...${C_RESET}"
  IFS= read -r _ || true
  printf '\n'
}
