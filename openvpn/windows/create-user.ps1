<#
.SYNOPSIS
    OpenVPN User Creation Script for Windows

.DESCRIPTION
    Creates a new OpenVPN user and generates a .ovpn file.

.PARAMETER Username
    The username to create

.EXAMPLE
    .\create-user.ps1 -Username "john"

.NOTES
    Requires Administrator privileges.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidatePattern('^[a-zA-Z0-9_-]+$')]
    [string]$Username
)

$ErrorActionPreference = "Stop"

# Variables
$ScriptDir = $PSScriptRoot
$BaseDir = Split-Path $ScriptDir -Parent
$StateFile = Join-Path $BaseDir ".openvpn-state.json"
$DataDir = Join-Path $BaseDir "openvpn-data"
$ClientsDir = Join-Path $BaseDir "clients"
$ContainerName = "OpenVPN-Server"

###############################################################################
# Runtime Detection
###############################################################################
$script:_RUNTIME = $null

function Get-ContainerRuntime {
    if ($script:_RUNTIME) { return $script:_RUNTIME }
    if (Get-Command podman -ErrorAction SilentlyContinue) { $script:_RUNTIME = "podman"; return "podman" }
    if (Get-Command docker -ErrorAction SilentlyContinue) { $script:_RUNTIME = "docker"; return "docker" }
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
Write-Host "  OpenVPN User Creation" -ForegroundColor Cyan
Write-Host "  Username: $Username" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Is container running?
if (-not $runtime) {
    Write-ColorOutput "Docker or Podman not installed!" -Type Error
    exit 1
}
$running = & $runtime ps --filter "name=$ContainerName" --format "{{.Names}}" 2>$null
if ($running -notcontains $ContainerName) {
    Write-ColorOutput "OpenVPN container is not running!" -Type Error
    Write-ColorOutput "To start the container: cd ..; $runtime compose up -d" -Type Info
    exit 1
}

# PKI directory check
$pkiDir = Join-Path $DataDir "pki"
if (-not (Test-Path $pkiDir)) {
    Write-ColorOutput "PKI directory not found! Run the setup script first." -Type Error
    exit 1
}

# Clients directory: create if missing
if (-not (Test-Path $ClientsDir)) {
    New-Item -Path $ClientsDir -ItemType Directory -Force | Out-Null
}

# User already exists?
$ovpnFile = Join-Path $ClientsDir "${Username}.ovpn"
if (Test-Path $ovpnFile) {
    Write-ColorOutput "This user already exists: ${Username}.ovpn" -Type Warning
    $response = Read-Host "Recreate anyway? (Y/N)"
    if ($response -notmatch '^[Yy]$') {
        Write-ColorOutput "Cancelled." -Type Info
        exit 0
    }
}

Write-ColorOutput "Generating user certificate: $Username" -Type Info
Write-ColorOutput "This may take a few seconds..." -Type Warning

try {
    # Generate client certificate (nopass)
    $dataVolume = "${DataDir}:/etc/openvpn"
    
    & $runtime run -v $dataVolume --rm -it kylemanna/openvpn `
        easyrsa build-client-full $Username nopass
    
    if ($LASTEXITCODE -ne 0) {
        throw "Certificate generation failed"
    }
    
    Write-ColorOutput "Generating .ovpn file..." -Type Info
    
    # Generate .ovpn file
    $ovpnContent = & $runtime run -v $dataVolume --rm kylemanna/openvpn `
        ovpn_getclient $Username
    
    if ($LASTEXITCODE -ne 0) {
        throw ".ovpn file generation failed"
    }
    
    # Save file
    $ovpnContent | Out-File -FilePath $ovpnFile -Encoding ASCII -Force
    
    # Update state file
    if (Test-Path $StateFile) {
        try {
            $state = Get-Content $StateFile -Raw | ConvertFrom-Json
            $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            
            $newUser = @{
                username = $Username
                createdAt = $timestamp
            }
            
            $state.users.created += $newUser
            $state.lastUpdated = $timestamp
            
            $state | ConvertTo-Json -Depth 10 | Set-Content $StateFile -Encoding UTF8
            
            Write-ColorOutput "State file updated." -Type Info
        } catch {
            Write-ColorOutput "Could not update state (non-critical): $($_.Exception.Message)" -Type Warning
        }
    }
    
    Write-Host ""
    Write-ColorOutput "✓ User created successfully!" -Type Success
    Write-Host ""
    Write-ColorOutput "Client configuration file:" -Type Info
    Write-Host "  $ovpnFile" -ForegroundColor White
    Write-Host ""
    Write-ColorOutput "Copy this file to the client and import it with OpenVPN." -Type Info
    Write-Host ""
    Write-Host "Windows: OpenVPN GUI → Import file" -ForegroundColor Gray
    Write-Host "Linux: sudo openvpn --config ${Username}.ovpn" -ForegroundColor Gray
    Write-Host "Mobile: Import via QR code or file" -ForegroundColor Gray
    Write-Host ""
    
} catch {
    Write-ColorOutput "An error occurred: $($_.Exception.Message)" -Type Error
    exit 1
}
