param(
    [string]$RouteName    = "PC-784766",
    [string]$SourceFolder = "C:\Boot"
)

# Fail fast on any error
$ErrorActionPreference = 'Stop'
# Suppress progress output from Add-AdsRoute
$ProgressPreference    = 'SilentlyContinue'

try {
    Write-Host "INFO: Checking for ADS route '$RouteName'..."
    $route = Get-AdsRoute -Name $RouteName -ErrorAction SilentlyContinue

    if (-not $route) {
        Write-Host "INFO: No existing route found. Prompting for credentials..."
        $cred = Get-Credential -Message "Enter credentials for ADS route to '$RouteName'"

        Write-Host "INFO: Adding persistent ADS route..."
        Add-AdsRoute `
            -Credential $cred `
            -Address    $RouteName `
            -SelfSigned `
            -Passthru | Out-Null
    }
    else {
        Write-Host "INFO: ADS route '$RouteName' already exists."
    }

    # Summarize route check using numeric milliseconds and the correct property
    $stats  = Get-AdsRoute -Name $RouteName | Test-AdsRoute
    $ms     = [math]::Round($stats.Latency.TotalMilliseconds)
    $status = $stats.CommandResult
    Write-Host "INFO: Route check → Latency: ${ms} ms; Status: $status"

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
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
