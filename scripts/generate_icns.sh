#!/bin/bash
set -e

# Define directories
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ASSETS_DIR="$PROJECT_DIR/assets"
ICONSET_DIR="$ASSETS_DIR/AppIcon.iconset"
SOURCE_PNG="$ASSETS_DIR/prasenz_printer.png"
OUTPUT_ICNS="$ASSETS_DIR/AppIcon.icns"

if [ ! -f "$SOURCE_PNG" ]; then
    echo "Error: Source image $SOURCE_PNG not found!"
    exit 1
fi

echo "Creating temporary iconset directory..."
mkdir -p "$ICONSET_DIR"

echo "Generating resized icon sizes..."
sips -z 16 16     "$SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16.png" > /dev/null
sips -z 32 32     "$SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" > /dev/null
sips -z 32 32     "$SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32.png" > /dev/null
sips -z 64 64     "$SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" > /dev/null
sips -z 128 128   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128.png" > /dev/null
sips -z 256 256   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
sips -z 256 256   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256.png" > /dev/null
sips -z 512 512   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
sips -z 512 512   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_512x512.png" > /dev/null
sips -z 1024 1024 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null

echo "Compiling to AppIcon.icns..."
iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_ICNS"

echo "Cleaning up temporary iconset..."
rm -rf "$ICONSET_DIR"

echo "Success! AppIcon.icns generated at $OUTPUT_ICNS"
