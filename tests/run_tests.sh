#!/usr/bin/env bash
# tests/run_tests.sh — full check suite for VPS-Traffic-Tunnel.
#
#   ./tests/run_tests.sh
#
# Runs, in order:
#   1. bash -n syntax check on every shell file
#   2. shellcheck (skipped with a warning when the binary is missing)
#   3. unit tests for the pure helper functions
#   4. end-to-end install dry-runs inside throwaway VT_ROOT directories,
#      covering every tunnel mode and every certificate source
#   5. schema validation of the generated Xray configuration
#   6. uninstall dry-run

set -uo pipefail

# The installer creates /etc/vt as 0700 root (it holds private keys), so the
# assertions need root too. Re-exec once if we are not root.
if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E env PATH="$PATH" bash "${BASH_SOURCE[0]}" "$@"
  fi
  echo "This suite must run as root (the installer needs root)." >&2
  exit 1
fi

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
WORK=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$WORK'" EXIT

PASS=0
FAIL=0
FAILED_NAMES=()

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YEL=$'\033[0;33m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; YEL=""; RST=""; }

ok()   { PASS=$((PASS + 1)); printf '  %s✓%s %s\n' "$GREEN" "$RST" "$1"; }
bad()  { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); printf '  %s✗%s %s\n' "$RED" "$RST" "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }
sect() { printf '\n%s== %s ==%s\n' "$YEL" "$1" "$RST"; }

assert_eq() { # assert_eq <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
assert_contains() { # assert_contains <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "[$3] not found in output"; fi
}
assert_file() { if [[ -f "$2" ]]; then ok "$1"; else bad "$1" "missing file: $2"; fi }
assert_json() { if jq -e "$2" "$3" >/dev/null 2>&1; then ok "$1"; else bad "$1" "jq [$2] failed on $3"; fi }

export REPO WORK

# --------------------------------------------------------------------------
sect "1/7 syntax"
# --------------------------------------------------------------------------
SYNTAX_BAD=0
for f in "$REPO/vt" "$REPO/bootstrap.sh" "$REPO"/lib/*.sh "$REPO"/tests/*.sh "$REPO"/docker/*.sh; do
  if ! bash -n "$f" 2>"$WORK/syn.err"; then
    SYNTAX_BAD=$((SYNTAX_BAD + 1))
    bad "bash -n $(basename "$f")" "$(cat "$WORK/syn.err")"
  fi
done
(( SYNTAX_BAD == 0 )) && ok "bash -n on all shell files"

# A hand-edit of these sources once went through a formatter that escaped the
# shell metacharacters LaTeX-style: the pipe character was spelled out as a
# control sequence and a backslash was inserted before the percent sign.
# That is *valid* bash for printf (it just prints the text literally) and
# valid jq nowhere, so it broke the installer in ways `bash -n` cannot see.
# The backslash is written as the character class [\\] so this check never
# matches its own pattern.
LATEX_HITS=$(grep -rnE '[\\](vert|%s|%Y|[_&{}])' \
  "$REPO/vt" "$REPO"/lib/*.sh "$REPO"/tests/*.sh "$REPO"/docker/*.sh 2>/dev/null || true)
if [[ -z "$LATEX_HITS" ]]; then
  ok "no LaTeX-style escaping in the sources"
else
  bad "no LaTeX-style escaping in the sources" "$(head -n 5 <<<"$LATEX_HITS")"
fi

# --------------------------------------------------------------------------
sect "2/7 shellcheck"
# --------------------------------------------------------------------------
SHELLCHECK_BIN=""
for c in shellcheck "$HOME/bin/shellcheck"; do
  command -v "$c" >/dev/null 2>&1 && { SHELLCHECK_BIN=$(command -v "$c"); break; }
done
if [[ -n "$SHELLCHECK_BIN" ]]; then
  if (cd "$REPO" && "$SHELLCHECK_BIN" -x -s bash vt bootstrap.sh lib/*.sh tests/*.sh docker/*.sh) >"$WORK/sc.out" 2>&1; then
    ok "shellcheck clean"
  else
    bad "shellcheck" "$(head -n 40 "$WORK/sc.out")"
  fi
else
  printf '  %s-%s shellcheck not installed, skipped\n' "$YEL" "$RST"
fi

# --------------------------------------------------------------------------
sect "3/7 unit tests"
# --------------------------------------------------------------------------
bash "$HERE/unit_test.sh"
UNIT_RC=$?
if (( UNIT_RC == 0 )); then
  ok "unit tests"
else
  bad "unit tests" "exit code $UNIT_RC"
fi

# --------------------------------------------------------------------------
sect "4/7 install dry-runs"
# --------------------------------------------------------------------------
# shellcheck source=tests/e2e_lib.sh
. "$HERE/e2e_lib.sh"

e2e_case "reality-random-port" \
  --mode reality --port random --email main --sni www.microsoft.com
e2e_case "ws-tls-domain-selfsigned" \
  --mode ws-tls --domain tunnel.example.com --cert selfsigned --port 443 --email alice
e2e_case "tcp-tls-ip-letsencrypt" \
  --mode tcp-tls --cert letsencrypt-ip --port random --email bob
e2e_case "ws-edge-railway-domain" \
  --mode ws-edge --domain vtt-demo.up.railway.app --port 8080 --email main
e2e_case "ws-tls-domain-letsencrypt" \
  --mode ws-tls --domain proxy.example.org --cert letsencrypt-domain --acme standalone --port 443

# --------------------------------------------------------------------------
sect "5/7 xray config schema"
# --------------------------------------------------------------------------
for d in "$WORK"/root-*; do
  conf="$d/usr/local/etc/xray/config.json"
  [[ -f "$conf" ]] || continue
  if python3 "$HERE/validate_config.py" "$conf" >"$WORK/v.out" 2>&1; then
    ok "schema: $(basename "$d")"
  else
    bad "schema: $(basename "$d")" "$(head -n 10 "$WORK/v.out")"
  fi
done

# --------------------------------------------------------------------------
sect "6/7 container services (no systemd)"
# --------------------------------------------------------------------------
# Railway/Docker/Fly containers have no systemd: `systemctl` never exists
# there, so the tunnel has to be supervised as a plain process.
e2e_container_services

# --------------------------------------------------------------------------
sect "7/7 uninstall"
# --------------------------------------------------------------------------
e2e_uninstall "reality-random-port"

# --------------------------------------------------------------------------
printf '\n%s──────────────────────────────────────────%s\n' "$YEL" "$RST"
printf '  %sPASS: %d%s   %sFAIL: %d%s\n' "$GREEN" "$PASS" "$RST" "$RED" "$FAIL" "$RST"
if (( FAIL > 0 )); then
  printf '  failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
printf '  %sALL GREEN%s\n' "$GREEN" "$RST"
