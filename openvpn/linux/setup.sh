#!/bin/bash

###############################################################################
# OpenVPN Server Setup Script for Linux (State-Aware)
# Resumes from the last completed step if interrupted
# Usage: sudo ./setup.sh
###############################################################################

set -e  # Exit on error

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_FILE="$BASE_DIR/.openvpn-state.json"
COMPOSE_FILE="$BASE_DIR/compose.yml"
DATA_DIR="$BASE_DIR/openvpn-data"
LOGS_DIR="$BASE_DIR/logs"
CLIENTS_DIR="$BASE_DIR/clients"
CONTAINER_NAME="OpenVPN-Server"

###############################################################################
# Runtime Detection
###############################################################################
get_runtime() {
    if command -v podman &> /dev/null; then echo "podman"; return; fi
    if command -v docker &> /dev/null; then echo "docker"; return; fi
    echo ""
}

get_compose_cmd() {
    local r
    r=$(get_runtime)
    if [[ -z "$r" ]]; then echo ""; return; fi
    if [[ "$r" == "podman" ]]; then
        if command -v podman-compose &> /dev/null; then echo "podman-compose"; return; fi
        if podman compose version &> /dev/null 2>&1; then echo "podman compose"; return; fi
    else
        if command -v docker-compose &> /dev/null; then echo "docker-compose"; return; fi
        if docker compose version &> /dev/null 2>&1; then echo "docker compose"; return; fi
    fi
    echo ""
}

RUNTIME=$(get_runtime)
COMPOSE_CMD=$(get_compose_cmd)

###############################################################################
# Helper Functions
###############################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# JSON value reader (basic grep fallback if jq is missing)
read_json_value() {
    local file=$1
    local path=$2
    
    if command -v jq &> /dev/null; then
        jq -r "$path" "$file" 2>/dev/null || echo "null"
    else
        # Fallback: basic grep (only works for root level)
        grep "\"$path\"" "$file" | head -1 | cut -d'"' -f4 || echo "null"
    fi
}

# Update state
update_state() {
    local step=$1
    local status=$2
    local error_msg=$3
    local extra_data=$4
    
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    if command -v jq &> /dev/null; then
        # jq update
        local tmp_file=$(mktemp)
        jq --arg step "$step" \
           --arg status "$status" \
           --arg timestamp "$timestamp" \
           --arg error "$error_msg" \
           --arg extra "$extra_data" \
           '.lastUpdated = $timestamp |
            .setup.steps[$step].status = $status |
            .setup.steps[$step].timestamp = $timestamp |
            .setup.steps[$step].error = (if $error == "" then null else $error end) |
            .setup.currentStep = $step |
            if $extra != "" and $step == "detect_ip" then
              .setup.steps.detect_ip.detected_ip = $extra |
              .metadata.serverIP = $extra
            else . end' \
            "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    else
        # Fallback: manual update (basic)
        log_warning "jq not found, state updates will be limited"
        sed -i "s/\"currentStep\": .*/\"currentStep\": \"$step\",/" "$STATE_FILE" || true
    fi
}

# Mark setup as completed
mark_setup_completed() {
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    if command -v jq &> /dev/null; then
        local tmp_file=$(mktemp)
        jq --arg timestamp "$timestamp" \
           '.setup.status = "completed" |
            .setup.completed = true |
            .lastUpdated = $timestamp |
            .metadata.lastModified = $timestamp |
            if .metadata.createdAt == null then
              .metadata.createdAt = $timestamp
            else . end' \
            "$STATE_FILE" > "$tmp_file" && mv "$tmp_file" "$STATE_FILE"
    fi
}

# Check if step is completed
is_step_completed() {
    local step=$1
    
    if command -v jq &> /dev/null; then
        local status=$(jq -r ".setup.steps.$step.status" "$STATE_FILE" 2>/dev/null)
        [[ "$status" == "completed" ]] && return 0 || return 1
    else
        # Fallback: basic check
        grep -q "\"$step\".*\"completed\"" "$STATE_FILE" 2>/dev/null && return 0 || return 1
    fi
}

# Is setup completed?
is_setup_completed() {
    if command -v jq &> /dev/null; then
        local completed=$(jq -r '.setup.completed' "$STATE_FILE" 2>/dev/null)
        [[ "$completed" == "true" ]] && return 0 || return 1
    else
        grep -q '"completed": true' "$STATE_FILE" 2>/dev/null && return 0 || return 1
    fi
}

###############################################################################
# Setup Steps
###############################################################################

# Step 0: Pre-checks
step_precheck() {
    log_info "Step 0/7: Pre-checks (runtime, privileges, port check)..."
    
    if is_step_completed "precheck"; then
        log_success "Pre-checks already completed, skipping..."
        return 0
    fi
    
    update_state "precheck" "in_progress" ""
    
    # Root/sudo check
    if [[ $EUID -ne 0 ]]; then
        update_state "precheck" "failed" "This script must be run as root or with sudo"
        log_error "This script must be run as root or with sudo!"
        exit 1
    fi
    
    # Container runtime check (Podman or Docker)
    if [[ -z "$RUNTIME" ]]; then
        update_state "precheck" "failed" "Container runtime not installed"
        log_error "Docker or Podman not installed! Please install one."
        log_info "Podman: https://podman.io/getting-started/installation"
        log_info "Docker: https://docs.docker.com/get-docker/"
        exit 1
    fi
    
    # Compose check
    if [[ -z "$COMPOSE_CMD" ]]; then
        update_state "precheck" "failed" "Compose provider not installed"
        log_error "Compose provider not installed!"
        if [[ "$RUNTIME" == "docker" ]]; then
            log_info "Install: https://docs.docker.com/compose/install/"
        else
            log_info "Install: pip3 install podman-compose or use Podman 3.0+"
        fi
        exit 1
    fi
    
    # Is runtime running?
    if ! $RUNTIME info &> /dev/null; then
        update_state "precheck" "failed" "$RUNTIME is not running"
        log_error "$RUNTIME is not running!"
        if [[ "$RUNTIME" == "docker" ]]; then
            log_info "Start Docker daemon: sudo systemctl start docker"
        else
            log_info "Check Podman installation"
        fi
        exit 1
    fi
    
    # Port 1194 in use?
    if netstat -tuln 2>/dev/null | grep -q ":1194 " || ss -tuln 2>/dev/null | grep -q ":1194 "; then
        log_warning "Port 1194 is already in use! Do you want to continue? (y/N)"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            update_state "precheck" "failed" "Port 1194 in use and user declined to continue"
            exit 1
        fi
    fi
    
    # Compose file check
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        update_state "precheck" "failed" "compose.yml not found"
        log_error "compose.yml not found: $COMPOSE_FILE"
        exit 1
    fi
    
    update_state "precheck" "completed" ""
    log_success "Pre-checks completed ✓"
}

# Step 1: State init
step_state_init() {
    log_info "Step 1/7: Checking state file..."
    
    if is_step_completed "state_init"; then
        log_success "State init already completed, skipping..."
        return 0
    fi
    
    update_state "state_init" "in_progress" ""
    
    # State file must exist (should already be created from template)
    if [[ ! -f "$STATE_FILE" ]]; then
        log_error "State file not found: $STATE_FILE"
        log_info "Please copy from template: .openvpn-state.json"
        exit 1
    fi
    
    # jq recommendation
    if ! command -v jq &> /dev/null; then
        log_warning "jq not found. Installing jq is recommended for state management."
        log_info "Install: sudo apt-get install jq  (Ubuntu/Debian)"
        log_info "         sudo yum install jq      (CentOS/RHEL)"
    fi
    
    update_state "state_init" "completed" ""
    log_success "State init completed ✓"
}

# Step 2: Create volumes/directories
step_create_volumes() {
    log_info "Step 2/7: Creating directories..."
    
    if is_step_completed "create_volumes"; then
        log_success "Directories already created, skipping..."
        return 0
    fi
    
    update_state "create_volumes" "in_progress" ""
    
    # Create directories
    mkdir -p "$DATA_DIR" "$LOGS_DIR" "$CLIENTS_DIR"
    
    # Set permissions
    chmod 755 "$DATA_DIR" "$LOGS_DIR" "$CLIENTS_DIR"
    
    update_state "create_volumes" "completed" ""
    log_success "Directories created ✓"
}

# Step 3: IP detection
step_detect_ip() {
    log_info "Step 3/7: Detecting server IP address..."
    
    if is_step_completed "detect_ip"; then
        log_success "IP address already detected, skipping..."
        return 0
    fi
    
    update_state "detect_ip" "in_progress" ""
    
    # Detect public IP
    SERVER_IP=""
    
    # Try different services
    for service in "ifconfig.me" "icanhazip.com" "api.ipify.org"; do
        SERVER_IP=$(curl -s --connect-timeout 5 "https://$service" 2>/dev/null || echo "")
        if [[ -n "$SERVER_IP" ]] && [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_success "Public IP detected: $SERVER_IP"
            break
        fi
    done
    
    # If IP not detected, ask the user
    if [[ -z "$SERVER_IP" ]] || [[ ! "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_warning "Could not auto-detect public IP."
        log_info "Please enter your server's public IP address or domain:"
        read -r SERVER_IP
        
        if [[ -z "$SERVER_IP" ]]; then
            update_state "detect_ip" "failed" "No IP address entered"
            log_error "No IP address was entered!"
            exit 1
        fi
    fi
    
    log_info "Address to use: $SERVER_IP"
    
    update_state "detect_ip" "completed" "" "$SERVER_IP"
    log_success "IP address saved ✓"
}

# Step 4: Start container
step_start_container() {
    log_info "Step 4/7: Starting container ($RUNTIME)..."
    
    if is_step_completed "start_container"; then
        log_success "Container already started, skipping..."
        return 0
    fi
    
    update_state "start_container" "in_progress" ""
    
    # Start container
    cd "$BASE_DIR"
    $COMPOSE_CMD up -d
    
    # Check container started
    sleep 3
    if ! $RUNTIME ps | grep -q "$CONTAINER_NAME"; then
        update_state "start_container" "failed" "Container failed to start"
        log_error "Container failed to start!"
        log_info "Check logs: $COMPOSE_CMD logs openvpn"
        exit 1
    fi
    
    update_state "start_container" "completed" ""
    log_success "Container started ✓"
}

# Step 5: PKI Initialization
step_pki_init() {
    log_info "Step 5/7: Generating OpenVPN configuration..."
    
    if is_step_completed "pki_init"; then
        log_success "PKI init already completed, skipping..."
        return 0
    fi
    
    update_state "pki_init" "in_progress" ""
    
    # Read IP from state
    local SERVER_IP=""
    if command -v jq &> /dev/null; then
        SERVER_IP=$(jq -r '.metadata.serverIP' "$STATE_FILE")
    fi
    
    if [[ -z "$SERVER_IP" ]] || [[ "$SERVER_IP" == "null" ]]; then
        update_state "pki_init" "failed" "Server IP not found in state"
        log_error "Server IP not found in state!"
        exit 1
    fi
    
    log_info "Generating OpenVPN config: udp://$SERVER_IP:1194"
    
    # Run ovpn_genconfig
    $RUNTIME run -v "$DATA_DIR:/etc/openvpn" --rm kylemanna/openvpn ovpn_genconfig \
        -u udp://$SERVER_IP:1194 \
        -N -n 1.1.1.1 -n 1.0.0.1
    
    if [[ $? -ne 0 ]]; then
        update_state "pki_init" "failed" "ovpn_genconfig failed"
        log_error "ovpn_genconfig failed!"
        exit 1
    fi
    
    # Fix NAT setting (ensures internet routing through VPN)
    log_info "Applying NAT and routing configuration..."
    $RUNTIME run -v "$DATA_DIR:/etc/openvpn" --rm kylemanna/openvpn sh -c \
        "grep -q OVPN_NAT=1 /etc/openvpn/ovpn_env.sh || sed -i 's/OVPN_NAT=0/OVPN_NAT=1/' /etc/openvpn/ovpn_env.sh"
    $RUNTIME run -v "$DATA_DIR:/etc/openvpn" --rm kylemanna/openvpn sh -c \
        "grep -q redirect-gateway /etc/openvpn/openvpn.conf || echo 'push \"redirect-gateway def1 bypass-dhcp\"' >> /etc/openvpn/openvpn.conf"
    log_success "NAT and routing configuration applied ✓"
    
    update_state "pki_init" "completed" ""
    log_success "OpenVPN configuration generated ✓"
}

# Step 6: Generate CA Certificate
step_generate_ca() {
    log_info "Step 6/7: Generating CA certificate..."
    
    if is_step_completed "generate_ca"; then
        log_success "CA certificate already generated, skipping..."
        return 0
    fi
    
    update_state "generate_ca" "in_progress" ""
    
    log_info "Generating CA certificate (nopass mode)..."
    log_warning "This may take 10-20 seconds..."
    
    # Run ovpn_initpki (nopass mode)
    $RUNTIME run -v "$DATA_DIR:/etc/openvpn" --rm -it kylemanna/openvpn ovpn_initpki nopass
    
    if [[ $? -ne 0 ]]; then
        update_state "generate_ca" "failed" "CA certificate generation failed"
        log_error "CA certificate generation failed!"
        exit 1
    fi
    
    # Restart container
    log_info "Restarting container..."
    cd "$BASE_DIR"
    $COMPOSE_CMD restart
    sleep 3
    
    update_state "generate_ca" "completed" ""
    log_success "CA certificate generated ✓"
}

# Step 7: Verification
step_verification() {
    log_info "Step 7/7: Verifying installation..."
    
    if is_step_completed "verification"; then
        log_success "Verification already completed, skipping..."
        return 0
    fi
    
    update_state "verification" "in_progress" ""
    
    # Is container running?
    if ! $RUNTIME ps | grep -q "$CONTAINER_NAME"; then
        update_state "verification" "failed" "Container not running"
        log_error "Container not running!"
        exit 1
    fi
    
    # Port check from host
    log_info "Checking port..."
    sleep 2
    
    # Port check from host
    if netstat -tuln 2>/dev/null | grep -q ":1194 " || ss -tuln 2>/dev/null | grep -q ":1194 "; then
        log_success "Port 1194/UDP listening ✓"
    else
        log_warning "Port 1194 may not be listening yet, wait a few seconds..."
    fi
    
    # Config file check
    if [[ -f "$DATA_DIR/openvpn.conf" ]]; then
        log_success "OpenVPN config file present ✓"
    else
        update_state "verification" "failed" "openvpn.conf not found"
        log_error "openvpn.conf not found!"
        exit 1
    fi
    
    # PKI directory check
    if [[ -d "$DATA_DIR/pki" ]]; then
        log_success "PKI directory present ✓"
    else
        update_state "verification" "failed" "PKI directory not found"
        log_error "PKI directory not found!"
        exit 1
    fi
    
    update_state "verification" "completed" ""
    log_success "Verification completed ✓"
}

###############################################################################
# Main
###############################################################################

main() {
    echo ""
    echo "=========================================="
    echo "  OpenVPN Server Setup (Linux)"
    echo "  State-Aware Installation"
    echo "=========================================="
    echo ""
    
    # Is setup already completed?
    if is_setup_completed; then
        log_success "✓ OpenVPN setup already completed!"
        log_info ""
        log_info "To create a user:"
        log_info "  sudo ./create-user.sh <username>"
        log_info ""
        log_info "For status check:"
        log_info "  ./status.sh"
        log_info ""
        log_info "To reset state:"
        log_info "  sudo ./reset-state.sh"
        echo ""
        exit 0
    fi
    
    # Run steps
    step_precheck
    step_state_init
    step_create_volumes
    step_detect_ip
    step_start_container
    step_pki_init
    step_generate_ca
    step_verification
    
    # Mark setup completed
    mark_setup_completed
    
    echo ""
    echo "=========================================="
    log_success "✓ OpenVPN setup completed successfully!"
    echo "=========================================="
    echo ""
    log_info "Next steps:"
    log_info ""
    log_info "1. Create a user:"
    log_info "   sudo ./create-user.sh <username>"
    log_info ""
    log_info "2. Copy the generated .ovpn file to the client:"
    log_info "   ../clients/<username>.ovpn"
    log_info ""
    log_info "3. Connect using an OpenVPN client"
    log_info ""
    log_info "Status check:"
    log_info "   ./status.sh"
    log_info ""
    log_info "View logs:"
    log_info "   docker compose logs -f openvpn"
    echo ""
}

# Run script
main "$@"
