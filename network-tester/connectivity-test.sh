#!/bin/bash

# ============================================
# Network Connectivity Tester
# ============================================
# This script continuously tests network connectivity
# to a specified gateway and logs the results.
# Designed to run as a DaemonSet pod on OpenShift.
# ============================================

set -o pipefail

# Configuration from environment variables
GATEWAY="${GATEWAY_IP:-192.168.1.1}"
TEST_INTERVAL="${TEST_INTERVAL:-10}"
PING_COUNT="${PING_COUNT:-3}"
PING_TIMEOUT="${PING_TIMEOUT:-2}"
TCP_PORTS="${TCP_PORTS:-22,80,443}"
DNS_TEST_HOST="${DNS_TEST_HOST:-kubernetes.default.svc.cluster.local}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Colors for terminal output (optional)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get node and pod info
NODE_NAME="${NODE_NAME:-unknown}"
POD_NAME="${POD_NAME:-unknown}"
POD_IP="${POD_IP:-unknown}"

# ============================================
# Logging Functions
# ============================================

log_timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

log_info() {
    echo "[$(log_timestamp)] [INFO] [$NODE_NAME] $1"
}

log_success() {
    echo "[$(log_timestamp)] [OK] [$NODE_NAME] $1"
}

log_error() {
    echo "[$(log_timestamp)] [FAIL] [$NODE_NAME] $1"
}

log_warn() {
    echo "[$(log_timestamp)] [WARN] [$NODE_NAME] $1"
}

log_separator() {
    echo "========================================"
}

# ============================================
# Test Functions
# ============================================

test_icmp_ping() {
    local target="$1"
    local result
    local latency
    
    result=$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$target" 2>&1)
    
    if echo "$result" | grep -q "bytes from"; then
        latency=$(echo "$result" | grep "rtt" | awk -F'/' '{print $5}')
        log_success "ICMP ping to $target: OK (avg latency: ${latency}ms)"
        return 0
    else
        log_error "ICMP ping to $target: FAILED"
        return 1
    fi
}

test_tcp_port() {
    local target="$1"
    local port="$2"
    local timeout="${3:-3}"
    
    if command -v nc &> /dev/null; then
        if nc -z -w "$timeout" "$target" "$port" 2>/dev/null; then
            log_success "TCP port $port to $target: OPEN"
            return 0
        else
            log_error "TCP port $port to $target: CLOSED/FILTERED"
            return 1
        fi
    elif command -v timeout &> /dev/null; then
        if timeout "$timeout" bash -c "echo >/dev/tcp/$target/$port" 2>/dev/null; then
            log_success "TCP port $port to $target: OPEN"
            return 0
        else
            log_error "TCP port $port to $target: CLOSED/FILTERED"
            return 1
        fi
    else
        log_warn "TCP port $port to $target: SKIPPED (no nc or timeout available)"
        return 2
    fi
}

test_dns_resolution() {
    local hostname="$1"
    local result
    
    if command -v nslookup &> /dev/null; then
        result=$(nslookup "$hostname" 2>&1)
        if echo "$result" | grep -qE "Address:|answer:"; then
            log_success "DNS resolution for $hostname: OK"
            return 0
        else
            log_error "DNS resolution for $hostname: FAILED"
            return 1
        fi
    elif command -v host &> /dev/null; then
        result=$(host "$hostname" 2>&1)
        if echo "$result" | grep -q "has address"; then
            log_success "DNS resolution for $hostname: OK"
            return 0
        else
            log_error "DNS resolution for $hostname: FAILED"
            return 1
        fi
    else
        log_warn "DNS resolution: SKIPPED (no nslookup or host available)"
        return 2
    fi
}

test_default_route() {
    local route
    
    if command -v ip &> /dev/null; then
        route=$(ip route | grep default | head -1)
        if [ -n "$route" ]; then
            log_info "Default route: $route"
            return 0
        else
            log_error "Default route: NOT FOUND"
            return 1
        fi
    else
        log_warn "Default route check: SKIPPED (ip command not available)"
        return 2
    fi
}

test_mtu_path() {
    local target="$1"
    local sizes=(64 512 1024 1472)
    local max_mtu=0
    
    for size in "${sizes[@]}"; do
        if ping -c 1 -W 2 -s "$size" -M do "$target" &>/dev/null; then
            max_mtu=$((size + 28))
        else
            break
        fi
    done
    
    if [ $max_mtu -gt 0 ]; then
        log_success "MTU path to $target: at least ${max_mtu} bytes"
    else
        log_error "MTU path to $target: could not determine"
    fi
}

# ============================================
# Main Test Loop
# ============================================

run_connectivity_tests() {
    local test_count=0
    local icmp_pass=0
    local icmp_fail=0
    local tcp_pass=0
    local tcp_fail=0
    
    log_separator
    log_info "=== Connectivity Test Cycle #$((++CYCLE_COUNT)) ==="
    log_separator
    
    # Pod/Node info
    log_info "Node: $NODE_NAME"
    log_info "Pod: $POD_NAME"
    log_info "Pod IP: $POD_IP"
    log_info "Target Gateway: $GATEWAY"
    log_info "Test Interval: ${TEST_INTERVAL}s"
    echo ""
    
    # Test 1: Default route check
    log_info "--- Routing Check ---"
    test_default_route
    echo ""
    
    # Test 2: ICMP ping to gateway
    log_info "--- ICMP Connectivity ---"
    if test_icmp_ping "$GATEWAY"; then
        ((icmp_pass++))
    else
        ((icmp_fail++))
    fi
    echo ""
    
    # Test 3: TCP port connectivity
    log_info "--- TCP Port Connectivity ---"
    IFS=',' read -ra PORTS <<< "$TCP_PORTS"
    for port in "${PORTS[@]}"; do
        if test_tcp_port "$GATEWAY" "$port"; then
            ((tcp_pass++))
        else
            ((tcp_fail++))
        fi
    done
    echo ""
    
    # Test 4: DNS resolution
    log_info "--- DNS Resolution ---"
    test_dns_resolution "$DNS_TEST_HOST"
    test_dns_resolution "google.com" 2>/dev/null || true
    echo ""
    
    # Test 5: MTU path discovery
    log_info "--- MTU Path Discovery ---"
    test_mtu_path "$GATEWAY"
    echo ""
    
    # Summary
    log_separator
    log_info "=== Test Summary ==="
    log_info "ICMP: ${icmp_pass} passed, ${icmp_fail} failed"
    log_info "TCP: ${tcp_pass} passed, ${tcp_fail} failed"
    log_separator
    echo ""
}

# ============================================
# Signal Handlers
# ============================================

cleanup() {
    log_info "Received shutdown signal. Stopping connectivity tests..."
    log_info "Final statistics:"
    log_info "  Total test cycles: $CYCLE_COUNT"
    log_info "  Runtime: $SECONDS seconds"
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# ============================================
# Main Entry Point
# ============================================

main() {
    CYCLE_COUNT=0
    
    log_separator
    log_info "╔════════════════════════════════════════════════════════╗"
    log_info "║  NETWORK CONNECTIVITY TESTER                          ║"
    log_info "║  Starting continuous connectivity monitoring...       ║"
    log_info "╚════════════════════════════════════════════════════════╝"
    log_separator
    
    log_info "Configuration:"
    log_info "  Gateway IP: $GATEWAY"
    log_info "  Test Interval: ${TEST_INTERVAL}s"
    log_info "  Ping Count: $PING_COUNT"
    log_info "  TCP Ports: $TCP_PORTS"
    log_info "  DNS Test Host: $DNS_TEST_HOST"
    log_info "  Node Name: $NODE_NAME"
    log_info "  Pod Name: $POD_NAME"
    log_info "  Pod IP: $POD_IP"
    log_separator
    echo ""
    
    # Continuous testing loop
    while true; do
        run_connectivity_tests
        
        log_info "Sleeping for ${TEST_INTERVAL} seconds before next test..."
        sleep "$TEST_INTERVAL" &
        wait $!
    done
}

main "$@"
