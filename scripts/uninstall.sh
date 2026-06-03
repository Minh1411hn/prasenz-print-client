#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=====================================================${NC}"
echo -e "${BLUE}  PrasenzPrinter - Uninstall Menu Bar App${NC}"
echo -e "${BLUE}=====================================================${NC}"
echo

LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.prasenz.printagent.plist"
APP_PATH="/Applications/PrasenzPrinter.app"

# Confirm
echo -e "${YELLOW}⚠️  Are you sure you want to completely uninstall PrasenzPrinter?${NC}"
read -p "Type 'yes' to confirm: " confirm
if [ "$confirm" != "yes" ]; then
  echo -e "${BLUE}Uninstallation cancelled.${NC}"
  exit 0
fi
echo

# Step 1: Unload and clean LaunchAgent
echo -e "${YELLOW}[1/3] Unregistering Start with macOS...${NC}"
if [ -f "$LAUNCH_AGENT" ]; then
  launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
  rm -f "$LAUNCH_AGENT"
  echo -e "  ${GREEN}✅ Removed LaunchAgent from system${NC}"
else
  echo -e "  ${GREEN}✅ LaunchAgent is not enabled on this system${NC}"
fi
echo

# Step 2: Terminate running processes
echo -e "${YELLOW}[2/3] Stopping background processes...${NC}"
pkill -f "PrasenzPrinter" 2>/dev/null || true
pkill -f "prasenz-print-server" 2>/dev/null || true
pkill -f "cloudflared-silicon" 2>/dev/null || true
pkill -f "cloudflared-intel" 2>/dev/null || true
echo -e "  ${GREEN}✅ Stopped related processes${NC}"
echo

# Step 3: Remove from Applications
echo -e "${YELLOW}[3/3] Deleting application from /Applications...${NC}"
if [ -d "$APP_PATH" ]; then
  rm -rf "$APP_PATH"
  echo -e "  ${GREEN}✅ Deleted ${APP_PATH}${NC}"
else
  echo -e "  ${GREEN}✅ Application does not exist at ${APP_PATH}${NC}"
fi
echo

# Clean up logs
rm -f /tmp/prasenz_print_agent.log /tmp/prasenz_print_agent_err.log 2>/dev/null || true

echo -e "${BLUE}=====================================================${NC}"
echo -e "${GREEN}🎉 COMPLETELY UNINSTALLED!${NC}"
echo -e "${BLUE}=====================================================${NC}"
echo -e "  PrasenzPrinter has been cleanly removed from your Mac."
echo
