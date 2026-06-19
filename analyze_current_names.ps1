# analyze_current_names.ps1
$csvPath = "c:\Users\jeanp\github\syncOnedrive\_cache\evaluation_report.csv"
$csv = Import-Csv -Path $csvPath -Delimiter ";"

Write-Host "Searching for current names with duplicate words..."
$found = 0

foreach ($row in $csv) {
    $nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($row.Name)
    $words = $nameNoExt -split "_" | Where-Object { $_ -and $_ -notmatch '^\d+$' } # skip date/time numbers
    
    $seen = @{}
    $dupes = @()
    foreach ($w in $words) {
        $wLower = $w.ToLower()
        if ($wLower -eq "odr") { continue }
        if ($seen.ContainsKey($wLower)) {
            $dupes += $w
        }
        $seen[$wLower] = $true
    }
    
    if ($dupes.Count -gt 0) {
        $found++
        Write-Host "File ID      : $($row.Id)"
        Write-Host "Current Name : $($row.Name)"
        Write-Host "Parent Path  : $($row.ParentPath)"
        Write-Host "Is Organised : $($row.IsAlreadyProcessed)"
        Write-Host "Duplicate    : $($dupes -join ', ')"
        Write-Host "----------------------------------"
        if ($found -ge 20) {
            Write-Host "Showing first 20 examples."
            break
        }
    }
}

Write-Host "Total files found with duplicate words in current name: $found"
