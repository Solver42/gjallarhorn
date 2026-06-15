#!/bin/sh
# Compile gjallarhorn and install it to ~/.local/bin/

set -e

cd "$(dirname "$0")"

BINARY="gjallarhorn"
INSTALL_DIR="$HOME/.local/bin"

echo "==> Compiling $BINARY..."

if [ "$1" = "dev" ]; then
    odin build . -out:"$BINARY"
else
    odin build . -out:"$BINARY" -o:speed -disable-assert -no-bounds-check
fi

if [ ! -x "$BINARY" ]; then
    echo "ERROR: compilation produced no binary."
    exit 1
fi

mkdir -p "$INSTALL_DIR"
install -m 755 "$BINARY" "$INSTALL_DIR/$BINARY"

echo "==> Installed: $INSTALL_DIR/$BINARY"

case ":$PATH:" in
    *":$INSTALL_DIR:"*|*":$INSTALL_DIR/"*)
        echo "==> '$INSTALL_DIR' is on PATH."
        ;;
    *)
        echo "==> NOTE: '$INSTALL_DIR' is not on PATH."
        echo "    Add this to your shell profile:"
        echo "      export PATH=\"\$HOME/.local/bin:\$PATH\""
        ;;
esac

echo "Done."
echo "Open any Odin file in Vim, press Ctrl+X Ctrl+U for autocomplete, press Shift+K to peek the symbol's content."
