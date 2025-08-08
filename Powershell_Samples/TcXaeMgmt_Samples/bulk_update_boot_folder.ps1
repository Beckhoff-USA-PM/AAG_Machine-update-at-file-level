param(
    [string]$DeviceListFile = "devices.csv",
    [string]$SourceFolder = "C:\temp\Boot",
    [string]$UpdateScript = ".\update_boot_folder.ps1",
    [switch]$Parallel,
    [int]$MaxConcurrency = 5,
    [switch]$Force
)

# Fail fast on any error
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Update-SingleDevice {
    param(
        [PSCustomObject]$DeviceInfo,
        [string]$ScriptPath,
        [string]$SourceFolder,
        [bool]$ForceRestart
    )
    
    try {
        $deviceName = $DeviceInfo."Computer Name"
        $shouldRestart = $DeviceInfo."Restart TwinCAT"
        
        Write-Log "Starting update for device: $deviceName (Restart: $shouldRestart)"
        
        # Build parameters hashtable for the update script
        $scriptParams = @{
            RouteName = $deviceName
            SourceFolder = $SourceFolder
        }
        
        # Add restart parameter if specified in CSV
        if ($shouldRestart -eq $true -or $shouldRestart -eq "True" -or $shouldRestart -eq "Y" -or $shouldRestart -eq "Yes" -or $shouldRestart -eq "1") {
            $scriptParams['Restart'] = $true
            Write-Log "TwinCAT restart will be performed for: $deviceName"
        }
        
        # Add force parameter if specified at bulk level
        if ($ForceRestart) {
            $scriptParams['Force'] = $true
        }
        
        # Run the update script for this device
        & $ScriptPath @scriptParams
        
        Write-Log "Successfully updated device: $deviceName" -Level "SUCCESS"
        
        # Return a PSCustomObject for results tracking
        return [PSCustomObject]@{
            Device = $deviceName
            Status = "Success"
            RestartRequested = $shouldRestart
            Error = ""
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
        $deviceName = if ($DeviceInfo."Computer Name") { $DeviceInfo."Computer Name" } else { "Unknown" }
        Write-Log "Failed to update device '$deviceName': $errorMsg" -Level "ERROR"
        
        # Return failure result
        return [PSCustomObject]@{
            Device = $deviceName
            Status = "Failed"
            RestartRequested = $shouldRestart
            Error = $errorMsg
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
}

try {
    # Validate input files
    if (-not (Test-Path $DeviceListFile)) {
        throw "Device list file not found: $DeviceListFile"
    }
    
    if (-not (Test-Path $UpdateScript)) {
        throw "Update script not found: $UpdateScript"
    }
    
    if (-not (Test-Path $SourceFolder)) {
        throw "Source folder not found: $SourceFolder"
    }
    
    # Read device list from CSV
    Write-Log "Reading device list from CSV: $DeviceListFile"
    try {
        $devices = Import-Csv $DeviceListFile
    }
    catch {
        throw "Failed to import CSV file '$DeviceListFile': $($_.Exception.Message)"
    }
    
    # Validate CSV structure
    $requiredColumns = @("Computer Name", "Restart TwinCAT")
    $csvColumns = $devices[0].PSObject.Properties.Name
    
    foreach ($column in $requiredColumns) {
        if ($column -notin $csvColumns) {
            throw "Required column '$column' not found in CSV file. Available columns: $($csvColumns -join ', ')"
        }
    }
    
    # Filter out empty or commented rows
    $devices = $devices | Where-Object { 
        $_."Computer Name" -and 
        $_."Computer Name".Trim() -ne "" -and 
        -not $_."Computer Name".StartsWith("#") 
    }
    
    if ($devices.Count -eq 0) {
        throw "No valid devices found in the CSV file"
    }
    
    Write-Log "Found $($devices.Count) devices to update"
    
    # Show restart summary
    $restartDevices = $devices | Where-Object { 
        $_."Restart TwinCAT" -eq $true -or 
        $_."Restart TwinCAT" -eq "True" -or 
        $_."Restart TwinCAT" -eq "Y" -or 
        $_."Restart TwinCAT" -eq "Yes" -or 
        $_."Restart TwinCAT" -eq "1" 
    }
    Write-Log "Devices scheduled for TwinCAT restart: $($restartDevices.Count)"
    
    if ($Force) {
        Write-Log "Force mode enabled - TwinCAT restarts will not require confirmation"
    }
    
    $results = @()
    
    if ($Parallel) {
        Write-Log "Running updates in parallel (Max concurrency: $MaxConcurrency)"
        
        # Use PowerShell jobs for parallel execution
        $jobs = @()
        $activeJobs = 0
        
        foreach ($device in $devices) {
            # Wait if we've reached max concurrency
            while ($activeJobs -ge $MaxConcurrency) {
                $completedJobs = Get-Job | Where-Object { $_.State -in @("Completed", "Failed") }
                if ($completedJobs) {
                    foreach ($job in $completedJobs) {
                        $result = Receive-Job $job
                        $results += $result
                        Remove-Job $job
                        $activeJobs--
                    }
                }
                Start-Sleep -Milliseconds 500
            }
            
            # Start new job
            $job = Start-Job -ScriptBlock {
                param($DeviceInfo, $ScriptPath, $SourceFolder, $ForceRestart, $FunctionDef)
                
                # Import the function definition
                . ([ScriptBlock]::Create($FunctionDef))
                
                Update-SingleDevice -DeviceInfo $DeviceInfo -ScriptPath $ScriptPath -SourceFolder $SourceFolder -ForceRestart $ForceRestart
            } -ArgumentList $device, (Resolve-Path $UpdateScript).Path, $SourceFolder, $Force.IsPresent, ${function:Update-SingleDevice}.ToString()
            
            $jobs += $job
            $activeJobs++
        }
        
        # Wait for remaining jobs to complete
        while ($jobs | Where-Object { $_.State -eq "Running" }) {
            $completedJobs = Get-Job | Where-Object { $_.State -in @("Completed", "Failed") }
            foreach ($job in $completedJobs) {
                $result = Receive-Job $job
                $results += $result
                Remove-Job $job
            }
            Start-Sleep -Milliseconds 500
        }
        
        # Clean up any remaining jobs
        Get-Job | Remove-Job -Force
    }
    else {
        Write-Log "Running updates sequentially"
        
        foreach ($device in $devices) {
            $result = Update-SingleDevice -DeviceInfo $device -ScriptPath $UpdateScript -SourceFolder $SourceFolder -ForceRestart $Force.IsPresent
            $results += $result
        }
    }
    
    # Summary
    Write-Log ("=" * 60)
    Write-Log "UPDATE SUMMARY"
    Write-Log ("=" * 60)
    
    $successful = $results | Where-Object { $_.Status -eq "Success" }
    $failed = $results | Where-Object { $_.Status -eq "Failed" }
    $restarted = $results | Where-Object { $_.Status -eq "Success" -and $_.RestartRequested -in @($true, "True", "Y", "Yes", "1") }
    
    Write-Log "Total devices: $($devices.Count)"
    Write-Log "Successful: $($successful.Count)" -Level "SUCCESS"
    Write-Log "Failed: $($failed.Count)" -Level $(if($failed.Count -gt 0) { "ERROR" } else { "INFO" })
    Write-Log "TwinCAT restarted: $($restarted.Count)" -Level "INFO"
    
    if ($successful.Count -gt 0) {
        Write-Log ""
        Write-Log "Successful updates:"
        foreach ($success in $successful) {
            $restartStatus = if ($success.RestartRequested -in @($true, "True", "Y", "Yes", "1")) { " (Restarted)" } else { "" }
            Write-Log "  [OK] $($success.Device)$restartStatus" -Level "SUCCESS"
        }
    }
    
    if ($failed.Count -gt 0) {
        Write-Log ""
        Write-Log "Failed updates:"
        foreach ($failure in $failed) {
            Write-Log "  [FAIL] $($failure.Device): $($failure.Error)" -Level "ERROR"
        }
    }
    
    # Export results to CSV for record keeping
    $csvFile = "update_results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    
    # Ensure we have results to export and they're in the right format
    if ($results.Count -gt 0) {
        try {
            $results | Export-Csv -Path $csvFile -NoTypeInformation
            Write-Log "Detailed results exported to: $csvFile"
        }
        catch {
            Write-Log "Warning: Could not export results to CSV: $($_.Exception.Message)" -Level "WARN"
        }
    }
    else {
        Write-Log "No results to export to CSV" -Level "WARN"
    }
    
    # Exit with appropriate code
    if ($failed.Count -gt 0) {
        exit 1
    }
    else {
        exit 0
    }
}
catch {
    Write-Log "Script execution failed: $($_.Exception.Message)" -Level "ERROR"
    exit 1
}