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
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
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

function msg_section() {
  echo -e "${MAGENTA}[SECTION]${NC} $1"
}

# Header information
function header_info() {
  clear
  cat <<"EOF"
   _________ _____    _____ __                               ______            _____
  /_  / ____/ ___/   / ___// /_____  _________ _____ ____   / ____/___  ____  / __(_)___ _
   / / /_   \__ \    \__ \/ __/ __ \/ ___/ __ `/ __ `/ _ \ / /   / __ \/ __ \/ /_/ / __ `/
  / / __/  ___/ /   ___/ / /_/ /_/ / /  / /_/ / /_/ /  __// /___/ /_/ / / / / __/ / /_/ /
 /_/_/    /____/   /____/\__/\____/_/   \__,_/\__, /\___/ \____/\____/_/ /_/_/ /_/\__, /
                                             /____/                               /____/
EOF
}

header_info
echo -e "\n Loading...\n"

# Convert bytes to human readable format
function bytes_to_human() {
    local bytes=$1
    if (( bytes >= 1099511627776 )); then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1099511627776}") TB"
    elif (( bytes >= 1073741824 )); then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}") GB"
    elif (( bytes >= 1048576 )); then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}") MB"
    else
        echo "$bytes bytes"
    fi
}

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

# 3. Check if ZFS is installed
msg_info "Checking for ZFS installation"
if ! command -v zfs &> /dev/null; then
    msg_error "ZFS is not installed on this system"
    exit 1
fi
msg_ok "ZFS is installed"

# Variables to track what needs to be configured
CONFIGURE_ARC=false
CONFIGURE_RECORDSIZE=false
CONFIGURE_VOLBLOCKSIZE=false
NEEDS_REBOOT=false

# Main menu
while true; do
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}ZFS Storage Configuration Menu${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  1) Configure ZFS ARC (Memory Cache Limit)"
    echo "  2) Configure ZFS Dataset Record Size (for files/containers)"
    echo "  3) Configure VM Disk Block Size (volblocksize for VMs)"
    echo "  4) Configure All (ARC + Record Size + VM Block Size)"
    echo "  5) View Current ZFS Status"
    echo "  6) Exit"
    echo ""
    read -p "Select option [1-6]: " main_option

    case $main_option in
        1)
            CONFIGURE_ARC=true
            break
            ;;
        2)
            CONFIGURE_RECORDSIZE=true
            break
            ;;
        3)
            CONFIGURE_VOLBLOCKSIZE=true
            break
            ;;
        4)
            CONFIGURE_ARC=true
            CONFIGURE_RECORDSIZE=true
            CONFIGURE_VOLBLOCKSIZE=true
            break
            ;;
        5)
            echo ""
            msg_section "Current ZFS Status"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            msg_info "ZFS Pools:"
            zpool list
            echo ""
            msg_info "ZFS Datasets:"
            zfs list -o name,used,avail,refer,mountpoint,recordsize
            echo ""
            msg_info "ZFS Volumes (VM Disks):"
            zfs list -t volume -o name,used,refer,volblocksize 2>/dev/null || echo "No volumes found"
            echo ""
            if command -v arc_summary &> /dev/null; then
                msg_info "ARC Summary:"
                arc_summary | head -20
            fi
            echo ""
            msg_info "Proxmox Storage Configuration:"
            grep -A 5 "^zfspool:" /etc/pve/storage.cfg 2>/dev/null || echo "No ZFS storage configured"
            echo ""
            read -p "Press Enter to continue..."
            continue
            ;;
        6)
            msg_info "Exiting without changes"
            exit 0
            ;;
        *)
            msg_error "Invalid option"
            continue
            ;;
    esac
done

################################################################################
# SECTION 1: Configure ZFS ARC
################################################################################

if [ "$CONFIGURE_ARC" = true ]; then
    echo ""
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    msg_section "SECTION 1: Configure ZFS ARC (Memory Cache)"
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Get total system memory
    msg_info "Detecting system memory"
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_BYTES=$((TOTAL_MEM_KB * 1024))
    TOTAL_MEM_GB=$(awk "BEGIN {printf \"%.2f\", $TOTAL_MEM_BYTES/1073741824}")

    msg_ok "Total system memory: ${TOTAL_MEM_GB} GB"

    # Calculate recommended values
    ARC_25_PERCENT=$((TOTAL_MEM_BYTES * 25 / 100))
    ARC_33_PERCENT=$((TOTAL_MEM_BYTES * 33 / 100))
    ARC_50_PERCENT=$((TOTAL_MEM_BYTES * 50 / 100))

    # Display current ARC status
    echo ""
    msg_info "Current ZFS ARC Status:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if command -v arc_summary &> /dev/null; then
        echo ""
        arc_summary | grep -A 10 "ARC Size:" || true
        echo ""
    else
        if [ -f /proc/spl/kstat/zfs/arcstats ]; then
            ARC_SIZE=$(grep "^size" /proc/spl/kstat/zfs/arcstats | awk '{print $3}')
            ARC_MAX=$(grep "^c_max" /proc/spl/kstat/zfs/arcstats | awk '{print $3}')
            echo "  Current ARC Size: $(bytes_to_human $ARC_SIZE)"
            echo "  Current ARC Max:  $(bytes_to_human $ARC_MAX)"
        fi
        echo ""
    fi

    # Display recommendations
    echo ""
    msg_info "ZFS ARC Size Recommendations:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "  ${CYAN}Total System Memory:${NC} ${TOTAL_MEM_GB} GB (${TOTAL_MEM_BYTES} bytes)"
    echo ""
    echo -e "  ${GREEN}Recommended Options:${NC}"
    echo "  ┌────────────────────────────────────────────────────┐"
    echo "  │  25% (Conservative): $(bytes_to_human $ARC_25_PERCENT)"
    echo "  │  33% (Balanced):     $(bytes_to_human $ARC_33_PERCENT)"
    echo "  │  50% (Aggressive):   $(bytes_to_human $ARC_50_PERCENT)"
    echo "  └────────────────────────────────────────────────────┘"
    echo ""
    msg_info "Recommended: 25-33% for general use, up to 50% for storage-heavy workloads"
    echo ""

    # Prompt for ARC size
    msg_warning "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Enter desired ZFS ARC maximum size:"
    echo ""
    echo "  1) 25% - $(bytes_to_human $ARC_25_PERCENT) (Conservative, recommended)"
    echo "  2) 33% - $(bytes_to_human $ARC_33_PERCENT) (Balanced)"
    echo "  3) 50% - $(bytes_to_human $ARC_50_PERCENT) (Aggressive)"
    echo "  4) Custom value in bytes"
    echo "  5) Skip ARC configuration"
    echo ""
    read -p "Select option [1-5]: " arc_option

    case $arc_option in
        1)
            ARC_MAX=$ARC_25_PERCENT
            ARC_PERCENT="25%"
            ;;
        2)
            ARC_MAX=$ARC_33_PERCENT
            ARC_PERCENT="33%"
            ;;
        3)
            ARC_MAX=$ARC_50_PERCENT
            ARC_PERCENT="50%"
            ;;
        4)
            read -p "Enter ARC max size in bytes: " ARC_MAX
            if ! [[ "$ARC_MAX" =~ ^[0-9]+$ ]]; then
                msg_error "Invalid input: must be a number"
                exit 1
            fi
            ARC_PERCENT="Custom"
            ;;
        5)
            msg_info "Skipping ARC configuration"
            CONFIGURE_ARC=false
            ;;
        *)
            msg_error "Invalid option"
            exit 1
            ;;
    esac

    if [ "$CONFIGURE_ARC" = true ]; then
        # Confirm ARC settings
        echo ""
        msg_info "Selected ARC Configuration:"
        echo "  ARC Max Size: $(bytes_to_human $ARC_MAX) (${ARC_MAX} bytes)"
        echo "  Percentage: ${ARC_PERCENT} of total memory"
        echo ""
        read -p "Apply this ARC configuration? (y/n): " confirm_arc

        if [[ "$confirm_arc" == "y" ]]; then
            # Backup and write configuration
            ZFS_CONF="/etc/modprobe.d/zfs.conf"
            if [ -f "$ZFS_CONF" ]; then
                BACKUP_FILE="${ZFS_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
                msg_info "Backing up existing configuration"
                cp "$ZFS_CONF" "$BACKUP_FILE"
                msg_ok "Backup created: $BACKUP_FILE"
            fi

            msg_info "Writing ZFS ARC configuration"
            echo "options zfs zfs_arc_max=${ARC_MAX}" > "$ZFS_CONF"
            msg_ok "Configuration written to $ZFS_CONF"

            msg_info "Updating initramfs"
            if update-initramfs -u; then
                msg_ok "Initramfs updated successfully"
                NEEDS_REBOOT=true
            else
                msg_error "Failed to update initramfs"
                exit 1
            fi
        else
            msg_info "ARC configuration cancelled"
            CONFIGURE_ARC=false
        fi
    fi
fi

################################################################################
# SECTION 2: Configure ZFS Dataset Record Size
################################################################################

if [ "$CONFIGURE_RECORDSIZE" = true ]; then
    echo ""
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    msg_section "SECTION 2: Configure ZFS Dataset Record Size"
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    msg_info "What is Record Size?"
    echo "  Record size affects how ZFS stores FILES and data in datasets."
    echo "  This applies to: containers, regular files, and filesystem data."
    echo "  Does NOT affect VM disks (use volblocksize for that)."
    echo ""

    # List ZFS datasets (excluding volumes)
    msg_info "Available ZFS Datasets:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    zfs list -H -t filesystem -o name,recordsize,mountpoint | nl -w2 -s') '
    echo ""

    # Prompt for dataset selection
    read -p "Enter dataset number (or 'all' for all datasets, 'skip' to skip): " dataset_choice

    if [[ "$dataset_choice" == "skip" ]]; then
        msg_info "Skipping record size configuration"
        CONFIGURE_RECORDSIZE=false
    elif [[ "$dataset_choice" == "all" ]]; then
        SELECTED_DATASETS=$(zfs list -H -t filesystem -o name)
    else
        SELECTED_DATASETS=$(zfs list -H -t filesystem -o name | sed -n "${dataset_choice}p")
        if [ -z "$SELECTED_DATASETS" ]; then
            msg_error "Invalid dataset number"
            exit 1
        fi
    fi

    if [ "$CONFIGURE_RECORDSIZE" = true ]; then
        # Display record size recommendations
        echo ""
        msg_info "Record Size Recommendations:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo -e "  ${CYAN}Use Case Based Recommendations:${NC}"
        echo "  ┌─────────────────────────────────────────────────────┐"
        echo "  │  4K   - Small random I/O workloads                   │"
        echo "  │  8K   - Database with mixed access patterns          │"
        echo "  │  16K  - General purpose, small files                 │"
        echo "  │  32K  - Balanced for mixed workloads                 │"
        echo "  │  64K  - Containers, large files                      │"
        echo "  │  128K - Default, good for most cases (recommended)   │"
        echo "  │  256K - Large sequential I/O                         │"
        echo "  │  512K - Very large files, backups                    │"
        echo "  │  1M   - Extremely large files, media storage         │"
        echo "  └─────────────────────────────────────────────────────┘"
        echo ""
        msg_warning "Note: Only NEW data will use the new record size. Existing data keeps its original size."
        echo ""

        # Prompt for record size
        echo "Available record sizes:"
        echo "  1) 4K      6) 128K (Default)"
        echo "  2) 8K      7) 256K"
        echo "  3) 16K     8) 512K"
        echo "  4) 32K     9) 1M"
        echo "  5) 64K     10) Custom (e.g., 96K)"
        echo ""
        read -p "Select record size [1-10]: " recordsize_option

        case $recordsize_option in
            1) RECORDSIZE="4K" ;;
            2) RECORDSIZE="8K" ;;
            3) RECORDSIZE="16K" ;;
            4) RECORDSIZE="32K" ;;
            5) RECORDSIZE="64K" ;;
            6) RECORDSIZE="128K" ;;
            7) RECORDSIZE="256K" ;;
            8) RECORDSIZE="512K" ;;
            9) RECORDSIZE="1M" ;;
            10)
                read -p "Enter custom record size (e.g., 96K, 192K): " RECORDSIZE
                ;;
            *)
                msg_error "Invalid option"
                exit 1
                ;;
        esac

        # Confirm record size changes
        echo ""
        msg_info "Selected Configuration:"
        echo "  Record Size: ${RECORDSIZE}"
        echo "  Datasets:"
        echo "$SELECTED_DATASETS" | sed 's/^/    - /'
        echo ""
        read -p "Apply this record size to selected datasets? (y/n): " confirm_recordsize

        if [[ "$confirm_recordsize" == "y" ]]; then
            echo ""
            msg_info "Applying record size changes..."

            while IFS= read -r dataset; do
                msg_info "Setting recordsize=${RECORDSIZE} for ${dataset}"
                if zfs set recordsize="${RECORDSIZE}" "${dataset}"; then
                    msg_ok "Updated ${dataset}"
                else
                    msg_error "Failed to update ${dataset}"
                fi
            done <<< "$SELECTED_DATASETS"

            msg_ok "Dataset record size configuration complete"
        else
            msg_info "Record size configuration cancelled"
            CONFIGURE_RECORDSIZE=false
        fi
    fi
fi

################################################################################
# SECTION 3: Configure VM Disk Block Size (volblocksize)
################################################################################

if [ "$CONFIGURE_VOLBLOCKSIZE" = true ]; then
    echo ""
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    msg_section "SECTION 3: Configure VM Disk Block Size (volblocksize)"
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    msg_info "What is volblocksize?"
    echo "  This sets the block size for FUTURE VM disks created on ZFS storage."
    echo "  This is configured in Proxmox Web UI: Datacenter → Storage → Edit → Block Size"
    echo "  Existing VM disks are NOT affected - only new disks use this setting."
    echo ""

    # List ZFS pools configured in Proxmox
    msg_info "ZFS Storage Pools in Proxmox:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    STORAGE_CFG="/etc/pve/storage.cfg"
    if [ ! -f "$STORAGE_CFG" ]; then
        msg_error "Proxmox storage configuration not found"
        CONFIGURE_VOLBLOCKSIZE=false
    else
        # Extract ZFS pool names from storage.cfg
        ZFS_STORAGES=$(grep "^zfspool:" "$STORAGE_CFG" | awk '{print $2}')

        if [ -z "$ZFS_STORAGES" ]; then
            msg_warning "No ZFS storage pools configured in Proxmox"
            CONFIGURE_VOLBLOCKSIZE=false
        else
            echo "$ZFS_STORAGES" | nl -w2 -s') '
            echo ""

            # Show current blocksize settings
            msg_info "Current blocksize settings:"
            while IFS= read -r pool; do
                current_blocksize=$(grep -A 10 "^zfspool: ${pool}" "$STORAGE_CFG" | grep "^\s*blocksize" | awk '{print $2}')
                if [ -z "$current_blocksize" ]; then
                    echo "  ${pool}: (not set - defaults to 8K)"
                else
                    echo "  ${pool}: ${current_blocksize}"
                fi
            done <<< "$ZFS_STORAGES"
            echo ""

            # Prompt for storage selection
            read -p "Enter storage number (or 'all' for all storages, 'skip' to skip): " storage_choice

            if [[ "$storage_choice" == "skip" ]]; then
                msg_info "Skipping volblocksize configuration"
                CONFIGURE_VOLBLOCKSIZE=false
            elif [[ "$storage_choice" == "all" ]]; then
                SELECTED_STORAGES="$ZFS_STORAGES"
            else
                SELECTED_STORAGES=$(echo "$ZFS_STORAGES" | sed -n "${storage_choice}p")
                if [ -z "$SELECTED_STORAGES" ]; then
                    msg_error "Invalid storage number"
                    exit 1
                fi
            fi
        fi
    fi

    if [ "$CONFIGURE_VOLBLOCKSIZE" = true ]; then
        # Display volblocksize recommendations
        echo ""
        msg_info "VM Disk Block Size (volblocksize) Recommendations:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo -e "  ${CYAN}Use Case Based Recommendations:${NC}"
        echo "  ┌─────────────────────────────────────────────────────┐"
        echo "  │  4K   - Database VMs (best for random I/O)          │"
        echo "  │  8K   - General purpose VMs (Proxmox default)        │"
        echo "  │  16K  - Balanced performance (recommended)           │"
        echo "  │  32K  - Large I/O workloads                          │"
        echo "  │  64K  - Sequential I/O, media servers                │"
        echo "  │  128K - Very large block I/O                         │"
        echo "  └─────────────────────────────────────────────────────┘"
        echo ""
        msg_warning "⚠️  Smaller block size = better random I/O, more metadata overhead"
        msg_warning "⚠️  Larger block size = better sequential I/O, less overhead"
        echo ""

        # Prompt for volblocksize
        echo "Available block sizes for VM disks:"
        echo "  1) 4K      5) 64K"
        echo "  2) 8K (Proxmox default)"
        echo "  3) 16K (Recommended)"
        echo "  4) 32K     6) 128K"
        echo ""
        read -p "Select block size [1-6]: " volblocksize_option

        case $volblocksize_option in
            1) VOLBLOCKSIZE="4K" ;;
            2) VOLBLOCKSIZE="8K" ;;
            3) VOLBLOCKSIZE="16K" ;;
            4) VOLBLOCKSIZE="32K" ;;
            5) VOLBLOCKSIZE="64K" ;;
            6) VOLBLOCKSIZE="128K" ;;
            *)
                msg_error "Invalid option"
                exit 1
                ;;
        esac

        # Confirm volblocksize changes
        echo ""
        msg_info "Selected Configuration:"
        echo "  VM Disk Block Size: ${VOLBLOCKSIZE}"
        echo "  Storage Pools:"
        echo "$SELECTED_STORAGES" | sed 's/^/    - /'
        echo ""
        msg_warning "This only affects FUTURE VM disks. Existing VM disks will NOT change."
        echo ""
        read -p "Apply this block size to selected storage pools? (y/n): " confirm_volblocksize

        if [[ "$confirm_volblocksize" == "y" ]]; then
            echo ""
            msg_info "Updating Proxmox storage configuration..."

            # Backup storage.cfg
            STORAGE_BACKUP="${STORAGE_CFG}.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$STORAGE_CFG" "$STORAGE_BACKUP"
            msg_ok "Backup created: $STORAGE_BACKUP"

            # Update blocksize for selected storages
            while IFS= read -r storage; do
                msg_info "Setting blocksize=${VOLBLOCKSIZE} for ${storage}"

                # Remove existing blocksize line if present
                sed -i "/^zfspool: ${storage}/,/^$/{/^\s*blocksize/d}" "$STORAGE_CFG"

                # Add new blocksize parameter after the zfspool line
                sed -i "/^zfspool: ${storage}/a\\        blocksize ${VOLBLOCKSIZE}" "$STORAGE_CFG"

                msg_ok "Updated ${storage}"
            done <<< "$SELECTED_STORAGES"

            msg_ok "Proxmox storage configuration updated"

            # Show updated configuration
            echo ""
            msg_info "Updated storage.cfg entries:"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            while IFS= read -r storage; do
                echo ""
                grep -A 5 "^zfspool: ${storage}" "$STORAGE_CFG"
            done <<< "$SELECTED_STORAGES"
            echo ""
        else
            msg_info "volblocksize configuration cancelled"
            CONFIGURE_VOLBLOCKSIZE=false
        fi
    fi
fi

################################################################################
# FINAL SUMMARY
################################################################################

echo ""
msg_ok "═══════════════════════════════════════════════════════════"
msg_ok "         ✓  ZFS Storage Configuration Complete  ✓"
msg_ok "═══════════════════════════════════════════════════════════"
echo ""

if [ "$CONFIGURE_ARC" = true ]; then
    msg_info "ARC Configuration:"
    echo "  ✓ ARC Max Size: $(bytes_to_human ${ARC_MAX:-0})"
    echo "  ✓ Configuration: /etc/modprobe.d/zfs.conf"
    echo ""
fi

if [ "$CONFIGURE_RECORDSIZE" = true ]; then
    msg_info "Dataset Record Size Configuration:"
    echo "  ✓ Record Size: ${RECORDSIZE}"
    echo "  ✓ Applies to: Files, containers in datasets"
    echo "  ✓ Updated Datasets:"
    echo "$SELECTED_DATASETS" | sed 's/^/      - /'
    echo ""
fi

if [ "$CONFIGURE_VOLBLOCKSIZE" = true ]; then
    msg_info "VM Disk Block Size Configuration:"
    echo "  ✓ Block Size: ${VOLBLOCKSIZE}"
    echo "  ✓ Applies to: NEW VM disks only"
    echo "  ✓ Updated Storage Pools:"
    echo "$SELECTED_STORAGES" | sed 's/^/      - /'
    echo "  ✓ Configuration: /etc/pve/storage.cfg"
    echo ""
fi

if [ "$NEEDS_REBOOT" = true ]; then
    msg_warning "IMPORTANT: A reboot is REQUIRED for ARC changes to take effect"
    echo ""
fi

msg_info "Verification Commands:"
if [ "$CONFIGURE_ARC" = true ]; then
    echo "  • Check ARC status: arc_summary"
    echo "  • View ARC max: cat /proc/spl/kstat/zfs/arcstats | grep c_max"
fi
if [ "$CONFIGURE_RECORDSIZE" = true ]; then
    echo "  • Check record sizes: zfs get recordsize"
fi
if [ "$CONFIGURE_VOLBLOCKSIZE" = true ]; then
    echo "  • View storage config: cat /etc/pve/storage.cfg"
    echo "  • Check existing VM disk sizes: zfs list -t volume -o name,volblocksize"
fi
echo ""

# Prompt for reboot if needed
if [ "$NEEDS_REBOOT" = true ]; then
    read -p "Reboot now? (y/n): " reboot_now
    if [[ "$reboot_now" == "y" ]]; then
        msg_info "Rebooting in 5 seconds... Press Ctrl+C to cancel"
        sleep 5
        reboot
    else
        msg_warning "Remember to reboot manually for ARC changes to take effect!"
    fi
fi
