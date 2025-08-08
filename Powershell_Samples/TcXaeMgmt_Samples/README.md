# TcXaeMgmt PowerShell Samples

This directory contains PowerShell scripts that leverage the TcXaeMgmt module for TwinCAT automation and management tasks.

## Prerequisites

- **TwinCAT 3** must be installed on the system running these scripts
- **TcXaeMgmt PowerShell module** (included with TwinCAT installation)
- **PowerShell 5.1** or later (PowerShell 7+ recommended)
- **Administrator privileges** may be required for certain operations

## Available Scripts

### 1. bulk_create_AdsRoutes.ps1

Creates ADS routes to multiple TwinCAT runtimes based on a CSV file configuration.

**Features:**
- Batch creation of ADS routes from CSV input
- Automatic discovery of device IP addresses via broadcast search
- Skip existing routes option
- Configurable broadcast timeout
- Detailed logging and error reporting

**Usage:**
```powershell
# Use default CSV file (runtimes.csv)
.\bulk_create_AdsRoutes.ps1

# Specify custom CSV file
.\bulk_create_AdsRoutes.ps1 -CsvPath "C:\Config\TwinCATRuntimes.csv"

# Don't skip existing routes (prompt for each)
.\bulk_create_AdsRoutes.ps1 -SkipExisting:$false -BroadcastTimeout 10
```

**CSV Format (runtimes.csv):**
```csv
Computer Name,User,Password,UseIP,IPAddress
Device1,Administrator,password123,true,192.168.1.100
Device2,Administrator,password456,true,
```

### 2. update_boot_folder.ps1

Updates TwinCAT boot folder on a remote runtime via ADS file transfer.

**Features:**
- Copy boot folder contents to remote TwinCAT runtime
- Optional TwinCAT system restart
- Force mode for unattended operation
- Progress reporting for file transfers

**Usage:**
```powershell
# Basic file copy
.\update_boot_folder.ps1 -RouteName "Device1" -SourceFolder "C:\Boot"

# Copy and restart TwinCAT
.\update_boot_folder.ps1 -RouteName "Device1" -SourceFolder "C:\Boot" -Restart

# Force restart without confirmation
.\update_boot_folder.ps1 -RouteName "Device1" -SourceFolder "C:\Boot" -Restart -Force
```

### 3. bulk_update_boot_folder.ps1

Orchestrates boot folder updates across multiple TwinCAT runtimes.

**Features:**
- Batch processing from CSV configuration
- Parallel or sequential execution modes
- Configurable concurrency for parallel mode
- Comprehensive logging with timestamps
- Automatic restart management per device
- Detailed success/failure reporting

**Usage:**
```powershell
# Sequential update (default)
.\bulk_update_boot_folder.ps1 -DeviceListFile "devices.csv" -SourceFolder "C:\Boot"

# Parallel update with max 5 concurrent operations
.\bulk_update_boot_folder.ps1 -Parallel -MaxConcurrency 5 -SourceFolder "C:\Boot"

# Force mode (no restart confirmations)
.\bulk_update_boot_folder.ps1 -Force -SourceFolder "C:\Boot"

# Custom log file
.\bulk_update_boot_folder.ps1 -LogFile "update_log.txt" -SourceFolder "C:\Boot"
```

**CSV Format (devices.csv):**
```csv
Computer Name,Restart TwinCAT
Device1,true
Device2,false
Device3,yes
```

## Configuration Files

### runtimes.csv
Used by `bulk_create_AdsRoutes.ps1` for ADS route configuration.

**Columns:**
- `Computer Name` (required): Target runtime name
- `User` (required): Username for authentication
- `Password` (required): Password for authentication
- `UseIP` (optional): Whether to use IP address instead of hostname (true/false)
- `IPAddress` (optional): Specific IP address to use

### devices.csv
Used by `bulk_update_boot_folder.ps1` for batch updates.

**Columns:**
- `Computer Name` (required): Target runtime name (must have existing ADS route)
- `Restart TwinCAT` (required): Whether to restart TwinCAT after update (true/false/yes/no/y/n/1/0)

## Common Workflows

### Initial Setup Workflow
1. Create ADS routes to all target runtimes:
   ```powershell
   .\bulk_create_AdsRoutes.ps1 -CsvPath "runtimes.csv"
   ```

2. Update boot folders across all runtimes:
   ```powershell
   .\bulk_update_boot_folder.ps1 -DeviceListFile "devices.csv" -SourceFolder "C:\Boot"
   ```

### Production Deployment Workflow
1. Prepare your boot folder with the latest PLC project
2. Test on a single device:
   ```powershell
   .\update_boot_folder.ps1 -RouteName "TestDevice" -SourceFolder "C:\Boot" -Restart
   ```
3. Deploy to all production devices:
   ```powershell
   .\bulk_update_boot_folder.ps1 -Parallel -Force -SourceFolder "C:\Boot"
   ```

## Important Notes

- **Security**: CSV files contain passwords in plain text. Secure or delete these files after use.
- **ADS Routes**: Target devices must be accessible via ADS. Routes must exist before running update scripts.
- **Permissions**: Administrator privileges required on target systems for boot folder updates.
- **Network**: Ensure stable network connectivity during bulk operations.
- **Backup**: Always backup existing boot folders before updates in production environments.

## Troubleshooting

### Common Issues

1. **"TcXaeMgmt module not found"**
   - Ensure TwinCAT 3 is installed
   - Run PowerShell as Administrator
   - Import module manually: `Import-Module TcXaeMgmt`

2. **"ADS route not found"**
   - Verify route exists: `Get-AdsRoute`
   - Create route first using `bulk_create_AdsRoutes.ps1`

3. **"Access denied" errors**
   - Verify credentials in CSV files
   - Ensure user has sufficient permissions on target system
   - Check Windows Firewall settings

4. **Broadcast search not finding devices**
   - Increase timeout: `-BroadcastTimeout 10`
   - Verify network connectivity
   - Check if ADS/AMS Router service is running on targets

## Examples

### Example 1: Deploy to specific device group
```powershell
# Create custom device list
@"
Computer Name,Restart TwinCAT
ProductionLine1,true
ProductionLine2,true
ProductionLine3,false
"@ | Out-File -FilePath "production_devices.csv"

# Deploy with logging
.\bulk_update_boot_folder.ps1 `
    -DeviceListFile "production_devices.csv" `
    -SourceFolder "C:\Releases\v1.2.3\Boot" `
    -LogFile "deployment_$(Get-Date -Format 'yyyyMMdd').log" `
    -Force
```

### Example 2: Parallel deployment with progress monitoring
```powershell
# Deploy to all devices in parallel
.\bulk_update_boot_folder.ps1 `
    -DeviceListFile "all_devices.csv" `
    -SourceFolder "C:\CurrentBoot" `
    -Parallel `
    -MaxConcurrency 10 `
    -Force
```

## Support

For issues or questions about these scripts:
1. Check the generated log files for detailed error information
2. Verify TwinCAT and network configuration
3. Consult Beckhoff InfoSys documentation for TcXaeMgmt module reference