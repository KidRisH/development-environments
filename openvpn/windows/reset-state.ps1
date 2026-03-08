<#
.SYNOPSIS
    Reset OpenVPN State

.DESCRIPTION
    Kurulum state dosyasını sıfırlar. Sertifikalar ve kullanıcılar etkilenmez.

.EXAMPLE
    .\reset-state.ps1

.NOTES
    Yönetici yetkisi gerektirir.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$BaseDir = Split-Path $ScriptDir -Parent
$StateFile = Join-Path $BaseDir ".openvpn-state.json"

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )
    
    switch ($Type) {
        "Info"    { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
        "Success" { Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
        "Warning" { Write-Host "[WARNING] $Message" -ForegroundColor Yellow }
        "Error"   { Write-Host "[ERROR] $Message" -ForegroundColor Red }
    }
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  OpenVPN State Reset" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# State dosyası var mı?
if (-not (Test-Path $StateFile)) {
    Write-ColorOutput "State dosyası bulunamadı: $StateFile" -Type Error
    exit 1
}

Write-ColorOutput "Bu işlem kurulum state'ini sıfırlayacak!" -Type Warning
Write-ColorOutput "OpenVPN konfigürasyonu, sertifikalar ve kullanıcılar ETKİLENMEYECEK." -Type Info
Write-ColorOutput "Sadece kurulum durumu sıfırlanacak ve setup script'i baştan çalıştırılabilecek." -Type Info
Write-Host ""

$response = Read-Host "Devam etmek istiyor musunuz? (Y/N)"

if ($response -notmatch '^[Yy]$') {
    Write-ColorOutput "İptal edildi." -Type Info
    exit 0
}

# Backup oluştur
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupFile = "${StateFile}.backup-${timestamp}"

Write-ColorOutput "State dosyası yedekleniyor: $backupFile" -Type Info
Copy-Item -Path $StateFile -Destination $backupFile -Force

# State dosyasını sıfırla
Write-ColorOutput "State dosyası sıfırlanıyor..." -Type Info

$newState = @{
    version = "1.0"
    lastUpdated = $null
    setup = @{
        status = "not-started"
        steps = @{
            precheck = @{
                status = "pending"
                timestamp = $null
                error = $null
            }
            state_init = @{
                status = "pending"
                timestamp = $null
                error = $null
            }
            create_volumes = @{
                status = "pending"
                timestamp = $null
                error = $null
            }
            detect_ip = @{
                status = "pending"
                timestamp = $null
                error = $null
                detected_ip = $null
            }
            start_container = @{
                status = "pending"
                timestamp = $null
                error = $null
            }
            pki_init = @{
                status = "pending"
                timestamp = $null
                error = $null
            }
            generate_ca = @{
                status = "pending"
                timestamp = $null
                error = $null
            }
            verification = @{
                status = "pending"
                timestamp = $null
                error = $null
            }
        }
        currentStep = $null
        completed = $false
    }
    users = @{
        created = @()
        revoked = @()
    }
    metadata = @{
        serverIP = $null
        port = "1194"
        protocol = "udp"
        dns = @("1.1.1.1", "1.0.0.1")
        createdAt = $null
        lastModified = $null
    }
}

$newState | ConvertTo-Json -Depth 10 | Set-Content $StateFile -Encoding UTF8

Write-Host ""
Write-ColorOutput "✓ State dosyası sıfırlandı!" -Type Success
Write-Host ""
Write-ColorOutput "Backup dosyası: $backupFile" -Type Info
Write-Host ""
Write-ColorOutput "Şimdi setup script'ini tekrar çalıştırabilirsiniz:" -Type Info
Write-Host "  .\windows\setup.ps1" -ForegroundColor White
Write-Host ""
