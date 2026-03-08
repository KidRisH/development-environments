#!/bin/bash

###############################################################################
# OpenVPN Troubleshooting Script for Linux
# Kullanım: sudo ./troubleshoot.sh
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
DATA_DIR="$BASE_DIR/openvpn-data"
CONTAINER_NAME="OpenVPN-Server"

ISSUES_FOUND=0

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
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
}

log_fix() {
    echo -e "${CYAN}  → Fix:${NC} $1"
}

echo ""
echo "=========================================="
echo "  OpenVPN Troubleshooting"
echo "=========================================="
echo ""

# Root kontrolü
if [[ $EUID -ne 0 ]]; then
    log_warning "Bu script root veya sudo ile çalıştırılması önerilir"
    echo ""
fi

# 1. Container Runtime kontrolü
echo -e "${BLUE}[1] Container Runtime${NC}"
if [[ -z "$RUNTIME" ]]; then
    log_error "Docker veya Podman yüklü değil!"
    log_fix "Podman: https://podman.io/getting-started/installation"
    log_fix "Docker: https://docs.docker.com/get-docker/"
else
    RUNTIME_VERSION=$($RUNTIME --version)
    log_success "$RUNTIME yüklü: $RUNTIME_VERSION"

    if $RUNTIME info &> /dev/null; then
        log_success "$RUNTIME çalışıyor"
    else
        log_error "$RUNTIME çalışmıyor!"
        if [[ "$RUNTIME" == "docker" ]]; then
            log_fix "sudo systemctl start docker"
        else
            log_fix "Podman kurulumunu kontrol edin"
        fi
    fi

    if [[ "$RUNTIME" == "podman" ]]; then
        PODMAN_INFO=$(podman info 2>/dev/null)
        if echo "$PODMAN_INFO" | grep -q "rootless: true"; then
            log_warning "Podman ROOTLESS modda çalışıyor (TUN device sorunu yaşanabilir)"
            log_fix "podman machine stop && podman machine set --rootful && podman machine start"
        else
            log_success "Podman rootful modda çalışıyor"
        fi
    fi
fi
echo ""

# 2. Compose kontrolü
echo -e "${BLUE}[2] Compose Status${NC}"
if [[ -n "$COMPOSE_CMD" ]]; then
    log_success "Compose provider: $COMPOSE_CMD"
else
    log_error "Compose provider yüklü değil!"
    if [[ "$RUNTIME" == "docker" ]]; then
        log_fix "https://docs.docker.com/compose/install/"
    else
        log_fix "pip3 install podman-compose (veya podman compose built-in kullanın)"
    fi
fi
echo ""

# 3. Container durumu
echo -e "${BLUE}[3] Container Status${NC}"
if [[ -z "$RUNTIME" ]]; then
    log_warning "Container runtime yüklü olmadığı için kontrol atlanıyor"
else
    if $RUNTIME ps -a --format "{{.Names}}" | grep -q "$CONTAINER_NAME"; then
        if $RUNTIME ps --format "{{.Names}}" | grep -q "$CONTAINER_NAME"; then
            log_success "Container çalışıyor"

            # Container logs'da hata var mı?
            ERROR_COUNT=$($RUNTIME logs "$CONTAINER_NAME" 2>&1 | grep -i "error\|fail\|fatal" | wc -l)
            if [[ $ERROR_COUNT -gt 0 ]]; then
                log_warning "Container logs'da $ERROR_COUNT hata mesajı bulundu"
                log_fix "$RUNTIME logs $CONTAINER_NAME | grep -i error"
            fi
        else
            log_error "Container durdurulmuş"
            log_fix "cd $BASE_DIR && $COMPOSE_CMD up -d"
        fi
    else
        log_error "Container bulunamadı"
        log_fix "cd $SCRIPT_DIR && sudo ./setup.sh"
    fi
fi
echo ""

# 4. Port kontrolü
echo -e "${BLUE}[4] Network & Port Status${NC}"
if netstat -tuln 2>/dev/null | grep -q ":1194 " || ss -tuln 2>/dev/null | grep -q ":1194 "; then
    log_success "Port 1194/UDP dinleniyor"
else
    log_error "Port 1194/UDP dinlenmiyor"
    log_fix "Container çalışıyor mu kontrol edin: ${RUNTIME:-podman} ps"
    log_fix "Firewall kontrolü yapın (aşağıda)"
fi

# IP forwarding kontrolü
if [[ $(cat /proc/sys/net/ipv4/ip_forward) == "1" ]]; then
    log_success "IP forwarding aktif"
else
    log_warning "IP forwarding devre dışı"
    log_fix "sudo sysctl -w net.ipv4.ip_forward=1"
    log_fix "Kalıcı: echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf"
fi
echo ""

# 5. Firewall kontrolü
echo -e "${BLUE}[5] Firewall Status${NC}"
if command -v ufw &> /dev/null; then
    if ufw status | grep -q "Status: active"; then
        log_info "UFW aktif"
        
        if ufw status | grep -q "1194/udp"; then
            log_success "UFW'de 1194/UDP portu açık"
        else
            log_warning "UFW'de 1194/UDP portu kapalı olabilir"
            log_fix "sudo ufw allow 1194/udp"
        fi
    else
        log_info "UFW devre dışı"
    fi
elif command -v firewall-cmd &> /dev/null; then
    if firewall-cmd --state 2>/dev/null | grep -q "running"; then
        log_info "Firewalld aktif"
        
        if firewall-cmd --list-ports 2>/dev/null | grep -q "1194/udp"; then
            log_success "Firewalld'de 1194/UDP portu açık"
        else
            log_warning "Firewalld'de 1194/UDP portu kapalı olabilir"
            log_fix "sudo firewall-cmd --permanent --add-port=1194/udp"
            log_fix "sudo firewall-cmd --reload"
        fi
    else
        log_info "Firewalld devre dışı"
    fi
else
    log_info "Bilinen bir firewall bulunamadı (ufw/firewalld)"
fi
echo ""

# 6. PKI/Sertifika kontrolü
echo -e "${BLUE}[6] PKI & Certificates${NC}"
if [[ -d "$DATA_DIR/pki" ]]; then
    log_success "PKI dizini mevcut"
    
    if [[ -f "$DATA_DIR/pki/ca.crt" ]]; then
        log_success "CA sertifikası mevcut"
        
        # CA sertifikası geçerli mi?
        if command -v openssl &> /dev/null; then
            if openssl x509 -in "$DATA_DIR/pki/ca.crt" -noout -checkend 0 &> /dev/null; then
                log_success "CA sertifikası geçerli"
            else
                log_error "CA sertifikası süresi dolmuş veya geçersiz"
                log_fix "Yeni PKI oluşturmanız gerekebilir"
            fi
        fi
    else
        log_error "CA sertifikası bulunamadı"
        log_fix "cd $SCRIPT_DIR && sudo ./setup.sh (PKI initialization)"
    fi
    
    if [[ -f "$DATA_DIR/pki/issued/server.crt" ]]; then
        log_success "Sunucu sertifikası mevcut"
    else
        log_error "Sunucu sertifikası bulunamadı"
        log_fix "PKI yeniden oluşturulmalı"
    fi
else
    log_error "PKI dizini bulunamadı"
    log_fix "cd $SCRIPT_DIR && sudo ./setup.sh"
fi
echo ""

# 7. Config dosyası kontrolü
echo -e "${BLUE}[7] Configuration Files${NC}"
if [[ -f "$DATA_DIR/openvpn.conf" ]]; then
    log_success "OpenVPN config dosyası mevcut"
    
    # Config'de server IP var mı?
    if grep -q "proto udp" "$DATA_DIR/openvpn.conf"; then
        log_success "Protokol: UDP"
    fi
    
    if grep -q "port 1194" "$DATA_DIR/openvpn.conf"; then
        log_success "Port: 1194"
    fi
else
    log_error "openvpn.conf bulunamadı"
    log_fix "cd $SCRIPT_DIR && sudo ./setup.sh"
fi
echo ""

# 8. Disk alanı kontrolü
echo -e "${BLUE}[8] Disk Space${NC}"
DISK_USAGE=$(df -h "$BASE_DIR" | tail -1 | awk '{print $5}' | sed 's/%//')
if [[ $DISK_USAGE -lt 90 ]]; then
    log_success "Disk alanı yeterli (${DISK_USAGE}% kullanımda)"
else
    log_warning "Disk alanı az (${DISK_USAGE}% kullanımda)"
    log_fix "Gereksiz dosyaları temizleyin"
    log_fix "${RUNTIME:-podman} system prune -a"
fi
echo ""

# 9. State dosyası kontrolü
echo -e "${BLUE}[9] State File${NC}"
if [[ -f "$STATE_FILE" ]]; then
    log_success "State dosyası mevcut"
    
    if command -v jq &> /dev/null; then
        SETUP_COMPLETED=$(jq -r '.setup.completed' "$STATE_FILE" 2>/dev/null)
        
        if [[ "$SETUP_COMPLETED" == "true" ]]; then
            log_success "Kurulum tamamlanmış"
        else
            log_warning "Kurulum tamamlanmamış"
            
            CURRENT_STEP=$(jq -r '.setup.currentStep' "$STATE_FILE" 2>/dev/null)
            if [[ "$CURRENT_STEP" != "null" ]]; then
                log_info "Son adım: $CURRENT_STEP"
                
                STEP_STATUS=$(jq -r ".setup.steps.$CURRENT_STEP.status" "$STATE_FILE" 2>/dev/null)
                if [[ "$STEP_STATUS" == "failed" ]]; then
                    STEP_ERROR=$(jq -r ".setup.steps.$CURRENT_STEP.error" "$STATE_FILE" 2>/dev/null)
                    log_error "Son adımda hata: $STEP_ERROR"
                fi
            fi
            
            log_fix "cd $SCRIPT_DIR && sudo ./setup.sh (kaldığı yerden devam edecek)"
        fi
    else
        log_warning "jq yüklü değil, detaylı state analizi yapılamıyor"
        log_fix "sudo apt-get install jq  (Ubuntu/Debian)"
    fi
else
    log_error "State dosyası bulunamadı"
    log_fix "Template'ten .openvpn-state.json oluşturun"
fi
echo ""

# 10. Son log kontrolü
echo -e "${BLUE}[10] Recent Errors in Logs${NC}"
if [[ -z "$RUNTIME" ]]; then
    log_info "Container runtime yüklü olmadığı için log kontrolü yapılamadı"
elif $RUNTIME ps --format "{{.Names}}" | grep -q "$CONTAINER_NAME"; then
    RECENT_ERRORS=$($RUNTIME logs "$CONTAINER_NAME" --tail=50 2>&1 | grep -i "error\|fail\|fatal" | tail -5)
    
    if [[ -z "$RECENT_ERRORS" ]]; then
        log_success "Son loglarda önemli hata yok"
    else
        log_warning "Son loglarda hatalar bulundu:"
        echo "$RECENT_ERRORS" | while IFS= read -r line; do
            echo "    $line"
        done
        log_fix "$RUNTIME logs $CONTAINER_NAME (tüm log'ları görmek için)"
    fi
else
    log_info "Container çalışmıyor, log kontrolü yapılamadı"
fi
echo ""

# Özet
echo "=========================================="
if [[ $ISSUES_FOUND -eq 0 ]]; then
    echo -e "${GREEN}✓ Hiçbir sorun bulunamadı!${NC}"
else
    echo -e "${YELLOW}! $ISSUES_FOUND sorun/uyarı bulundu${NC}"
    echo -e "Yukarıdaki ${CYAN}'→ Fix:'${NC} önerilerini takip edin."
fi
echo "=========================================="
echo ""

exit $ISSUES_FOUND
