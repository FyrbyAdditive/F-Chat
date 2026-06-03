#!/usr/bin/env bash
# Fetch a relocatable, self-contained CPython for bundling into FyxLocal.app.
#
# Agent Skills frequently ship `.py` helper scripts, and an end-user Mac is not
# guaranteed to have a system `python3`. We bundle a standalone CPython (from
# the astral-sh/python-build-standalone project) so `run_code` can execute
# Python regardless of the user's machine. The runtime is relocatable, which
# keeps the sandbox profile's read scope bounded to the bundled directory.
#
# Output: vendor/python3/  (a `bin/python3` + its libraries). Cached — re-runs
# are a no-op once present. make-app.sh copies this into the .app bundle.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/python3"

if [[ -x "$DEST/bin/python3" ]]; then
    echo "==> python3 already vendored at $DEST/bin/python3"
    exit 0
fi

# Pin a specific python-build-standalone release for reproducibility. The
# `install_only` tarball is the relocatable, stripped build with a normal
# bin/lib layout (no PGO/LTO build dirs).
PBS_TAG="20250115"
PY_VERSION="3.12.8"

ARCH="$(uname -m)"
case "$ARCH" in
    arm64)  TRIPLE="aarch64-apple-darwin" ;;
    x86_64) TRIPLE="x86_64-apple-darwin" ;;
    *) echo "error: unsupported arch $ARCH" >&2; exit 1 ;;
esac

ASSET="cpython-${PY_VERSION}+${PBS_TAG}-${TRIPLE}-install_only.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${ASSET}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> downloading $ASSET"
curl -fSL "$URL" -o "$TMP/python.tar.gz"

echo "==> extracting"
tar -xzf "$TMP/python.tar.gz" -C "$TMP"
# The archive unpacks to a top-level `python/` directory.
if [[ ! -x "$TMP/python/bin/python3" ]]; then
    echo "error: extracted archive missing bin/python3" >&2
    exit 1
fi

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mv "$TMP/python" "$DEST"

echo "==> vendored python3 at $DEST/bin/python3"
"$DEST/bin/python3" --version
