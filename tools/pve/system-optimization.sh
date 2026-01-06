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
   _____            __                  ____        __  _           _           __  _
  / ___/__  _______/ /____  ____ ___   / __ \____  / /_(_)___ ___  (_)___  ____/ /_(_)___  ____
  \__ \/ / / / ___/ __/ _ \/ __ `__ \ / / / / __ \/ __/ / __ `__ \/ /_  / / __  / / __ \/ __ \
 ___/ / /_/ (__  ) /_/  __/ / / / / // /_/ / /_/ / /_/ / / / / / / / / /_/ /_/ / / /_/ / / / /
/____/\__, /____/\__/\___/_/ /_/ /_/ \____/ .___/\__/_/_/ /_/ /_/_/ /___/\__,_/_/\____/_/ /_/
     /____/                               /_/
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

# Variables to track what needs to be configured
CONFIGURE_JOURNALD=false
CONFIGURE_ZFS=false
CONFIGURE_SWAP=false
CONFIGURE_SWAPPINESS=false
NEEDS_REBOOT=false

# Main menu
while true; do
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}System Optimization Menu${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  1) Configure journald (Reduce SSD Wear)"
    echo "  2) ZFS Optimization (Reduce SSD Wear)"
    echo "  3) Configure Swap Size (Resize Swap)"
    echo "  4) Configure Swappiness (Memory Swap Behavior)"
    echo "  5) Apply All Optimizations"
    echo "  6) View Current Status"
    echo "  7) Exit"
    echo ""
    read -p "Select option [1-7]: " main_option

    case $main_option in
        1)
            CONFIGURE_JOURNALD=true
            break
            ;;
        2)
            CONFIGURE_ZFS=true
            break
            ;;
        3)
            CONFIGURE_SWAP=true
            break
            ;;
        4)
            CONFIGURE_SWAPPINESS=true
            break
            ;;
        5)
            CONFIGURE_JOURNALD=true
            CONFIGURE_ZFS=true
            CONFIGURE_SWAP=true
            CONFIGURE_SWAPPINESS=true
            break
            ;;
        6)
            echo ""
            msg_section "Current System Status"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            msg_info "journald Configuration:"
            if [ -f /etc/systemd/journald.conf.d/99-ssd-optimize.conf ]; then
                cat /etc/systemd/journald.conf.d/99-ssd-optimize.conf
            else
                echo "  Not configured (using system defaults)"
            fi
            echo ""
            msg_info "Journal Status:"
            journalctl --disk-usage
            echo ""
            msg_info "fstab Mount Options:"
            grep -v "^#" /etc/fstab | grep -v "^$"
            echo ""
            msg_info "Current Mount Options:"
            mount | grep -E "^/dev/.*on / "
            echo ""
            read -p "Press Enter to continue..."
            continue
            ;;
        5)
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
# SECTION 1: Configure journald
################################################################################

if [ "$CONFIGURE_JOURNALD" = true ]; then
    echo ""
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    msg_section "SECTION 1: Configure journald for SSD Optimization"
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    msg_info "What is journald optimization?"
    echo "  systemd-journald writes system logs to disk frequently."
    echo "  This configuration reduces SSD wear by:"
    echo "    • Storing logs in volatile memory (/run) instead of disk"
    echo "    • Limiting log size to 64MB"
    echo "    • Disabling compression to reduce CPU usage"
    echo "    • Syncing to disk every 10 minutes instead of constantly"
    echo ""
    msg_warning "Note: Logs will be lost on reboot, but critical errors are still logged to /var/log/syslog"
    echo ""

    # Show current journal usage
    msg_info "Current journal disk usage:"
    journalctl --disk-usage
    echo ""

    # Prompt for confirmation
    read -p "Apply journald optimization? (y/n): " confirm_journald

    if [[ "$confirm_journald" == "y" ]]; then
        # Create configuration directory
        msg_info "Creating journald configuration directory"
        mkdir -p /etc/systemd/journald.conf.d/

        # Backup existing configuration if it exists
        JOURNALD_CONF="/etc/systemd/journald.conf.d/99-ssd-optimize.conf"
        if [ -f "$JOURNALD_CONF" ]; then
            BACKUP_FILE="${JOURNALD_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$JOURNALD_CONF" "$BACKUP_FILE"
            msg_ok "Backup created: $BACKUP_FILE"
        fi

        # Write journald configuration
        msg_info "Writing journald optimization configuration"
        cat > "$JOURNALD_CONF" << 'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=64M
RuntimeKeepFree=128M
Compress=no
SyncIntervalSec=10m
EOF

        msg_ok "Configuration written to $JOURNALD_CONF"

        # Display configuration
        echo ""
        msg_info "Configuration contents:"
        cat "$JOURNALD_CONF"
        echo ""

        # Restart journald service
        msg_info "Restarting systemd-journald service"
        if systemctl restart systemd-journald; then
            msg_ok "systemd-journald restarted successfully"
        else
            msg_error "Failed to restart systemd-journald"
            exit 1
        fi

        # Show new journal usage
        echo ""
        msg_info "New journal disk usage:"
        journalctl --disk-usage
        echo ""

        msg_ok "journald optimization complete"
    else
        msg_info "journald configuration cancelled"
        CONFIGURE_JOURNALD=false
    fi
fi

################################################################################
# SECTION 2: ZFS Optimization
################################################################################

if [ "$CONFIGURE_ZFS" = true ]; then
    echo ""
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    msg_section "SECTION 2: ZFS Optimization (Reduce SSD Wear)"
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  This section will configure:"
    echo "    • noatime for zfs filesystems (via /etc/fstab)"
    echo "    • atime=off for ZFS pools (via zfs set)"
    echo "    • xattr=sa for ZFS pools (via zfs set)"
    echo "    • acltype=posix for ZFS pools (via zfs set)"
    echo ""
    msg_warning "Note: Most applications don't need access time information"
    echo ""

    # Show current fstab
    msg_info "Current /etc/fstab:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    grep -v "^#" /etc/fstab | grep -v "^$"
    echo ""

    # Check for ZFS
    HAS_ZFS=false
    if command -v zfs &> /dev/null; then
        HAS_ZFS=true
        msg_info "ZFS Pools detected:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        zpool list -H -o name,size,free | while read name size free; do
            atime_status=$(zfs get -H -o value atime "$name" 2>/dev/null || echo "unknown")
            xattr_status=$(zfs get -H -o value xattr "$name" 2>/dev/null || echo "unknown")
            acltype_status=$(zfs get -H -o value acltype "$name" 2>/dev/null || echo "unknown")
            echo "  Pool: $name | Size: $size | Free: $free | atime: $atime_status | xattr: $xattr_status | acltype: $acltype_status"
        done
        echo ""
    fi

    # Check if root partition already has noatime
    NEEDS_FSTAB_UPDATE=false
    if grep -E "^[^#].* / .* noatime" /etc/fstab > /dev/null; then
        msg_info "Root filesystem already has noatime option"
    else
        msg_warning "Root filesystem does NOT have noatime"
        NEEDS_FSTAB_UPDATE=true
    fi

    # Check ZFS atime status
    NEEDS_ZFS_UPDATE=false
    if [ "$HAS_ZFS" = true ]; then
        ZFS_POOLS_TO_UPDATE=""
        while IFS= read -r pool; do
            atime_status=$(zfs get -H -o value atime "$pool" 2>/dev/null)
            xattr_status=$(zfs get -H -o value xattr "$pool" 2>/dev/null)
            acltype_status=$(zfs get -H -o value acltype "$pool" 2>/dev/null)
            # IDK but xattr_status return on even if sa is set
            if [[ "$atime_status" != "off" ]] || [[ "$xattr_status" != "on" ]] || [[ "$acltype_status" != "posix" ]]; then
                NEEDS_ZFS_UPDATE=true
                ZFS_POOLS_TO_UPDATE="${ZFS_POOLS_TO_UPDATE}${pool}\n"
            fi
        done < <(zpool list -H -o name)

        if [ "$NEEDS_ZFS_UPDATE" = true ]; then
            msg_warning "Some ZFS pools does not have a recommended properties."
        else
            msg_info "All ZFS pools already have atime=off, xattr=sa, acltype=posix"
        fi
    fi

    # If everything is already configured
    if [ "$NEEDS_FSTAB_UPDATE" = false ] && [ "$NEEDS_ZFS_UPDATE" = false ]; then
        msg_ok "All filesystems already have atime=off, xattr=sa, acltype=posix"
        read -p "Continue anyway? (y/n): " continue_conf_zfs
        if [[ "$continue_conf_zfs" != "y" ]]; then
            msg_info "zfs configuration cancelled"
            CONFIGURE_ZFS=false
        fi
    fi

    if [ "$CONFIGURE_ZFS" = true ]; then
        # Prompt for confirmation
        echo ""
        msg_info "Configuration Plan:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        if [ "$NEEDS_FSTAB_UPDATE" = true ]; then
            echo "  ✓ Add noatime to root filesystem (zfs)"
        else
            echo "  - Root filesystem already has noatime"
        fi
        if [ "$NEEDS_ZFS_UPDATE" = true ]; then
            echo "  ✓ Set atime=off, xattr=sa, acltype=posix for ZFS pools:"
            echo -e "$ZFS_POOLS_TO_UPDATE" | sed 's/^/      - /'
        else
            if [ "$HAS_ZFS" = true ]; then
                echo "  - ZFS pools already have atime=off, xattr=sa, acltype=posix"
            else
                echo "  - No ZFS pools detected"
            fi
        fi
        echo ""

        read -p "Apply ZFS properties configuration? (y/n): " confirm_conf_zfs

        if [[ "$confirm_conf_zfs" == "y" ]]; then
            ZFS_CONF_CONFIGURED=false

            # Part A: Configure fstab for ext4/xfs
            if [ "$NEEDS_FSTAB_UPDATE" = true ]; then
                msg_info "Configuring noatime for traditional filesystems"

                # Backup fstab
                FSTAB="/etc/fstab"
                FSTAB_BACKUP="${FSTAB}.backup.$(date +%Y%m%d_%H%M%S)"
                cp "$FSTAB" "$FSTAB_BACKUP"
                msg_ok "Backup created: $FSTAB_BACKUP"

                # Find root partition line
                ROOT_DEVICE=$(findmnt -n -o SOURCE /)
                msg_info "Detected root device: $ROOT_DEVICE"

                # Add noatime to root partition
                msg_info "Adding noatime option to root filesystem"

                # Check if it's a standard Proxmox installation
                if grep -q "^/dev/pve/root" "$FSTAB"; then
                    # Standard Proxmox with LVM
                    if grep "^/dev/pve/root" "$FSTAB" | grep -q "noatime"; then
                        msg_warning "noatime already present in fstab"
                    else
                        # Add noatime after the filesystem type
                        sed -i '/^\/dev\/pve\/root/ s/\(ext4\s\+\)/\1noatime,/' "$FSTAB"
                        msg_ok "Added noatime to /dev/pve/root"
                    fi
                else
                    # Other configurations - find root partition
                    if grep -E "^[^#].* / " "$FSTAB" | grep -q "noatime"; then
                        msg_warning "noatime already present in fstab"
                    else
                        # Add noatime to the root partition line
                        sed -i '/\s\/\s/ {/^[^#]/s/\(defaults\|errors=remount-ro\)/noatime,\1/}' "$FSTAB"
                        msg_ok "Added noatime to root partition"
                    fi
                fi

                # Display modified fstab
                echo ""
                msg_info "Modified /etc/fstab:"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                grep -v "^#" "$FSTAB" | grep -v "^$"
                echo ""

                # Remount root filesystem with new options
                msg_info "Remounting root filesystem with new options"
                if mount -o remount /; then
                    msg_ok "Root filesystem remounted successfully"

                    # Verify noatime is active
                    if mount | grep -E "^${ROOT_DEVICE} on / " | grep -q "noatime"; then
                        msg_ok "noatime is now active on root filesystem"
                        ZFS_CONF_CONFIGURED=true
                    else
                        msg_warning "noatime not detected in current mount. A reboot may be required."
                        NEEDS_REBOOT=true
                    fi
                else
                    msg_warning "Failed to remount. Changes will take effect after reboot."
                    NEEDS_REBOOT=true
                fi
            fi

            # Part B: Configure ZFS pools
            if [ "$NEEDS_ZFS_UPDATE" = true ]; then
                echo ""
                msg_info "Configuring atime=off, xattr=sa, acltype=posix for ZFS pools"

                while IFS= read -r pool; do
                    [ -z "$pool" ] && continue

                    msg_info "Setting atime=off for pool: $pool"
                    if zfs set atime=off "$pool"; then
                        msg_ok "Set atime=off for $pool"
                        ZFS_CONF_CONFIGURED=true

                        # Also set for all child datasets
                        msg_info "Setting atime=off for child datasets of $pool"
                        zfs list -H -r -o name "$pool" | while read dataset; do
                            if [ "$dataset" != "$pool" ]; then
                                if zfs set atime=off "$dataset"; then
                                    msg_ok "  └─ Set atime=off for $dataset"
                                else
                                    msg_warning "  └─ Failed to set atime=off for $dataset"
                                fi
                            fi
                        done
                    else
                        msg_error "Failed to set atime=off for $pool"
                    fi

                    msg_info "Setting xattr=sa for pool: $pool"
                    if zfs set xattr=sa "$pool"; then
                        msg_ok "Set xattr=sa for $pool"
                        ZFS_CONF_CONFIGURED=true

                        # Also set for all child datasets
                        msg_info "Setting xattr=sa for child datasets of $pool"
                        zfs list -H -r -o name "$pool" | while read dataset; do
                            if [ "$dataset" != "$pool" ]; then
                                if zfs set xattr=sa "$dataset"; then
                                    msg_ok "  └─ Set xattr=sa for $dataset"
                                else
                                    msg_warning "  └─ Failed to set xattr=sa for $dataset"
                                fi
                            fi
                        done
                    else
                        msg_error "Failed to set xattr=sa for $pool"
                    fi

                    msg_info "Setting acltype=posix for pool: $pool"
                    if zfs set acltype=posix "$pool"; then
                        msg_ok "Set acltype=posix for $pool"
                        ZFS_CONF_CONFIGURED=true

                        # Also set for all child datasets
                        msg_info "Setting acltype=posix for child datasets of $pool"
                        zfs list -H -r -o name "$pool" | while read dataset; do
                            if [ "$dataset" != "$pool" ]; then
                                if zfs set acltype=posix "$dataset"; then
                                    msg_ok "  └─ Set acltype=posix for $dataset"
                                else
                                    msg_warning "  └─ Failed to set acltype=posix for $dataset"
                                fi
                            fi
                        done
                    else
                        msg_error "Failed to set acltype=posix for $pool"
                    fi
                done < <(echo -e "$ZFS_POOLS_TO_UPDATE")

                # Display ZFS pool status
                echo ""
                msg_info "ZFS Pool atime,xattr,acltype Status:"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                zfs get -r atime,xattr,acltype | grep -E "^(NAME|[a-z])" | head -20
                echo ""
            fi

            if [ "$ZFS_CONF_CONFIGURED" = true ]; then
                msg_ok "atime,xattr,acltype configuration complete"
            else
                msg_warning "No changes were needed or applied"
            fi
        else
            msg_info "atime,xattr,acltype configuration cancelled"
            CONFIGURE_ZFS=false
        fi
    fi
fi

################################################################################
# SECTION 3: Configure Swap Size
################################################################################

if [ "$CONFIGURE_SWAP" = true ]; then
    echo ""
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    msg_section "SECTION 3: Configure Swap Size"
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    msg_info "What is Swap?"
    echo "  Swap is disk space used when RAM is full."
    echo "  Larger swap allows system to handle memory spikes better."
    echo "  Recommended: 32GB for systems with 64GB+ RAM"
    echo ""

    # Show current swap status
    msg_info "Current Swap Status:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    swapon --show
    echo ""
    free -h
    echo ""

    # Check if /dev/pve/swap exists
    if ! lvs | grep -q "swap"; then
        msg_warning "No swap LV found in /dev/pve/swap"
        read -p "Continue anyway? (y/n): " continue_swap
        if [[ "$continue_swap" != "y" ]]; then
            msg_info "Swap configuration cancelled"
            CONFIGURE_SWAP=false
        fi
    fi

    if [ "$CONFIGURE_SWAP" = true ]; then
        # Get total system memory for recommendation
        TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        TOTAL_MEM_GB=$(awk "BEGIN {printf \"%.0f\", $TOTAL_MEM_KB/1048576}")

        echo ""
        msg_info "Swap Size Recommendations:"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  System Memory: ${TOTAL_MEM_GB}GB"
        echo ""
        echo "  Recommended swap sizes:"
        echo "  ┌────────────────────────────────────────┐"
        echo "  │  16GB  - For systems with 32-64GB RAM  │"
        echo "  │  32GB  - For systems with 64-128GB RAM │"
        echo "  │  64GB  - For systems with 128GB+ RAM   │"
        echo "  └────────────────────────────────────────┘"
        echo ""

        # Prompt for swap size
        echo "Enter desired swap size:"
        echo "  1) 16GB"
        echo "  2) 32GB (Recommended for most systems)"
        echo "  3) 64GB"
        echo "  4) Custom size"
        echo "  5) Skip swap configuration"
        echo ""
        read -p "Select option [1-5]: " swap_option

        case $swap_option in
            1) SWAP_SIZE="16G" ;;
            2) SWAP_SIZE="32G" ;;
            3) SWAP_SIZE="64G" ;;
            4)
                read -p "Enter custom swap size (e.g., 24G, 48G): " SWAP_SIZE
                if ! [[ "$SWAP_SIZE" =~ ^[0-9]+[GM]$ ]]; then
                    msg_error "Invalid format. Use format like 32G or 16000M"
                    exit 1
                fi
                ;;
            5)
                msg_info "Skipping swap configuration"
                CONFIGURE_SWAP=false
                ;;
            *)
                msg_error "Invalid option"
                exit 1
                ;;
        esac

        if [ "$CONFIGURE_SWAP" = true ]; then
            # Confirm swap resize
            echo ""
            msg_info "Selected Configuration:"
            echo "  New Swap Size: ${SWAP_SIZE}"
            echo ""
            msg_warning "⚠️  This will:"
            echo "  1. Disable current swap"
            echo "  2. DELETE existing swap LV"
            echo "  3. Create new swap LV with size ${SWAP_SIZE}"
            echo "  4. Format and enable new swap"
            echo ""
            read -p "Proceed with swap resize? (y/n): " confirm_swap

            if [[ "$confirm_swap" == "y" ]]; then
                # Step 1: Disable swap
                msg_info "Disabling swap"
                if swapoff -a; then
                    msg_ok "Swap disabled"
                else
                    msg_error "Failed to disable swap"
                    exit 1
                fi

                # Step 2: Remove existing swap LV
                msg_info "Removing existing swap LV"
                if lvremove -y /dev/pve/swap 2>/dev/null; then
                    msg_ok "Existing swap LV removed"
                else
                    msg_warning "No existing swap LV found or already removed"
                fi

                # Step 3: Create new swap LV
                msg_info "Creating new swap LV with size ${SWAP_SIZE}"
                if lvcreate -L "${SWAP_SIZE}" -n swap pve; then
                    msg_ok "New swap LV created"
                else
                    msg_error "Failed to create swap LV"
                    msg_error "You may need to manually restore swap!"
                    exit 1
                fi

                # Step 4: Format swap
                msg_info "Formatting swap partition"
                if mkswap /dev/pve/swap; then
                    msg_ok "Swap formatted"
                else
                    msg_error "Failed to format swap"
                    exit 1
                fi

                # Step 5: Enable swap
                msg_info "Enabling swap"
                if swapon /dev/pve/swap; then
                    msg_ok "Swap enabled"
                else
                    msg_error "Failed to enable swap"
                    exit 1
                fi

                # Verify new swap
                echo ""
                msg_info "New Swap Status:"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                swapon --show
                echo ""
                free -h
                echo ""

                msg_ok "Swap resize complete"
            else
                msg_info "Swap configuration cancelled"
                CONFIGURE_SWAP=false
            fi
        fi
    fi
fi

################################################################################
# SECTION 4: Configure Swappiness
################################################################################

if [ "$CONFIGURE_SWAPPINESS" = true ]; then
    echo ""
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    msg_section "SECTION 4: Configure Swappiness"
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    msg_info "What is Swappiness?"
    echo "  Swappiness controls how aggressively the kernel swaps memory to disk."
    echo "  Value range: 0-100"
    echo "    • 0   = Avoid swapping as much as possible"
    echo "    • 10  = Recommended for servers with enough RAM"
    echo "    • 60  = Default Linux value (balanced)"
    echo "    • 100 = Swap aggressively"
    echo ""

    # Show current swappiness
    CURRENT_SWAPPINESS=$(sysctl -n vm.swappiness)
    msg_info "Current swappiness: ${CURRENT_SWAPPINESS}"
    echo ""

    # Recommendations
    msg_info "Swappiness Recommendations:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  ┌──────────────────────────────────────────────────┐"
    echo "  │  1  - Minimal swap (for systems with lots of RAM) │"
    echo "  │  10 - Recommended for Proxmox servers (default)   │"
    echo "  │  20 - Moderate swap usage                         │"
    echo "  │  60 - Linux default (balanced)                    │"
    echo "  └──────────────────────────────────────────────────┘"
    echo ""

    # Prompt for swappiness value
    echo "Select swappiness value:"
    echo "  1) 1  (Minimal swap)"
    echo "  2) 10 (Recommended)"
    echo "  3) 20 (Moderate)"
    echo "  4) 60 (Linux default)"
    echo "  5) Custom value (0-100)"
    echo "  6) Skip swappiness configuration"
    echo ""
    read -p "Select option [1-6]: " swappiness_option

    case $swappiness_option in
        1) SWAPPINESS_VALUE=1 ;;
        2) SWAPPINESS_VALUE=10 ;;
        3) SWAPPINESS_VALUE=20 ;;
        4) SWAPPINESS_VALUE=60 ;;
        5)
            read -p "Enter custom swappiness value (0-100): " SWAPPINESS_VALUE
            if ! [[ "$SWAPPINESS_VALUE" =~ ^[0-9]+$ ]] || [ "$SWAPPINESS_VALUE" -lt 0 ] || [ "$SWAPPINESS_VALUE" -gt 100 ]; then
                msg_error "Invalid value. Must be between 0 and 100"
                exit 1
            fi
            ;;
        6)
            msg_info "Skipping swappiness configuration"
            CONFIGURE_SWAPPINESS=false
            ;;
        *)
            msg_error "Invalid option"
            exit 1
            ;;
    esac

    if [ "$CONFIGURE_SWAPPINESS" = true ]; then
        # Confirm swappiness change
        echo ""
        msg_info "Selected Configuration:"
        echo "  Current Swappiness: ${CURRENT_SWAPPINESS}"
        echo "  New Swappiness: ${SWAPPINESS_VALUE}"
        echo ""
        read -p "Apply this swappiness value? (y/n): " confirm_swappiness

        if [[ "$confirm_swappiness" == "y" ]]; then
            # Backup existing configuration if it exists
            SWAPPINESS_CONF="/etc/sysctl.d/99-swappiness.conf"
            if [ -f "$SWAPPINESS_CONF" ]; then
                BACKUP_FILE="${SWAPPINESS_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
                cp "$SWAPPINESS_CONF" "$BACKUP_FILE"
                msg_ok "Backup created: $BACKUP_FILE"
            fi

            # Write swappiness configuration
            msg_info "Writing swappiness configuration"
            echo "vm.swappiness=${SWAPPINESS_VALUE}" > "$SWAPPINESS_CONF"
            msg_ok "Configuration written to $SWAPPINESS_CONF"

            # Apply immediately
            msg_info "Applying swappiness setting"
            if sysctl -p "$SWAPPINESS_CONF"; then
                msg_ok "Swappiness applied successfully"
            else
                msg_error "Failed to apply swappiness"
                exit 1
            fi

            # Verify new value
            NEW_SWAPPINESS=$(sysctl -n vm.swappiness)
            echo ""
            msg_info "Swappiness verification:"
            echo "  Previous: ${CURRENT_SWAPPINESS}"
            echo "  Current:  ${NEW_SWAPPINESS}"
            echo ""

            if [ "$NEW_SWAPPINESS" -eq "$SWAPPINESS_VALUE" ]; then
                msg_ok "Swappiness successfully set to ${SWAPPINESS_VALUE}"
            else
                msg_warning "Swappiness value mismatch. Reboot may be required."
            fi

            msg_ok "Swappiness configuration complete"
        else
            msg_info "Swappiness configuration cancelled"
            CONFIGURE_SWAPPINESS=false
        fi
    fi
fi

################################################################################
# FINAL SUMMARY
################################################################################

echo ""
msg_ok "═══════════════════════════════════════════════════════════"
msg_ok "         ✓  System Optimization Complete  ✓"
msg_ok "═══════════════════════════════════════════════════════════"
echo ""

if [ "$CONFIGURE_JOURNALD" = true ]; then
    msg_info "journald Optimization:"
    echo "  ✓ Logs stored in volatile memory (/run)"
    echo "  ✓ Maximum log size: 64MB"
    echo "  ✓ Compression disabled"
    echo "  ✓ Sync interval: 10 minutes"
    echo "  ✓ Configuration: /etc/systemd/journald.conf.d/99-ssd-optimize.conf"
    echo ""
fi

if [ "$CONFIGURE_ZFS" = true ]; then
    msg_info "ZFS Optimization:"
    echo "  ✓ File access time updates disabled"
    echo "  ✓ No xattr file created"
    echo "  ✓ support standard linux ACL"
    echo "  ✓ to reduced SSD write operations"
    if [ "$NEEDS_FSTAB_UPDATE" = true ]; then
        echo "  ✓ Traditional filesystems: /etc/fstab (noatime)"
    fi
    if [ "$NEEDS_ZFS_UPDATE" = true ]; then
        echo "  ✓ ZFS pools: atime=off, xattr=sa, acltype=posix"
    fi
    echo ""
fi

if [ "$CONFIGURE_SWAP" = true ]; then
    msg_info "Swap Configuration:"
    echo "  ✓ Swap size: ${SWAP_SIZE}"
    echo "  ✓ Device: /dev/pve/swap"
    echo ""
fi

if [ "$CONFIGURE_SWAPPINESS" = true ]; then
    msg_info "Swappiness Configuration:"
    echo "  ✓ Swappiness value: ${SWAPPINESS_VALUE}"
    echo "  ✓ Configuration: /etc/sysctl.d/99-swappiness.conf"
    echo ""
fi

if [ "$NEEDS_REBOOT" = true ]; then
    msg_warning "IMPORTANT: A reboot is recommended to ensure all changes take effect"
    echo ""
fi

msg_info "Verification Commands:"
if [ "$CONFIGURE_JOURNALD" = true ]; then
    echo "  • Check journal status: journalctl --disk-usage"
    echo "  • View journald config: cat /etc/systemd/journald.conf.d/99-ssd-optimize.conf"
    echo "  • Check journald service: systemctl status systemd-journald"
fi
if [ "$CONFIGURE_ZFS" = true ]; then
    echo "  • Check fstab: cat /etc/fstab"
    echo "  • Check current mounts: mount | grep ' / '"
    if [ "$HAS_ZFS" = true ]; then
        echo "  • Check ZFS atime: zfs get -r atime,xattr,acltype"
    fi
fi
if [ "$CONFIGURE_SWAP" = true ]; then
    echo "  • Check swap: swapon --show"
    echo "  • View memory: free -h"
fi
if [ "$CONFIGURE_SWAPPINESS" = true ]; then
    echo "  • Check swappiness: sysctl vm.swappiness"
    echo "  • View config: cat /etc/sysctl.d/99-swappiness.conf"
fi
echo ""

msg_info "Benefits of These Optimizations:"
echo "  • Reduced SSD wear and tear"
echo "  • Lower I/O operations"
echo "  • Extended SSD lifespan"
echo "  • Optimized memory management"
echo "  • Better system performance"
echo ""

# Prompt for reboot if needed
if [ "$NEEDS_REBOOT" = true ]; then
    read -p "Reboot now? (y/n): " reboot_now
    if [[ "$reboot_now" == "y" ]]; then
        msg_info "Rebooting in 5 seconds... Press Ctrl+C to cancel"
        sleep 5
        reboot
    else
        msg_warning "Remember to reboot manually for changes to take full effect!"
    fi
fi
