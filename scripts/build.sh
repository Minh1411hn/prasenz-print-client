#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=====================================================${NC}"
echo -e "${BLUE}  PrasenzPrinter - 100% Pure Swift App Builder       ${NC}"
echo -e "${BLUE}=====================================================${NC}"
echo

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"
BIN_DIR="$PROJECT_DIR/bin"
APP_BUNDLE="$DIST_DIR/PrasenzPrinter.app"

# Step 1: Check dependencies
echo -e "${YELLOW}[1/5] Kiểm tra công cụ biên dịch macOS...${NC}"
command -v swiftc >/dev/null 2>&1 || { echo -e "${RED}❌ Cần cài đặt Command Line Tools bằng lệnh: xcode-select --install${NC}"; exit 1; }
command -v lipo >/dev/null 2>&1 || { echo -e "${RED}❌ Cần công cụ lipo của hệ thống${NC}"; exit 1; }
echo -e "${GREEN}✅ swiftc OK | lipo OK${NC}"
echo

# Step 2: Download cloudflared binaries if not present
echo -e "${YELLOW}[2/5] Kiểm tra Cloudflare Tunnel binaries...${NC}"
mkdir -p "$BIN_DIR"

CF_BASE_URL="https://github.com/cloudflare/cloudflared/releases/latest/download"

if [ ! -f "$BIN_DIR/cloudflared-intel" ]; then
  echo -e "  ${BLUE}⬇️  Đang tải cloudflared cho Intel (amd64)...${NC}"
  curl -L "$CF_BASE_URL/cloudflared-darwin-amd64.tgz" -o "$BIN_DIR/cloudflared-darwin-amd64.tgz"
  tar -xzf "$BIN_DIR/cloudflared-darwin-amd64.tgz" -C "$BIN_DIR"
  mv "$BIN_DIR/cloudflared" "$BIN_DIR/cloudflared-intel"
  rm -f "$BIN_DIR/cloudflared-darwin-amd64.tgz"
  echo -e "  ${GREEN}✅ cloudflared-intel đã sẵn sàng${NC}"
else
  echo -e "  ${GREEN}✅ cloudflared-intel đã tồn tại${NC}"
fi

if [ ! -f "$BIN_DIR/cloudflared-silicon" ]; then
  echo -e "  ${BLUE}⬇️  Đang tải cloudflared cho Apple Silicon (arm64)...${NC}"
  curl -L "$CF_BASE_URL/cloudflared-darwin-arm64.tgz" -o "$BIN_DIR/cloudflared-darwin-arm64.tgz"
  tar -xzf "$BIN_DIR/cloudflared-darwin-arm64.tgz" -C "$BIN_DIR"
  mv "$BIN_DIR/cloudflared" "$BIN_DIR/cloudflared-silicon"
  rm -f "$BIN_DIR/cloudflared-darwin-arm64.tgz"
  echo -e "  ${GREEN}✅ cloudflared-silicon đã sẵn sàng${NC}"
else
  echo -e "  ${GREEN}✅ cloudflared-silicon đã tồn tại${NC}"
fi

chmod +x "$BIN_DIR/cloudflared-intel" "$BIN_DIR/cloudflared-silicon"
echo

# Step 3: Compile Swift Source Code to Universal Binary
echo -e "${YELLOW}[3/5] Biên dịch Swift GUI và HTTP Server ngầm...${NC}"
mkdir -p "$DIST_DIR"
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)

echo -e "  ${BLUE}⚙️  Biên dịch cho Intel (x64)...${NC}"
swiftc -O -sdk "$SDK_PATH" -target x86_64-apple-macosx10.15 \
  src-swift/main.swift src-swift/AppDelegate.swift src-swift/HttpServer.swift \
  -o "$DIST_DIR/PrasenzPrinter-macos-x64"

echo -e "  ${BLUE}⚙️  Biên dịch cho Apple Silicon (arm64)...${NC}"
swiftc -O -sdk "$SDK_PATH" -target arm64-apple-macosx11.0 \
  src-swift/main.swift src-swift/AppDelegate.swift src-swift/HttpServer.swift \
  -o "$DIST_DIR/PrasenzPrinter-macos-arm64"

echo -e "  ${BLUE}⚙️  Gộp 2 kiến trúc thành Universal Binary...${NC}"
lipo -create \
  "$DIST_DIR/PrasenzPrinter-macos-x64" \
  "$DIST_DIR/PrasenzPrinter-macos-arm64" \
  -output "$DIST_DIR/PrasenzPrinter"

echo -e "${GREEN}✅ Biên dịch Swift thành công!${NC}"
echo

# Step 4: Assemble complete macOS .app bundle
echo -e "${YELLOW}[4/5] Lắp ghép cấu trúc .app bundle hoàn chỉnh...${NC}"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS/bin"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy main Swift binary (the one and only app binary!)
cp "$DIST_DIR/PrasenzPrinter" "$APP_BUNDLE/Contents/MacOS/"

# Copy cloudflared binaries
cp "$BIN_DIR/cloudflared-intel" "$APP_BUNDLE/Contents/MacOS/bin/"
cp "$BIN_DIR/cloudflared-silicon" "$APP_BUNDLE/Contents/MacOS/bin/"

# Copy Info.plist
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/"

# Copy AppIcon.icns resource
if [ -f "$PROJECT_DIR/assets/AppIcon.icns" ]; then
  cp "$PROJECT_DIR/assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
fi


# Set executable permissions
chmod +x "$APP_BUNDLE/Contents/MacOS/PrasenzPrinter"
chmod +x "$APP_BUNDLE/Contents/MacOS/bin/cloudflared-intel"
chmod +x "$APP_BUNDLE/Contents/MacOS/bin/cloudflared-silicon"

# Clean up temp build artifacts
rm -f "$DIST_DIR/PrasenzPrinter-macos-x64" "$DIST_DIR/PrasenzPrinter-macos-arm64" "$DIST_DIR/PrasenzPrinter"

echo -e "${GREEN}✅ .app bundle đã lắp ráp xong${NC}"
echo

# Step 5: Finished
echo -e "${BLUE}=====================================================${NC}"
echo -e "${GREEN}🎉 NATIVE SWIFT APP BUILD THÀNH CÔNG!${NC}"
echo -e "${BLUE}=====================================================${NC}"
echo -e "  📦 App Bundle: ${APP_BUNDLE}"
echo -e "  📏 Kích thước: $(du -sh "$APP_BUNDLE" | cut -f1) (Giảm hơn 4 lần!)"
echo
echo -e "  👉 Chỉ cần kéo thả file ${YELLOW}dist/PrasenzPrinter.app${NC} vào thư mục ${YELLOW}/Applications${NC}"
echo -e "  👉 Sau đó click đúp ứng dụng để kích hoạt chạy ngầm trên Menu Bar."
echo
