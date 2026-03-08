#!/bin/bash

###############################################################################
# OpenVPN User Creation Script for Linux
# Usage: sudo ./create-user.sh <username>
###############################################################################

set -e

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
DATA_DIR="$BASE_DIR/openvpn-data"
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

# Argument check
if [[ $# -ne 1 ]]; then
    log_error "Usage: sudo ./create-user.sh <username>"
    exit 1
fi

USERNAME="$1"

# Username validation
if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_error "Invalid username! Only letters, numbers, hyphens, and underscores are allowed."
    exit 1
fi

echo ""
echo "=========================================="
echo "  OpenVPN User Creation"
echo "  Username: $USERNAME"
echo "=========================================="
echo ""

# Root check
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root or with sudo!"
    exit 1
fi

# Is container running?
if [[ -z "$RUNTIME" ]]; then
    log_error "Docker or Podman not installed!"
    exit 1
fi
if ! $RUNTIME ps | grep -q "$CONTAINER_NAME"; then
    log_error "OpenVPN container is not running!"
    log_info "To start: cd $BASE_DIR && $COMPOSE_CMD up -d"
    exit 1
fi

# PKI directory check
if [[ ! -d "$DATA_DIR/pki" ]]; then
    log_error "PKI directory not found! Run the setup script first."
    exit 1
fi

# Create clients directory if it doesn't exist
mkdir -p "$CLIENTS_DIR"

# User already exists?
if [[ -f "$CLIENTS_DIR/${USERNAME}.ovpn" ]]; then
    log_warning "This user already exists: ${USERNAME}.ovpn"
    log_info "Recreate anyway? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Cancelled."
        exit 0
    fi
fi

log_info "Generating user certificate: $USERNAME"
log_warning "This may take a few seconds..."

# Generate client certificate (nopass)
$RUNTIME run -v "$DATA_DIR:/etc/openvpn" --rm -it kylemanna/openvpn \
    easyrsa build-client-full "$USERNAME" nopass

if [[ $? -ne 0 ]]; then
    log_error "Certificate generation failed!"
    exit 1
fi

log_info "Generating .ovpn file..."

# Generate .ovpn file
$RUNTIME run -v "$DATA_DIR:/etc/openvpn" --rm kylemanna/openvpn \
    ovpn_getclient "$USERNAME" > "$CLIENTS_DIR/${USERNAME}.ovpn"

if [[ $? -ne 0 ]] || [[ ! -f "$CLIENTS_DIR/${USERNAME}.ovpn" ]]; then
    log_error ".ovpn file generation failed!"
    exit 1
fi

# Update state file
if [[ -f "$STATE_FILE" ]] && command -v jq &> /dev/null; then
    TMP_FILE=$(mktemp)
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    jq --arg username "$USERNAME" \
       --arg timestamp "$TIMESTAMP" \
       '.users.created += [{"username": $username, "createdAt": $timestamp}] | 
        .lastUpdated = $timestamp' \
        "$STATE_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$STATE_FILE"
    
    log_info "State file updated."
fi

echo ""
log_success "✓ User created successfully!"
echo ""
log_info "Client configuration file:"
echo "  $CLIENTS_DIR/${USERNAME}.ovpn"
echo ""
log_info "Copy this file to the client and import it with OpenVPN."
echo ""
log_info "Windows: OpenVPN GUI → Import file"
log_info "Linux: sudo openvpn --config ${USERNAME}.ovpn"
log_info "Mobile: Import via QR code or file"
echo ""
