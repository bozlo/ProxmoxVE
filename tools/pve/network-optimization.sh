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
    _   __     __                      __      ____        __  _           _            __  _          
   / | / /__  / /__      ______  _____/ /__   / __ \____  / /_(_)___ ___  (_)___  ___  / /_(_)___  ___ 
  /  |/ / _ \/ __/ | /| / / __ \/ ___/ //_/  / / / / __ \/ __/ / __ `__ \/ /_  / / _ \/ __/ / __ \/ _ \
 / /|  /  __/ /_ | |/ |/ / /_/ / /  / ,<    / /_/ / /_/ / /_/ / / / / / / / / /_/  __/ /_/ / /_/ /  __/
/_/ |_/\___/\__/ |__/|__/\____/_/  /_/|_|   \____/ .___/\__/_/_/ /_/ /_/_/ /___/\___/\__/_/\____/\___/ 
                                                 /_/                                                     
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
CONFIGURE_NETWORK=false
CONFIGURE_DIRTY_CACHE=false
NEEDS_REBOOT=false

# Main menu
while true; do
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${CYAN}Network & Storage Optimization Menu${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo " 1) Configure Network Optimization (BBR + Conntrack)"
    echo " 2) Configure SSD Write Cache (Dirty Pages)"
    echo " 3) Apply All Optimizations"
    echo " 4) View Current Status"
    echo " 5) Exit"
    echo ""
    read -p "Select option [1-5]: " main_option

    case $main_option in
        1)
            CONFIGURE_NETWORK=true
            break
            ;;
        2)
            CONFIGURE_DIRTY_CACHE=true
            break
            ;;
        3)
            CONFIGURE_NETWORK=true
            CONFIGURE_DIRTY_CACHE=true
            break
            ;;
        4)
            echo ""
            msg_section "Current System Status"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            msg_info "Network Configuration:"
            if [ -f /etc/sysctl.d/99-network-optimize.conf ]; then
                cat /etc/sysctl.d/99-network-optimize.conf
            else
                echo "  Not configured (using system defaults)"
            fi
            echo ""
            msg_info "Current Network Settings:"
            sysctl net.core.default_qdisc 2>/dev/null || echo "  default_qdisc: not set"
            sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo "  tcp_congestion_control: not set"
            sysctl net.netfilter.nf_conntrack_max 2>/dev/null || echo "  nf_conntrack_max: not set"
            sysctl net.netfilter.nf_conntrack_buckets 2>/dev/null || echo "  nf_conntrack_buckets: not set"
            echo ""
            msg_info "Dirty Pages Configuration:"
            if [ -f /etc/sysctl.d/99-dirty-optimize.conf ]; then
                cat /etc/sysctl.d/99-dirty-optimize.conf
            else
                echo "  Not configured (using system defaults)"
            fi
            echo ""
            msg_info "Current Dirty Pages Settings:"
            sysctl vm.dirty_background_bytes 2>/dev/null || echo "  dirty_background_bytes: not set"
            sysctl vm.dirty_bytes 2>/dev/null || echo "  dirty_bytes: not set"
            sysctl vm.dirty_background_ratio 2>/dev/null || echo "  dirty_background_ratio: not set"
            sysctl vm.dirty_ratio 2>/dev/null || echo "  dirty_ratio: not set"
            sysctl vm.dirty_expire_centisecs 2>/dev/null || echo "  dirty_expire_centisecs: not set"
            sysctl vm.dirty_writeback_centisecs 2>/dev/null || echo "  dirty_writeback_centisecs: not set"
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
# SECTION 1: Configure Network Optimization
################################################################################
if [ "$CONFIGURE_NETWORK" = true ]; then
    echo ""
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    msg_section "SECTION 1: Network Optimization (10 users, 10 apps)"
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    msg_info "What is network optimization?"
    echo "  This configuration improves network performance by:"
    echo "  • BBR congestion control: Modern TCP algorithm for better throughput"
    echo "  • FQ queueing discipline: Fair Queue for better packet scheduling"
    echo "  • Conntrack optimization: 256K max connections (for 10 users/10 apps)"
    echo "  • Conntrack buckets: 65K buckets (max/4) for hash table efficiency"
    echo ""
    msg_warning "Note: These settings are optimized for 10 users and 10 applications"
    echo ""

    # Show current network settings
    msg_info "Current network settings:"
    sysctl net.core.default_qdisc 2>/dev/null || echo "  default_qdisc: not set"
    sysctl net.ipv4.tcp_congestion_control 2>/dev/null || echo "  tcp_congestion_control: not set"
    sysctl net.netfilter.nf_conntrack_max 2>/dev/null || echo "  nf_conntrack_max: not set"
    sysctl net.netfilter.nf_conntrack_buckets 2>/dev/null || echo "  nf_conntrack_buckets: not set"
    echo ""

    # Prompt for confirmation
    read -p "Apply network optimization? (y/n): " confirm_network

    if [[ "$confirm_network" == "y" ]]; then
        # Backup existing configuration if it exists
        NETWORK_CONF="/etc/sysctl.d/99-network-optimize.conf"
        if [ -f "$NETWORK_CONF" ]; then
            BACKUP_FILE="${NETWORK_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$NETWORK_CONF" "$BACKUP_FILE"
            msg_ok "Backup created: $BACKUP_FILE"
        fi

        # Write network configuration
        msg_info "Writing network optimization configuration"
        cat > "$NETWORK_CONF" << 'EOF'
# Network Optimization for Proxmox VE
# Optimized for 10 users and 10 applications

# BBR TCP congestion control (modern algorithm for better throughput)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Connection tracking optimization (256K connections for 10 users/10 apps)
net.netfilter.nf_conntrack_max = 262144      # 256K max connections
net.netfilter.nf_conntrack_buckets = 65536   # max / 4 for efficient hash table
EOF

        msg_ok "Configuration written to $NETWORK_CONF"

        # Display configuration
        echo ""
        msg_info "Configuration contents:"
        cat "$NETWORK_CONF"
        echo ""

        # Apply configuration
        msg_info "Applying network optimization configuration"
        if sysctl -p "$NETWORK_CONF"; then
            msg_ok "Network optimization applied successfully"
        else
            msg_error "Failed to apply network optimization"
            exit 1
        fi

        # Verify new settings
        echo ""
        msg_info "New network settings:"
        sysctl net.core.default_qdisc
        sysctl net.ipv4.tcp_congestion_control
        sysctl net.netfilter.nf_conntrack_max
        sysctl net.netfilter.nf_conntrack_buckets
        echo ""

        msg_ok "Network optimization complete"
    else
        msg_info "Network configuration cancelled"
        CONFIGURE_NETWORK=false
    fi
fi

################################################################################
# SECTION 2: Configure SSD Write Cache (Dirty Pages)
################################################################################
if [ "$CONFIGURE_DIRTY_CACHE" = true ]; then
    echo ""
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    msg_section "SECTION 2: SSD Write Cache Optimization (384GB RAM)"
    msg_section "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    msg_info "What is dirty pages optimization?"
    echo "  This configuration improves SSD write performance by:"
    echo "  • dirty_background_bytes: Start background flush at 256MB"
    echo "  • dirty_bytes: Force flush at 1GB (high-performance write cache)"
    echo "  • dirty_expire_centisecs: Flush data older than 10 seconds"
    echo "  • dirty_writeback_centisecs: Check for dirty data every 1 second"
    echo ""
    msg_warning "Note: Optimized for systems with 384GB RAM and SSD storage"
    echo ""

    # Show current dirty pages settings
    msg_info "Current dirty pages settings:"
    sysctl vm.dirty_background_bytes
    sysctl vm.dirty_bytes
    sysctl vm.dirty_background_ratio
    sysctl vm.dirty_ratio
    sysctl vm.dirty_expire_centisecs
    sysctl vm.dirty_writeback_centisecs
    echo ""

    # Prompt for confirmation
    read -p "Apply dirty pages optimization? (y/n): " confirm_dirty

    if [[ "$confirm_dirty" == "y" ]]; then
        # Backup existing configuration if it exists
        DIRTY_CONF="/etc/sysctl.d/99-dirty-optimize.conf"
        if [ -f "$DIRTY_CONF" ]; then
            BACKUP_FILE="${DIRTY_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$DIRTY_CONF" "$BACKUP_FILE"
            msg_ok "Backup created: $BACKUP_FILE"
        fi

        # Write dirty pages configuration
        msg_info "Writing dirty pages optimization configuration"
        cat > "$DIRTY_CONF" << 'EOF'
# SSD High-Performance Write Caching (384GB RAM)
# Optimizes write performance with aggressive caching

vm.dirty_background_bytes = 268435456        # 256MB - Start background flush
vm.dirty_bytes = 1073741824                  # 1GB - Force flush threshold
vm.dirty_background_ratio = 0                # Disable ratio (use bytes instead)
vm.dirty_ratio = 0                           # Disable ratio (use bytes instead)
vm.dirty_expire_centisecs = 1000             # 10 seconds - Flush old data
vm.dirty_writeback_centisecs = 100           # 1 second - Check interval
EOF

        msg_ok "Configuration written to $DIRTY_CONF"

        # Display configuration
        echo ""
        msg_info "Configuration contents:"
        cat "$DIRTY_CONF"
        echo ""

        # Apply configuration
        msg_info "Applying dirty pages optimization configuration"
        if sysctl -p "$DIRTY_CONF"; then
            msg_ok "Dirty pages optimization applied successfully"
        else
            msg_error "Failed to apply dirty pages optimization"
            exit 1
        fi

        # Verify new settings
        echo ""
        msg_info "New dirty pages settings:"
        sysctl vm.dirty_background_bytes
        sysctl vm.dirty_bytes
        sysctl vm.dirty_background_ratio
        sysctl vm.dirty_ratio
        sysctl vm.dirty_expire_centisecs
        sysctl vm.dirty_writeback_centisecs
        echo ""

        msg_ok "Dirty pages optimization complete"
    else
        msg_info "Dirty pages configuration cancelled"
        CONFIGURE_DIRTY_CACHE=false
    fi
fi

################################################################################
# FINAL SUMMARY
################################################################################
echo ""
msg_ok "═══════════════════════════════════════════════════════════"
msg_ok " ✓ Network & Storage Optimization Complete ✓"
msg_ok "═══════════════════════════════════════════════════════════"
echo ""

if [ "$CONFIGURE_NETWORK" = true ]; then
    msg_info "Network Optimization:"
    echo "  ✓ BBR TCP congestion control enabled"
    echo "  ✓ Fair Queue (fq) queueing discipline"
    echo "  ✓ Connection tracking: 256K max connections"
    echo "  ✓ Connection tracking buckets: 65K"
    echo "  ✓ Configuration: /etc/sysctl.d/99-network-optimize.conf"
    echo ""
fi

if [ "$CONFIGURE_DIRTY_CACHE" = true ]; then
    msg_info "SSD Write Cache Optimization:"
    echo "  ✓ Background flush starts at 256MB"
    echo "  ✓ Force flush at 1GB"
    echo "  ✓ Flush old data after 10 seconds"
    echo "  ✓ Check for dirty data every 1 second"
    echo "  ✓ Configuration: /etc/sysctl.d/99-dirty-optimize.conf"
    echo ""
fi

msg_info "Verification Commands:"
if [ "$CONFIGURE_NETWORK" = true ]; then
    echo "  • Check network settings: sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control"
    echo "  • View network config: cat /etc/sysctl.d/99-network-optimize.conf"
    echo "  • Check conntrack: cat /proc/sys/net/netfilter/nf_conntrack_max"
fi
if [ "$CONFIGURE_DIRTY_CACHE" = true ]; then
    echo "  • Check dirty pages: sysctl vm.dirty_background_bytes vm.dirty_bytes"
    echo "  • View dirty config: cat /etc/sysctl.d/99-dirty-optimize.conf"
fi
echo ""

msg_info "Benefits of These Optimizations:"
echo "  • Improved network throughput and latency"
echo "  • Better handling of concurrent connections"
echo "  • Optimized SSD write performance"
echo "  • Reduced write latency with smart caching"
echo "  • Configured for 10 users and 10 applications"
echo ""

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
