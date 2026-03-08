<#
.SYNOPSIS
    List OpenVPN users

.DESCRIPTION
    OpenVPN kullanıcılarını ve sertifikalarını listeler.

.EXAMPLE
    .\list-users.ps1
#>

[CmdletBinding()]
param()

$ScriptDir = $PSScriptRoot
$BaseDir = Split-Path $ScriptDir -Parent
$DataDir = Join-Path $BaseDir "openvpn-data"
$ClientsDir = Join-Path $BaseDir "clients"
$StateFile = Join-Path $BaseDir ".openvpn-state.json"

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  OpenVPN Users" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# PKI dizini var mı?
$pkiIssued = Join-Path $DataDir "pki\issued"
if (-not (Test-Path $pkiIssued)) {
    Write-Host "[ERROR] PKI dizini bulunamadı! Önce setup scriptini çalıştırın." -ForegroundColor Red
    exit 1
}

# Sertifikalar
Write-Host "Issued Certificates:" -ForegroundColor Blue
Write-Host ""

$certFiles = Get-ChildItem -Path $pkiIssued -Filter "*.crt" -ErrorAction SilentlyContinue
$certCount = 0

foreach ($cert in $certFiles) {
    $filename = $cert.BaseName
    
    # Server sertifikasını atla
    if ($filename -eq "server") {
        continue
    }
    
    $certCount++
    
    # Sertifika bilgileri
    try {
        $certInfo = (openssl x509 -in $cert.FullName -noout -dates 2>$null)
        $issueDate = ($certInfo -split "`n" | Where-Object { $_ -match "notBefore" }) -replace "notBefore=", ""
        $expireDate = ($certInfo -split "`n" | Where-Object { $_ -match "notAfter" }) -replace "notAfter=", ""
    } catch {
        $issueDate = "N/A"
        $expireDate = "N/A"
    }
    
    # .ovpn dosyası var mı?
    $ovpnFile = Join-Path $ClientsDir "${filename}.ovpn"
    $ovpnStatus = if (Test-Path $ovpnFile) { "✓" } else { "❌" }
    
    Write-Host "  ● $filename" -ForegroundColor Green
    Write-Host "    Issued:  $issueDate" -ForegroundColor Gray
    Write-Host "    Expires: $expireDate" -ForegroundColor Gray
    Write-Host "    .ovpn:   $ovpnStatus" -ForegroundColor Gray
    Write-Host ""
}

if ($certCount -eq 0) {
    Write-Host "  No users found." -ForegroundColor Yellow
    Write-Host ""
}

# İptal edilen sertifikalar
Write-Host "Revoked Certificates:" -ForegroundColor Blue
Write-Host ""

$revokedCount = 0
$indexFile = Join-Path $DataDir "pki\index.txt"

if (Test-Path $indexFile) {
    $indexContent = Get-Content $indexFile -ErrorAction SilentlyContinue
    
    foreach ($line in $indexContent) {
        if ($line -match '^R') {
            # Format: R	date	revoke_date	serial	unknown	/CN=username
            if ($line -match '/CN=([^/]+)') {
                $username = $matches[1]
                if ($username -ne "server") {
                    $revokedCount++
                    Write-Host "  ● $username (revoked)" -ForegroundColor Red
                }
            }
        }
    }
}

if ($revokedCount -eq 0) {
    Write-Host "  No revoked users." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Total Active Users: $certCount" -ForegroundColor Green
Write-Host "Total Revoked Users: $revokedCount" -ForegroundColor Red
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# .ovpn dosyaları listesi
if (Test-Path $ClientsDir) {
    $ovpnFiles = Get-ChildItem -Path $ClientsDir -Filter "*.ovpn" -ErrorAction SilentlyContinue
    $ovpnCount = $ovpnFiles.Count
    
    Write-Host "Available .ovpn files: $ovpnCount" -ForegroundColor Blue
    
    if ($ovpnCount -gt 0) {
        foreach ($ovpn in $ovpnFiles) {
            $filesize = "{0:N2} KB" -f ($ovpn.Length / 1KB)
            Write-Host "  - $($ovpn.Name) ($filesize)" -ForegroundColor Gray
        }
    }
    Write-Host ""
}

# State dosyasından bilgi
if (Test-Path $StateFile) {
    try {
        $state = Get-Content $StateFile -Raw | ConvertFrom-Json
        
        Write-Host "State File Info:" -ForegroundColor Blue
        Write-Host "  Users in state: $($state.users.created.Count)" -ForegroundColor Gray
        Write-Host "  Server IP: $($state.metadata.serverIP)" -ForegroundColor Gray
        Write-Host "  Setup Status: $($state.setup.status)" -ForegroundColor Gray
        Write-Host ""
    } catch {
        # State okunamadı, sessizce atla
    }
}
