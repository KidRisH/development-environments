# OpenVPN Server - Podman Setup

Bu klasör, state-aware (durum takipli) OpenVPN sunucu kurulumu ve yönetimi için gerekli scriptleri içerir.

## 📋 İçindekiler

- [Kurulum](#kurulum)
- [Kullanım](#kullanım)
- [Kullanıcı Yönetimi](#kullanıcı-yönetimi)
- [Troubleshooting](#troubleshooting)
- [State Yönetimi](#state-yönetimi)

---

## 🚀 Kurulum

### Gereksinimler

**Linux (Ubuntu/Debian/CentOS):**
- Podman 3.0+
- podman-compose veya podman compose
- Root veya sudo yetkisi
- Açık 1194/UDP portu

**Windows Server:**
- Podman for Windows
- PowerShell 5.1+
- Yönetici yetkisi
- Açık 1194/UDP portu

### Kurulum Adımları

#### Linux

```bash
# Linux klasörüne git
cd linux/

# Kurulum scriptini çalıştır
chmod +x setup.sh
sudo ./setup.sh
```

#### Windows

```powershell
# Windows klasörüne git
cd windows

# PowerShell'i yönetici olarak çalıştır
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
.\setup.ps1
```

### Kurulum Süreci

Script otomatik olarak şu adımları gerçekleştirir:

1. **Pre-checks** - Podman, port ve yetki kontrolü
2. **State Init** - Durum takip dosyası oluşturma
3. **Volume Creation** - openvpn-data ve logs klasörleri
4. **IP Detection** - Public IP otomatik algılama
5. **Container Start** - Podman container başlatma
6. **PKI Initialization** - OpenVPN config oluşturma
7. **CA Certificate** - Certificate Authority oluşturma
8. **Verification** - Kurulum doğrulama

**Önemli:** Herhangi bir adımda hata alırsanız, scripti tekrar çalıştırın. Kaldığı yerden devam edecektir.

---

## 📱 Kullanım

### Container Yönetimi

```bash
# Container durumu kontrol et
podman-compose ps  # veya: podman compose ps

# Logları izle
podman-compose logs -f openvpn  # veya: podman compose logs -f openvpn

# Container'ı durdur
podman-compose down  # veya: podman compose down

# Container'ı başlat
podman-compose up -d  # veya: podman compose up -d
```

---

## 👥 Kullanıcı Yönetimi

### Yeni Kullanıcı Oluşturma

#### Linux
```bash
cd linux/
chmod +x create-user.sh
sudo ./create-user.sh kullanici_adi
```

#### Windows
```powershell
cd windows
.\create-user.ps1 -Username "kullanici_adi"
```

Oluşturulan `.ovpn` dosyası `./clients/` klasöründe olacaktır.

### Kullanıcıları Listeleme

#### Linux
```bash
cd linux/
chmod +x list-users.sh
./list-users.sh
```

#### Windows
```powershell
cd windows
.\list-users.ps1
```

### Kullanıcı İptal Etme

#### Linux
```bash
cd linux/
chmod +x revoke-user.sh
sudo ./revoke-user.sh kullanici_adi
```

#### Windows
```powershell
cd windows
.\revoke-user.ps1 -Username "kullanici_adi"
```

---

## 🔍 Durum Kontrolü

### Sunucu Durumu

#### Linux
```bash
cd linux/
chmod +x status.sh
./status.sh
```

#### Windows
```powershell
cd windows
.\status.ps1
```

Bu komut şunları gösterir:
- Container durumu
- Port listen durumu
- Aktif bağlantılar
- Son 10 log satırı

---

## 🔧 Troubleshooting

### Otomatik Sorun Giderme

#### Linux
```bash
cd linux/
chmod +x troubleshoot.sh
sudo ./troubleshoot.sh
```

#### Windows
```powershell
cd windows
.\troubleshoot.ps1
```

### Yaygın Sorunlar

#### 1. Container Başlamıyor

**Çözüm:**
```bash
# Logları kontrol et
podman-compose logs openvpn  # veya: podman compose logs openvpn

# Container'ı yeniden başlat
podman-compose down  # veya: podman compose down
podman-compose up -d  # veya: podman compose up -d
```

#### 2. Port 1194 Kullanımda

**Çözüm:**
```bash
# Portu kullanan process'i bul (Linux)
sudo lsof -i :1194

# Portu kullanan process'i bul (Windows)
netstat -ano | findstr :1194
```

#### 3. IP Algılanamıyor

**Çözüm:**
Manuel olarak IP girin veya script tekrar çalıştırıldığında IP sorulduğunda girin.

#### 4. Client Bağlanamıyor

**Kontroller:**
- Sunucu IP/domain doğru mu?
- Firewall 1194/UDP portunu açık mı?
- Client .ovpn dosyası doğru mu?
- Container çalışıyor mu?

```bash
# Container çalışıyor mu?
podman-compose ps  # veya: podman compose ps

# Port dinliyor mu?
sudo netstat -tulpn | grep 1194  # Linux
netstat -ano | findstr :1194     # Windows
```

---

## 📊 State Yönetimi

### State Dosyası Yapısı

`.openvpn-state.json` dosyası kurulum ilerlemesini ve kullanıcı bilgilerini tutar:

```json
{
  "version": "1.0",
  "setup": {
    "status": "completed",
    "steps": { ... },
    "currentStep": "verification",
    "completed": true
  },
  "users": {
    "created": ["user1", "user2"],
    "revoked": ["old_user"]
  },
  "metadata": {
    "serverIP": "203.0.113.1",
    "port": "1194",
    "protocol": "udp"
  }
}
```

### State Sıfırlama

**Uyarı:** Bu işlem tüm kurulum durumunu sıfırlar. Kullanıcılar ve sertifikalar etkilenmez.

#### Linux
```bash
cd linux/
chmod +x reset-state.sh
sudo ./reset-state.sh
```

#### Windows
```powershell
cd windows
.\reset-state.ps1
```

---

## 📁 Klasör Yapısı

```
openvpn/
├── compose.yml                    # Podman Compose yapılandırması
├── .openvpn-state.json           # State tracking dosyası
├── README.md                      # Bu dosya
├── linux/                        # Linux scriptleri
│   ├── setup.sh                  # Kurulum scripti
│   ├── create-user.sh            # Kullanıcı oluşturma
│   ├── list-users.sh             # Kullanıcı listeleme
│   ├── revoke-user.sh            # Kullanıcı iptal etme
│   ├── status.sh                 # Durum kontrolü
│   ├── reset-state.sh            # State sıfırlama
│   └── troubleshoot.sh           # Sorun giderme
├── windows/                      # Windows scriptleri
│   ├── setup.ps1                 # Kurulum scripti
│   ├── create-user.ps1           # Kullanıcı oluşturma
│   ├── list-users.ps1            # Kullanıcı listeleme
│   ├── revoke-user.ps1           # Kullanıcı iptal etme
│   ├── status.ps1                # Durum kontrolü
│   ├── reset-state.ps1           # State sıfırlama
│   └── troubleshoot.ps1          # Sorun giderme
├── openvpn-data/                 # OpenVPN config ve sertifikalar
│   └── (otomatik oluşturulur)
├── logs/                         # OpenVPN logları
│   └── (otomatik oluşturulur)
└── clients/                      # Client .ovpn dosyaları
    └── (otomatik oluşturulur)
```

---

## 🔐 Güvenlik Notları

1. **Sertifika Yönetimi:**
   - `openvpn-data/` klasörünü düzenli yedekleyin
   - Private key'leri güvenli saklayın
   - `.ovpn` dosyalarını güvenli kanallardan paylaşın

2. **Firewall:**
   - Sadece 1194/UDP portunu açın
   - Gereksiz portları kapatın

3. **Güncellemeler:**
   - Container image'ini düzenli güncelleyin:
     ```bash
     podman-compose pull  # veya: podman compose pull
     podman-compose up -d  # veya: podman compose up -d
     ```

4. **Log Yönetimi:**
   - Logları düzenli kontrol edin
   - Disk alanını izleyin

---

## 📞 Destek

State dosyası sayesinde, herhangi bir aşamada hatayla karşılaşırsanız:

1. Hata mesajını not alın
2. State dosyasını kontrol edin: `.openvpn-state.json`
3. Script'i tekrar çalıştırın - kaldığı yerden devam edecek
4. Sorun devam ederse `troubleshoot` scriptini çalıştırın

---

## 📄 Lisans

Bu scriptler MIT lisansı altında sunulmaktadır.

---

## 🔄 Versiyon

- **Version:** 1.0
- **Son Güncelleme:** Mart 2026
- **Uyumluluk:** Docker 20.10+, kylemanna/openvpn:latest
