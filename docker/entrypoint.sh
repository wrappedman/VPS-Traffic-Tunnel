#!/usr/bin/env bash
# Container entrypoint — the Docker/Railway counterpart of the systemd units.
#
#   docker run ... image [install options] -- [vt run options]
#
# It is safe to re-run: an install that already exists is kept (so the REALITY
# keys and the client UUIDs survive a restart when /etc/vt is a volume), and
# only a missing or half-written installation is repeated. Everything after
# `--` is passed to the supervisor.
#
# Environment:
#   VT_INSTALL_ARGS   default install options (used when none are given)
#   VT_RUN_ARGS       default supervisor options
#   VT_FORCE_INSTALL=1  rebuild the installation even if one exists
#                       (this rotates the keys and breaks existing clients)
set -uo pipefail

VT_BIN="${VT_BIN:-/opt/vt/vt}"
[[ -x "$VT_BIN" ]] || VT_BIN="$(command -v vt)" || true
VT_BIN="${VT_BIN:-vt}"

install_args=()
run_args=()
saw_separator=0
for a in "$@"; do
  if [[ "$a" == "--" && "$saw_separator" == 0 ]]; then
    saw_separator=1
    continue
  fi
  if [[ "$saw_separator" == 1 ]]; then run_args+=("$a"); else install_args+=("$a"); fi
done

if (( ${#install_args[@]} == 0 )) && [[ -n "${VT_INSTALL_ARGS:-}" ]]; then
  # Word splitting is the point here: the variable holds a list of options.
  # shellcheck disable=SC2206
  install_args=(${VT_INSTALL_ARGS})
fi
if (( ${#run_args[@]} == 0 )) && [[ -n "${VT_RUN_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  run_args=(${VT_RUN_ARGS})
fi

if (( ${#install_args[@]} == 0 )); then
  install_args=(--mode reality --port random --sni www.microsoft.com --yes)
fi

# A container is not a VPS: no systemd, no interactive terminal, the platform
# owns the firewall. Say so instead of guessing (and never twice).
has_arg() {
  local want="$1" a
  for a in "${install_args[@]}"; do [[ "$a" == "$want" ]] && return 0; done
  return 1
}
has_arg --yes || install_args+=(--yes)
has_arg --firewall || install_args+=(--firewall no)
if [[ "${VT_FORCE_INSTALL:-0}" == "1" ]]; then
  install_args+=(--force)
fi

# VT_ROOT is empty inside the container; the test-suite points it at a scratch
# directory so this script can be exercised without building an image.
installed() {
  local root="${VT_ROOT:-}"
  [[ -f "$root/usr/local/etc/xray/config.json" && -f "$root/etc/vt/vt.env" ]]
}

echo "=== VPS-Traffic-Tunnel container entrypoint ==="
if installed && [[ "${VT_FORCE_INSTALL:-0}" != "1" ]]; then
  echo "==> an existing installation was found - keeping it."
  echo "    (keys and users are preserved; set VT_FORCE_INSTALL=1 to rebuild)"
else
  if installed; then
    echo "==> rebuilding the installation (VT_FORCE_INSTALL=1): ${install_args[*]}"
  else
    echo "==> installing: ${install_args[*]}"
  fi
  if ! "$VT_BIN" install "${install_args[@]}"; then
    echo "==> the install failed - not starting the tunnel. Fix the error above" >&2
    echo "    (or run 'vt install ...' by hand inside a shell) and try again." >&2
    exit 1
  fi
fi

echo "==> starting the supervisor: vt run ${run_args[*]:-}"
echo "    (vt stop from another shell stops it; SIGTERM stops it cleanly)"
exec "$VT_BIN" run "${run_args[@]}"
