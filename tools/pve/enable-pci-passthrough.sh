#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: Bozlo
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

# Color definitions
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Error handling
set -euo pipefail
trap 'echo -e "${RED}✗ Error occurred at line $LINENO${NC}"; exit 1' ERR

# Message functions
function msg_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

function msg_ok() {
  echo -e "${GREEN}[OK]${NC} $1"
}

function msg_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

function msg_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Header information
function header_info() {
  clear
  cat <<"EOF"
    ____  __________   ____                 __  __                           __
   / __ \/ ____/  _/  / __ \____ ___________/ /_/ /_  _________  __  ______ _/ /_
  / /_/ / /    / /   / /_/ / __ `/ ___/ ___/ __/ __ \/ ___/ __ \/ / / / __ `/ __ \
 / ____/ /____/ /   / ____/ /_/ (__  |__  ) /_/ / / / /  / /_/ / /_/ / /_/ / / / /
/_/    \____/___/  /_/    \__,_/____/____/\__/_/ /_/_/   \____/\__,_/\__, /_/ /_/
                                                                     /____/
EOF
}

header_info
echo -e "\n Loading...\n"

# 1. Check for root privileges
if [[ $EUID -ne 0 ]]; then
   msg_error "This script must be run as root"
   exit 1
fi

# 2. Verify running on Proxmox VE host
if ! command -v pvesm &> /dev/null; then
    msg_error "This script must run on Proxmox VE host, not inside a container"
    exit 1
fi

# 3. Detect CPU type
msg_info "Detecting CPU type"
if grep -q "Intel" /proc/cpuinfo; then
    CPU_TYPE="intel"
    IOMMU_PARAM="intel_iommu=on"
    msg_ok "Detected Intel CPU"
elif grep -q "AMD" /proc/cpuinfo; then
    CPU_TYPE="amd"
    IOMMU_PARAM="amd_iommu=on"
    msg_ok "Detected AMD CPU"
else
    msg_error "Unable to detect CPU type (Intel or AMD required)"
    exit 1
fi

# 4. Check if IOMMU is already enabled
msg_info "Checking current IOMMU status"
if dmesg | grep -e "DMAR" -e "IOMMU" | grep -q "enabled"; then
    msg_warning "IOMMU appears to be already enabled"
    read -p "Continue anyway? (y/n): " continue_anyway
    if [[ "$continue_anyway" != "y" ]]; then
        msg_info "Operation cancelled by user"
        exit 0
    fi
else
    msg_info "IOMMU is not currently enabled"
fi

# 5. Backup GRUB configuration
msg_info "Backing up GRUB configuration"
GRUB_FILE="/etc/default/grub"
BACKUP_FILE="/etc/default/grub.backup.$(date +%Y%m%d_%H%M%S)"

if cp "$GRUB_FILE" "$BACKUP_FILE"; then
    msg_ok "Backup created: $BACKUP_FILE"
else
    msg_error "Failed to create backup"
    exit 1
fi

# 6. Modify GRUB configuration
msg_info "Modifying GRUB configuration"

# Check if parameter already exists
if grep -q "$IOMMU_PARAM" "$GRUB_FILE"; then
    msg_warning "$IOMMU_PARAM is already present in GRUB configuration"
else
    # Add IOMMU parameter to GRUB_CMDLINE_LINUX_DEFAULT
    sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/\"\(.*\)\"/\"\1 $IOMMU_PARAM\"/" "$GRUB_FILE"
    msg_ok "Added $IOMMU_PARAM to GRUB configuration"
fi

# Display the modified line
echo ""
msg_info "Current GRUB_CMDLINE_LINUX_DEFAULT:"
grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$GRUB_FILE"
echo ""

# 7. Update GRUB
msg_info "Updating GRUB bootloader"
if update-grub; then
    msg_ok "GRUB updated successfully"
else
    msg_error "Failed to update GRUB"
    msg_warning "Restoring backup..."
    cp "$BACKUP_FILE" "$GRUB_FILE"
    exit 1
fi

# 8. Load required kernel modules
msg_info "Configuring kernel modules"
MODULES_FILE="/etc/modules"

# Backup modules file
cp "$MODULES_FILE" "${MODULES_FILE}.backup.$(date +%Y%m%d_%H%M%S)"

# Add required modules if not already present
REQUIRED_MODULES=("vfio" "vfio_iommu_type1" "vfio_pci" "vfio_virqfd")

for module in "${REQUIRED_MODULES[@]}"; do
    if grep -q "^$module$" "$MODULES_FILE"; then
        msg_info "$module already in modules file"
    else
        echo "$module" >> "$MODULES_FILE"
        msg_ok "Added $module to modules file"
    fi
done

# 9. Update initramfs
msg_info "Updating initramfs"
if update-initramfs -u -k all; then
    msg_ok "Initramfs updated successfully"
else
    msg_error "Failed to update initramfs"
    exit 1
fi

# 10. Check IOMMU groups (for information)
echo ""
msg_info "IOMMU Groups (will be available after reboot):"
msg_warning "Run the following command after reboot to see IOMMU groups:"
echo "  find /sys/kernel/iommu_groups/ -type l"
echo ""

# 11. Final summary
echo ""
msg_ok "═══════════════════════════════════════════════════════════"
msg_ok "        ✓  PCI Passthrough Configuration Complete  ✓"
msg_ok "═══════════════════════════════════════════════════════════"
echo ""
msg_warning "IMPORTANT: A reboot is required for changes to take effect"
echo ""
msg_info "What was done:"
echo "  ✓ Added $IOMMU_PARAM to GRUB configuration"
echo "  ✓ Updated GRUB bootloader"
echo "  ✓ Configured VFIO kernel modules"
echo "  ✓ Updated initramfs"
echo ""
msg_info "After reboot, verify IOMMU is enabled:"
echo "  dmesg | grep -e DMAR -e IOMMU"
echo ""
msg_info "To view IOMMU groups:"
echo "  find /sys/kernel/iommu_groups/ -type l"
echo ""
msg_info "Backup files created:"
echo "  - $BACKUP_FILE"
echo "  - ${MODULES_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
echo ""

# 12. Prompt for reboot
read -p "Reboot now? (y/n): " reboot_now
if [[ "$reboot_now" == "y" ]]; then
    msg_info "Rebooting in 5 seconds... Press Ctrl+C to cancel"
    sleep 5
    reboot
else
    msg_warning "Remember to reboot manually for changes to take effect!"
fi
