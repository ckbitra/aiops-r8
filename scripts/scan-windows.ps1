# =============================================================================
# Windows CVE Scan Script
# =============================================================================
# Scans Windows instances for CVE-related security updates.
# Run via SSM Run Command or directly on the instance.
# Report output: C:\aiops\reports\windows_scan_report.txt
# =============================================================================

$ReportDir = if ($env:REPORT_DIR) { $env:REPORT_DIR } else { "C:\aiops\reports" }
$ReportFile = Join-Path $ReportDir "windows_scan_report.txt"
$Timestamp = Get-Date -Format "o"
$Hostname = $env:COMPUTERNAME

if (-not (Test-Path $ReportDir)) {
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
}

$report = @"
==========================================
Windows CVE Security Scan Report
==========================================
Scan Date: $Timestamp
Hostname: $Hostname

=== System Information ===
"@

$report += "`nOS: " + (Get-CimInstance Win32_OperatingSystem).Caption
$report += "`n"

# Check for available updates
$report += "`n=== Available Security Updates ===`n"
try {
    $updateSession = New-Object -ComObject Microsoft.Update.Session
    $updateSearcher = $updateSession.CreateUpdateSearcher()
    $searchResult = $updateSearcher.Search("IsInstalled=0 and Type='Software'")
    $report += "Pending updates count: $($searchResult.Updates.Count)`n"
    foreach ($update in $searchResult.Updates) {
        $report += "  - $($update.Title)`n"
    }
} catch {
    $report += "Update check: $($_.Exception.Message)`n"
}

# Installed updates (recent)
$report += "`n=== Recently Installed Updates ===`n"
try {
    $hotfixes = Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 20
    $report += ($hotfixes | Format-Table -AutoSize | Out-String)
} catch {
    $report += "Hotfix info: $($_.Exception.Message)`n"
}

$report += @"

==========================================
Report stored at: $ReportFile
==========================================
"@

$report | Out-File -FilePath $ReportFile -Encoding UTF8
Write-Host "Windows scan complete. Report: $ReportFile"
Get-Content $ReportFile
