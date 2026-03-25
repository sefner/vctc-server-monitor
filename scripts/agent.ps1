# VCTC Server Monitor Agent
# Schedule as a Windows Scheduled Task every 30 minutes.
# Task Action: powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\vctc-agent.ps1"

$API_URL = "https://YOUR-SERVER/api/checkin"  # Replace with your server URL
$API_KEY = "YOUR_API_KEY_HERE"                 # Replace with the key from server registration

# ── OS Info ───────────────────────────────────────────────────────────────────
$os = Get-CimInstance Win32_OperatingSystem
$osInfo = "$($os.Caption) (Build $($os.BuildNumber))"
$uptimeSeconds = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds

# ── Disk Usage ────────────────────────────────────────────────────────────────
$disks = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null -and $_.Free -ne $null } | ForEach-Object {
    $total = $_.Used + $_.Free
    $usedPct = if ($total -gt 0) { [math]::Round(($_.Used / $total) * 100, 1) } else { 0 }
    @{
        drive    = $_.Root
        total_gb = [math]::Round($total / 1GB, 2)
        free_gb  = [math]::Round($_.Free / 1GB, 2)
        used_pct = $usedPct
    }
}

# ── Windows Updates ───────────────────────────────────────────────────────────
$pendingUpdates = $null
$lastUpdateInstalled = $null
try {
    $updateSession  = New-Object -ComObject Microsoft.Update.Session
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    $searchResult   = $updateSearcher.Search("IsInstalled=0 and Type='Software'")
    $pendingUpdates = $searchResult.Updates.Count

    $historyCount = $updateSearcher.GetTotalHistoryCount()
    if ($historyCount -gt 0) {
        $history = $updateSearcher.QueryHistory(0, [math]::Min($historyCount, 20)) |
            Where-Object { $_.ResultCode -eq 2 } |
            Sort-Object Date -Descending |
            Select-Object -First 1
        if ($history) { $lastUpdateInstalled = $history.Date.ToString("yyyy-MM-ddTHH:mm:ss") }
    }
} catch {
    Write-Warning "Could not query Windows Updates: $_"
}

# ── Services to Monitor ───────────────────────────────────────────────────────
# Add or remove service names as needed for each server
$serviceNames = @(
    "wuauserv",     # Windows Update
    "W32Time",      # Windows Time
    "Dnscache",     # DNS Client
    "LanmanServer", # Server (file sharing)
    "WinRM"         # Windows Remote Management
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

# ── CloudBerry Backup Status ───────────────────────────────────────────────────
# Queries the local CloudBerry SQLite database for recent backup session results.
# result codes: 6 = Success, 2 = Failed, 3 = Warning
$cloudberryJobs = @()
try {
    $cbDb  = "C:\ProgramData\CloudBerryLab\CloudBerry Backup\data\cbbackup.db"
    $cbDll = "C:\Program Files\CloudBerryLab\CloudBerry Backup\System.Data.SQLite.dll"

    if ((Test-Path $cbDb) -and (Test-Path $cbDll)) {
        Add-Type -Path $cbDll -ErrorAction Stop

        $conn = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$cbDb;Version=3;Read Only=True;")
        $conn.Open()
        $cmd = $conn.CreateCommand()

        # Get the most recent session per plan
        $cmd.CommandText = @"
            SELECT plan_name, result, date_start_utc, duration, total_size, error_message
            FROM session_history
            WHERE id IN (
                SELECT MAX(id) FROM session_history GROUP BY plan_name
            )
            ORDER BY date_start_utc DESC
"@
        $reader = $cmd.ExecuteReader()
        while ($reader.Read()) {
            $dateRaw = $reader["date_start_utc"].ToString()
            # Parse YYYYMMDDHHmmss format
            $dateStr = $null
            if ($dateRaw.Length -eq 14) {
                $dateStr = "$($dateRaw.Substring(0,4))-$($dateRaw.Substring(4,2))-$($dateRaw.Substring(6,2))T$($dateRaw.Substring(8,2)):$($dateRaw.Substring(10,2)):$($dateRaw.Substring(12,2))Z"
            }
            $resultCode = [int]$reader["result"]
            $resultText = switch ($resultCode) {
                6 { "Success" }
                2 { "Failed" }
                3 { "Warning" }
                default { "Unknown ($resultCode)" }
            }
            $cloudberryJobs += @{
                plan_name        = $reader["plan_name"].ToString()
                status           = $resultText
                date_start_utc   = $dateStr
                duration_seconds = [int]$reader["duration"]
                total_size_bytes = [long]$reader["total_size"]
                error_message    = $reader["error_message"].ToString()
            }
        }
        $reader.Close()
        $conn.Close()
    }
} catch {
    Write-Warning "Could not query CloudBerry backup DB: $_"
}

# ── Build Payload ─────────────────────────────────────────────────────────────
$payload = @{
    os_info               = $osInfo
    uptime_seconds        = $uptimeSeconds
    disks                 = $disks
    pending_updates       = $pendingUpdates
    last_update_installed = $lastUpdateInstalled
    services              = @($services)
    cloudberry_jobs       = $cloudberryJobs
} | ConvertTo-Json -Depth 5

# ── Send to API ───────────────────────────────────────────────────────────────
try {
    $response = Invoke-RestMethod -Uri $API_URL -Method POST -Body $payload -ContentType "application/json" -Headers @{ "x-api-key" = $API_KEY }
    Write-Host "Check-in successful: $($response.server_name)"
} catch {
    Write-Error "Check-in failed: $_"
    exit 1
}
