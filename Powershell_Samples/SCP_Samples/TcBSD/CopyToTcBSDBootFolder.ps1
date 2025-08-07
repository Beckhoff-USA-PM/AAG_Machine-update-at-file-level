# Enhanced PowerShell script to copy TwinCAT boot folder to TcBSD over SSH
# Handles various source folder names and provides optional restart control
# Requires scp command (comes with Windows OpenSSH client)

param(
    [Parameter(Mandatory=$true, HelpMessage="Path to the source folder (e.g., 'TwinCAT OS (x64)', 'Boot', etc.)")]
    [string]$SourcePath,
    
    [Parameter(Mandatory=$true, HelpMessage="Remote host IP address or hostname")]
    [string]$RemoteHost,
    
    [Parameter(Mandatory=$false, HelpMessage="Restart TwinCAT in run mode after copying")]
    [switch]$RestartTwinCAT = $false,
    
    [Parameter(Mandatory=$false, HelpMessage="Username for SSH connection (default: Administrator)")]
    [string]$Username = "Administrator"
)

# Function to display script usage
function Show-Usage {
    Write-Host ""
    Write-Host "Usage Examples:" -ForegroundColor Green
    Write-Host "  .\script.ps1 -SourcePath 'C:\Path\To\TwinCAT OS (x64)' -RemoteHost 192.168.1.100"
    Write-Host "  .\script.ps1 -SourcePath 'C:\Path\To\Boot' -RemoteHost 192.168.1.100 -RestartTwinCAT"
    Write-Host "  .\script.ps1 -SourcePath '.\xyz' -RemoteHost tcbsd.local -Username myuser -RestartTwinCAT"
    Write-Host ""
}

# Validate inputs
Write-Host "=== TwinCAT Boot Folder Copy Script ===" -ForegroundColor Cyan
Write-Host ""

# Check if source folder exists
if (-not (Test-Path $SourcePath)) {
    Write-Error "Source folder '$SourcePath' not found"
    Show-Usage
    exit 1
}

# Get the absolute path and folder name
$SourcePath = Resolve-Path $SourcePath
$FolderName = Split-Path $SourcePath -Leaf

# Display configuration
Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Source folder: $SourcePath"
Write-Host "  Folder name: $FolderName"
Write-Host "  Remote host: $RemoteHost"
Write-Host "  Username: $Username"
Write-Host "  Restart TwinCAT: $(if ($RestartTwinCAT) { 'Yes' } else { 'No' })"
Write-Host "  Target destination: /usr/local/etc/TwinCAT/3.1/Boot"
Write-Host ""

# Confirm before proceeding
$confirmation = Read-Host "Proceed with the copy operation? (y/N)"
if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
    Write-Host "Operation cancelled by user" -ForegroundColor Yellow
    exit 0
}

# Destination paths
$TempDestination = "${Username}@${RemoteHost}:~/"
$FinalDestination = "/usr/local/etc/TwinCAT/3.1/Boot"

Write-Host "Starting copy operation..." -ForegroundColor Green
Write-Host "Step 1: Copying folder to remote temporary location..."

# Copy folder using scp
scp -r "$SourcePath" "$TempDestination"

if ($LASTEXITCODE -ne 0) {
    Write-Error "SCP copy failed with exit code $LASTEXITCODE"
    Write-Host "Please check:"
    Write-Host "- Network connectivity to $RemoteHost"
    Write-Host "- SSH key authentication or password access"
    Write-Host "- Remote user permissions"
    exit 1
}

Write-Host "Step 2: Moving folder to final destination and setting up permissions..."

# Build the remote command
$remoteCommands = @(
    "echo 'Creating directory structure if needed...'"
    "doas mkdir -p '$FinalDestination'"
    "echo 'Copying files to destination (overwriting existing files only)...'"
    "cd ~/$FolderName && doas cp -R ./* '$FinalDestination/'"
    "echo 'Cleaning up temporary files...'"
    "cd ~ && rm -rf '$FolderName'"
    "echo 'Setting appropriate permissions on new/updated files...'"
    "doas chown -R root:wheel '$FinalDestination'"
    "doas chmod -R 755 '$FinalDestination'"
)

# Add TwinCAT restart commands if requested
if ($RestartTwinCAT) {
    $remoteCommands += @(
        "echo 'Restarting TwinCAT in run mode...'"
        "doas TcSysExe.exe --run"
        "echo 'Checking TwinCAT mode...'"
        "TcSysExe.exe --mode"
    )
} else {
    $remoteCommands += @(
        "echo 'TwinCAT restart skipped (use -RestartTwinCAT flag to enable)'"
        "echo 'Current TwinCAT mode:'"
        "TcSysExe.exe --mode"
    )
}

# Join commands with proper separators
$fullCommand = $remoteCommands -join " && "

# Execute remote commands
ssh -t "${Username}@${RemoteHost}" "$fullCommand"

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "=== Operation Completed Successfully ===" -ForegroundColor Green
    Write-Host "Boot folder contents have been updated at: $FinalDestination"
    Write-Host "Existing files were preserved, only copied files were overwritten"
    Write-Host "Temporary files have been cleaned up"
    if ($RestartTwinCAT) {
        Write-Host "TwinCAT has been restarted in run mode"
    } else {
        Write-Host "TwinCAT was not restarted (use -RestartTwinCAT flag if needed)"
    }
} else {
    Write-Error "Remote command execution failed with exit code $LASTEXITCODE"
    Write-Host ""
    Write-Host "Troubleshooting steps:" -ForegroundColor Yellow
    Write-Host "1. Check if you have sudo/doas privileges on the remote system"
    Write-Host "2. Verify TwinCAT installation paths on the target system"
    Write-Host "3. Check if TwinCAT services are running"
    Write-Host "4. You may need to manually clean up ~/$FolderName on the remote machine"
    exit 1
}

Write-Host ""
Write-Host "Script execution completed." -ForegroundColor Cyan