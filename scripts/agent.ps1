# VCTC Server Monitor Agent
# Schedule this as a Windows Scheduled Task to run every 30 minutes.
# Task Action: powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\vctc-agent.ps1"

$API_URL  = "https://YOUR-SERVER/api/checkin"   # Replace with your server URL
$API_KEY  = "YOUR_API_KEY_HERE"                  # Replace with the key from server registration

# ── OS Info ───────────────────────────────────────────────────────────────────
$os = Get-CimInstance Win32_OperatingSystem
$osInfo = "$($os.Caption) (Build $($os.BuildNumber))"
$uptimeSeconds = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds

# ── Disk Usage ────────────────────────────────────────────────────────────────
$disks = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null -and $_.Free -ne $null } | ForEach-Object {
    $total = $_.Used + $_.Free
    $usedPct = if ($total -gt 0) { [math]::Round(($_.Used / $total) * 100, 1) } else { 0 }
    @{
        drive     = $_.Root
        total_gb  = [math]::Round($total / 1GB, 2)
        free_gb   = [math]::Round($_.Free / 1GB, 2)
        used_pct  = $usedPct
    }
}

# ── Windows Updates ───────────────────────────────────────────────────────────
$pendingUpdates = 0
$lastUpdateInstalled = $null
try {
    $updateSession = New-Object -ComObject Microsoft.Update.Session
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    $searchResult = $updateSearcher.Search("IsInstalled=0 and Type='Software'")
    $pendingUpdates = $searchResult.Updates.Count

    # Last installed update
    $historyCount = $updateSearcher.GetTotalHistoryCount()
    if ($historyCount -gt 0) {
        $history = $updateSearcher.QueryHistory(0, [math]::Min($historyCount, 20)) | Where-Object { $_.ResultCode -eq 2 } | Sort-Object Date -Descending | Select-Object -First 1
        if ($history) { $lastUpdateInstalled = $history.Date.ToString("yyyy-MM-ddTHH:mm:ss") }
    }
} catch {
    Write-Warning "Could not query Windows Updates: $_"
}

# ── Services to Monitor ───────────────────────────────────────────────────────
# Add any service names you want to monitor here
$serviceNames = @(
    "wuauserv",      # Windows Update
    "W32Time",       # Windows Time
    "Dnscache",      # DNS Client
    "LanmanServer",  # Server (file sharing)
    "WinRM"          # Windows Remote Management
    # Add your own: "SQLServer", "MSSQLSERVER", etc.
)

$services = $serviceNames | ForEach-Object {
    $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
    if ($svc) {
        @{
            name         = $svc.Name
            display_name = $svc.DisplayName
            status       = $svc.Status.ToString()
        }
    }
} | Where-Object { $_ -ne $null }

# ── Veeam Backup ──────────────────────────────────────────────────────────────
$veeamJob = $null
try {
    if (Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
        Import-Module Veeam.Backup.PowerShell -ErrorAction Stop
        $lastSession = Get-VBRBackupSession | Sort-Object EndTime -Descending | Select-Object -First 1
        if ($lastSession) {
            $veeamJob = @{
                job_name         = $lastSession.JobName
                status           = $lastSession.Result.ToString()
                end_time         = $lastSession.EndTime.ToString("yyyy-MM-ddTHH:mm:ss")
                size_gb          = [math]::Round($lastSession.BackupStats.DataSize / 1GB, 2)
                duration_seconds = [int]($lastSession.EndTime - $lastSession.CreationTime).TotalSeconds
            }
        }
    }
} catch {
    Write-Warning "Could not query Veeam: $_"
}

# ── Build Payload ─────────────────────────────────────────────────────────────
$payload = @{
    os_info               = $osInfo
    uptime_seconds        = $uptimeSeconds
    disks                 = $disks
    pending_updates       = $pendingUpdates
    last_update_installed = $lastUpdateInstalled
    services              = $services
    veeam_last_job        = $veeamJob
} | ConvertTo-Json -Depth 5

# ── Send to API ───────────────────────────────────────────────────────────────
try {
    $response = Invoke-RestMethod -Uri $API_URL -Method POST -Body $payload -ContentType "application/json" -Headers @{ "x-api-key" = $API_KEY }
    Write-Host "Check-in successful: $($response.server_name)"
} catch {
    Write-Error "Check-in failed: $_"
    exit 1
}
