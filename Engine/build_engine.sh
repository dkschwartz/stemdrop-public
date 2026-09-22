#!/usr/bin/env bash
# Builds the relocatable Python engine runtime into ../Resources/engine/
# from the python-build-standalone tree in Engine/pbs/python, pip-installing
# requirements.txt and vendoring the stemdrop_engine package.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DEST="$SCRIPT_DIR/../Resources/engine"

echo "==> Removing existing $DEST"
rm -rf "$DEST"

echo "==> Copying pbs/python -> $DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$SCRIPT_DIR/pbs/python" "$DEST"

PY="$DEST/bin/python3"
if [ ! -x "$PY" ]; then
    echo "error: $PY not found/executable after copy" >&2
    exit 1
fi

echo "==> Installing requirements.txt into relocatable runtime"
"$PY" -m pip install --no-cache-dir -r "$SCRIPT_DIR/requirements.txt"

SITE_PACKAGES="$("$PY" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
echo "==> site-packages: $SITE_PACKAGES"

echo "==> Vendoring stemdrop_engine package"
rm -rf "$SITE_PACKAGES/stemdrop_engine"
cp -R "$SCRIPT_DIR/stemdrop_engine" "$SITE_PACKAGES/stemdrop_engine"

echo "==> Stripping __pycache__ dirs"
find "$DEST" -type d -name "__pycache__" -prune -exec rm -rf {} +

echo "==> Removing test/tests dirs under site-packages"
find "$SITE_PACKAGES" -maxdepth 2 -type d \( -name "test" -o -name "tests" \) -prune -exec rm -rf {} +

echo "==> Final size"
du -sh "$DEST"
