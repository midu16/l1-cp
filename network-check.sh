#!/bin/bash

# ============================================
# Enhanced Network Connection Checker Script
# ============================================
# Usage: ./network-check.sh <FQDN> [output_dir]
#
# Features:
# - DNS resolution (forward/reverse, multiple servers)
# - IP/MAC/ARP resolution
# - ICMP connectivity
# - TCP/UDP port connectivity with tcpdump captures
# - SSL/TLS certificate validation
# - HTTP/HTTPS response checks
# - MTU path discovery
# - Multiple traceroute methods
# - Network interface and routing info
# - Firewall rules check
#
# Requirements: Run with sudo for full functionality
# ============================================

# Don't exit on error - we handle errors manually
set +e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Check if FQDN is provided
if [ -z "$1" ]; then
    echo -e "${RED}Error: No FQDN provided${NC}"
    echo "Usage: $0 <FQDN> [output_directory]"
    echo ""
    echo "Examples:"
    echo "  $0 google.com"
    echo "  $0 api.example.com /tmp/network-captures"
    echo "  sudo $0 api.example.com  # For full tcpdump and traceroute functionality"
    exit 1
fi

FQDN="$1"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${2:-/tmp/network-check-${FQDN}-${TIMESTAMP}}"
PORTS=(22 80 443 8080 8443 6443 9090 5000)
TIMEOUT_SEC=5

# Create output directory
mkdir -p "$OUTPUT_DIR"
SUMMARY_FILE="$OUTPUT_DIR/summary.txt"
TCPDUMP_DIR="$OUTPUT_DIR/tcpdump"
mkdir -p "$TCPDUMP_DIR"

# Check if running as root
IS_ROOT=false
if [ "$EUID" -eq 0 ]; then
    IS_ROOT=true
fi

# ============================================
# Helper Functions
# ============================================

print_header() {
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo "============================================" >> "$SUMMARY_FILE"
    echo "  $1" >> "$SUMMARY_FILE"
    echo "============================================" >> "$SUMMARY_FILE"
}

print_subheader() {
    echo -e "${CYAN}--------------------------------------------${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}--------------------------------------------${NC}"
    echo "--------------------------------------------" >> "$SUMMARY_FILE"
    echo "  $1" >> "$SUMMARY_FILE"
    echo "--------------------------------------------" >> "$SUMMARY_FILE"
}

print_status() {
    local label="$1"
    local status="$2"
    local details="$3"
    
    if [ "$status" == "OK" ] || [ "$status" == "OPEN" ]; then
        echo -e "  $label: ${GREEN}$status${NC} $details"
        echo "  $label: $status $details" >> "$SUMMARY_FILE"
    elif [ "$status" == "FAIL" ] || [ "$status" == "CLOSED" ]; then
        echo -e "  $label: ${RED}$status${NC} $details"
        echo "  $label: $status $details" >> "$SUMMARY_FILE"
    else
        echo -e "  $label: ${YELLOW}$status${NC} $details"
        echo "  $label: $status $details" >> "$SUMMARY_FILE"
    fi
}

log_info() {
    echo -e "  ${YELLOW}$1${NC}"
    echo "  $1" >> "$SUMMARY_FILE"
}

log_detail() {
    echo -e "    $1"
    echo "    $1" >> "$SUMMARY_FILE"
}

# Function to start tcpdump for a specific port
start_tcpdump() {
    local port="$1"
    local protocol="$2"
    local capture_file="$TCPDUMP_DIR/${protocol}_port_${port}_${FQDN}.pcap"
    
    if $IS_ROOT && command -v tcpdump &> /dev/null; then
        # Capture traffic to/from the target IP on the specific port
        tcpdump -i any -w "$capture_file" "host $IP_ADDR and port $port" -c 100 2>/dev/null &
        TCPDUMP_PID=$!
        sleep 0.5  # Give tcpdump time to start
        echo "$TCPDUMP_PID"
    else
        echo ""
    fi
}

# Function to stop tcpdump
stop_tcpdump() {
    local pid="$1"
    local capture_file="$2"
    
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        sleep 1  # Allow capture of response packets
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        
        if [ -f "$capture_file" ] && [ -s "$capture_file" ]; then
            log_detail "Capture saved: $capture_file"
        fi
    fi
}

# ============================================
# OS Detection and Package Manager Functions
# ============================================

detect_os() {
    OS_ID=""
    OS_ID_LIKE=""
    PKG_MANAGER=""
    PKG_INSTALL_CMD=""
    
    # Try to read os-release
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_ID_LIKE="${ID_LIKE:-}"
        OS_VERSION="${VERSION_ID:-}"
        OS_NAME="${PRETTY_NAME:-$OS_ID}"
    elif [ -f /etc/redhat-release ]; then
        OS_ID="rhel"
        OS_NAME=$(cat /etc/redhat-release)
    elif [ -f /etc/debian_version ]; then
        OS_ID="debian"
        OS_NAME="Debian $(cat /etc/debian_version)"
    else
        OS_ID="unknown"
        OS_NAME="Unknown OS"
    fi
    
    # Detect package manager
    if command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        PKG_INSTALL_CMD="sudo dnf install -y"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        PKG_INSTALL_CMD="sudo yum install -y"
    elif command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
        PKG_INSTALL_CMD="sudo apt-get install -y"
    elif command -v apt &> /dev/null; then
        PKG_MANAGER="apt"
        PKG_INSTALL_CMD="sudo apt install -y"
    elif command -v zypper &> /dev/null; then
        PKG_MANAGER="zypper"
        PKG_INSTALL_CMD="sudo zypper install -y"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
        PKG_INSTALL_CMD="sudo pacman -S --noconfirm"
    elif command -v apk &> /dev/null; then
        PKG_MANAGER="apk"
        PKG_INSTALL_CMD="sudo apk add"
    elif command -v brew &> /dev/null; then
        PKG_MANAGER="brew"
        PKG_INSTALL_CMD="brew install"
    else
        PKG_MANAGER="unknown"
        PKG_INSTALL_CMD=""
    fi
}

# Get package name for a tool based on OS/package manager
get_package_name() {
    local tool="$1"
    local pkg=""
    
    # Package mappings: tool -> package name per package manager
    # Format: dnf/yum | apt | zypper | pacman | apk | brew
    
    case "$tool" in
        dig)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="bind-utils" ;;
                apt) pkg="dnsutils" ;;
                zypper) pkg="bind-utils" ;;
                pacman) pkg="bind" ;;
                apk) pkg="bind-tools" ;;
                brew) pkg="bind" ;;
            esac
            ;;
        host)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="bind-utils" ;;
                apt) pkg="bind9-host" ;;
                zypper) pkg="bind-utils" ;;
                pacman) pkg="bind" ;;
                apk) pkg="bind-tools" ;;
                brew) pkg="bind" ;;
            esac
            ;;
        nslookup)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="bind-utils" ;;
                apt) pkg="dnsutils" ;;
                zypper) pkg="bind-utils" ;;
                pacman) pkg="bind" ;;
                apk) pkg="bind-tools" ;;
                brew) pkg="bind" ;;
            esac
            ;;
        ping)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="iputils" ;;
                apt) pkg="iputils-ping" ;;
                zypper) pkg="iputils" ;;
                pacman) pkg="iputils" ;;
                apk) pkg="iputils" ;;
                brew) pkg="" ;; # Usually pre-installed on macOS
            esac
            ;;
        nc|netcat)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="nmap-ncat" ;;
                apt) pkg="netcat-openbsd" ;;
                zypper) pkg="netcat-openbsd" ;;
                pacman) pkg="gnu-netcat" ;;
                apk) pkg="netcat-openbsd" ;;
                brew) pkg="netcat" ;;
            esac
            ;;
        nmap)
            pkg="nmap"  # Same on all distros
            ;;
        curl)
            pkg="curl"  # Same on all distros
            ;;
        wget)
            pkg="wget"  # Same on all distros
            ;;
        openssl)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="openssl" ;;
                apt) pkg="openssl" ;;
                zypper) pkg="openssl" ;;
                pacman) pkg="openssl" ;;
                apk) pkg="openssl" ;;
                brew) pkg="openssl" ;;
            esac
            ;;
        traceroute)
            pkg="traceroute"  # Same on most distros
            ;;
        tracepath)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="iputils" ;;
                apt) pkg="iputils-tracepath" ;;
                zypper) pkg="iputils" ;;
                pacman) pkg="iputils" ;;
                apk) pkg="iputils" ;;
                brew) pkg="" ;;
            esac
            ;;
        mtr)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="mtr" ;;
                apt) pkg="mtr-tiny" ;;
                zypper) pkg="mtr" ;;
                pacman) pkg="mtr" ;;
                apk) pkg="mtr" ;;
                brew) pkg="mtr" ;;
            esac
            ;;
        tcpdump)
            pkg="tcpdump"  # Same on all distros
            ;;
        ss)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="iproute" ;;
                apt) pkg="iproute2" ;;
                zypper) pkg="iproute2" ;;
                pacman) pkg="iproute2" ;;
                apk) pkg="iproute2" ;;
                brew) pkg="" ;;
            esac
            ;;
        ip)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="iproute" ;;
                apt) pkg="iproute2" ;;
                zypper) pkg="iproute2" ;;
                pacman) pkg="iproute2" ;;
                apk) pkg="iproute2" ;;
                brew) pkg="" ;;
            esac
            ;;
        arp)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="net-tools" ;;
                apt) pkg="net-tools" ;;
                zypper) pkg="net-tools" ;;
                pacman) pkg="net-tools" ;;
                apk) pkg="net-tools" ;;
                brew) pkg="" ;;
            esac
            ;;
        ethtool)
            pkg="ethtool"  # Same on all distros
            ;;
        iptables)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="iptables" ;;
                apt) pkg="iptables" ;;
                zypper) pkg="iptables" ;;
                pacman) pkg="iptables" ;;
                apk) pkg="iptables" ;;
                brew) pkg="" ;;
            esac
            ;;
        nft)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="nftables" ;;
                apt) pkg="nftables" ;;
                zypper) pkg="nftables" ;;
                pacman) pkg="nftables" ;;
                apk) pkg="nftables" ;;
                brew) pkg="" ;;
            esac
            ;;
        whois)
            pkg="whois"  # Same on most distros
            ;;
        tcptraceroute)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="tcptraceroute" ;;
                apt) pkg="tcptraceroute" ;;
                zypper) pkg="tcptraceroute" ;;
                pacman) pkg="tcptraceroute" ;;
                apk) pkg="tcptraceroute" ;;
                brew) pkg="tcptraceroute" ;;
            esac
            ;;
        socat)
            pkg="socat"  # Same on all distros
            ;;
        telnet)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="telnet" ;;
                apt) pkg="telnet" ;;
                zypper) pkg="telnet" ;;
                pacman) pkg="inetutils" ;;
                apk) pkg="busybox-extras" ;;
                brew) pkg="telnet" ;;
            esac
            ;;
        netstat)
            case "$PKG_MANAGER" in
                dnf|yum) pkg="net-tools" ;;
                apt) pkg="net-tools" ;;
                zypper) pkg="net-tools" ;;
                pacman) pkg="net-tools" ;;
                apk) pkg="net-tools" ;;
                brew) pkg="" ;;
            esac
            ;;
        *)
            pkg="$tool"  # Default: use tool name as package name
            ;;
    esac
    
    echo "$pkg"
}

# Check for required tools with installation suggestions
check_tools() {
    print_subheader "Operating System Detection"
    
    detect_os
    
    log_info "OS: $OS_NAME"
    log_info "OS ID: $OS_ID"
    [ -n "$OS_ID_LIKE" ] && log_info "OS Family: $OS_ID_LIKE"
    log_info "Package Manager: $PKG_MANAGER"
    echo ""
    
    print_subheader "Available Tools Check"
    
    # Define all tools to check
    local tools=("dig" "host" "nslookup" "ping" "nc" "nmap" "curl" "wget" "openssl" 
                 "traceroute" "tracepath" "mtr" "tcpdump" "ss" "ip" "arp" "ethtool"
                 "iptables" "nft" "whois" "tcptraceroute" "socat" "telnet" "netstat")
    
    # Arrays to collect missing tools
    declare -a MISSING_TOOLS
    declare -a MISSING_PACKAGES
    declare -A PACKAGE_TO_TOOLS  # Map package -> tools it provides
    
    for tool in "${tools[@]}"; do
        if command -v "$tool" &> /dev/null; then
            print_status "$tool" "OK" "($(which $tool))"
        else
            print_status "$tool" "MISSING" ""
            MISSING_TOOLS+=("$tool")
            pkg=$(get_package_name "$tool")
            if [ -n "$pkg" ]; then
                # Add to package list if not already there
                if [[ ! " ${MISSING_PACKAGES[*]} " =~ " ${pkg} " ]]; then
                    MISSING_PACKAGES+=("$pkg")
                fi
                # Track which tools each package provides
                if [ -n "${PACKAGE_TO_TOOLS[$pkg]}" ]; then
                    PACKAGE_TO_TOOLS[$pkg]="${PACKAGE_TO_TOOLS[$pkg]}, $tool"
                else
                    PACKAGE_TO_TOOLS[$pkg]="$tool"
                fi
            fi
        fi
    done
    echo ""
    
    # If there are missing tools, show installation commands
    if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
        print_subheader "Missing Tools Installation"
        
        echo -e "  ${YELLOW}Missing ${#MISSING_TOOLS[@]} tools: ${MISSING_TOOLS[*]}${NC}"
        echo ""
        
        if [ -n "$PKG_INSTALL_CMD" ]; then
            # Show package-to-tool mapping
            echo -e "  ${CYAN}Packages to install:${NC}"
            for pkg in "${MISSING_PACKAGES[@]}"; do
                echo -e "    ${GREEN}$pkg${NC} -> provides: ${PACKAGE_TO_TOOLS[$pkg]}"
            done
            echo ""
            
            # Show single install command
            echo -e "  ${CYAN}Install all missing tools with:${NC}"
            echo -e "  ${GREEN}${PKG_INSTALL_CMD} ${MISSING_PACKAGES[*]}${NC}"
            echo ""
            
            # Store install command for later use
            INSTALL_CMD="${PKG_INSTALL_CMD} ${MISSING_PACKAGES[*]}"
            
            # Offer to install if running as root
            if $IS_ROOT; then
                echo -e "  ${YELLOW}Would you like to install missing tools now? [y/N]${NC}"
                read -t 10 -n 1 REPLY || REPLY="n"
                echo ""
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    echo -e "  ${CYAN}Installing packages...${NC}"
                    if eval "$INSTALL_CMD"; then
                        echo -e "  ${GREEN}Installation completed successfully!${NC}"
                        echo ""
                        # Re-check tools after installation
                        echo -e "  ${CYAN}Re-checking tools...${NC}"
                        for tool in "${MISSING_TOOLS[@]}"; do
                            if command -v "$tool" &> /dev/null; then
                                print_status "$tool" "OK" "(installed)"
                            else
                                print_status "$tool" "STILL MISSING" ""
                            fi
                        done
                    else
                        echo -e "  ${RED}Installation failed. Please install manually.${NC}"
                    fi
                else
                    echo -e "  ${YELLOW}Skipping installation. Continuing with available tools...${NC}"
                fi
            else
                echo -e "  ${YELLOW}TIP: Run this script with sudo to auto-install missing tools${NC}"
            fi
        else
            # Unknown package manager - show commands for all known managers
            echo -e "  ${YELLOW}Could not detect package manager. Here are commands for common distros:${NC}"
            echo ""
            
            # Build package lists for each distro
            echo -e "  ${CYAN}Fedora/RHEL/CentOS (dnf):${NC}"
            echo -e "    sudo dnf install -y bind-utils iputils nmap-ncat nmap curl wget openssl \\"
            echo -e "      traceroute mtr tcpdump iproute net-tools ethtool iptables nftables whois \\"
            echo -e "      tcptraceroute socat telnet"
            echo ""
            
            echo -e "  ${CYAN}Debian/Ubuntu (apt):${NC}"
            echo -e "    sudo apt-get install -y dnsutils iputils-ping netcat-openbsd nmap curl wget \\"
            echo -e "      openssl traceroute iputils-tracepath mtr-tiny tcpdump iproute2 net-tools \\"
            echo -e "      ethtool iptables nftables whois tcptraceroute socat telnet"
            echo ""
            
            echo -e "  ${CYAN}openSUSE (zypper):${NC}"
            echo -e "    sudo zypper install -y bind-utils iputils netcat-openbsd nmap curl wget \\"
            echo -e "      openssl traceroute mtr tcpdump iproute2 net-tools ethtool iptables nftables whois"
            echo ""
            
            echo -e "  ${CYAN}Arch Linux (pacman):${NC}"
            echo -e "    sudo pacman -S --noconfirm bind iputils gnu-netcat nmap curl wget openssl \\"
            echo -e "      traceroute mtr tcpdump iproute2 net-tools ethtool iptables nftables whois"
            echo ""
            
            echo -e "  ${CYAN}Alpine Linux (apk):${NC}"
            echo -e "    sudo apk add bind-tools iputils netcat-openbsd nmap curl wget openssl \\"
            echo -e "      traceroute mtr tcpdump iproute2 net-tools ethtool iptables nftables whois"
            echo ""
            
            echo -e "  ${CYAN}macOS (brew):${NC}"
            echo -e "    brew install bind nmap curl wget openssl traceroute mtr tcpdump whois netcat"
            echo ""
        fi
        echo ""
    else
        echo -e "  ${GREEN}All tools are available!${NC}"
        echo ""
    fi
    
    # Save tool check results to file
    {
        echo "Tool Check Results"
        echo "=================="
        echo "OS: $OS_NAME"
        echo "Package Manager: $PKG_MANAGER"
        echo ""
        echo "Missing tools: ${MISSING_TOOLS[*]:-None}"
        echo "Missing packages: ${MISSING_PACKAGES[*]:-None}"
        [ -n "$INSTALL_CMD" ] && echo "Install command: $INSTALL_CMD"
    } > "$OUTPUT_DIR/tool_check.txt"
}

# ============================================
# Start Script
# ============================================

echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║     ENHANCED NETWORK CONNECTION CHECKER                    ║${NC}"
echo -e "${MAGENTA}║     Target: ${YELLOW}$FQDN${MAGENTA}${NC}"
echo -e "${MAGENTA}║     Output: ${CYAN}$OUTPUT_DIR${MAGENTA}${NC}"
echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Initialize summary file
echo "Network Check Report for: $FQDN" > "$SUMMARY_FILE"
echo "Generated: $(date)" >> "$SUMMARY_FILE"
echo "Output Directory: $OUTPUT_DIR" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

if ! $IS_ROOT; then
    echo -e "${YELLOW}⚠ Running without root privileges. Some features will be limited.${NC}"
    echo -e "${YELLOW}  Run with sudo for full functionality (tcpdump, ICMP traceroute, etc.)${NC}"
    echo ""
fi

# ============================================
# 0. Tool Availability Check
# ============================================
print_header "0. System & Tool Check"
check_tools

# ============================================
# 1. Network Interface Information
# ============================================
print_header "1. Local Network Configuration"

print_subheader "1a. Network Interfaces"
if command -v ip &> /dev/null; then
    ip -br addr 2>/dev/null | while read -r line; do
        log_detail "$line"
    done
else
    ifconfig 2>/dev/null | grep -E "^[a-z]|inet " | while read -r line; do
        log_detail "$line"
    done
fi
echo ""

print_subheader "1b. Default Gateway"
if command -v ip &> /dev/null; then
    DEFAULT_GW=$(ip route | grep default | head -1)
    log_detail "$DEFAULT_GW"
else
    DEFAULT_GW=$(route -n 2>/dev/null | grep "^0.0.0.0" | head -1)
    log_detail "$DEFAULT_GW"
fi
echo ""

print_subheader "1c. DNS Servers (/etc/resolv.conf)"
if [ -f /etc/resolv.conf ]; then
    grep -E "^nameserver|^search|^domain" /etc/resolv.conf | while read -r line; do
        log_detail "$line"
    done
fi
echo ""

# ============================================
# 2. DNS Resolution Tests
# ============================================
print_header "2. DNS Resolution"

print_subheader "2a. Forward DNS Lookup"
IP_ADDR=""
IPV6_ADDR=""

# Try multiple DNS resolution methods
if command -v dig &> /dev/null; then
    log_info "Using dig:"
    DIG_RESULT=$(dig +short "$FQDN" A 2>&1) || true
    DIG_RESULT_V6=$(dig +short "$FQDN" AAAA 2>&1) || true
    
    if [ -n "$DIG_RESULT" ]; then
        IP_ADDR=$(echo "$DIG_RESULT" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
        echo "$DIG_RESULT" | while read -r ip; do
            log_detail "A Record: $ip"
        done
    fi
    if [ -n "$DIG_RESULT_V6" ]; then
        IPV6_ADDR=$(echo "$DIG_RESULT_V6" | head -1)
        echo "$DIG_RESULT_V6" | while read -r ip; do
            log_detail "AAAA Record: $ip"
        done
    fi
    
    # Full dig output
    dig "$FQDN" ANY +noall +answer > "$OUTPUT_DIR/dns_dig_full.txt" 2>&1
    log_detail "Full dig output saved to: $OUTPUT_DIR/dns_dig_full.txt"
fi

if command -v host &> /dev/null; then
    log_info "Using host:"
    HOST_RESULT=$(host "$FQDN" 2>&1) || true
    echo "$HOST_RESULT" | grep -E "has address|has IPv6|mail is handled" | while read -r line; do
        log_detail "$line"
    done
    [ -z "$IP_ADDR" ] && IP_ADDR=$(echo "$HOST_RESULT" | grep "has address" | awk '{print $4}' | head -1)
fi

# Fallback to getent
if [ -z "$IP_ADDR" ] && command -v getent &> /dev/null; then
    IP_ADDR=$(getent hosts "$FQDN" 2>/dev/null | awk '{print $1}' | head -1) || true
fi

if [ -n "$IP_ADDR" ]; then
    print_status "IPv4 Resolution" "OK" "$IP_ADDR"
else
    print_status "IPv4 Resolution" "FAIL" "Could not resolve"
    IP_ADDR="$FQDN"  # Fallback to FQDN
fi
echo ""

print_subheader "2b. Reverse DNS Lookup"
if [ -n "$IP_ADDR" ] && [ "$IP_ADDR" != "$FQDN" ]; then
    if command -v dig &> /dev/null; then
        REVERSE_DNS=$(dig +short -x "$IP_ADDR" 2>&1) || true
        if [ -n "$REVERSE_DNS" ]; then
            print_status "Reverse DNS (PTR)" "OK" "$REVERSE_DNS"
        else
            print_status "Reverse DNS (PTR)" "N/A" "No PTR record"
        fi
    elif command -v host &> /dev/null; then
        REVERSE_DNS=$(host "$IP_ADDR" 2>&1 | grep "domain name pointer" | awk '{print $5}') || true
        if [ -n "$REVERSE_DNS" ]; then
            print_status "Reverse DNS (PTR)" "OK" "$REVERSE_DNS"
        else
            print_status "Reverse DNS (PTR)" "N/A" "No PTR record"
        fi
    fi
fi
echo ""

print_subheader "2c. DNS from Multiple Servers"
DNS_SERVERS=("8.8.8.8" "1.1.1.1" "9.9.9.9")
for dns in "${DNS_SERVERS[@]}"; do
    if command -v dig &> /dev/null; then
        RESULT=$(dig +short "$FQDN" @"$dns" 2>/dev/null | head -1) || true
        if [ -n "$RESULT" ]; then
            print_status "DNS $dns" "OK" "$RESULT"
        else
            print_status "DNS $dns" "FAIL" ""
        fi
    fi
done
echo ""

print_subheader "2d. WHOIS Information"
if command -v whois &> /dev/null && [ "$IP_ADDR" != "$FQDN" ]; then
    whois "$IP_ADDR" > "$OUTPUT_DIR/whois_ip.txt" 2>&1 || true
    whois "$FQDN" > "$OUTPUT_DIR/whois_domain.txt" 2>&1 || true
    log_detail "WHOIS data saved to: $OUTPUT_DIR/whois_*.txt"
    
    # Extract key info
    ORG=$(grep -iE "^orgname:|^org-name:|^organization:" "$OUTPUT_DIR/whois_ip.txt" 2>/dev/null | head -1)
    [ -n "$ORG" ] && log_detail "$ORG"
fi
echo ""

# ============================================
# 3. Layer 2 - ARP/MAC Resolution
# ============================================
print_header "3. Layer 2 (ARP/MAC) Information"

if [ "$IP_ADDR" != "$FQDN" ]; then
    # Ping first to populate ARP cache
    ping -c 1 -W 1 "$IP_ADDR" &>/dev/null || true
    
    if command -v arp &> /dev/null; then
        ARP_ENTRY=$(arp -n "$IP_ADDR" 2>/dev/null | grep -v "incomplete" | tail -1) || true
        if [ -n "$ARP_ENTRY" ]; then
            print_status "ARP Entry" "OK" ""
            log_detail "$ARP_ENTRY"
        else
            print_status "ARP Entry" "N/A" "(not in local network or no response)"
        fi
    elif command -v ip &> /dev/null; then
        ARP_ENTRY=$(ip neigh show "$IP_ADDR" 2>/dev/null) || true
        if [ -n "$ARP_ENTRY" ]; then
            print_status "ARP Entry" "OK" ""
            log_detail "$ARP_ENTRY"
        fi
    fi
fi
echo ""

# ============================================
# 4. ICMP Connectivity Tests
# ============================================
print_header "4. ICMP Connectivity"

print_subheader "4a. Basic Ping Test"
# Start tcpdump for ICMP
ICMP_CAPTURE="$TCPDUMP_DIR/icmp_${FQDN}.pcap"
if $IS_ROOT && command -v tcpdump &> /dev/null; then
    tcpdump -i any -w "$ICMP_CAPTURE" "host $IP_ADDR and icmp" -c 20 2>/dev/null &
    ICMP_TCPDUMP_PID=$!
    sleep 0.5
fi

PING_OUTPUT=$(ping -c 5 -W 2 "$FQDN" 2>&1) || true
if echo "$PING_OUTPUT" | grep -q "bytes from"; then
    print_status "ICMP Ping" "OK" ""
    echo "$PING_OUTPUT" | grep -E "bytes from|packet loss|rtt" | while read -r line; do
        log_detail "$line"
    done
else
    print_status "ICMP Ping" "FAIL" "(host may block ICMP)"
fi

# Save ping output
echo "$PING_OUTPUT" > "$OUTPUT_DIR/ping_output.txt"

# Stop ICMP tcpdump
if [ -n "$ICMP_TCPDUMP_PID" ]; then
    sleep 1
    kill "$ICMP_TCPDUMP_PID" 2>/dev/null || true
    wait "$ICMP_TCPDUMP_PID" 2>/dev/null || true
    [ -s "$ICMP_CAPTURE" ] && log_detail "ICMP capture: $ICMP_CAPTURE"
fi
echo ""

print_subheader "4b. Ping with Different Packet Sizes (MTU Discovery)"
for size in 64 512 1024 1472 1500; do
    RESULT=$(ping -c 1 -W 2 -s $size -M do "$IP_ADDR" 2>&1) || true
    if echo "$RESULT" | grep -q "bytes from"; then
        print_status "Ping size=$size" "OK" ""
    else
        print_status "Ping size=$size" "FAIL" "(possible MTU issue)"
    fi
done
echo ""

# ============================================
# 5. TCP Port Connectivity with tcpdump
# ============================================
print_header "5. TCP Port Connectivity (with packet capture)"

log_info "Testing ports: ${PORTS[*]}"
log_info "Captures will be saved to: $TCPDUMP_DIR"
echo ""

for PORT in "${PORTS[@]}"; do
    CAPTURE_FILE="$TCPDUMP_DIR/tcp_port_${PORT}_${FQDN}.pcap"
    
    # Start tcpdump for this port
    if $IS_ROOT && command -v tcpdump &> /dev/null; then
        tcpdump -i any -w "$CAPTURE_FILE" "host $IP_ADDR and tcp port $PORT" -c 50 2>/dev/null &
        TCPDUMP_PID=$!
        sleep 0.3
    else
        TCPDUMP_PID=""
    fi
    
    # Test TCP connectivity
    TCP_STATUS="CLOSED"
    TCP_DETAILS=""
    
    if command -v nc &> /dev/null; then
        if timeout $TIMEOUT_SEC nc -zv "$FQDN" "$PORT" 2>&1 | grep -qE "succeeded|open|Connected"; then
            TCP_STATUS="OPEN"
        fi
        TCP_DETAILS=$(timeout $TIMEOUT_SEC nc -zv "$FQDN" "$PORT" 2>&1 | head -1) || true
    elif command -v timeout &> /dev/null; then
        if timeout $TIMEOUT_SEC bash -c "echo >/dev/tcp/$FQDN/$PORT" 2>/dev/null; then
            TCP_STATUS="OPEN"
        fi
    fi
    
    # Also try with curl for HTTP ports
    if [[ "$PORT" =~ ^(80|8080|443|8443)$ ]]; then
        PROTO="http"
        [[ "$PORT" =~ ^(443|8443)$ ]] && PROTO="https"
        CURL_RESULT=$(timeout $TIMEOUT_SEC curl -sI -o /dev/null -w "%{http_code}" "${PROTO}://${FQDN}:${PORT}/" 2>/dev/null) || true
        if [ -n "$CURL_RESULT" ] && [ "$CURL_RESULT" != "000" ]; then
            TCP_STATUS="OPEN"
            TCP_DETAILS="HTTP $CURL_RESULT"
        fi
    fi
    
    print_status "TCP $PORT" "$TCP_STATUS" "$TCP_DETAILS"
    
    # Stop tcpdump
    if [ -n "$TCPDUMP_PID" ]; then
        sleep 0.5
        kill "$TCPDUMP_PID" 2>/dev/null || true
        wait "$TCPDUMP_PID" 2>/dev/null || true
        if [ -s "$CAPTURE_FILE" ]; then
            PACKET_COUNT=$(tcpdump -r "$CAPTURE_FILE" 2>/dev/null | wc -l) || true
            log_detail "  Captured $PACKET_COUNT packets -> $CAPTURE_FILE"
        else
            rm -f "$CAPTURE_FILE" 2>/dev/null
        fi
    fi
done
echo ""

# ============================================
# 6. UDP Port Connectivity with tcpdump
# ============================================
print_header "6. UDP Port Connectivity (with packet capture)"

log_info "Note: UDP is connectionless - results may show OPEN|FILTERED"
echo ""

UDP_PORTS=(53 123 161 500 514 1194)
for PORT in "${UDP_PORTS[@]}"; do
    CAPTURE_FILE="$TCPDUMP_DIR/udp_port_${PORT}_${FQDN}.pcap"
    
    # Start tcpdump for this port
    if $IS_ROOT && command -v tcpdump &> /dev/null; then
        tcpdump -i any -w "$CAPTURE_FILE" "host $IP_ADDR and udp port $PORT" -c 20 2>/dev/null &
        TCPDUMP_PID=$!
        sleep 0.3
    else
        TCPDUMP_PID=""
    fi
    
    UDP_STATUS="FILTERED"
    
    if command -v nc &> /dev/null; then
        # Send UDP packet and check for ICMP unreachable
        timeout 2 nc -zu "$FQDN" "$PORT" 2>&1
        if [ $? -eq 0 ]; then
            UDP_STATUS="OPEN|FILTERED"
        fi
    fi
    
    print_status "UDP $PORT" "$UDP_STATUS" ""
    
    # Stop tcpdump
    if [ -n "$TCPDUMP_PID" ]; then
        sleep 0.5
        kill "$TCPDUMP_PID" 2>/dev/null || true
        wait "$TCPDUMP_PID" 2>/dev/null || true
        if [ -s "$CAPTURE_FILE" ]; then
            log_detail "  Capture -> $CAPTURE_FILE"
        else
            rm -f "$CAPTURE_FILE" 2>/dev/null
        fi
    fi
done
echo ""

# ============================================
# 7. SSL/TLS Certificate Check
# ============================================
print_header "7. SSL/TLS Certificate Validation"

SSL_PORTS=(443 8443 6443)
for PORT in "${SSL_PORTS[@]}"; do
    print_subheader "7. SSL on port $PORT"
    
    if command -v openssl &> /dev/null; then
        CERT_FILE="$OUTPUT_DIR/ssl_cert_port_${PORT}.txt"
        
        # Get certificate
        CERT_OUTPUT=$(echo | timeout 5 openssl s_client -connect "${FQDN}:${PORT}" -servername "$FQDN" 2>/dev/null) || true
        
        if echo "$CERT_OUTPUT" | grep -q "BEGIN CERTIFICATE"; then
            print_status "SSL/TLS Port $PORT" "OK" ""
            
            # Extract certificate details
            echo "$CERT_OUTPUT" | openssl x509 -noout -text > "$CERT_FILE" 2>/dev/null || true
            
            # Show key details
            SUBJECT=$(echo "$CERT_OUTPUT" | openssl x509 -noout -subject 2>/dev/null) || true
            ISSUER=$(echo "$CERT_OUTPUT" | openssl x509 -noout -issuer 2>/dev/null) || true
            DATES=$(echo "$CERT_OUTPUT" | openssl x509 -noout -dates 2>/dev/null) || true
            
            [ -n "$SUBJECT" ] && log_detail "$SUBJECT"
            [ -n "$ISSUER" ] && log_detail "$ISSUER"
            echo "$DATES" | while read -r line; do
                log_detail "$line"
            done
            
            # Check expiration
            END_DATE=$(echo "$CERT_OUTPUT" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
            if [ -n "$END_DATE" ]; then
                END_EPOCH=$(date -d "$END_DATE" +%s 2>/dev/null) || true
                NOW_EPOCH=$(date +%s)
                if [ -n "$END_EPOCH" ]; then
                    DAYS_LEFT=$(( (END_EPOCH - NOW_EPOCH) / 86400 ))
                    if [ $DAYS_LEFT -lt 0 ]; then
                        print_status "Certificate" "EXPIRED" "$DAYS_LEFT days ago"
                    elif [ $DAYS_LEFT -lt 30 ]; then
                        print_status "Certificate" "EXPIRING" "in $DAYS_LEFT days"
                    else
                        print_status "Certificate" "VALID" "$DAYS_LEFT days remaining"
                    fi
                fi
            fi
            
            log_detail "Full cert saved: $CERT_FILE"
        else
            print_status "SSL/TLS Port $PORT" "FAIL" "(no certificate or connection failed)"
        fi
    fi
done
echo ""

# ============================================
# 8. HTTP/HTTPS Response Check
# ============================================
print_header "8. HTTP/HTTPS Connectivity"

if command -v curl &> /dev/null; then
    for PROTO in "http" "https"; do
        for PORT in 80 443 8080 8443; do
            # Skip http on 443/8443, https on 80/8080
            [[ "$PROTO" == "http" && "$PORT" =~ ^(443|8443)$ ]] && continue
            [[ "$PROTO" == "https" && "$PORT" =~ ^(80|8080)$ ]] && continue
            
            URL="${PROTO}://${FQDN}:${PORT}/"
            RESPONSE_FILE="$OUTPUT_DIR/http_${PROTO}_${PORT}.txt"
            
            # Get HTTP response
            HTTP_CODE=$(timeout 10 curl -sI -k -o "$RESPONSE_FILE" -w "%{http_code}" "$URL" 2>/dev/null) || true
            
            if [ -n "$HTTP_CODE" ] && [ "$HTTP_CODE" != "000" ]; then
                print_status "$PROTO://:$PORT" "OK" "HTTP $HTTP_CODE"
                
                # Extract headers
                SERVER=$(grep -i "^server:" "$RESPONSE_FILE" 2>/dev/null | head -1)
                [ -n "$SERVER" ] && log_detail "$SERVER"
            else
                print_status "$PROTO://:$PORT" "FAIL" ""
                rm -f "$RESPONSE_FILE" 2>/dev/null
            fi
        done
    done
fi
echo ""

# ============================================
# 9. Traceroute (Multiple Methods)
# ============================================
print_header "9. Traceroute Analysis"

# Start tcpdump for traceroute
TRACE_CAPTURE="$TCPDUMP_DIR/traceroute_${FQDN}.pcap"
if $IS_ROOT && command -v tcpdump &> /dev/null; then
    tcpdump -i any -w "$TRACE_CAPTURE" "host $IP_ADDR or icmp" -c 500 2>/dev/null &
    TRACE_TCPDUMP_PID=$!
    sleep 0.5
fi

print_subheader "9a. ICMP Traceroute"
if command -v traceroute &> /dev/null; then
    TRACE_FILE="$OUTPUT_DIR/traceroute_icmp.txt"
    if $IS_ROOT; then
        traceroute -I -m 25 -w 2 "$IP_ADDR" 2>&1 | tee "$TRACE_FILE" | while read -r line; do
            log_detail "$line"
        done || true
    else
        traceroute -m 25 -w 2 "$IP_ADDR" 2>&1 | tee "$TRACE_FILE" | while read -r line; do
            log_detail "$line"
        done || true
    fi
fi
echo ""

print_subheader "9b. TCP Traceroute (port 443)"
if command -v traceroute &> /dev/null && $IS_ROOT; then
    TRACE_FILE="$OUTPUT_DIR/traceroute_tcp_443.txt"
    traceroute -T -p 443 -m 25 -w 2 "$IP_ADDR" 2>&1 | tee "$TRACE_FILE" | while read -r line; do
        log_detail "$line"
    done || true
else
    log_info "(Requires root - skipped)"
fi
echo ""

print_subheader "9c. MTR Report"
if command -v mtr &> /dev/null; then
    MTR_FILE="$OUTPUT_DIR/mtr_report.txt"
    mtr --report --report-cycles 10 --no-dns "$IP_ADDR" 2>&1 | tee "$MTR_FILE" | while read -r line; do
        log_detail "$line"
    done || true
fi
echo ""

# Stop traceroute tcpdump
if [ -n "$TRACE_TCPDUMP_PID" ]; then
    sleep 1
    kill "$TRACE_TCPDUMP_PID" 2>/dev/null || true
    wait "$TRACE_TCPDUMP_PID" 2>/dev/null || true
    [ -s "$TRACE_CAPTURE" ] && log_detail "Traceroute capture: $TRACE_CAPTURE"
fi

# ============================================
# 10. Firewall Rules Check (Local)
# ============================================
print_header "10. Local Firewall Configuration"

if $IS_ROOT; then
    print_subheader "10a. iptables rules"
    if command -v iptables &> /dev/null; then
        IPTABLES_FILE="$OUTPUT_DIR/iptables_rules.txt"
        iptables -L -n -v > "$IPTABLES_FILE" 2>&1 || true
        iptables -L -n 2>/dev/null | head -20 | while read -r line; do
            log_detail "$line"
        done
        log_detail "Full rules saved: $IPTABLES_FILE"
    fi
    echo ""
    
    print_subheader "10b. nftables rules"
    if command -v nft &> /dev/null; then
        NFT_FILE="$OUTPUT_DIR/nftables_rules.txt"
        nft list ruleset > "$NFT_FILE" 2>&1 || true
        nft list ruleset 2>/dev/null | head -20 | while read -r line; do
            log_detail "$line"
        done
    fi
    echo ""
    
    print_subheader "10c. firewalld zones"
    if command -v firewall-cmd &> /dev/null; then
        FW_FILE="$OUTPUT_DIR/firewalld_info.txt"
        {
            echo "=== Active Zones ==="
            firewall-cmd --get-active-zones
            echo ""
            echo "=== Default Zone ==="
            firewall-cmd --get-default-zone
            echo ""
            echo "=== All Services ==="
            firewall-cmd --list-all
        } > "$FW_FILE" 2>&1 || true
        firewall-cmd --list-all 2>/dev/null | while read -r line; do
            log_detail "$line"
        done
    fi
else
    log_info "(Requires root - skipped)"
fi
echo ""

# ============================================
# 11. Connection State Check
# ============================================
print_header "11. Existing Connections to Target"

if command -v ss &> /dev/null; then
    CONNECTIONS=$(ss -tunapo 2>/dev/null | grep "$IP_ADDR" | head -10) || true
    if [ -n "$CONNECTIONS" ]; then
        echo "$CONNECTIONS" | while read -r line; do
            log_detail "$line"
        done
    else
        log_info "No active connections to $IP_ADDR"
    fi
elif command -v netstat &> /dev/null; then
    CONNECTIONS=$(netstat -tunapo 2>/dev/null | grep "$IP_ADDR" | head -10) || true
    if [ -n "$CONNECTIONS" ]; then
        echo "$CONNECTIONS" | while read -r line; do
            log_detail "$line"
        done
    else
        log_info "No active connections to $IP_ADDR"
    fi
fi
echo ""

# ============================================
# 12. Summary & Report
# ============================================
print_header "12. Summary"

echo -e "  ${CYAN}Target FQDN:${NC}    ${YELLOW}$FQDN${NC}"
echo -e "  ${CYAN}Resolved IP:${NC}    ${GREEN}$IP_ADDR${NC}"
[ -n "$IPV6_ADDR" ] && echo -e "  ${CYAN}IPv6 Address:${NC}   ${GREEN}$IPV6_ADDR${NC}"
echo -e "  ${CYAN}TCP Ports:${NC}      ${BLUE}${PORTS[*]}${NC}"
echo -e "  ${CYAN}UDP Ports:${NC}      ${BLUE}${UDP_PORTS[*]}${NC}"
echo ""
echo -e "  ${CYAN}Output Directory:${NC} ${GREEN}$OUTPUT_DIR${NC}"
echo ""

# List generated files
echo -e "  ${CYAN}Generated Files:${NC}"
ls -la "$OUTPUT_DIR"/*.txt 2>/dev/null | while read -r line; do
    log_detail "$line"
done
echo ""
echo -e "  ${CYAN}Packet Captures:${NC}"
ls -la "$TCPDUMP_DIR"/*.pcap 2>/dev/null | while read -r line; do
    log_detail "$line"
done || echo -e "    ${YELLOW}No captures (requires sudo)${NC}"
echo ""

# Add to summary file
{
    echo ""
    echo "============================================"
    echo "  Files Generated"
    echo "============================================"
    ls -la "$OUTPUT_DIR"
    echo ""
    ls -la "$TCPDUMP_DIR" 2>/dev/null
} >> "$SUMMARY_FILE"

echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║  ${GREEN}Network check completed!${MAGENTA}                                 ║${NC}"
echo -e "${MAGENTA}║  Summary: ${CYAN}$SUMMARY_FILE${MAGENTA}${NC}"
echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════╝${NC}"
