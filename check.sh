#!/usr/bin/env bash

# ==============================================================================
# Lightbits Cluster Deployment - Pre-flight Validation Script!
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

# Counters
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

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
    echo -e "${YELLOW}ℹ️  INFO: '--fix' flag detected. Auto-remediation is not yet implemented.${NC}"
    echo -e "${YELLOW}   Running in assessment mode only...${NC}\n"
fi

# Helper Functions
pass() {
    echo -e " ${GREEN}${CHECK} $1${NC}"
    ((PASS_COUNT++))
}

fail() {
    echo -e " ${RED}${CROSS} $1${NC}"
    ((FAIL_COUNT++))
}

warn() {
    echo -e " ${YELLOW}${WARNING} $1${NC}"
    ((WARN_COUNT++))
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
    if [[ "$ID" =~ ^(rhel|almalinux|rocky)$ ]] && [[ "$VERSION_ID" =~ ^(8|9) ]]; then
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
    fail "Python 3 is not installed"
fi

# Required Packages Check
REQUIRED_PKGS=("firewalld" "network-scripts" "yum-utils" "net-tools")
for pkg in "${REQUIRED_PKGS[@]}"; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
        pass "Required package installed: $pkg"
    else
        fail "Missing required package: $pkg"
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

# Memory (RAM) Check
MIN_RAM_GB=64 # Replace 64 with your actual minimum requirement
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))

if [ "$TOTAL_RAM_GB" -ge "$MIN_RAM_GB" ]; then
    pass "Sufficient RAM detected (${TOTAL_RAM_GB}GB available)"
else
    fail "Insufficient RAM detected (${TOTAL_RAM_GB}GB available, requires ${MIN_RAM_GB}GB+)"
fi

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
    if [ "$NVME_COUNT" -ge 8 ]; then
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
# Report Generation
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}${BOLD}======================================================${NC}"
echo -e "${BLUE}${BOLD}                 Validation Summary                   ${NC}"
echo -e "${BLUE}${BOLD}======================================================${NC}"

echo -e " ${GREEN}Passed Checks:   ${BOLD}$PASS_COUNT${NC}"
if [[ $WARN_COUNT -gt 0 ]]; then
    echo -e " ${YELLOW}Warnings:        ${BOLD}$WARN_COUNT${NC}"
fi
echo -e " ${RED}Failed Checks:   ${BOLD}$FAIL_COUNT${NC}"
echo ""

if [[ $FAIL_COUNT -eq 0 && $WARN_COUNT -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}Excellent! 🎉 Your server meets all the prerequisites and is fully ready for a Flawless Lightbits Installation!${NC}"
elif [[ $FAIL_COUNT -eq 0 && $WARN_COUNT -gt 0 ]]; then
    echo -e "${YELLOW}${BOLD}Good to go, but review the warnings above! ⚠️${NC}"
    echo -e "Your server meets the strict requirements, but you may have a sub-optimal hardware configuration (e.g., fewer than 3 NVMe drives)."
else
    echo -e "${RED}${BOLD}Oh no! It looks like a few checks didn't pass. But don't worry, we've got you covered! 🛠️${NC}"
    echo -e "You can automatically resolve the missing packages and OS configurations by running this script again with the '--fix' flag:\n"
    
    echo -e "${BOLD}  curl -sL https://github.com/your-repo/check.sh | sudo bash -s -- --fix${NC}\n"
    
    echo -e "Once the environment is fixed, you will be ready to deploy your Lightbits cluster!"
fi

echo -e "${BLUE}${BOLD}======================================================${NC}"


