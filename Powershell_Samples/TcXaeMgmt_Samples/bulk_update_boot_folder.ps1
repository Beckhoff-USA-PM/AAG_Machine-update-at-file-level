param(
    [string]$DeviceListFile = "devices.csv",
    [string]$SourceFolder = "C:\Boot",
    [string]$UpdateScript = ".\update_boot_folder.ps1",
    [switch]$Parallel,
    [int]$MaxConcurrency = 5,
    [switch]$Force,
    [string]$LogFile = "bulk_update_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
)

# Fail fast on any error
$ErrorActionPreference = 'Stop'

# Initialize log file
$script:LogFilePath = $LogFile
if (-not [System.IO.Path]::IsPathRooted($LogFile)) {
    $script:LogFilePath = Join-Path (Get-Location).Path $LogFile
}

# Create or clear the log file
try {
    $null = New-Item -Path $script:LogFilePath -ItemType File -Force
    $logHeader = @"
========================================
Bulk Boot Folder Update Log
Started: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
========================================

"@
    Add-Content -Path $script:LogFilePath -Value $logHeader
}
catch {
    Write-Host "Warning: Could not create log file at $script:LogFilePath. Logging to console only." -ForegroundColor Yellow
    $script:LogFilePath = $null
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to console with color
    $color = switch($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host $logEntry -ForegroundColor $color
    
    # Write to log file
    if ($script:LogFilePath) {
        try {
            Add-Content -Path $script:LogFilePath -Value $logEntry
        }
        catch {
            # If we can't write to the log file, just continue
        }
    }
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
    Write-Log "Script parameters:"
    Write-Log "  Device List File: $DeviceListFile"
    Write-Log "  Source Folder: $SourceFolder"
    Write-Log "  Update Script: $UpdateScript"
    Write-Log "  Parallel Mode: $($Parallel.IsPresent)"
    Write-Log "  Max Concurrency: $MaxConcurrency"
    Write-Log "  Force Mode: $($Force.IsPresent)"
    Write-Log "  Log File: $script:LogFilePath"
    Write-Log ""
    
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
    
    # Log device list
    Write-Log "Device list:"
    foreach ($device in $devices) {
        $restartFlag = if ($device."Restart TwinCAT" -in @($true, "True", "Y", "Yes", "1")) { "[RESTART]" } else { "[NO-RESTART]" }
        Write-Log "  - $($device."Computer Name") $restartFlag"
    }
    Write-Log ""
    
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
    
    Write-Log ""
    Write-Log ("=" * 60)
    Write-Log "STARTING UPDATE PROCESS"
    Write-Log ("=" * 60)
    Write-Log ""
    
    $results = @()
    
    if ($Parallel) {
        Write-Log "Running updates in parallel (Max concurrency: $MaxConcurrency)"
        
        # Use Start-Process for parallel execution since PowerShell jobs don't inherit module context
        $processes = @()
        $activeProcesses = 0
        $tempDir = $env:TEMP
        
        foreach ($device in $devices) {
            # Wait if we've reached max concurrency
            while ($activeProcesses -ge $MaxConcurrency) {
                $runningProcesses = $processes | Where-Object { -not $_.HasExited }
                if ($runningProcesses.Count -lt $activeProcesses) {
                    # Some processes have finished, collect their results
                    $finishedProcesses = $processes | Where-Object { $_.HasExited }
                    foreach ($proc in $finishedProcesses) {
                        $deviceName = $proc.StartInfo.EnvironmentVariables["DEVICE_NAME"]
                        $resultFile = Join-Path $tempDir "result_$($proc.Id).json"
                        
                        if (Test-Path $resultFile) {
                            try {
                                $result = Get-Content $resultFile -Raw | ConvertFrom-Json
                                $results += [PSCustomObject]@{
                                    Device = $result.Device
                                    Status = $result.Status
                                    RestartRequested = $result.RestartRequested
                                    Error = $result.Error
                                    Timestamp = $result.Timestamp
                                }
                                Remove-Item $resultFile -Force
                            }
                            catch {
                                Write-Log "Warning: Could not read result for device '$deviceName': $($_.Exception.Message)" -Level "WARN"
                                $results += [PSCustomObject]@{
                                    Device = $deviceName
                                    Status = "Failed"
                                    RestartRequested = "Unknown"
                                    Error = "Could not read process result"
                                    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                                }
                            }
                        } else {
                            $results += [PSCustomObject]@{
                                Device = $deviceName
                                Status = "Failed"  
                                RestartRequested = "Unknown"
                                Error = "Process completed but no result file found"
                                Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                            }
                        }
                    }
                    
                    # Remove finished processes from tracking
                    $processes = $processes | Where-Object { -not $_.HasExited }
                    $activeProcesses = $processes.Count
                }
                Start-Sleep -Milliseconds 500
            }
            
            # Build command line arguments
            $deviceName = $device."Computer Name"
            $shouldRestart = $device."Restart TwinCAT"
            
            $arguments = @(
                "-File", "`"$((Resolve-Path $UpdateScript).Path)`""
                "-RouteName", "`"$deviceName`""
                "-SourceFolder", "`"$SourceFolder`""
            )
            
            if ($shouldRestart -eq $true -or $shouldRestart -eq "True" -or $shouldRestart -eq "Y" -or $shouldRestart -eq "Yes" -or $shouldRestart -eq "1") {
                $arguments += "-Restart"
            }
            
            if ($Force.IsPresent) {
                $arguments += "-Force"
            }
            
            # Create a wrapper script that captures output and writes results to a file
            $resultFile = Join-Path $tempDir "result_$([System.Guid]::NewGuid().ToString('N')).json"
            $wrapperScript = @"
`$ErrorActionPreference = 'Stop'
try {
    & '$((Resolve-Path $UpdateScript).Path)' -RouteName "$deviceName" -SourceFolder "$SourceFolder" $(if ($shouldRestart -eq $true -or $shouldRestart -eq "True" -or $shouldRestart -eq "Y" -or $shouldRestart -eq "Yes" -or $shouldRestart -eq "1") { "-Restart" }) $(if ($Force.IsPresent) { "-Force" })
    
    @{
        Device = "$deviceName"
        Status = "Success"
        RestartRequested = "$shouldRestart"
        Error = ""
        Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json | Out-File -FilePath "$resultFile" -Encoding UTF8 -Force
    exit 0
}
catch {
    @{
        Device = "$deviceName"
        Status = "Failed"
        RestartRequested = "$shouldRestart"
        Error = `$_.Exception.Message
        Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    } | ConvertTo-Json | Out-File -FilePath "$resultFile" -Encoding UTF8 -Force
    exit 1
}
"@
            
            $wrapperFile = Join-Path $tempDir "wrapper_$([System.Guid]::NewGuid().ToString('N')).ps1"
            $wrapperScript | Out-File -FilePath $wrapperFile -Encoding UTF8
            
            # Start the process
            $processInfo = New-Object System.Diagnostics.ProcessStartInfo
            $processInfo.FileName = "powershell.exe"
            $processInfo.Arguments = "-ExecutionPolicy Bypass -File `"$wrapperFile`""
            $processInfo.UseShellExecute = $false
            $processInfo.RedirectStandardOutput = $true
            $processInfo.RedirectStandardError = $true
            $processInfo.CreateNoWindow = $true
            $processInfo.EnvironmentVariables["DEVICE_NAME"] = $deviceName
            $processInfo.EnvironmentVariables["RESULT_FILE"] = $resultFile
            $processInfo.EnvironmentVariables["WRAPPER_FILE"] = $wrapperFile
            
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $processInfo
            $process.Start() | Out-Null
            
            $processes += $process
            $activeProcesses++
            
            Write-Log "Started parallel update for device: $deviceName (PID: $($process.Id))"
        }
        
        # Wait for all remaining processes to complete
        Write-Log "Waiting for all parallel processes to complete..."
        $processedPIDs = @()
        
        while ($processes | Where-Object { -not $_.HasExited }) {
            $runningProcesses = $processes | Where-Object { -not $_.HasExited }
            Write-Log "Still waiting for $($runningProcesses.Count) processes to complete..."
            Start-Sleep -Seconds 2
        }
        
        Write-Log "All processes have exited. Collecting results..."
        
        # Now collect all results after all processes are complete
        foreach ($proc in $processes) {
            $deviceName = $proc.StartInfo.EnvironmentVariables["DEVICE_NAME"]
            $resultFile = $proc.StartInfo.EnvironmentVariables["RESULT_FILE"]
            $wrapperFile = $proc.StartInfo.EnvironmentVariables["WRAPPER_FILE"]
            
            Write-Log "Collecting results for device: $deviceName (PID: $($proc.Id))"
            
            if (Test-Path $resultFile) {
                try {
                    $result = Get-Content $resultFile -Raw | ConvertFrom-Json
                    $results += [PSCustomObject]@{
                        Device = $result.Device
                        Status = $result.Status
                        RestartRequested = $result.RestartRequested
                        Error = $result.Error
                        Timestamp = $result.Timestamp
                    }
                    Write-Log "Successfully collected results for device: $deviceName - Status: $($result.Status)"
                    Remove-Item $resultFile -Force -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Log "Warning: Could not read result for device '$deviceName': $($_.Exception.Message)" -Level "WARN"
                    $results += [PSCustomObject]@{
                        Device = $deviceName
                        Status = "Failed"
                        RestartRequested = "Unknown"
                        Error = "Could not read process result: $($_.Exception.Message)"
                        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    }
                }
            }
            else {
                Write-Log "Warning: Result file not found for device '$deviceName'" -Level "WARN"
                # Still try to determine if it was successful based on exit code
                $exitCode = $proc.ExitCode
                if ($exitCode -eq 0) {
                    Write-Log "Process exited with code 0, assuming success for device: $deviceName"
                    $results += [PSCustomObject]@{
                        Device = $deviceName
                        Status = "Success"
                        RestartRequested = "Unknown"
                        Error = ""
                        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    }
                }
                else {
                    Write-Log "Process exited with code $exitCode, assuming failure for device: $deviceName" -Level "ERROR"
                    $results += [PSCustomObject]@{
                        Device = $deviceName
                        Status = "Failed"
                        RestartRequested = "Unknown"
                        Error = "Process exited with code $exitCode"
                        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    }
                }
            }
            
            # Clean up wrapper file
            if (Test-Path $wrapperFile) {
                Remove-Item $wrapperFile -Force -ErrorAction SilentlyContinue
            }
        }
        
        Write-Log "All parallel processes completed and results collected"
    }
    else {
        Write-Log "Running updates sequentially"
        
        foreach ($device in $devices) {
            $result = Update-SingleDevice -DeviceInfo $device -ScriptPath $UpdateScript -SourceFolder $SourceFolder -ForceRestart $Force.IsPresent
            $results += $result
        }
    }
    
    Write-Log ""
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
    
    # Write detailed results to log file
    if ($results.Count -gt 0) {
        Write-Log ""
        Write-Log ("=" * 60)
        Write-Log "DETAILED RESULTS"
        Write-Log ("=" * 60)
        Write-Log ""
        Write-Log "Device Name                    | Status    | Restart Requested | Timestamp                | Error"
        Write-Log ("-" * 120)
        
        foreach ($result in $results) {
            $deviceCol = $result.Device.PadRight(30).Substring(0, 30)
            $statusCol = $result.Status.PadRight(9).Substring(0, 9)
            $restartCol = $result.RestartRequested.ToString().PadRight(17).Substring(0, 17)
            $timestampCol = $result.Timestamp.PadRight(24).Substring(0, 24)
            $errorCol = if ($result.Error) { $result.Error } else { "N/A" }
            
            $logLevel = if ($result.Status -eq "Success") { "SUCCESS" } else { "ERROR" }
            Write-Log "$deviceCol | $statusCol | $restartCol | $timestampCol | $errorCol" -Level $logLevel
        }
        
        Write-Log ("-" * 120)
    }
    
    Write-Log ""
    Write-Log ("=" * 60)
    Write-Log "Script completed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log "Log file location: $script:LogFilePath"
    Write-Log ("=" * 60)
    
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
    Write-Log ""
    Write-Log "Stack trace:" -Level "ERROR"
    Write-Log $_.ScriptStackTrace -Level "ERROR"
    Write-Log ""
    Write-Log ("=" * 60)
    Write-Log "Script terminated with error at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Log ("=" * 60)
    exit 1
}