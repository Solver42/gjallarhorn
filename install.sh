#!/bin/sh
set -e

cd "$(dirname "$0")"

BINARY="gjallarhorn"
INSTALL_DIR="$HOME/.local/bin"

if [ "$1" = "dev" ]; then
    odin build . -out:"$BINARY" -define:DEV=true
else
    odin build . -out:"$BINARY" -o:speed -disable-assert -no-bounds-check
fi

[ -x "$BINARY" ] || { echo "ERROR: compilation produced no binary."; exit 1; }

mkdir -p "$INSTALL_DIR"
if [ "$1" = "dev" ]; then
    install -m 755 "$BINARY" "$INSTALL_DIR/$BINARY.bin"
    printf '#!/bin/sh\nexec "%s/%s.bin" "$@"\n' "$INSTALL_DIR" "$BINARY" > "$INSTALL_DIR/$BINARY"
    chmod +x "$INSTALL_DIR/$BINARY"
else
    install -m 755 "$BINARY" "$INSTALL_DIR/$BINARY"
fi
case ":$PATH:" in
    *":$INSTALL_DIR:"*|*":$INSTALL_DIR/"*) ;;
    *) echo "NOTE: add to shell profile: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo "Installed $INSTALL_DIR/$BINARY"

echo "Open any Odin file in Vim — Ctrl+X Ctrl+O to complete, K to hover and gd to go to definition"
