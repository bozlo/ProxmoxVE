#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
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
    ____       __     __           __                     __    __  ____  ___
   / __ \___  / /__  / /____      / /   ____  _________ _/ /   / / / /  |/  /
  / / / / _ \/ / _ \/ __/ _ \    / /   / __ \/ ___/ __ `/ /   / / / / /|_/ / 
 / /_/ /  __/ /  __/ /_/  __/   / /___/ /_/ / /__/ /_/ / /   / /_/ / /  / /  
/_____/\___/_/\___/\__/\___/   /_____/\____/\___/\__,_/_/____\____/_/  /_/   
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

msg_info "Checking for local-lvm storage"

# 3. Check if local-lvm storage exists
if ! pvesm status | grep -q "local-lvm"; then
    msg_ok "local-lvm storage not found - nothing to do"
    exit 0
fi

if ! lvs | grep -q "data"; then
    msg_ok "local-lvm LVM volume not found - nothing to do"
    exit 0
fi

msg_ok "Found local-lvm storage"

# 4. Check for VMs/CTs using local-lvm
msg_info "Checking for VMs/CTs using local-lvm"

echo ""
msg_warning "═══════════════════════════════════════════════════════════"
msg_warning "           ⚠️  CRITICAL WARNING  ⚠️"
msg_warning "═══════════════════════════════════════════════════════════"
msg_warning "This will PERMANENTLY DELETE local-lvm storage!"
msg_warning "All data on local-lvm will be LOST!"
echo ""

# Check VMs
vms_on_lvm=$(qm list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r vmid; do
    if qm config "$vmid" 2>/dev/null | grep -q "local-lvm"; then
        echo "$vmid"
    fi
done)

if [[ -n "$vms_on_lvm" ]]; then
    msg_warning "VMs using local-lvm storage:"
    echo "$vms_on_lvm" | while read vmid; do
        vm_name=$(qm config $vmid | grep "^name:" | cut -d' ' -f2)
        echo "  - VM $vmid: $vm_name"
    done
    echo ""
fi

# Check containers
cts_on_lvm=$(pct list 2>/dev/null | awk 'NR>1 {print $1}' | while read -r ctid; do
    if pct config "$ctid" 2>/dev/null | grep -q "local-lvm"; then
        echo "$ctid"
    fi
done)

if [[ -n "$cts_on_lvm" ]]; then
    msg_warning "Containers using local-lvm storage:"
    echo "$cts_on_lvm" | while read ctid; do
        ct_name=$(pct config $ctid | grep "^hostname:" | cut -d' ' -f2)
        echo "  - CT $ctid: $ct_name"
    done
    echo ""
fi

if [[ -n "$vms_on_lvm" ]] || [[ -n "$cts_on_lvm" ]]; then
    msg_error "Cannot proceed: VMs/CTs are using local-lvm storage"
    msg_error "Please migrate or remove them first"
    exit 1
fi

msg_ok "No VMs/CTs using local-lvm"

# 5. Display current storage status
echo ""
msg_info "Current storage status:"
df -h / | tail -1
pvs
lvs | grep pve
echo ""

# 6. User confirmation
msg_warning "═══════════════════════════════════════════════════════════"
read -p "Type 'DELETE' to confirm deletion of local-lvm: " confirm

if [[ "$confirm" != "DELETE" ]]; then
    msg_error "Operation cancelled by user"
    exit 1
fi

echo ""
msg_warning "Starting deletion in 10 seconds... Press Ctrl+C to cancel"
sleep 10

# 7. Remove storage from Web UI
msg_info "Removing local-lvm from Web UI configuration"
if pvesm remove local-lvm 2>/dev/null; then
    msg_ok "Removed local-lvm from storage configuration"
else
    msg_warning "Could not remove from Web UI (may not exist)"
fi

# 8. Remove LVM logical volume
msg_info "Removing LVM logical volume"
if lvremove -y /dev/pve/data 2>/dev/null; then
    msg_ok "Removed /dev/pve/data logical volume"
else
    msg_error "Failed to remove logical volume"
    exit 1
fi

# 9. Extend root partition
msg_info "Extending root logical volume to maximum size"
if lvextend -l +100%FREE /dev/pve/root; then
    msg_ok "Extended root logical volume"
else
    msg_error "Failed to extend root volume"
    exit 1
fi

msg_info "Resizing root filesystem"
if resize2fs /dev/mapper/pve-root; then
    msg_ok "Resized root filesystem"
else
    msg_error "Failed to resize filesystem"
    exit 1
fi

# 10. Display final results
echo ""
msg_ok "═══════════════════════════════════════════════════════════"
msg_ok "           ✓  Operation Completed Successfully  ✓"
msg_ok "═══════════════════════════════════════════════════════════"
echo ""

msg_info "Final storage status:"
echo ""
echo "Disk usage:"
df -h / | tail -1
echo ""
echo "Physical volumes:"
pvs
echo ""
echo "Logical volumes:"
lvs | grep pve
echo ""
echo "Proxmox storages:"
pvesm status
echo ""

msg_ok "local-lvm has been removed and root storage has been extended!"
msg_ok "You can now use the full disk capacity for local storage."
echo ""
msg_warning "Note: You may need to refresh the Web UI to see the changes."
