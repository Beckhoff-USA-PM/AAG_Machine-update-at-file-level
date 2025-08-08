param(
    [string]$DeviceListFile = "devices.txt",
    [string]$SourceFolder = "C:\Boot",
    [string]$UpdateScript = ".\update_boot_folder.ps1",
    [switch]$Parallel,
    [int]$MaxConcurrency = 5
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
        [string]$DeviceName,
        [string]$ScriptPath,
        [string]$SourceFolder
    )
    
    try {
        Write-Log "Starting update for device: $DeviceName"
        
        # Run the update script for this device
        & $ScriptPath -RouteName $DeviceName -SourceFolder $SourceFolder
        
        Write-Log "Successfully updated device: $DeviceName" -Level "SUCCESS"
        
        # Return a PSCustomObject instead of hashtable for better CSV compatibility
        return [PSCustomObject]@{
            Device = $DeviceName
            Status = "Success"
            Error = ""  # Use empty string instead of null
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        }
    }
    catch {
        $errorMsg = $_.Exception.Message
        Write-Log "Failed to update device '$DeviceName': $errorMsg" -Level "ERROR"
        
        # Return a PSCustomObject instead of hashtable
        return [PSCustomObject]@{
            Device = $DeviceName
            Status = "Failed"
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
    
    # Read device list
    Write-Log "Reading device list from: $DeviceListFile"
    $devices = Get-Content $DeviceListFile | Where-Object { 
        $_.Trim() -ne "" -and -not $_.StartsWith("#") 
    }
    
    if ($devices.Count -eq 0) {
        throw "No devices found in the device list file"
    }
    
    Write-Log "Found $($devices.Count) devices to update"
    
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
                param($DeviceName, $ScriptPath, $SourceFolder, $FunctionDef)
                
                # Import the function definition
                . ([ScriptBlock]::Create($FunctionDef))
                
                Update-SingleDevice -DeviceName $DeviceName -ScriptPath $ScriptPath -SourceFolder $SourceFolder
            } -ArgumentList $device, (Resolve-Path $UpdateScript), $SourceFolder, ${function:Update-SingleDevice}.ToString()
            
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
            $result = Update-SingleDevice -DeviceName $device -ScriptPath $UpdateScript -SourceFolder $SourceFolder
            $results += $result
        }
    }
    
    # Summary
    Write-Log ("=" * 60)
    Write-Log "UPDATE SUMMARY"
    Write-Log ("=" * 60)
    
    $successful = $results | Where-Object { $_.Status -eq "Success" }
    $failed = $results | Where-Object { $_.Status -eq "Failed" }
    
    Write-Log "Total devices: $($devices.Count)"
    Write-Log "Successful: $($successful.Count)" -Level "SUCCESS"
    Write-Log "Failed: $($failed.Count)" -Level $(if($failed.Count -gt 0) { "ERROR" } else { "INFO" })
    
    if ($successful.Count -gt 0) {
        Write-Log ""
        Write-Log "Successful updates:"
        foreach ($success in $successful) {
            Write-Log "  [OK] $($success.Device)" -Level "SUCCESS"
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