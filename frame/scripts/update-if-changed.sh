#!/bin/bash

set -euo pipefail

FRAME_URL="http://birdnet.local/frame/frame.png"

CACHE_DIR="/home/ferran/.cache/avian-frame"
CURRENT="$CACHE_DIR/current.png"
TMP="$CACHE_DIR/download.png"

DISPLAY_DIR="/home/ferran/AvianVisitors/frame"
DISPLAY_PY="$DISPLAY_DIR/display.py"
PYTHON="$DISPLAY_DIR/.venv/bin/python"
CONFIG="/home/ferran/.birdframe/config.toml"

mkdir -p "$CACHE_DIR"

# Descarrega la versió actual.
if ! curl \
    --fail \
    --silent \
    --show-error \
    --max-time 30 \
    -o "$TMP" \
    "$FRAME_URL"
then
    echo "No s'ha pogut descarregar el frame."
    rm -f "$TMP"
    exit 1
fi

# Validació mínima: ha de ser una PNG.
if ! file "$TMP" | grep -q "PNG image data"; then
    echo "El fitxer descarregat no és una PNG vàlida."
    rm -f "$TMP"
    exit 1
fi

# Si ja tenim una imatge mostrada i és exactament igual, acabem.
if [ -f "$CURRENT" ] && cmp -s "$TMP" "$CURRENT"; then
    echo "Frame sense canvis; no s'actualitza la pantalla."
    rm -f "$TMP"
    exit 0
fi

echo "S'ha detectat un canvi; actualitzant la pantalla..."

cd "$DISPLAY_DIR"

sudo "$PYTHON" "$DISPLAY_PY" \
    --config "$CONFIG" \
    --force \
    --no-signature

# Només marquem aquesta versió com a mostrada si display.py ha acabat bé.
mv "$TMP" "$CURRENT"

echo "Pantalla actualitzada."
