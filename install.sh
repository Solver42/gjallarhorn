#!/bin/sh
set -e

cd "$(dirname "$0")"

BINARY="gjallarhorn"
INSTALL_DIR="$HOME/.local/bin"

if [ "$1" = "dev" ]; then
    odin build . -out:"$BINARY"
else
    odin build . -out:"$BINARY" -o:speed -disable-assert -no-bounds-check
fi

[ -x "$BINARY" ] || { echo "ERROR: compilation produced no binary."; exit 1; }

mkdir -p "$INSTALL_DIR"
install -m 755 "$BINARY" "$INSTALL_DIR/$BINARY"

case ":$PATH:" in
    *":$INSTALL_DIR:"*|*":$INSTALL_DIR/"*) ;;
    *) echo "NOTE: add to shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo "Installed $INSTALL_DIR/$BINARY"
echo "Open any Odin file in Vim — Ctrl+X Ctrl+U to complete, K to hover."
