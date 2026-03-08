<#
.SYNOPSIS
    Revoke OpenVPN user certificate

.DESCRIPTION
    Kullanıcı sertifikasını iptal eder ve erişimi engeller.

.PARAMETER Username
    İptal edilecek kullanıcı adı

.EXAMPLE
    .\revoke-user.ps1 -Username "john"

.NOTES
    Yönetici yetkisi gerektirir.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Username
)

$ErrorActionPreference = "Stop"

# Değişkenler
$ScriptDir = $PSScriptRoot
$BaseDir = Split-Path $ScriptDir -Parent
$StateFile = Join-Path $BaseDir ".openvpn-state.json"
$DataDir = Join-Path $BaseDir "openvpn-data"
$ClientsDir = Join-Path $BaseDir "clients"
$ComposeFile = Join-Path $BaseDir "compose.yml"
$ContainerName = "OpenVPN-Server"

###############################################################################
# Runtime Detection
###############################################################################
$script:_RUNTIME     = $null
$script:_COMPOSE_CMD = $null

function Get-ContainerRuntime {
    if ($script:_RUNTIME) { return $script:_RUNTIME }
    if (Get-Command podman -ErrorAction SilentlyContinue) { $script:_RUNTIME = "podman"; return "podman" }
    if (Get-Command docker -ErrorAction SilentlyContinue) { $script:_RUNTIME = "docker"; return "docker" }
    return $null
}

function Get-ComposeCommand {
    if ($script:_COMPOSE_CMD) { return $script:_COMPOSE_CMD }
    $r = Get-ContainerRuntime
    if (-not $r) { return $null }
    if ($r -eq "podman") {
        if (Get-Command podman-compose -ErrorAction SilentlyContinue) { $script:_COMPOSE_CMD = "podman-compose"; return $script:_COMPOSE_CMD }
        $null = & podman compose version 2>&1
        if ($LASTEXITCODE -eq 0) { $script:_COMPOSE_CMD = "podman compose"; return $script:_COMPOSE_CMD }
    } else {
        if (Get-Command docker-compose -ErrorAction SilentlyContinue) { $script:_COMPOSE_CMD = "docker-compose"; return $script:_COMPOSE_CMD }
        $null = & docker compose version 2>&1
        if ($LASTEXITCODE -eq 0) { $script:_COMPOSE_CMD = "docker compose"; return $script:_COMPOSE_CMD }
    }
    return $null
}

$runtime = Get-ContainerRuntime

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
Write-Host "  OpenVPN User Revocation" -ForegroundColor Cyan
Write-Host "  Username: $Username" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Container çalışıyor mu?
if (-not $runtime) {
    Write-ColorOutput "Docker veya Podman yuklu degil!" -Type Error
    exit 1
}
$running = & $runtime ps --filter "name=$ContainerName" --format "{{.Names}}" 2>$null
if ($running -notcontains $ContainerName) {
    Write-ColorOutput "OpenVPN container çalışmıyor!" -Type Error
    Write-ColorOutput "Container'ı başlatmak için: cd ..; $runtime compose up -d" -Type Info
    exit 1
}

# PKI var mı?
$pkiDir = Join-Path $DataDir "pki"
if (-not (Test-Path $pkiDir)) {
    Write-ColorOutput "PKI dizini bulunamadı!" -Type Error
    exit 1
}

# Kullanıcı sertifikası var mı?
$certFile = Join-Path $DataDir "pki\issued\${Username}.crt"
if (-not (Test-Path $certFile)) {
    Write-ColorOutput "Kullanıcı sertifikası bulunamadı: $Username" -Type Error
    exit 1
}

# Zaten iptal edilmiş mi?
$indexFile = Join-Path $DataDir "pki\index.txt"
if (Test-Path $indexFile) {
    $indexContent = Get-Content $indexFile -Raw
    if ($indexContent -match "R.*\/CN=${Username}") {
        Write-ColorOutput "Bu kullanıcı zaten iptal edilmiş!" -Type Warning
        exit 0
    }
}

# Onay al
Write-ColorOutput "Bu işlem kullanıcının erişimini kalıcı olarak iptal edecek!" -Type Warning
$response = Read-Host "Devam etmek istiyor musunuz? (Y/N)"
if ($response -notmatch '^[Yy]$') {
    Write-ColorOutput "İptal edildi." -Type Info
    exit 0
}

Write-ColorOutput "Kullanıcı iptal ediliyor: $Username" -Type Info

try {
    # Sertifikayı iptal et
    $dataVolume = "${DataDir}:/etc/openvpn"
    
    & $runtime run -v $dataVolume --rm -it kylemanna/openvpn `
        easyrsa revoke $Username
    
    if ($LASTEXITCODE -ne 0) {
        throw "Kullanıcı iptal edilemedi"
    }
    
    Write-ColorOutput "CRL (Certificate Revocation List) güncelleniyor..." -Type Info
    
    # CRL güncelle
    & $runtime run -v $dataVolume --rm kylemanna/openvpn `
        easyrsa gen-crl
    
    if ($LASTEXITCODE -ne 0) {
        throw "CRL güncellenemedi"
    }
    
    # Container'ı yeniden başlat
    Write-ColorOutput "Container yeniden başlatılıyor..." -Type Info
    Push-Location $BaseDir
    $cc = Get-ComposeCommand
    Invoke-Expression "$cc restart"
    Pop-Location
    
    Write-ColorOutput "Bekleyiniz..." -Type Info
    Start-Sleep -Seconds 3
    
    # .ovpn dosyasını sil veya yedekle
    $ovpnFile = Join-Path $ClientsDir "${Username}.ovpn"
    if (Test-Path $ovpnFile) {
        $backupDir = Join-Path $ClientsDir "revoked"
        if (-not (Test-Path $backupDir)) {
            New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
        }
        
        $backupFile = Join-Path $backupDir "${Username}.ovpn.revoked"
        Move-Item -Path $ovpnFile -Destination $backupFile -Force
        Write-ColorOutput ".ovpn dosyası taşındı: $backupFile" -Type Info
    }
    
    # State dosyasını güncelle
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content $StateFile -Raw | ConvertFrom-Json
            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            
            $revokedUser = @{
                username = $Username
                revokedAt = $timestamp
            }
            
            $state.users.revoked += $revokedUser
            $state.lastUpdated = $timestamp
            
            $state | ConvertTo-Json -Depth 10 | Set-Content $StateFile -Encoding UTF8
            
            Write-ColorOutput "State dosyası güncellendi." -Type Info
        } catch {
            Write-ColorOutput "State güncellenemedi (önemli değil): $($_.Exception.Message)" -Type Warning
        }
    }
    
    Write-Host ""
    Write-ColorOutput "✓ Kullanıcı başarıyla iptal edildi!" -Type Success
    Write-Host ""
    Write-ColorOutput "Kullanıcı artık VPN'e bağlanamayacak." -Type Info
    Write-ColorOutput "CRL güncellendiği için mevcut bağlantılar kesilmiş olabilir." -Type Info
    Write-Host ""
    
} catch {
    Write-ColorOutput "Hata oluştu: $($_.Exception.Message)" -Type Error
    exit 1
}
