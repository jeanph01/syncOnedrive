# analyze_detailed.ps1
$csvPath = "c:\Users\jeanp\github\syncOnedrive\_cache\evaluation_report.csv"
$csv = Import-Csv -Path $csvPath -Delimiter ";"

Write-Host "Total rows loaded: $($csv.Count)"

# 1. Inspect Video Routing
Write-Host "`n=== 1. VIDEO FILES ROUTING ANALYSIS ===" -ForegroundColor Yellow
$videoExts = @(".mp4", ".mov", ".avi", ".mkv", ".wmv", ".3gp", ".mpg", ".mpeg", ".m4v", ".flv")

$videos = $csv | Where-Object { $videoExts -contains $_.Extension.ToLower() }
Write-Host "Total videos in watched folders: $($videos.Count)"

$videosByDest = $videos | Group-Object ProposedDestination | Select-Object Name, Count | Sort-Object Count -Descending
Write-Host "Videos by proposed destination:"
$videosByDest | Format-Table -AutoSize

# Let's print some videos that are routed to Images
$videosInImages = $videos | Where-Object { $_.ProposedDestination -like "*/Images/*" }
Write-Host "Total videos routed to Images: $($videosInImages.Count)"
$videosInImages | Select-Object Name, ParentPath, RoutingAction, ProposedDestination, ProposedName -First 10 | Format-Table -AutoSize


# 2. Inspect Name Duplicates (detailed, case-insensitive)
Write-Host "`n=== 2. DETAILED DUPLICATE WORDS IN GENERATED NAMES ===" -ForegroundColor Yellow
$dupesList = New-Object System.Collections.Generic.List[Object]

foreach ($row in $csv) {
    if (-not $row.ProposedName) { continue }
    $nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($row.ProposedName)
    # Split by underscore and clean
    $parts = $nameNoExt -split "_" | Where-Object { $_ -and $_ -notmatch '^\d+$' } # skip date/time numbers
    
    # Check for duplicates case-insensitively
    $seen = @{}
    $hasDupe = $false
    $dupeWord = ""
    foreach ($p in $parts) {
        $pLower = $p.ToLower()
        # Skip small words or standard markers
        if ($pLower -eq "odr" -or $pLower.Length -le 2) { continue }
        if ($seen.ContainsKey($pLower)) {
            $hasDupe = $true
            $dupeWord = $p
            break
        }
        $seen[$pLower] = $true
    }
    
    if ($hasDupe) {
        $dupesList.Add([PSCustomObject]@{
            Name          = $row.Name
            ProposedName  = $row.ProposedName
            DuplicateWord = $dupeWord
            ParentPath    = $row.ParentPath
        })
    }
}

Write-Host "Found $($dupesList.Count) files with case-insensitive duplicate words in the proposed name."
$dupesList | Select-Object Name, ProposedName, DuplicateWord, ParentPath -First 15 | Format-Table -AutoSize


# 3. Inspect Container Folder Naming (Path Tags)
Write-Host "`n=== 3. CONTAINER FOLDER SEGMENTS IN FILENAME ===" -ForegroundColor Yellow
$containerFolderStats = $csv | Where-Object {
    if (-not $_.ProposedName) { return $false }
    $path = $_.ParentPath -replace "^/drive/root:", ""
    $segs = $path.Split("/") | Where-Object { $_ -and $_ -ne "jp" -and $_ -ne "JPM" }
    $matched = $false
    foreach ($seg in $segs) {
        if ($_.ProposedName -match [regex]::Escape($seg)) {
            $matched = $true
            break
        }
    }
    return $matched
}

Write-Host "Found $($containerFolderStats.Count) files whose proposed name contains folder names from their path."
$containerFolderStats | Select-Object Name, ParentPath, ProposedName -First 15 | Format-Table -AutoSize
