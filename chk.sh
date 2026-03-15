#!/usr/bin/env bash

# ==============================================================================
# Lightbits Cluster Deployment - Pre-flight Validation Script
# ==============================================================================

# Console Colors & Symbols
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

CHECK="✅"
CROSS="❌"
WARNING="⚠️"
FIXED="🔧"

# Counters
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
FIX_COUNT=0

# Hardware Specs Variables
NVME_COUNT=0
CORE_COUNT=0
MEM_GB=0
NIC_COUNT=0

# OS Version Variable
OS_MAJOR_VERSION=0

# Error Log File
ERROR_LOG="/var/log/lightbits_preflight_errors.log"

# Initialize the log file
echo "======================================================" > "$ERROR_LOG"
echo " Lightbits Pre-Flight Error Log - $(date)" >> "$ERROR_LOG"
echo "======================================================" >> "$ERROR_LOG"

# Check for --fix argument
FIX_MODE=0
for arg in "$@"; do
    if [[ "$arg" == "--fix" ]]; then
        FIX_MODE=1
    fi
done

echo -e "${BLUE}${BOLD}======================================================${NC}"
echo -e "${BLUE}${BOLD}      Lightbits Pre-Flight Environment Checker        ${NC}"
echo -e "${BLUE}${BOLD}======================================================${NC}\n"

if [[ $FIX_MODE -eq 1 ]]; then
    echo -e "${YELLOW}ℹ️  INFO: '--fix' flag detected. Auto-remediation is enabled.${NC}"
    echo -e "${YELLOW}   The script will attempt to install missing packages...${NC}\n"
fi

# Helper Functions
pass() {
    echo -e " ${GREEN}${CHECK} $1${NC}"
    ((PASS_COUNT++))
}

fail() {
    echo -e " ${RED}${CROSS} $1${NC}"
    echo "$(date '+%H:%M:%S') [FAILED] $1" >> "$ERROR_LOG"
    ((FAIL_COUNT++))
}

warn() {
    echo -e " ${YELLOW}${WARNING} $1${NC}"
    ((WARN_COUNT++))
}

fixed() {
    echo -e " ${GREEN}${FIXED} $1${NC}"
    ((PASS_COUNT++))
    ((FIX_COUNT++))
}

# ------------------------------------------------------------------------------
# 1. Access & Environment Checks
# ------------------------------------------------------------------------------
echo -e "${BOLD}[Access & Environment]${NC}"

if [ "$EUID" -ne 0 ]; then
    fail "Root permissions (Script must be run as root or via passwordless sudo)"
else
    pass "Root permissions verified"
fi

# ------------------------------------------------------------------------------
# 2. Operating System Checks
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Operating System & Packages]${NC}"

if [ -f /etc/os-release ]; then
    source /etc/os-release
    OS_MAJOR_VERSION=$(echo "$VERSION_ID" | cut -d. -f1)
    if [[ "$ID" =~ ^(rhel|almalinux|rocky)$ ]] && [[ "$OS_MAJOR_VERSION" =~ ^(8|9) ]]; then
        pass "Supported OS detected: $PRETTY_NAME"
    else
        fail "Unsupported OS detected: $PRETTY_NAME (Requires RHEL/AlmaLinux/Rocky 8 or 9)"
    fi
else
    fail "Could not determine OS flavor (/etc/os-release missing)"
fi

# Python Version Check
if command -v python3 >/dev/null 2>&1; then
    PY_VER=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
    if awk "BEGIN {exit !($PY_VER >= 3.6)}"; then
        pass "Python version is sufficient (Found v$PY_VER)"
    else
        fail "Python version is too old (Found v$PY_VER, requires 3.6+)"
    fi
else
    if [[ $FIX_MODE -eq 1 ]]; then
        echo -e "    ${YELLOW}Attempting to install python3...${NC}"
        if dnf install -y python3 >/dev/null 2>&1; then
            fixed "Successfully installed Python 3"
        else
            fail "Failed to install Python 3 automatically"
        fi
    else
        fail "Python 3 is not installed"
    fi
fi

# Required Packages Check (Smart OS Detection)
REQUIRED_PKGS=("firewalld" "yum-utils" "net-tools")

# network-scripts is deprecated on OS version 9 and above, only check for it on version 8
if [[ "$OS_MAJOR_VERSION" == "8" ]]; then
    REQUIRED_PKGS+=("network-scripts")
fi

for pkg in "${REQUIRED_PKGS[@]}"; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
        pass "Required package installed: $pkg"
    else
        if [[ $FIX_MODE -eq 1 ]]; then
            echo -e "    ${YELLOW}Attempting to install missing package: $pkg...${NC}"
            if dnf install -y "$pkg" >/dev/null 2>&1; then
                fixed "Successfully installed missing package: $pkg"
            else
                fail "Failed to install package: $pkg"
            fi
        else
            fail "Missing required package: $pkg"
        fi
    fi
done

# Boot Partition Check
if mountpoint -q /boot; then
    BOOT_SPACE=$(df -m /boot | awk 'NR==2 {print $4}')
    if [ "$BOOT_SPACE" -ge 512 ]; then
        pass "Boot partition has sufficient space (${BOOT_SPACE}MB available)"
    else
        fail "Boot partition is running out of space (${BOOT_SPACE}MB available, requires 512MB+)"
    fi
else
    fail "Could not locate /boot mountpoint"
fi

# ------------------------------------------------------------------------------
# 3. Hardware Checks
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Hardware Capabilities]${NC}"

# NUMA Check
if command -v lscpu >/dev/null 2>&1; then
    NUMA_NODES=$(lscpu | grep -i "NUMA node(s):" | awk '{print $3}')
    if [[ -n "$NUMA_NODES" ]] && [[ "$NUMA_NODES" -ge 1 ]]; then
        pass "NUMA architecture is enabled in BIOS"
    else
        fail "NUMA architecture appears to be disabled in BIOS"
    fi
else
    fail "Unable to check NUMA status (lscpu missing)"
fi

# NVMe Drive Count Check
if command -v lsblk >/dev/null 2>&1; then
    NVME_COUNT=$(lsblk -d -n -o NAME 2>/dev/null | grep '^nvme' | wc -l)
    if [ "$NVME_COUNT" -ge 3 ]; then
        pass "Found $NVME_COUNT NVMe device(s) attached"
    else
        warn "Found only $NVME_COUNT NVMe device(s). A minimum of 3 is recommended for a standard Lightbits node."
    fi
else
    warn "Unable to count NVMe devices (lsblk utility missing)"
fi

# ------------------------------------------------------------------------------
# 4. Network & Ports Checks
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}[Network & Ports]${NC}"

# Internal / Data Ports Check (Ensuring they are not bound by something else)
LIGHTBITS_PORTS=(2379 2380 4001 4007 4420 4421 8009 8090 22226 22227)

if command -v ss >/dev/null 2>&1; then
    for port in "${LIGHTBITS_PORTS[@]}"; do
        if ss -tuln | grep -q ":$port "; then
            fail "Port $port is currently in use by another process"
        else
            pass "Port $port is free and available for Lightbits"
        fi
    done
else
    fail "Unable to verify ports (ss utility from net-tools/iproute2 missing)"
fi

# ------------------------------------------------------------------------------
# 5. Gather System Specifications
# ------------------------------------------------------------------------------
# Cores
if command -v nproc >/dev/null 2>&1; then
    CORE_COUNT=$(nproc)
fi

# Memory (GB)
if [ -f /proc/meminfo ]; then
    MEM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
fi

# Physical NICs (Ignoring virtual interfaces like lo, tun, veth, etc.)
if [ -d /sys/class/net ]; then
    NIC_COUNT=$(ls -l /sys/class/net/ | grep -v virtual | grep -E '^d|l' | wc -l)
fi

# ------------------------------------------------------------------------------
# Report Generation
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}${BOLD}======================================================${NC}"
echo -e "${BLUE}${BOLD}                 Validation Summary                   ${NC}"
echo -e "${BLUE}${BOLD}======================================================${NC}"

echo -e " ${GREEN}Passed Checks:   ${BOLD}$PASS_COUNT${NC}"
if [[ $WARN_COUNT -gt 0 ]]; then
    echo -e " ${YELLOW}Warnings:        ${BOLD}$WARN_COUNT${NC}"
fi
if [[ $FIX_COUNT -gt 0 ]]; then
    echo -e " ${GREEN}Auto-Fixed:      ${BOLD}$FIX_COUNT${NC}"
fi
echo -e " ${RED}Failed Checks:   ${BOLD}$FAIL_COUNT${NC}"

echo -e "\n${BLUE}${BOLD}======================================================${NC}"
echo -e "${BLUE}${BOLD}               System Specifications                  ${NC}"
echo -e "${BLUE}${BOLD}======================================================${NC}"
echo -e " OS Version:      ${BOLD}v${OS_MAJOR_VERSION}${NC}"
echo -e " CPU Cores:       ${BOLD}${CORE_COUNT}${NC}"
echo -e " Total Memory:    ${BOLD}${MEM_GB} GB${NC}"
echo -e " Physical NICs:   ${BOLD}${NIC_COUNT}${NC}"
echo -e " NVMe Devices:    ${BOLD}${NVME_COUNT}${NC}"
echo ""

if [[ $FAIL_COUNT -eq 0 && $WARN_COUNT -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}Excellent! 🎉 Your server meets all the prerequisites and is fully ready for a Flawless Lightbits Installation!${NC}"
    rm -f "$ERROR_LOG" # Clean up the log file if everything passes cleanly
elif [[ $FAIL_COUNT -eq 0 && $WARN_COUNT -gt 0 ]]; then
    echo -e "${YELLOW}${BOLD}Good to go, but review the warnings above! ⚠️${NC}"
    echo -e "Your server meets the strict requirements, but you may have a sub-optimal hardware configuration (e.g., fewer than 3 NVMe drives)."
    rm -f "$ERROR_LOG"
else
    echo -e "${RED}${BOLD}Oh no! It looks like a few checks didn't pass. But don't worry, we've got you covered! 🛠️${NC}"
    echo -e "A detailed error log has been saved to: ${BOLD}$ERROR_LOG${NC}\n"
    if [[ $FIX_MODE -eq 0 ]]; then
        echo -e "You can automatically resolve the missing packages by running this script again with the '--fix' flag:\n"
        echo -e "${BOLD}  curl -sL https://github.com/your-repo/check.sh | sudo bash -s -- --fix${NC}\n"
    else
        echo -e "We attempted to fix the missing dependencies, but some issues (like hardware or OS partitions) require manual intervention."
    fi
fi

echo -e "${BLUE}${BOLD}======================================================${NC}\n"
