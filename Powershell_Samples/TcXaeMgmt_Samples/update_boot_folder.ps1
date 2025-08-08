param(
    [string]$RouteName    = "PC-784766",
    [string]$SourceFolder = "C:\Boot",
    [switch]$Restart,
    [switch]$Force
)

# Fail fast on any error
$ErrorActionPreference = 'Stop'
# Suppress progress output
$ProgressPreference    = 'SilentlyContinue'

try {
    Write-Host "INFO: Gathering files from '$SourceFolder'..."
    $files = Get-ChildItem -Path $SourceFolder -Recurse -Force -File

    Write-Host "INFO: Uploading files to remote directory 'BootDir'..."
    foreach ($f in $files) {
        $relativePath = $f.FullName.Substring($SourceFolder.Length).TrimStart('\')
        $remotePath   = $relativePath -replace '\\','/'

        Write-Host "    • $relativePath"
        Copy-AdsFile `
            -Address     $RouteName `
            -Directory   BootDir `
            -Path        $f.FullName `
            -Destination $remotePath `
            -Force       `
            -Upload
    }

    Write-Host "INFO: All files copied successfully."

    # Handle TwinCAT restart if requested
    if ($Restart) {
        Write-Host ""
        Write-Host "INFO: Initiating TwinCAT system restart..."
        
        try {
            # Build restart parameters
            $restartParams = @{
                Command = 'Reset'
                Address = $RouteName
            }
            
            # Add Force parameter if specified
            if ($Force) {
                $restartParams['Force'] = $true
                Write-Host "INFO: Using forced restart mode."
            }
            else {
                # Prompt for confirmation if not forced
                $confirmation = Read-Host "Are you sure you want to restart TwinCAT on '$RouteName'? (Y/N)"
                if ($confirmation -ne 'Y' -and $confirmation -ne 'y') {
                    Write-Host "INFO: TwinCAT restart cancelled by user."
                    exit 0
                }
            }
            
            # Execute restart
            $restartResult = Restart-TwinCAT @restartParams
            
            # Display log messages if available
            if ($restartResult.LogMessages) {
                Write-Host "INFO: TwinCAT restart initiated successfully."
                $restartResult | Select-Object -ExpandProperty LogMessages | ForEach-Object {
                    Write-Host "    LOG: [$($_.TimeStamp)] $($_.Message)"
                }
            }
            else {
                Write-Host "INFO: TwinCAT restart command sent successfully."
            }
            
            Write-Host "INFO: TwinCAT system will restart and enter Run mode."
        }
        catch {
            Write-Host "WARNING: Failed to restart TwinCAT: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "         Files were copied successfully, but restart failed."
            exit 2
        }
    }
    else {
        Write-Host ""
        Write-Host "INFO: TwinCAT restart not requested. Use -Restart parameter to restart after file copy."
    }
    
    Write-Host ""
    Write-Host "SUCCESS: Operation completed." -ForegroundColor Green
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}