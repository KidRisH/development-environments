#!/bin/bash

###############################################################################
# OpenVPN User Revocation Script for Linux
# Kullanım: sudo ./revoke-user.sh <username>
###############################################################################

set -e

# Renkli output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Değişkenler
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

# Kullanıcı adı kontrolü
if [[ $# -ne 1 ]]; then
    log_error "Kullanım: sudo ./revoke-user.sh <username>"
    exit 1
fi

USERNAME="$1"

echo ""
echo "=========================================="
echo "  OpenVPN User Revocation"
echo "  Username: $USERNAME"
echo "=========================================="
echo ""

# Root kontrolü
if [[ $EUID -ne 0 ]]; then
    log_error "Bu script root veya sudo ile çalıştırılmalı!"
    exit 1
fi

# Container çalışıyor mu?
if [[ -z "$RUNTIME" ]]; then
    log_error "Docker veya Podman yüklü değil!"
    exit 1
fi
if ! $RUNTIME ps | grep -q "$CONTAINER_NAME"; then
    log_error "OpenVPN container çalışmıyor!"
    log_info "Container'ı başlatmak için: cd $BASE_DIR && $COMPOSE_CMD up -d"
    exit 1
fi

# PKI var mı?
if [[ ! -d "$DATA_DIR/pki" ]]; then
    log_error "PKI dizini bulunamadı!"
    exit 1
fi

# Kullanıcı sertifikası var mı?
if [[ ! -f "$DATA_DIR/pki/issued/${USERNAME}.crt" ]]; then
    log_error "Kullanıcı sertifikası bulunamadı: $USERNAME"
    exit 1
fi

# Zaten iptal edilmiş mi?
if grep -q "R.*\/CN=${USERNAME}" "$DATA_DIR/pki/index.txt" 2>/dev/null; then
    log_warning "Bu kullanıcı zaten iptal edilmiş!"
    exit 0
fi

# Onay al
log_warning "Bu işlem kullanıcının erişimini kalıcı olarak iptal edecek!"
log_info "Devam etmek istiyor musunuz? (y/N)"
read -r response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
    log_info "İptal edildi."
    exit 0
fi

log_info "Kullanıcı iptal ediliyor: $USERNAME"

# Sertifikayı iptal et
$RUNTIME run -v "$DATA_DIR:/etc/openvpn" --rm -it kylemanna/openvpn \
    easyrsa revoke "$USERNAME"

if [[ $? -ne 0 ]]; then
    log_error "Kullanıcı iptal edilemedi!"
    exit 1
fi

log_info "CRL (Certificate Revocation List) güncelleniyor..."

# CRL güncelle
$RUNTIME run -v "$DATA_DIR:/etc/openvpn" --rm kylemanna/openvpn \
    easyrsa gen-crl

if [[ $? -ne 0 ]]; then
    log_error "CRL güncellenemedi!"
    exit 1
fi

# Container'ı yeniden başlat
log_info "Container yeniden başlatılıyor..."
cd "$BASE_DIR"
$COMPOSE_CMD restart

log_info "Bekleyiniz..."
sleep 3

# .ovpn dosyasını sil veya yedekle
if [[ -f "$CLIENTS_DIR/${USERNAME}.ovpn" ]]; then
    BACKUP_DIR="$CLIENTS_DIR/revoked"
    mkdir -p "$BACKUP_DIR"
    
    mv "$CLIENTS_DIR/${USERNAME}.ovpn" "$BACKUP_DIR/${USERNAME}.ovpn.revoked"
    log_info ".ovpn dosyası taşındı: $BACKUP_DIR/${USERNAME}.ovpn.revoked"
fi

# State dosyasını güncelle
if [[ -f "$STATE_FILE" ]] && command -v jq &> /dev/null; then
    TMP_FILE=$(mktemp)
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    jq --arg username "$USERNAME" \
       --arg timestamp "$TIMESTAMP" \
       '.users.revoked += [{"username": $username, "revokedAt": $timestamp}] |
        .lastUpdated = $timestamp' \
        "$STATE_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$STATE_FILE"
    
    log_info "State dosyası güncellendi."
fi

echo ""
log_success "✓ Kullanıcı başarıyla iptal edildi!"
echo ""
log_info "Kullanıcı artık VPN'e bağlanamayacak."
log_info "CRL güncellendiği için mevcut bağlantılar kesilmiş olabilir."
echo ""
