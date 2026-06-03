#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=====================================================${NC}"
echo -e "${BLUE}  PrasenzPrinter - Gỡ cài đặt Menu Bar App${NC}"
echo -e "${BLUE}=====================================================${NC}"
echo

LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.prasenz.printagent.plist"
APP_PATH="/Applications/PrasenzPrinter.app"

# Confirm
echo -e "${YELLOW}⚠️  Bạn có chắc muốn gỡ cài đặt PrasenzPrinter hoàn toàn?${NC}"
read -p "Nhập 'yes' để xác nhận: " confirm
if [ "$confirm" != "yes" ]; then
  echo -e "${BLUE}Đã hủy gỡ cài đặt.${NC}"
  exit 0
fi
echo

# Step 1: Unload and clean LaunchAgent
echo -e "${YELLOW}[1/3] Hủy đăng ký Khởi động cùng macOS...${NC}"
if [ -f "$LAUNCH_AGENT" ]; then
  launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
  rm -f "$LAUNCH_AGENT"
  echo -e "  ${GREEN}✅ Đã xóa LaunchAgent khỏi máy${NC}"
else
  echo -e "  ${GREEN}✅ LaunchAgent không được bật trên máy này${NC}"
fi
echo

# Step 2: Terminate running processes
echo -e "${YELLOW}[2/3] Tắt tiến trình đang chạy ngầm...${NC}"
pkill -f "PrasenzPrinter" 2>/dev/null || true
pkill -f "prasenz-print-server" 2>/dev/null || true
pkill -f "cloudflared-silicon" 2>/dev/null || true
pkill -f "cloudflared-intel" 2>/dev/null || true
echo -e "  ${GREEN}✅ Đã tắt các tiến trình liên quan${NC}"
echo

# Step 3: Remove from Applications
echo -e "${YELLOW}[3/3] Xóa ứng dụng khỏi /Applications...${NC}"
if [ -d "$APP_PATH" ]; then
  rm -rf "$APP_PATH"
  echo -e "  ${GREEN}✅ Đã xóa ${APP_PATH}${NC}"
else
  echo -e "  ${GREEN}✅ Ứng dụng không tồn tại tại ${APP_PATH}${NC}"
fi
echo

# Clean up logs
rm -f /tmp/prasenz_print_agent.log /tmp/prasenz_print_agent_err.log 2>/dev/null || true

echo -e "${BLUE}=====================================================${NC}"
echo -e "${GREEN}🎉 ĐÃ GỠ CÀI ĐẶT HOÀN TOÀN!${NC}"
echo -e "${BLUE}=====================================================${NC}"
echo -e "  PrasenzPrinter đã được dọn dẹp sạch sẽ khỏi máy Mac của bạn."
echo
