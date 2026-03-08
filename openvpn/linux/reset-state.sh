#!/bin/bash

###############################################################################
# OpenVPN State Reset Script for Linux
# Kullanım: sudo ./reset-state.sh
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

echo ""
echo "=========================================="
echo "  OpenVPN State Reset"
echo "=========================================="
echo ""

# Root kontrolü
if [[ $EUID -ne 0 ]]; then
    log_error "Bu script root veya sudo ile çalıştırılmalı!"
    exit 1
fi

# State dosyası var mı?
if [[ ! -f "$STATE_FILE" ]]; then
    log_error "State dosyası bulunamadı: $STATE_FILE"
    exit 1
fi

log_warning "Bu işlem kurulum state'ini sıfırlayacak!"
log_info "OpenVPN konfigürasyonu, sertifikalar ve kullanıcılar ETKİLENMEYECEK."
log_info "Sadece kurulum durumu sıfırlanacak ve setup script'i baştan çalıştırılabilecek."
echo ""
log_warning "Devam etmek istiyor musunuz? (y/N)"
read -r response

if [[ ! "$response" =~ ^[Yy]$ ]]; then
    log_info "İptal edildi."
    exit 0
fi

# Backup oluştur
BACKUP_FILE="${STATE_FILE}.backup-$(date +%Y%m%d-%H%M%S)"
log_info "State dosyası yedekleniyor: $BACKUP_FILE"
cp "$STATE_FILE" "$BACKUP_FILE"

# State dosyasını sıfırla
log_info "State dosyası sıfırlanıyor..."

cat > "$STATE_FILE" << 'EOF'
{
  "version": "1.0",
  "lastUpdated": null,
  "setup": {
    "status": "not-started",
    "steps": {
      "precheck": {
        "status": "pending",
        "timestamp": null,
        "error": null
      },
      "state_init": {
        "status": "pending",
        "timestamp": null,
        "error": null
      },
      "create_volumes": {
        "status": "pending",
        "timestamp": null,
        "error": null
      },
      "detect_ip": {
        "status": "pending",
        "timestamp": null,
        "error": null,
        "detected_ip": null
      },
      "start_container": {
        "status": "pending",
        "timestamp": null,
        "error": null
      },
      "pki_init": {
        "status": "pending",
        "timestamp": null,
        "error": null
      },
      "generate_ca": {
        "status": "pending",
        "timestamp": null,
        "error": null
      },
      "verification": {
        "status": "pending",
        "timestamp": null,
        "error": null
      }
    },
    "currentStep": null,
    "completed": false
  },
  "users": {
    "created": [],
    "revoked": []
  },
  "metadata": {
    "serverIP": null,
    "port": "1194",
    "protocol": "udp",
    "dns": ["1.1.1.1", "1.0.0.1"],
    "createdAt": null,
    "lastModified": null
  }
}
EOF

echo ""
log_success "✓ State dosyası sıfırlandı!"
echo ""
log_info "Backup dosyası: $BACKUP_FILE"
log_info ""
log_info "Şimdi setup script'ini tekrar çalıştırabilirsiniz:"
log_info "  sudo ./setup.sh"
echo ""
