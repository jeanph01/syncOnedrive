# analyze_dupes.ps1
$csvPath = "c:\Users\jeanp\github\syncOnedrive\_cache\evaluation_report.csv"
$csv = Import-Csv -Path $csvPath -Delimiter ";"

Write-Host "Searching for proposed names with duplicate words..."
$found = 0

foreach ($row in $csv) {
    if (-not $row.ProposedName) { continue }
    $nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($row.ProposedName)
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
        Write-Host "Original Name: $($row.Name)"
        Write-Host "Parent Path  : $($row.ParentPath)"
        Write-Host "Proposed Name: $($row.ProposedName)"
        Write-Host "Duplicate    : $($dupes -join ', ')"
        Write-Host "----------------------------------"
        if ($found -ge 20) {
            Write-Host "Showing first 20 examples."
            break
        }
    }
}

if ($found -eq 0) {
    Write-Host "No files with duplicate words found in ProposedName."
}
