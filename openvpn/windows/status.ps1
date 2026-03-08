<#
.SYNOPSIS
    OpenVPN Status Check

.DESCRIPTION
    Container durumu, aktif bağlantılar ve sistem bilgilerini gösterir.

.EXAMPLE
    .\status.ps1
#>

[CmdletBinding()]
param()

$ScriptDir = $PSScriptRoot
$BaseDir = Split-Path $ScriptDir -Parent
$StateFile = Join-Path $BaseDir ".openvpn-state.json"
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

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  OpenVPN Status" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Container durumu
Write-Host "Container Status:" -ForegroundColor Blue
if (-not $runtime) {
    Write-Host "  ✗ Docker veya Podman yuklu degil!" -ForegroundColor Red
} else {
    $running = & $runtime ps --filter "name=$ContainerName" --format "{{.Names}}" 2>$null

    if ($running -contains $ContainerName) {
        $containerInfo = & $runtime ps --filter "name=$ContainerName" --format "table {{.Names}}`t{{.Status}}`t{{.Ports}}" 2>$null | Select-Object -Skip 1
        Write-Host $containerInfo
        Write-Host "  ✓ Container is running" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Container is not running" -ForegroundColor Red

        $exists = & $runtime ps -a --filter "name=$ContainerName" --format "{{.Names}}" 2>$null
        $cc = Get-ComposeCommand
        if ($exists -contains $ContainerName) {
            Write-Host "  Container exists but is stopped" -ForegroundColor Yellow
            Write-Host "  Start with: cd ..; $cc up -d" -ForegroundColor Blue
        } else {
            Write-Host "  Container does not exist" -ForegroundColor Yellow
            Write-Host "  Run: cd windows; .\setup.ps1" -ForegroundColor Blue
        }
    }
}
Write-Host ""

# Port durumu
Write-Host "Port Status:" -ForegroundColor Blue
$portInUse = Get-NetUDPEndpoint -LocalPort 1194 -ErrorAction SilentlyContinue

if ($portInUse) {
    Write-Host "  ✓ Port 1194/UDP is listening" -ForegroundColor Green
    
    $process = Get-Process -Id $portInUse.OwningProcess -ErrorAction SilentlyContinue
    if ($process) {
        Write-Host "  Process: $($process.Name) (PID: $($process.Id))" -ForegroundColor Gray
    }
} else {
    Write-Host "  ✗ Port 1194/UDP is not listening" -ForegroundColor Red
}
Write-Host ""

# Aktif bağlantılar
Write-Host "Active Connections:" -ForegroundColor Blue
try {
    $statusLog = if ($runtime) { & $runtime exec $ContainerName cat /etc/openvpn/openvpn-status.log 2>$null } else { $null }
    
    if ($statusLog -match "CLIENT_LIST") {
        $clientLines = $statusLog -split "`n" | Where-Object { $_ -match "^CLIENT_LIST" }
        $clientCount = ($clientLines | Measure-Object).Count - 1  # İlk satır header
        
        if ($clientCount -gt 0) {
            Write-Host "  Active Clients: $clientCount" -ForegroundColor Green
            Write-Host ""
            
            foreach ($line in $clientLines[1..($clientLines.Count-1)]) {
                $fields = $line -split ','
                if ($fields.Count -ge 8) {
                    $cn = $fields[1]
                    $realIp = $fields[2]
                    $bytesRecv = $fields[4]
                    $bytesSent = $fields[5]
                    $since = $fields[7]
                    
                    Write-Host "    • $cn" -ForegroundColor White
                    Write-Host "      IP: $realIp" -ForegroundColor Gray
                    Write-Host "      Connected since: $since" -ForegroundColor Gray
                    Write-Host "      Data: ↓$([math]::Round($bytesRecv/1MB, 2)) MB / ↑$([math]::Round($bytesSent/1MB, 2)) MB" -ForegroundColor Gray
                    Write-Host ""
                }
            }
        } else {
            Write-Host "  No active connections" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Unable to read status log" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  Unable to read status log" -ForegroundColor Yellow
}
Write-Host ""

# Son 10 log satırı
Write-Host "Recent Logs (last 10 lines):" -ForegroundColor Blue
try {
    Push-Location $BaseDir
    $cc = Get-ComposeCommand
    $logs = if ($cc) { Invoke-Expression "$cc logs --tail=10 openvpn 2>`$null" } else { $null }
    Pop-Location
    
    if ($logs) {
        $logs | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    } else {
        Write-Host "  No logs available" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  Unable to read logs" -ForegroundColor Yellow
}
Write-Host ""

# State dosyası bilgileri
if (Test-Path $StateFile) {
    Write-Host "State File Info:" -ForegroundColor Blue
    
    try {
        $state = Get-Content $StateFile -Raw | ConvertFrom-Json
        
        Write-Host "  Setup Status: $($state.setup.status)" -ForegroundColor Gray
        Write-Host "  Setup Completed: $($state.setup.completed)" -ForegroundColor Gray
        Write-Host "  Server IP: $($state.metadata.serverIP)" -ForegroundColor Gray
        Write-Host "  Total Users Created: $($state.users.created.Count)" -ForegroundColor Gray
        Write-Host "  Total Users Revoked: $($state.users.revoked.Count)" -ForegroundColor Gray
        Write-Host "  Last Updated: $($state.lastUpdated)" -ForegroundColor Gray
    } catch {
        Write-Host "  Unable to parse state file" -ForegroundColor Yellow
    }
} else {
    Write-Host "  State file not found" -ForegroundColor Yellow
}
Write-Host ""

# Disk kullanımı
Write-Host "Disk Usage:" -ForegroundColor Blue

$dataDir = Join-Path $BaseDir "openvpn-data"
if (Test-Path $dataDir) {
    $dataSize = (Get-ChildItem -Path $dataDir -Recurse -ErrorAction SilentlyContinue | 
                 Measure-Object -Property Length -Sum).Sum
    Write-Host "  OpenVPN Data: $([math]::Round($dataSize/1MB, 2)) MB" -ForegroundColor Gray
}

$logsDir = Join-Path $BaseDir "logs"
if (Test-Path $logsDir) {
    $logsSize = (Get-ChildItem -Path $logsDir -Recurse -ErrorAction SilentlyContinue | 
                 Measure-Object -Property Length -Sum).Sum
    Write-Host "  Logs: $([math]::Round($logsSize/1MB, 2)) MB" -ForegroundColor Gray
}

$clientsDir = Join-Path $BaseDir "clients"
if (Test-Path $clientsDir) {
    $clientsFiles = Get-ChildItem -Path $clientsDir -Filter "*.ovpn" -ErrorAction SilentlyContinue
    $clientsSize = ($clientsFiles | Measure-Object -Property Length -Sum).Sum
    $clientsCount = $clientsFiles.Count
    Write-Host "  Clients: $([math]::Round($clientsSize/1KB, 2)) KB ($clientsCount .ovpn files)" -ForegroundColor Gray
}
Write-Host ""

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""
