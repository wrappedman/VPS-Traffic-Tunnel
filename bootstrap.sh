#!/usr/bin/env bash
# bootstrap.sh — one-line installer for VPS-Traffic-Tunnel.
#
#   curl -fsSL <this file> | sudo bash
#
# Downloads the repository, puts it in /opt/vt, puts `vt` on PATH, then drops
# you into the menu. Nothing else is touched until you choose "install".

set -uo pipefail

REPO_OWNER="wrappedman"
REPO_NAME="VPS-Traffic-Tunnel"
BRANCH="main"
DEST="/opt/vt"
TARBALL_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${BRANCH}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "this script must run as root:  curl -fsSL <url> | sudo bash" >&2
  exit 1
fi

echo "==> fetching ${REPO_NAME} ..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if ! curl -fsSL --connect-timeout 15 --max-time 180 -o "$TMP/repo.tgz" "$TARBALL_URL"; then
  echo "downloading from GitHub failed. If you have no direct access, clone it manually:" >&2
  echo "  git clone https://github.com/${REPO_OWNER}/${REPO_NAME}.git && cd ${REPO_NAME} && sudo ./vt self-install" >&2
  exit 1
fi

mkdir -p "$DEST"
tar xzf "$TMP/repo.tgz" -C "$TMP" || { echo "extraction failed." >&2; exit 1; }
SRC=$(find "$TMP" -maxdepth 1 -type d -name "${REPO_NAME}-*" | head -n1)
[[ -n "$SRC" && -x "$SRC/vt" ]] || { echo "unexpected archive layout." >&2; exit 1; }

cp -a "$SRC/." "$DEST/" || { echo "copying to ${DEST} failed." >&2; exit 1; }
chmod +x "$DEST/vt" "$DEST"/lib/*.sh 2>/dev/null || true
ln -sf "$DEST/vt" /usr/local/bin/vt

echo "==> installed in ${DEST} - the 'vt' command is ready."
echo
exec "$DEST/vt"
