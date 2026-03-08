#!/bin/bash

###############################################################################
# OpenVPN Status Check Script for Linux
# Kullanım: ./status.sh
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
STATE_FILE="$BASE_DIR/.openvpn-state.json"
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

echo ""
echo "=========================================="
echo "  OpenVPN Status"
echo "=========================================="
echo ""

# Container durumu
echo -e "${BLUE}Container Status:${NC}"
if [[ -z "$RUNTIME" ]]; then
    echo -e "  ${RED}✗ Docker veya Podman yüklü değil!${NC}"
else
    if $RUNTIME ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -q "$CONTAINER_NAME"; then
        $RUNTIME ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep "$CONTAINER_NAME"
        echo -e "  ${GREEN}✓ Container is running${NC}"
    else
        echo -e "  ${RED}✗ Container is not running${NC}"
        if $RUNTIME ps -a --format "{{.Names}}" | grep -q "$CONTAINER_NAME"; then
            echo -e "  ${YELLOW}Container exists but is stopped${NC}"
            echo -e "  ${BLUE}Start with: cd $BASE_DIR && $COMPOSE_CMD up -d${NC}"
        else
            echo -e "  ${YELLOW}Container does not exist${NC}"
            echo -e "  ${BLUE}Run: sudo ./setup.sh${NC}"
        fi
    fi
fi
echo ""

# Port durumu
echo -e "${BLUE}Port Status:${NC}"
if netstat -tuln 2>/dev/null | grep -q ":1194 " || ss -tuln 2>/dev/null | grep -q ":1194 "; then
    echo -e "  ${GREEN}✓ Port 1194/UDP is listening${NC}"
    
    # Hangi process kullanıyor?
    if command -v lsof &> /dev/null; then
        PROCESS=$(sudo lsof -i :1194 2>/dev/null | tail -n +2 | head -1)
        if [[ -n "$PROCESS" ]]; then
            echo "  Process: $PROCESS"
        fi
    fi
else
    echo -e "  ${RED}✗ Port 1194/UDP is not listening${NC}"
fi
echo ""

# Aktif bağlantılar
echo -e "${BLUE}Active Connections:${NC}"
if [[ -n "$RUNTIME" ]] && $RUNTIME exec "$CONTAINER_NAME" cat /etc/openvpn/openvpn-status.log 2>/dev/null | grep -q "CLIENT_LIST"; then
    CLIENT_COUNT=$($RUNTIME exec "$CONTAINER_NAME" cat /etc/openvpn/openvpn-status.log 2>/dev/null | grep "^CLIENT_LIST" | wc -l)
    
    if [[ $CLIENT_COUNT -gt 1 ]]; then
        # İlk satır header, gerçek client sayısı 1 eksik
        REAL_COUNT=$((CLIENT_COUNT - 1))
        echo -e "  ${GREEN}Active Clients: $REAL_COUNT${NC}"
        echo ""
        $RUNTIME exec "$CONTAINER_NAME" cat /etc/openvpn/openvpn-status.log 2>/dev/null | grep "^CLIENT_LIST" | tail -n +2 | while IFS=',' read -r _ cn real_ip _ bytes_recv bytes_sent _ since _; do
            echo "    • $cn"
            echo "      IP: $real_ip"
            echo "      Connected since: $since"
            echo "      Data: ↓$(numfmt --to=iec-i --suffix=B $bytes_recv 2>/dev/null || echo $bytes_recv) / ↑$(numfmt --to=iec-i --suffix=B $bytes_sent 2>/dev/null || echo $bytes_sent)"
            echo ""
        done
    else
        echo -e "  ${YELLOW}No active connections${NC}"
    fi
else
    echo -e "  ${YELLOW}Unable to read status log${NC}"
fi
echo ""

# Son 10 log satırı
echo -e "${BLUE}Recent Logs (last 10 lines):${NC}"
if [[ -n "$COMPOSE_CMD" ]]; then
    (cd "$BASE_DIR" && $COMPOSE_CMD logs --tail=10 openvpn 2>/dev/null | sed 's/^/  /')
fi
echo ""

# State dosyası bilgileri
if [[ -f "$STATE_FILE" ]]; then
    echo -e "${BLUE}State File Info:${NC}"
    
    if command -v jq &> /dev/null; then
        SETUP_STATUS=$(jq -r '.setup.status' "$STATE_FILE" 2>/dev/null)
        SETUP_COMPLETED=$(jq -r '.setup.completed' "$STATE_FILE" 2>/dev/null)
        SERVER_IP=$(jq -r '.metadata.serverIP' "$STATE_FILE" 2>/dev/null)
        USERS_COUNT=$(jq '.users.created | length' "$STATE_FILE" 2>/dev/null)
        REVOKED_COUNT=$(jq '.users.revoked | length' "$STATE_FILE" 2>/dev/null)
        LAST_UPDATED=$(jq -r '.lastUpdated' "$STATE_FILE" 2>/dev/null)
        
        echo "  Setup Status: $SETUP_STATUS"
        echo "  Setup Completed: $SETUP_COMPLETED"
        echo "  Server IP: $SERVER_IP"
        echo "  Total Users Created: $USERS_COUNT"
        echo "  Total Users Revoked: $REVOKED_COUNT"
        echo "  Last Updated: $LAST_UPDATED"
    else
        echo "  Install jq for detailed state info: sudo apt-get install jq"
    fi
else
    echo -e "  ${YELLOW}State file not found${NC}"
fi
echo ""

# Disk kullanımı
echo -e "${BLUE}Disk Usage:${NC}"
if [[ -d "$BASE_DIR/openvpn-data" ]]; then
    DATA_SIZE=$(du -sh "$BASE_DIR/openvpn-data" 2>/dev/null | cut -f1)
    echo "  OpenVPN Data: $DATA_SIZE"
fi
if [[ -d "$BASE_DIR/logs" ]]; then
    LOGS_SIZE=$(du -sh "$BASE_DIR/logs" 2>/dev/null | cut -f1)
    echo "  Logs: $LOGS_SIZE"
fi
if [[ -d "$BASE_DIR/clients" ]]; then
    CLIENTS_SIZE=$(du -sh "$BASE_DIR/clients" 2>/dev/null | cut -f1)
    CLIENTS_COUNT=$(find "$BASE_DIR/clients" -name "*.ovpn" 2>/dev/null | wc -l)
    echo "  Clients: $CLIENTS_SIZE ($CLIENTS_COUNT .ovpn files)"
fi
echo ""

echo "=========================================="
echo ""
