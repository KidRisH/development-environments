<#
.SYNOPSIS
    OpenVPN Server Setup Script for Windows (State-Aware)

.DESCRIPTION
    Resumes from the last completed step if interrupted.
    Supports Docker or Podman (auto-detected).

.EXAMPLE
    .\setup.ps1

.NOTES
    Must be run with Administrator privileges.
#>

#Requires -RunAsAdministrator

[CmdletBinding()]
param()

###############################################################################
# Variables
###############################################################################

$ScriptDir = $PSScriptRoot
$BaseDir = Split-Path $ScriptDir -Parent
$StateFile = Join-Path $BaseDir ".openvpn-state.json"
$ComposeFile = Join-Path $BaseDir "compose.yml"
$DataDir = Join-Path $BaseDir "openvpn-data"
$LogsDir = Join-Path $BaseDir "logs"
$ClientsDir = Join-Path $BaseDir "clients"
$ContainerName = "OpenVPN-Server"
$script:ContainerRuntime = $null   # "podman" or "docker" — determined in PreCheck
$script:ComposeCmd = $null         # determined in PreCheck

###############################################################################
# Helper Functions
###############################################################################

function Get-RuntimeCmd {
    # Returns the active container runtime: podman first, then docker
    if ($script:ContainerRuntime) { return $script:ContainerRuntime }

    if (Get-Command podman -ErrorAction SilentlyContinue) {
        $script:ContainerRuntime = "podman"
        return $script:ContainerRuntime
    }
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $script:ContainerRuntime = "docker"
        return $script:ContainerRuntime
    }
    return $null
}

function Get-ComposeCmd {
    # Returns the active compose command
    if ($script:ComposeCmd) { return $script:ComposeCmd }

    $runtime = Get-RuntimeCmd
    if (-not $runtime) { return $null }

    if ($runtime -eq "podman") {
        # Use standalone podman-compose if available, otherwise built-in "podman compose"
        if (Get-Command podman-compose -ErrorAction SilentlyContinue) {
            $script:ComposeCmd = "podman-compose"
        } else {
            $script:ComposeCmd = "podman compose"
        }
        return $script:ComposeCmd
    }

    # For Docker: standalone docker-compose first, then built-in
    if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
        $script:ComposeCmd = "docker-compose"
        return $script:ComposeCmd
    }
    $null = & docker compose version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $script:ComposeCmd = "docker compose"
        return $script:ComposeCmd
    }

    return $null
}

function Invoke-Compose {
    param([string]$Arguments)
    $cmd = Get-ComposeCmd
    if (-not $cmd) { throw "Compose command not found" }
    Invoke-Expression "$cmd $Arguments"
}

function Invoke-ContainerRun {
    # Runs 'podman run ...' or 'docker run ...'
    param([string]$Arguments)
    $runtime = Get-RuntimeCmd
    if (-not $runtime) { throw "Container runtime not found" }
    Invoke-Expression "$runtime run $Arguments"
}

function Write-ColorOutput {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Type = 'Info'
    )
    
    $color = switch ($Type) {
        'Info'    { 'Cyan' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }
    
    $prefix = switch ($Type) {
        'Info'    { '[INFO]' }
        'Success' { '[SUCCESS]' }
        'Warning' { '[WARNING]' }
        'Error'   { '[ERROR]' }
    }
    
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Read-JsonFile {
    param([string]$Path)
    
    if (Test-Path $Path) {
        try {
            return Get-Content $Path -Raw | ConvertFrom-Json
        }
        catch {
            Write-ColorOutput "JSON read error: $($_.Exception.Message)" -Type Error
            return $null
        }
    }
    return $null
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Data
    )
    
    try {
        $Data | ConvertTo-Json -Depth 10 | Set-Content $Path -Encoding UTF8
        return $true
    }
    catch {
            Write-ColorOutput "JSON write error: $($_.Exception.Message)" -Type Error
        return $false
    }
}

function Update-State {
    param(
        [string]$Step,
        [string]$Status,
        [string]$ErrorMessage = "",
        [string]$ExtraData = ""
    )
    
    $state = Read-JsonFile -Path $StateFile
    if (-not $state) { return }
    
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    $state.lastUpdated = $timestamp
    $state.setup.steps.$Step.status = $Status
    $state.setup.steps.$Step.timestamp = $timestamp
    
    if ($ErrorMessage) {
        $state.setup.steps.$Step.error = $ErrorMessage
    }
    else {
        $state.setup.steps.$Step.error = $null
    }
    
    $state.setup.currentStep = $Step
    
    # Special handling for extra data (IP detection)
    if ($ExtraData -and $Step -eq "detect_ip") {
        $state.setup.steps.detect_ip.detected_ip = $ExtraData
        $state.metadata.serverIP = $ExtraData
    }
    
    Write-JsonFile -Path $StateFile -Data $state
}

function Set-SetupCompleted {
    $state = Read-JsonFile -Path $StateFile
    if (-not $state) { return }
    
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    $state.setup.status = "completed"
    $state.setup.completed = $true
    $state.lastUpdated = $timestamp
    $state.metadata.lastModified = $timestamp
    
    if (-not $state.metadata.createdAt) {
        $state.metadata.createdAt = $timestamp
    }
    
    Write-JsonFile -Path $StateFile -Data $state
}

function Test-StepCompleted {
    param([string]$Step)
    
    $state = Read-JsonFile -Path $StateFile
    if (-not $state) { return $false }
    
    return $state.setup.steps.$Step.status -eq "completed"
}

function Test-SetupCompleted {
    $state = Read-JsonFile -Path $StateFile
    if (-not $state) { return $false }
    
    return $state.setup.completed -eq $true
}

###############################################################################
# Setup Steps
###############################################################################

function Step-PreCheck {
    Write-ColorOutput "Step 0/7: Pre-checks (runtime, privileges, port check)..." -Type Info
    
    if (Test-StepCompleted -Step "precheck") {
        Write-ColorOutput "Pre-checks already completed, skipping..." -Type Success
        return
    }
    
    Update-State -Step "precheck" -Status "in_progress"
    
    # Administrator check
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Update-State -Step "precheck" -Status "failed" -ErrorMessage "Administrator privileges required"
        Write-ColorOutput "This script must be run as Administrator!" -Type Error
        exit 1
    }
    
    # Container runtime check (Podman or Docker)
    $runtime = Get-RuntimeCmd
    if (-not $runtime) {
        Update-State -Step "precheck" -Status "failed" -ErrorMessage "Container runtime not found"
        Write-ColorOutput "Docker or Podman not found! Please install one." -Type Error
        Write-ColorOutput "Podman: https://podman.io/getting-started/installation" -Type Info
        Write-ColorOutput "Docker: https://docs.docker.com/get-docker/" -Type Info
        exit 1
    }
    Write-ColorOutput "Container runtime: $runtime ✓" -Type Info

    # Podman machine check (BEFORE compose detection — compose version fails without machine)
    if ($runtime -eq "podman") {
        $machineRunning = (podman machine ls 2>&1) | Select-String "Running"
        if (-not $machineRunning) {
            Write-ColorOutput "Starting Podman machine..." -Type Info
            podman machine start 2>&1
            if ($LASTEXITCODE -ne 0) {
                Update-State -Step "precheck" -Status "failed" -ErrorMessage "Failed to start Podman machine"
                Write-ColorOutput "Failed to start Podman machine! Manual: podman machine start" -Type Error
                exit 1
            }
            Write-ColorOutput "Podman machine started ✓" -Type Success
        }
    }

    # Compose check
    $composeCmd = Get-ComposeCmd
    if (-not $composeCmd) {
        Update-State -Step "precheck" -Status "failed" -ErrorMessage "Compose provider not found"
        Write-ColorOutput "Compose provider not found!" -Type Error
        Write-ColorOutput "Please install one of the following:" -Type Warning
        if ($runtime -eq "docker") {
            Write-Host "  docker-compose : https://docs.docker.com/compose/install/" -ForegroundColor Gray
        } else {
            Write-Host "  podman-compose : https://github.com/containers/podman-compose" -ForegroundColor Gray
            Write-Host "  Docker Desktop : https://docs.docker.com/desktop/windows/" -ForegroundColor Gray
        }
        exit 1
    }
    Write-ColorOutput "Compose provider: $composeCmd ✓" -Type Info
    
    # Port 11194 check
    $portInUse = Get-NetUDPEndpoint -LocalPort 11194 -ErrorAction SilentlyContinue
    if ($portInUse) {
        Write-ColorOutput "Port 11194 is already in use! Do you want to continue? (Y/N)" -Type Warning
        $response = Read-Host
        if ($response -notmatch '^[Yy]$') {
            Update-State -Step "precheck" -Status "failed" -ErrorMessage "Port 11194 in use and user declined to continue"
            exit 1
        }
    }
    
    # Compose file check
    if (-not (Test-Path $ComposeFile)) {
        Update-State -Step "precheck" -Status "failed" -ErrorMessage "compose.yml not found"
        Write-ColorOutput "compose.yml not found: $ComposeFile" -Type Error
        exit 1
    }
    
    Update-State -Step "precheck" -Status "completed"
    Write-ColorOutput "Pre-checks completed ✓" -Type Success
}

function Step-StateInit {
    Write-ColorOutput "Step 1/7: Checking state file..." -Type Info
    
    if (Test-StepCompleted -Step "state_init") {
        Write-ColorOutput "State init already completed, skipping..." -Type Success
        return
    }
    
    Update-State -Step "state_init" -Status "in_progress"
    
    if (-not (Test-Path $StateFile)) {
        Write-ColorOutput "State file not found: $StateFile" -Type Error
        Write-ColorOutput "Please create the .openvpn-state.json file." -Type Info
        exit 1
    }
    
    Update-State -Step "state_init" -Status "completed"
    Write-ColorOutput "State init completed ✓" -Type Success
}

function Step-CreateVolumes {
    Write-ColorOutput "Step 2/7: Creating directories..." -Type Info
    
    if (Test-StepCompleted -Step "create_volumes") {
        Write-ColorOutput "Directories already created, skipping..." -Type Success
        return
    }
    
    Update-State -Step "create_volumes" -Status "in_progress"
    
    # Create directories
    @($DataDir, $LogsDir, $ClientsDir) | ForEach-Object {
        if (-not (Test-Path $_)) {
            New-Item -Path $_ -ItemType Directory -Force | Out-Null
        }
    }
    
    Update-State -Step "create_volumes" -Status "completed"
    Write-ColorOutput "Directories created ✓" -Type Success
}

function Step-DetectIP {
    Write-ColorOutput "Step 3/7: Detecting server IP address..." -Type Info
    
    if (Test-StepCompleted -Step "detect_ip") {
        Write-ColorOutput "IP address already detected, skipping..." -Type Success
        return
    }
    
    Update-State -Step "detect_ip" -Status "in_progress"
    
    $serverIP = $null
    $services = @("https://ifconfig.me", "https://icanhazip.com", "https://api.ipify.org")
    
    foreach ($service in $services) {
        try {
            $serverIP = (Invoke-RestMethod -Uri $service -TimeoutSec 5).Trim()
            if ($serverIP -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                Write-ColorOutput "Public IP detected: $serverIP" -Type Success
                break
            }
        }
        catch {
            continue
        }
    }
    
    # If IP not detected, ask the user
    if (-not $serverIP -or $serverIP -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        Write-ColorOutput "Could not auto-detect public IP." -Type Warning
        Write-ColorOutput "Please enter your server's public IP address or domain:" -Type Info
        $serverIP = Read-Host
        
        if (-not $serverIP) {
            Update-State -Step "detect_ip" -Status "failed" -ErrorMessage "No IP address entered"
            Write-ColorOutput "No IP address was entered!" -Type Error
            exit 1
        }
    }
    
    Write-ColorOutput "Address to use: $serverIP" -Type Info
    
    Update-State -Step "detect_ip" -Status "completed" -ExtraData $serverIP
    Write-ColorOutput "IP address saved ✓" -Type Success
}

function Step-StartContainer {
    Write-ColorOutput "Step 4/7: Starting container ($script:ContainerRuntime)..." -Type Info
    
    if (Test-StepCompleted -Step "start_container") {
        Write-ColorOutput "Container already started, skipping..." -Type Success
        return
    }
    
    Update-State -Step "start_container" -Status "in_progress"
    
    Push-Location $BaseDir
    try {
        Invoke-Compose "up -d"
        
        if ($LASTEXITCODE -ne 0) {
            throw "Container start failed"
        }
        
        Start-Sleep -Seconds 3
        
        # Check if container was created (may be exited before config — that's normal)
        $exists = & $script:ContainerRuntime ps -a --filter "name=$ContainerName" --format "{{.Names}}"
        if (-not $exists) {
            throw "Container could not be created"
        }
        
        Write-ColorOutput "Container created (will be restarted after PKI init) ✓" -Type Success
        Update-State -Step "start_container" -Status "completed"
    }
    catch {
        Update-State -Step "start_container" -Status "failed" -ErrorMessage $_.Exception.Message
        Write-ColorOutput "Failed to start container!" -Type Error
        Write-ColorOutput "Check logs: $(Get-ComposeCmd) logs openvpn" -Type Info
        exit 1
    }
    finally {
        Pop-Location
    }
}

function Step-PKIInit {
    Write-ColorOutput "Step 5/7: Generating OpenVPN configuration..." -Type Info
    
    if (Test-StepCompleted -Step "pki_init") {
        Write-ColorOutput "PKI init already completed, skipping..." -Type Success
        return
    }
    
    Update-State -Step "pki_init" -Status "in_progress"
    
    # Read IP from state
    $state = Read-JsonFile -Path $StateFile
    $serverIP = $state.metadata.serverIP
    
    if (-not $serverIP) {
        Update-State -Step "pki_init" -Status "failed" -ErrorMessage "Server IP not found in state"
        Write-ColorOutput "Server IP not found in state!" -Type Error
        exit 1
    }
    
    Write-ColorOutput "Generating OpenVPN config: udp://${serverIP}:11194" -Type Info
    
    try {
        $dataVolume = "${DataDir}:/etc/openvpn"
        
        Invoke-ContainerRun "-v $dataVolume --rm kylemanna/openvpn ovpn_genconfig -u udp://${serverIP}:11194 -N -n 1.1.1.1 -n 1.0.0.1"
        
        if ($LASTEXITCODE -ne 0) {
            throw "ovpn_genconfig failed"
        }
        
        # Fix NAT setting (ensures internet routing through VPN)
        Write-ColorOutput "Applying NAT and routing configuration..." -Type Info
        $natCmd = "grep -q OVPN_NAT=1 /etc/openvpn/ovpn_env.sh || sed -i 's/OVPN_NAT=0/OVPN_NAT=1/' /etc/openvpn/ovpn_env.sh"
        $routeCmd = "grep -q redirect-gateway /etc/openvpn/openvpn.conf || echo 'push `"redirect-gateway def1 bypass-dhcp`"' >> /etc/openvpn/openvpn.conf"
        & $script:ContainerRuntime run -v $dataVolume --rm kylemanna/openvpn sh -c $natCmd
        & $script:ContainerRuntime run -v $dataVolume --rm kylemanna/openvpn sh -c $routeCmd
        Write-ColorOutput "NAT and routing configuration applied ✓" -Type Info
        
        Update-State -Step "pki_init" -Status "completed"
        Write-ColorOutput "OpenVPN configuration generated ✓" -Type Success
    }
    catch {
        Update-State -Step "pki_init" -Status "failed" -ErrorMessage $_.Exception.Message
        Write-ColorOutput "ovpn_genconfig failed!" -Type Error
        exit 1
    }
}

function Step-GenerateCA {
    Write-ColorOutput "Step 6/7: Generating CA certificate..." -Type Info
    
    if (Test-StepCompleted -Step "generate_ca") {
        Write-ColorOutput "CA certificate already generated, skipping..." -Type Success
        return
    }
    
    Update-State -Step "generate_ca" -Status "in_progress"
    
    Write-ColorOutput "Generating CA certificate (nopass mode)..." -Type Info
    Write-ColorOutput "This may take 10-20 seconds..." -Type Warning
    
    try {
        $dataVolume = "${DataDir}:/etc/openvpn"
        
        Invoke-ContainerRun "-v $dataVolume --rm -it kylemanna/openvpn ovpn_initpki nopass"
        
        if ($LASTEXITCODE -ne 0) {
            throw "CA generation failed"
        }
        
        # Recreate container with new config (force-recreate: gets TUN device etc.)
        Write-ColorOutput "Recreating container..." -Type Info
        Push-Location $BaseDir
        
        Invoke-Compose "up -d --force-recreate"
        
        Pop-Location
        
        if ($LASTEXITCODE -ne 0) {
            throw "Container recreation failed"
        }
        
        Start-Sleep -Seconds 3
        
        Update-State -Step "generate_ca" -Status "completed"
        Write-ColorOutput "CA certificate generated ✓" -Type Success
    }
    catch {
        Pop-Location -ErrorAction SilentlyContinue
        Update-State -Step "generate_ca" -Status "failed" -ErrorMessage $_.Exception.Message
        Write-ColorOutput "Failed to generate CA certificate!" -Type Error
        exit 1
    }
}

function Step-Verification {
    Write-ColorOutput "Step 7/7: Verifying installation..." -Type Info
    
    if (Test-StepCompleted -Step "verification") {
        Write-ColorOutput "Verification already completed, skipping..." -Type Success
        return
    }
    
    Update-State -Step "verification" -Status "in_progress"
    
    # Is container running? (wait a few seconds — don't query immediately after up)
    Start-Sleep -Seconds 5
    $running = & $script:ContainerRuntime ps --filter "name=$ContainerName" --filter "status=running" --format "{{.Names}}"
    if (-not ($running -match $ContainerName)) {
        $exitedStatus = & $script:ContainerRuntime ps -a --filter "name=$ContainerName" --format "{{.Names}} {{.Status}}"
        Write-ColorOutput "Container is not running! Status: $exitedStatus" -Type Error
        Write-ColorOutput "Logs: $script:ContainerRuntime logs $ContainerName" -Type Info
        Update-State -Step "verification" -Status "failed" -ErrorMessage "Container not running: $exitedStatus"
        exit 1
    }
    
    Write-ColorOutput "Checking port..." -Type Info
    Start-Sleep -Seconds 2
    
    # Port check
    $portInUse = Get-NetUDPEndpoint -LocalPort 11194 -ErrorAction SilentlyContinue
    if ($portInUse) {
        Write-ColorOutput "Port 11194/UDP listening ✓" -Type Success
    }
    else {
        Write-ColorOutput "Port 11194 may not be listening yet, wait a few seconds..." -Type Warning
    }
    
    # Config file check
    $configFile = Join-Path $DataDir "openvpn.conf"
    if (Test-Path $configFile) {
        Write-ColorOutput "OpenVPN config file present ✓" -Type Success
    }
    else {
        Update-State -Step "verification" -Status "failed" -ErrorMessage "openvpn.conf not found"
        Write-ColorOutput "openvpn.conf not found!" -Type Error
        exit 1
    }
    
    # PKI directory check
    $pkiDir = Join-Path $DataDir "pki"
    if (Test-Path $pkiDir) {
        Write-ColorOutput "PKI directory present ✓" -Type Success
    }
    else {
        Update-State -Step "verification" -Status "failed" -ErrorMessage "PKI directory not found"
        Write-ColorOutput "PKI directory not found!" -Type Error
        exit 1
    }
    
    Update-State -Step "verification" -Status "completed"
    Write-ColorOutput "Verification completed ✓" -Type Success
}

###############################################################################
# Main
###############################################################################

function Main {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  OpenVPN Server Setup (Windows)" -ForegroundColor Cyan
    Write-Host "  State-Aware Installation" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""

    # Initialize runtime every session (even if previous steps were skipped)
    $null = Get-RuntimeCmd
    if (-not $script:ContainerRuntime) {
        Write-ColorOutput "Docker or Podman not found! Please install one." -Type Error
        exit 1
    }

    # Podman machine: must be started BEFORE compose detection
    if ($script:ContainerRuntime -eq "podman") {
        $machineRunning = (podman machine ls 2>&1) | Select-String "Running"
        if (-not $machineRunning) {
            Write-ColorOutput "Starting Podman machine..." -Type Info
            podman machine start 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-ColorOutput "Failed to start Podman machine! Manual: podman machine start" -Type Error
                exit 1
            }
            Write-ColorOutput "Podman machine started ✓" -Type Success
        }
    }

    # Compose provider detection (after machine started)
    $script:ComposeCmd = $null
    $null = Get-ComposeCmd
    if (-not $script:ComposeCmd) {
        Write-ColorOutput "Compose provider not found!" -Type Error
        exit 1
    }

    # Test if compose actually works (podman compose may just be a wrapper)
    Push-Location $BaseDir
    $testOutput = Invoke-Expression "$script:ComposeCmd version" 2>&1
    Pop-Location
    if ($LASTEXITCODE -ne 0) {
        Write-ColorOutput "Compose not working ($script:ComposeCmd)!" -Type Error
        Write-ColorOutput "Please install one of the following:" -Type Warning
        Write-Host "  podman-compose : https://github.com/containers/podman-compose" -ForegroundColor Gray
        Write-Host "  Docker Desktop : https://docs.docker.com/desktop/windows/" -ForegroundColor Gray
        exit 1
    }
    Write-ColorOutput "Runtime: $script:ContainerRuntime | Compose: $script:ComposeCmd" -Type Info
    
    # Check if setup is already completed
    if (Test-SetupCompleted) {
        Write-ColorOutput "✓ OpenVPN setup already completed!" -Type Success
        Write-Host ""
        Write-ColorOutput "To create a user:" -Type Info
        Write-Host "  .\create-user.ps1 -Username `"username`"" -ForegroundColor White
        Write-Host ""
        Write-ColorOutput "For status check:" -Type Info
        Write-Host "  .\status.ps1" -ForegroundColor White
        Write-Host ""
        Write-ColorOutput "To reset state:" -Type Info
        Write-Host "  .\reset-state.ps1" -ForegroundColor White
        Write-Host ""
        exit 0
    }
    
    # Run steps
    try {
        Step-PreCheck
        Step-StateInit
        Step-CreateVolumes
        Step-DetectIP
        Step-StartContainer
        Step-PKIInit
        Step-GenerateCA
        Step-Verification
        
        # Mark setup as completed
        Set-SetupCompleted
        
        Write-Host ""
        Write-Host "==========================================" -ForegroundColor Green
        Write-ColorOutput "✓ OpenVPN setup completed successfully!" -Type Success
        Write-Host "==========================================" -ForegroundColor Green
        Write-Host ""
        Write-ColorOutput "Next steps:" -Type Info
        Write-Host ""
        Write-Host "1. Create a user:" -ForegroundColor White
        Write-Host "   .\create-user.ps1 -Username `"username`"" -ForegroundColor Gray
        Write-Host ""
        Write-Host "2. Copy the generated .ovpn file to the client:" -ForegroundColor White
        Write-Host "   ..\clients\<username>.ovpn" -ForegroundColor Gray
        Write-Host ""
        Write-Host "3. Connect with the OpenVPN client" -ForegroundColor White
        Write-Host ""
        Write-ColorOutput "Status check:" -Type Info
        Write-Host "   .\status.ps1" -ForegroundColor Gray
        Write-Host ""
        Write-ColorOutput "To view logs:" -Type Info
        Write-Host "   $(Get-ComposeCmd) logs -f openvpn" -ForegroundColor Gray
        Write-Host ""
    }
    catch {
        Write-ColorOutput "An error occurred: $($_.Exception.Message)" -Type Error
        Write-ColorOutput "Check the state file and run the script again." -Type Info
        exit 1
    }
}

# Run script
Main
