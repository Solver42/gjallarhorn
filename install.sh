#!/bin/sh
# Compile gjallarhorn and install it to ~/.local/bin/

set -e

cd "$(dirname "$0")"

BINARY="gjallarhorn"
INSTALL_DIR="$HOME/.local/bin"

echo "==> Compiling $BINARY..."
odin build . -out:"$BINARY" -o:speed

if [ ! -f "$BINARY" ]; then
    echo "ERROR: compilation produced no binary."
    exit 1
fi

mkdir -p "$INSTALL_DIR"
mv "$BINARY" "$INSTALL_DIR/$BINARY"
chmod 755 "$INSTALL_DIR/$BINARY"

echo "==> Installed: $INSTALL_DIR/$BINARY"

if command -v "$BINARY" >/dev/null 2>&1; then
    echo "==> '$BINARY' is on PATH."
else
    echo "==> NOTE: '$INSTALL_DIR' is not on PATH."
    echo "    Add this to your shell profile:"
    echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo "Done. Open any Odin file in Vim and press Ctrl+X Ctrl+U to complete."
