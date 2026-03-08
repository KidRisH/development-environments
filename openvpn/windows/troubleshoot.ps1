<#
.SYNOPSIS
    OpenVPN Troubleshooting Script

.DESCRIPTION
    Detects common OpenVPN issues and suggests fixes.

.EXAMPLE
    .\troubleshoot.ps1

.NOTES
    Administrator privileges recommended.
#>

[CmdletBinding()]
param()

$ScriptDir = $PSScriptRoot
$BaseDir = Split-Path $ScriptDir -Parent
$StateFile = Join-Path $BaseDir ".openvpn-state.json"
$DataDir = Join-Path $BaseDir "openvpn-data"
$ClientsDir = Join-Path $BaseDir "clients"
$ContainerName = "OpenVPN-Server"
$VpnPort = 11194

$IssuesFound = 0

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

function Write-Issue {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )

    switch ($Type) {
        "Info"    { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
        "Success" { Write-Host "[OK]   $Message" -ForegroundColor Green }
        "Warning" {
            Write-Host "[WARN] $Message" -ForegroundColor Yellow
            $script:IssuesFound++
        }
        "Error"   {
            Write-Host "[FAIL] $Message" -ForegroundColor Red
            $script:IssuesFound++
        }
    }
}

function Write-Fix {
    param([string]$Message)
    Write-Host "  --> $Message" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  OpenVPN Troubleshooting" -ForegroundColor Cyan
Write-Host "  Port: $VpnPort/UDP" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Issue "Running without Administrator privileges (recommended)" -Type Warning
    Write-Host ""
}

###############################################################################
# 1. Container Runtime
###############################################################################
Write-Host "[1] Container Runtime" -ForegroundColor Blue

$runtime = Get-ContainerRuntime
if (-not $runtime) {
    Write-Issue "Docker or Podman not installed!" -Type Error
    Write-Fix "Podman: https://podman.io/getting-started/installation"
    Write-Fix "Docker: https://docs.docker.com/get-docker/"
} else {
    $runtimeVer = & $runtime --version 2>&1
    Write-Issue "$runtime installed: $runtimeVer" -Type Success

    if ($runtime -eq "podman") {
        $machineRunning = (podman machine ls 2>&1) | Select-String "Running"
        if ($machineRunning) {
            Write-Issue "Podman machine running" -Type Success
        } else {
            Write-Issue "Podman machine STOPPED!" -Type Error
            Write-Fix "podman machine start"
        }

        $podmanInfo = podman info 2>&1 | Out-String
        if ($podmanInfo -match "rootless: true") {
            Write-Issue "Podman running in ROOTLESS mode (TUN device issues possible)" -Type Warning
            Write-Host "    Switch to rootful mode:" -ForegroundColor Gray
            Write-Host "    podman machine stop" -ForegroundColor Gray
            Write-Host "    podman machine set --rootful" -ForegroundColor Gray
            Write-Host "    podman machine start" -ForegroundColor Gray
        } else {
            Write-Issue "Podman running in rootful mode" -Type Success
        }
    } else {
        # Docker daemon check
        $null = docker info 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Issue "Docker daemon running" -Type Success
        } else {
            Write-Issue "Docker daemon NOT RUNNING!" -Type Error
            Write-Fix "Start Docker Desktop or: sudo systemctl start docker"
        }
    }
}
Write-Host ""

###############################################################################
# 2. Container
###############################################################################
Write-Host "[2] Container" -ForegroundColor Blue

if (-not $runtime) {
    Write-Issue "Container runtime not installed, skipping check" -Type Warning
} else {
    $allContainers     = & $runtime ps -a --format "{{.Names}}" 2>$null
    $runningContainers = & $runtime ps --format "{{.Names}}" 2>$null

    if ($allContainers -notcontains $ContainerName) {
        Write-Issue "Container not found: $ContainerName" -Type Error
        Write-Fix ".\setup.ps1"
    } elseif ($runningContainers -notcontains $ContainerName) {
        $statusLine = & $runtime ps -a --filter "name=$ContainerName" --format "{{.Names}} {{.Status}}" 2>$null
        Write-Issue "Container STOPPED: $statusLine" -Type Error
        $cc = Get-ComposeCommand
        Write-Fix "$cc -f ..\compose.yml up -d"
    } else {
        Write-Issue "Container running: $ContainerName" -Type Success

        $portBinding = & $runtime port $ContainerName 2>$null
        if ($portBinding) {
            Write-Issue "Port binding: $portBinding" -Type Success
        } else {
            Write-Issue "Could not retrieve container port binding" -Type Warning
        }
    }
}
Write-Host ""

###############################################################################
# 3. Compose
###############################################################################
Write-Host "[3] Compose" -ForegroundColor Blue

$composeCmd = Get-ComposeCommand
if ($composeCmd) {
    Write-Issue "Compose provider: $composeCmd" -Type Success
} else {
    Write-Issue "Compose provider not found!" -Type Error
    if ($runtime -eq "docker") {
        Write-Fix "https://docs.docker.com/compose/install/"
    } else {
        Write-Fix "https://github.com/containers/podman-compose"
    }
}
Write-Host ""

###############################################################################
# 4. Port and Network
###############################################################################
Write-Host "[4] Port and Network" -ForegroundColor Blue

$portEndpoint = Get-NetUDPEndpoint -LocalPort $VpnPort -ErrorAction SilentlyContinue
if ($portEndpoint) {
    Write-Issue "Port $VpnPort/UDP listening on Windows" -Type Success
} else {
    Write-Issue "Port $VpnPort/UDP not listening on Windows!" -Type Error
    Write-Host "    Possible causes:" -ForegroundColor Gray
    Write-Host "    - Container is not running" -ForegroundColor Gray
    Write-Host "    - Port forwarding not working (Podman rootless mode)" -ForegroundColor Gray
    Write-Host "    - compose.yml port definition incorrect (should be: ${VpnPort}:1194/udp)" -ForegroundColor Gray
}

$fwRule = Get-NetFirewallRule -ErrorAction SilentlyContinue |
    Where-Object { $_.Enabled -eq "True" } |
    Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -eq $VpnPort -and $_.Protocol -eq "UDP" }

if ($fwRule) {
    Write-Issue "Windows Firewall: active rule found for port $VpnPort/UDP" -Type Success
} else {
    Write-Issue "Windows Firewall: no rule found for port $VpnPort/UDP!" -Type Error
    Write-Fix "New-NetFirewallRule -DisplayName 'OpenVPN' -Direction Inbound -Protocol UDP -LocalPort $VpnPort -Action Allow"
}

try {
    $publicIP = (Invoke-RestMethod -Uri "https://ifconfig.me/ip" -TimeoutSec 5).Trim()
    Write-Issue "Server Public IP: $publicIP" -Type Info
} catch {
    Write-Issue "Could not retrieve public IP" -Type Warning
}
Write-Host ""

###############################################################################
# 5. PKI
###############################################################################
Write-Host "[5] PKI and Certificates" -ForegroundColor Blue

$pkiDir = Join-Path $DataDir "pki"
if (-not (Test-Path $pkiDir)) {
    Write-Issue "PKI directory not found!" -Type Error
    Write-Fix ".\setup.ps1"
} else {
    Write-Issue "PKI directory present" -Type Success

    $caCert = Join-Path $pkiDir "ca.crt"
    if (Test-Path $caCert) { Write-Issue "ca.crt present" -Type Success }
    else { Write-Issue "ca.crt NOT FOUND!" -Type Error }

    $issuedDir   = Join-Path $pkiDir "issued"
    $issuedCerts = Get-ChildItem $issuedDir -Filter "*.crt" -ErrorAction SilentlyContinue
    if ($issuedCerts -and $issuedCerts.Count -gt 0) {
        Write-Issue "Server certificate present: $($issuedCerts.Name -join ', ')" -Type Success
    } else {
        Write-Issue "No certificate found under issued/!" -Type Error
    }

    $privateDir  = Join-Path $pkiDir "private"
    $privateKeys = Get-ChildItem $privateDir -Filter "*.key" -ErrorAction SilentlyContinue
    if ($privateKeys -and $privateKeys.Count -gt 0) {
        Write-Issue "Private key present: $($privateKeys.Name -join ', ')" -Type Success
    } else {
        Write-Issue "No key found under private/!" -Type Error
    }
}
Write-Host ""

###############################################################################
# 6. OpenVPN Config
###############################################################################
Write-Host "[6] OpenVPN Config" -ForegroundColor Blue

$configFile = Join-Path $DataDir "openvpn.conf"
if (-not (Test-Path $configFile)) {
    Write-Issue "openvpn.conf not found!" -Type Error
    Write-Fix ".\setup.ps1"
} else {
    $cfg = Get-Content $configFile -Raw

    if ($cfg -match "proto\s+udp") { Write-Issue "Protocol: UDP" -Type Success }
    else { Write-Issue "UDP protocol not found!" -Type Error }

    if ($cfg -match "port\s+(\d+)") {
        $cfgPort = $Matches[1]
        Write-Issue "Container port: $cfgPort (mapped to host as $VpnPort)" -Type Info
    }

    if ($cfg -match "server\s+(\S+\s+\S+)") {
        Write-Issue "VPN subnet: $($Matches[1])" -Type Info
    }
}
Write-Host ""

###############################################################################
# 7. Client .ovpn Files
###############################################################################
Write-Host "[7] Client .ovpn Files" -ForegroundColor Blue

if (-not (Test-Path $ClientsDir)) {
    Write-Issue "Clients directory not found" -Type Warning
} else {
    $ovpnFiles = Get-ChildItem $ClientsDir -Filter "*.ovpn" -ErrorAction SilentlyContinue
    if (-not $ovpnFiles -or $ovpnFiles.Count -eq 0) {
        Write-Issue "No .ovpn files in clients directory" -Type Warning
        Write-Fix ".\create-user.ps1 -Username username"
    } else {
        Write-Issue "$($ovpnFiles.Count) .ovpn file(s) found" -Type Success
        foreach ($f in $ovpnFiles) {
            $remoteLine = (Get-Content $f.FullName) | Where-Object { $_ -match '^\s*remote\s+' } | Select-Object -First 1
            if ($remoteLine -and $remoteLine -match '^\s*remote\s+(\S+)\s+(\d+)') {
                $rHost = $Matches[1]
                $rPort = $Matches[2]
                if ($rPort -eq $VpnPort.ToString()) {
                    Write-Issue "$($f.Name): remote=$rHost port=$rPort (correct)" -Type Success
                } else {
                    Write-Issue "$($f.Name): remote=$rHost port=$rPort (WRONG! Expected: $VpnPort)" -Type Error
                    Write-Fix "Recreate users with .\create-user.ps1"
                }
            } else {
                Write-Issue "$($f.Name): remote line not found" -Type Warning
            }
        }
    }
}
Write-Host ""

###############################################################################
# 8. Container Logs
###############################################################################
Write-Host "[8] Container Logs (last 30 lines)" -ForegroundColor Blue

if (-not $runtime) {
    Write-Issue "No container runtime, cannot retrieve logs" -Type Info
} else {
    $isRunning = (& $runtime ps --format "{{.Names}}" 2>$null) -contains $ContainerName
    if (-not $isRunning) {
        Write-Issue "Container not running, cannot retrieve logs" -Type Info
    } else {
    $logs       = & $runtime logs $ContainerName --tail=30 2>&1
    $errorLines = $logs | Select-String -Pattern "error|fail|fatal|SIGTERM|Exiting" -CaseSensitive:$false
    if ($errorLines) {
        Write-Issue "Error/warning messages in logs:" -Type Warning
        $errorLines | ForEach-Object { Write-Host "    $($_.Line)" -ForegroundColor Gray }
    } else {
        Write-Issue "No critical errors in recent logs" -Type Success
    }
    Write-Host ""
    Write-Host "  Last 10 log lines:" -ForegroundColor DarkGray
    $logs | Select-Object -Last 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}
Write-Host ""

###############################################################################
# Ozet
###############################################################################
Write-Host "==========================================" -ForegroundColor Cyan
if ($IssuesFound -eq 0) {
    Write-Host "No issues found!" -ForegroundColor Green
    Write-Host "If you still have connectivity issues, check modem NAT/port forwarding." -ForegroundColor Cyan
} else {
    Write-Host "! $IssuesFound issue(s)/warning(s) found" -ForegroundColor Yellow
    Write-Host "Follow the '-->' suggestions above." -ForegroundColor Cyan
}
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

exit $IssuesFound
