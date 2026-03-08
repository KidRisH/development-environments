#!/bin/bash

###############################################################################
# OpenVPN Users List Script for Linux
# Kullanım: ./list-users.sh
###############################################################################

# Renkli output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Değişkenler
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DATA_DIR="$BASE_DIR/openvpn-data"
CLIENTS_DIR="$BASE_DIR/clients"
STATE_FILE="$BASE_DIR/.openvpn-state.json"

echo ""
echo "=========================================="
echo "  OpenVPN Users"
echo "=========================================="
echo ""

# PKI dizini var mı?
if [[ ! -d "$DATA_DIR/pki/issued" ]]; then
    echo -e "${RED}[ERROR]${NC} PKI dizini bulunamadı! Önce setup scriptini çalıştırın."
    exit 1
fi

# Sertifikalar
echo -e "${BLUE}Issued Certificates:${NC}"
echo ""

CERT_COUNT=0
for cert in "$DATA_DIR/pki/issued"/*.crt; do
    if [[ -f "$cert" ]]; then
        filename=$(basename "$cert" .crt)
        
        # Server sertifikasını atla
        if [[ "$filename" == "server" ]]; then
            continue
        fi
        
        CERT_COUNT=$((CERT_COUNT + 1))
        
        # Sertifika bilgilerini al
        if command -v openssl &> /dev/null; then
            ISSUE_DATE=$(openssl x509 -in "$cert" -noout -startdate 2>/dev/null | cut -d'=' -f2)
            EXPIRE_DATE=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d'=' -f2)
        else
            ISSUE_DATE="N/A"
            EXPIRE_DATE="N/A"
        fi
        
        # .ovpn dosyası var mı?
        OVPN_STATUS="❌"
        if [[ -f "$CLIENTS_DIR/${filename}.ovpn" ]]; then
            OVPN_STATUS="✓"
        fi
        
        echo -e "  ${GREEN}●${NC} ${CYAN}$filename${NC}"
        echo "    Issued:  $ISSUE_DATE"
        echo "    Expires: $EXPIRE_DATE"
        echo "    .ovpn:   $OVPN_STATUS"
        echo ""
    fi
done

if [[ $CERT_COUNT -eq 0 ]]; then
    echo -e "  ${YELLOW}No users found.${NC}"
    echo ""
fi

# İptal edilen sertifikalar
echo -e "${BLUE}Revoked Certificates:${NC}"
echo ""

REVOKED_COUNT=0
if [[ -f "$DATA_DIR/pki/index.txt" ]]; then
    while IFS= read -r line; do
        if [[ "$line" == R* ]]; then
            # Format: R	date	revoke_date	serial	unknown	/CN=username
            USERNAME=$(echo "$line" | sed -n 's/.*\/CN=\([^/]*\).*/\1/p')
            if [[ -n "$USERNAME" ]] && [[ "$USERNAME" != "server" ]]; then
                REVOKED_COUNT=$((REVOKED_COUNT + 1))
                echo -e "  ${RED}●${NC} $USERNAME (revoked)"
            fi
        fi
    done < "$DATA_DIR/pki/index.txt"
fi

if [[ $REVOKED_COUNT -eq 0 ]]; then
    echo -e "  ${YELLOW}No revoked users.${NC}"
fi

echo ""
echo "=========================================="
echo -e "Total Active Users: ${GREEN}$CERT_COUNT${NC}"
echo -e "Total Revoked Users: ${RED}$REVOKED_COUNT${NC}"
echo "=========================================="
echo ""

# .ovpn dosyaları listesi
if [[ -d "$CLIENTS_DIR" ]]; then
    OVPN_COUNT=$(find "$CLIENTS_DIR" -name "*.ovpn" 2>/dev/null | wc -l)
    echo -e "${BLUE}Available .ovpn files:${NC} $OVPN_COUNT"
    
    if [[ $OVPN_COUNT -gt 0 ]]; then
        for ovpn in "$CLIENTS_DIR"/*.ovpn; do
            if [[ -f "$ovpn" ]]; then
                filename=$(basename "$ovpn")
                filesize=$(du -h "$ovpn" | cut -f1)
                echo "  - $filename ($filesize)"
            fi
        done
    fi
    echo ""
fi

# State dosyasından bilgi
if [[ -f "$STATE_FILE" ]] && command -v jq &> /dev/null; then
    echo -e "${BLUE}State File Info:${NC}"
    
    CREATED_COUNT=$(jq '.users.created | length' "$STATE_FILE" 2>/dev/null || echo "0")
    echo "  Users in state: $CREATED_COUNT"
    
    SERVER_IP=$(jq -r '.metadata.serverIP' "$STATE_FILE" 2>/dev/null || echo "N/A")
    echo "  Server IP: $SERVER_IP"
    
    SETUP_STATUS=$(jq -r '.setup.status' "$STATE_FILE" 2>/dev/null || echo "unknown")
    echo "  Setup Status: $SETUP_STATUS"
    echo ""
fi
