<#
.SYNOPSIS
    Creates ADS routes to multiple TwinCAT runtimes based on a CSV file.

.DESCRIPTION
    This script reads a CSV file containing TwinCAT runtime information and creates
    ADS routes for each runtime if they don't already exist. It can use broadcast
    search to discover IP addresses when not provided.

.PARAMETER CsvPath
    Path to the CSV file containing runtime information.
    CSV should have columns: Computer Name, User, Password, UseIP (optional), IPAddress (optional)

.PARAMETER SkipExisting
    If specified, skip routes that already exist without prompting.

.PARAMETER BroadcastTimeout
    Timeout in seconds for broadcast search (default: 5 seconds)

.EXAMPLE
    .\bulk_create_AdsRoutes.ps1
    # Uses default values: -CsvPath ".\runtimes.csv" -SkipExisting

.EXAMPLE
    .\bulk_create_AdsRoutes.ps1 -CsvPath "C:\Config\TwinCATRuntimes.csv"

.EXAMPLE
    .\bulk_create_AdsRoutes.ps1 -SkipExisting:$false -BroadcastTimeout 10
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [string]$CsvPath = ".\runtimes.csv",

    [switch]$SkipExisting = $true,
    
    [int]$BroadcastTimeout = 5
)

# Import required module
try {
    Import-Module TcXaeMgmt -ErrorAction Stop
} catch {
    Write-Error "Failed to import TcXaeMgmt module. Please ensure TwinCAT is installed."
    exit 1
}

# Save original progress preference and suppress progress bars for this script
$OriginalProgressPreference = $ProgressPreference
$ProgressPreference = "SilentlyContinue"

# Script-level variable to store broadcast search results
$script:BroadcastResults = @()

# Function to perform broadcast search once and cache results
function Get-CachedBroadcastResults {
    param(
        [int]$Timeout = 5
    )
    
    if ($script:BroadcastResults.Count -eq 0) {
        Write-Host "Performing broadcast search to discover devices..." -ForegroundColor Cyan
        Write-Host "Timeout: $Timeout seconds" -ForegroundColor Gray
        
        try {
            $script:BroadcastResults = @(Get-AdsRoute -All)
            Write-Host "Found $($script:BroadcastResults.Count) device(s) on network" -ForegroundColor Green
            
            # Display discovered devices
            if ($script:BroadcastResults.Count -gt 0) {
                Write-Host "`nDiscovered devices:" -ForegroundColor Gray
                $script:BroadcastResults | ForEach-Object {
                    Write-Host "  - $($_.Name) at $($_.Address) (NetId: $($_.NetId))" -ForegroundColor Gray
                }
                Write-Host ""
            }
        }
        catch {
            Write-Warning "Broadcast search failed: $_"
            $script:BroadcastResults = @()
        }
    }
    
    return $script:BroadcastResults
}

# Function to find device IP from cached broadcast results
function Find-DeviceIP {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ComputerName
    )
    
    # Use cached results
    $routes = Get-CachedBroadcastResults
    
    # Look for matching computer name
    $matchingRoute = $routes | Where-Object { $_.Name -eq $ComputerName }
    
    if ($matchingRoute) {
        Write-Host "INFO: Found '$ComputerName' in broadcast results at IP: $($matchingRoute.Address)" -ForegroundColor Green
        return $matchingRoute.Address
    }
    else {
        Write-Warning "Device '$ComputerName' not found in broadcast results"
        return $null
    }
}

# Function to add a single ADS route
function Add-SingleAdsRoute {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ComputerName,
        
        [Parameter(Mandatory=$true)]
        [string]$User,
        
        [Parameter(Mandatory=$true)]
        [string]$Password,
        
        [string]$UseIP,
        
        [string]$IPAddress,
        
        [bool]$SkipIfExists
    )
    
    Write-Host "`nProcessing route: '$ComputerName'" -ForegroundColor Cyan
    
    # Determine what address to use for the route
    $routeAddress = $ComputerName  # Default to computer name
    $routeName = $ComputerName
    
    # Check if we should use IP address
    $shouldUseIP = ($UseIP -eq 'true' -or $UseIP -eq 'yes' -or $UseIP -eq '1' -or $UseIP -eq 'y')
    
    if ($shouldUseIP) {
        Write-Host "INFO: Route configured to use IP address" -ForegroundColor Gray
        
        if (![string]::IsNullOrWhiteSpace($IPAddress)) {
            # IP address provided in CSV
            $routeAddress = $IPAddress
            Write-Host "INFO: Using provided IP address: $routeAddress" -ForegroundColor Gray
        }
        else {
            # Need to discover IP from cached broadcast results
            $discoveredIP = Find-DeviceIP -ComputerName $ComputerName
            
            if ($discoveredIP) {
                $routeAddress = $discoveredIP
            }
            else {
                Write-Warning "Could not determine IP address for '$ComputerName'. Falling back to hostname."
                $routeAddress = $ComputerName
            }
        }
    }
    else {
        Write-Host "INFO: Using hostname for route address: $routeAddress" -ForegroundColor Gray
    }
    
    Write-Host "INFO: Checking for existing ADS route '$routeName'..."
    
    try {
        $route = Get-AdsRoute -Name $routeName -ErrorAction SilentlyContinue
        
        if (-not $route) {
            Write-Host "INFO: No existing route found. Creating credentials..." -ForegroundColor Yellow
            
            # Create credential object from provided username and password
            $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential($User, $securePassword)
            
            Write-Host "INFO: Adding persistent ADS route..." -ForegroundColor Green
            Write-Host "      Route Name: $routeName" -ForegroundColor Gray
            Write-Host "      Address: $routeAddress" -ForegroundColor Gray
            Write-Host "      User: $User" -ForegroundColor Gray
            
            Add-AdsRoute `
                -Credential $cred `
                -Address $routeAddress `
                -SelfSigned `
                -Passthru | Out-Null
                
            Write-Host "SUCCESS: ADS route '$routeName' added successfully." -ForegroundColor Green
            return "Success"
        }
        else {
            if ($SkipIfExists) {
                Write-Host "INFO: ADS route '$routeName' already exists. Skipping." -ForegroundColor Gray
                Write-Host "      Current Address: $($route.Address)" -ForegroundColor Gray
                return "Skipped"
            } else {
                Write-Host "INFO: ADS route '$routeName' already exists." -ForegroundColor Yellow
                Write-Host "      Current Address: $($route.Address)" -ForegroundColor Gray
                $response = Read-Host "Do you want to update it? (Y/N)"
                
                if ($response -eq 'Y' -or $response -eq 'y') {
                    Write-Host "INFO: Removing existing route..." -ForegroundColor Yellow
                    Remove-AdsRoute -Name $routeName -Force
                    
                    Write-Host "INFO: Creating new route with provided credentials..." -ForegroundColor Yellow
                    
                    # Create credential object from provided username and password
                    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
                    $cred = New-Object System.Management.Automation.PSCredential($User, $securePassword)
                    
                    Write-Host "      Route Name: $routeName" -ForegroundColor Gray
                    Write-Host "      Address: $routeAddress" -ForegroundColor Gray
                    Write-Host "      User: $User" -ForegroundColor Gray
                    
                    Add-AdsRoute `
                        -Credential $cred `
                        -Address $routeAddress `
                        -SelfSigned `
                        -Passthru | Out-Null
                        
                    Write-Host "SUCCESS: ADS route '$routeName' updated successfully." -ForegroundColor Green
                    return "Success"
                }
                else {
                    return "Skipped"
                }
            }
        }
    }
    catch {
        Write-Error "Failed to process route '$ComputerName': $_"
        throw
    }
}

# Main script execution
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  TwinCAT Bulk ADS Route Creation Script" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Read CSV file
try {
    Write-Host "Reading CSV file: $CsvPath" -ForegroundColor White
    $runtimes = Import-Csv -Path $CsvPath
    
    if ($runtimes.Count -eq 0) {
        Write-Warning "No entries found in CSV file."
        exit 0
    }
    
    Write-Host "Found $($runtimes.Count) runtime(s) in CSV file.`n" -ForegroundColor White
    
    # Validate required CSV columns
    $csvColumns = $runtimes[0].PSObject.Properties.Name
    
    # Check if required columns exist (handling potential variations in column names)
    $hasComputerName = ($csvColumns -contains 'Computer Name') -or ($csvColumns -contains 'ComputerName')
    $hasUser = $csvColumns -contains 'User'
    $hasPassword = $csvColumns -contains 'Password'
    
    if (-not ($hasComputerName -and $hasUser -and $hasPassword)) {
        Write-Error "Required columns not found in CSV file."
        Write-Host "Required columns: 'Computer Name', 'User', 'Password'"
        Write-Host "Optional columns: 'UseIP', 'IPAddress'"
        Write-Host "Found columns: $($csvColumns -join ', ')"
        exit 1
    }
    
    # Display optional column usage
    $hasUseIP = $csvColumns -contains 'UseIP'
    $hasIPAddress = $csvColumns -contains 'IPAddress'
    
    if ($hasUseIP -or $hasIPAddress) {
        Write-Host "Optional columns detected:" -ForegroundColor Gray
        if ($hasUseIP) { Write-Host "  - UseIP: Controls whether to use IP address" -ForegroundColor Gray }
        if ($hasIPAddress) { Write-Host "  - IPAddress: Provides specific IP address" -ForegroundColor Gray }
        Write-Host ""
    }
}
catch {
    Write-Error "Failed to read CSV file: $_"
    exit 1
}

# Check if any entries need IP discovery and perform single broadcast search
$needsBroadcast = $false
foreach ($runtime in $runtimes) {
    $useIP = $runtime.UseIP
    $ipAddress = $runtime.IPAddress
    $shouldUseIP = ($useIP -eq 'true' -or $useIP -eq 'yes' -or $useIP -eq '1' -or $useIP -eq 'y')
    
    if ($shouldUseIP -and [string]::IsNullOrWhiteSpace($ipAddress)) {
        $needsBroadcast = $true
        break
    }
}

# Perform single broadcast search if needed
if ($needsBroadcast) {
    $null = Get-CachedBroadcastResults -Timeout $BroadcastTimeout
}

# Process each runtime
$successCount = 0
$skipCount = 0
$errorCount = 0
$failedRoutes = @()

foreach ($runtime in $runtimes) {
    # Handle both 'Computer Name' and 'ComputerName' column names
    $computerName = if ($runtime.'Computer Name') { $runtime.'Computer Name' } else { $runtime.ComputerName }
    $user = $runtime.User
    $password = $runtime.Password
    $useIP = $runtime.UseIP
    $ipAddress = $runtime.IPAddress
    
    # Validate required fields
    if ([string]::IsNullOrWhiteSpace($computerName)) {
        Write-Warning "Skipping entry with empty Computer Name"
        $skipCount++
        continue
    }
    
    if ([string]::IsNullOrWhiteSpace($user)) {
        Write-Warning "Skipping entry for '$computerName' - missing User"
        $skipCount++
        continue
    }
    
    if ([string]::IsNullOrWhiteSpace($password)) {
        Write-Warning "Skipping entry for '$computerName' - missing Password"
        $skipCount++
        continue
    }
    
    try {
        $result = Add-SingleAdsRoute `
            -ComputerName $computerName `
            -User $user `
            -Password $password `
            -UseIP $useIP `
            -IPAddress $ipAddress `
            -SkipIfExists $SkipExisting
        
        # Properly categorize the result
        switch ($result) {
            "Success" { $successCount++ }
            "Skipped" { $skipCount++ }
            default { $successCount++ }  # Fallback for backwards compatibility
        }
    }
    catch {
        $errorCount++
        $failedRoutes += $computerName
        Write-Error "Failed to process route '$computerName': $_"
    }
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total entries: $($runtimes.Count)" -ForegroundColor White
Write-Host "Success:       $successCount" -ForegroundColor Green
Write-Host "Skipped:       $skipCount" -ForegroundColor Yellow
Write-Host "Errors:        $errorCount" -ForegroundColor Red

if ($failedRoutes.Count -gt 0) {
    Write-Host "`nFailed routes:" -ForegroundColor Red
    $failedRoutes | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}

if ($errorCount -gt 0) {
    Write-Host "`nScript completed with errors. Please review the error messages above." -ForegroundColor Yellow
} else {
    Write-Host "`nScript completed successfully!" -ForegroundColor Green
}

# Optional: List all current routes
$showRoutes = Read-Host "`nDo you want to display all current ADS routes? (Y/N)"
if ($showRoutes -eq 'Y' -or $showRoutes -eq 'y') {
    Write-Host "`nCurrent ADS Routes:" -ForegroundColor Cyan
    Get-AdsRoute | Format-Table -Property Name, Address, NetId, TcVersion, RTSystem -AutoSize
}

# Security reminder
Write-Host "`n[SECURITY NOTE] The CSV file contains passwords in plain text." -ForegroundColor Yellow
Write-Host "Consider deleting or securing the CSV file after use." -ForegroundColor Yellow

# Restore original progress preference
$ProgressPreference = $OriginalProgressPreference