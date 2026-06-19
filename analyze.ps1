# analyze.ps1
$csvPath = "c:\Users\jeanp\github\syncOnedrive\_cache\evaluation_report.csv"
if (-not (Test-Path $csvPath)) {
    Write-Host "CSV file not found at $csvPath"
    exit 1
}

Write-Host "Loading CSV..."
$csv = Import-Csv -Path $csvPath -Delimiter ";"
Write-Host "Loaded $($csv.Count) rows.`n"

# 1. Videos not in Videos folder
Write-Host "=== 1. VIDEOS NOT IN VIDEOS FOLDER ===" -ForegroundColor Yellow
$videoExts = @(".mp4", ".mov", ".avi", ".mkv", ".wmv", ".3gp", ".mpg", ".mpeg")
$misplacedVideos = $csv | Where-Object {
    $ext = $_.Extension.ToLower()
    ($videoExts -contains $ext) -and 
    ($_.ProposedDestination -notlike "*/Videos*" -and $_.ProposedDestination -notlike "*/Vidéos*") -and
    $_.ProposedDestination
}

Write-Host "Found $($misplacedVideos.Count) misplaced videos."
$misplacedVideos | Select-Object Name, ParentPath, Extension, RoutingAction, ProposedDestination -First 15 | Format-Table -AutoSize

# 2. Naming contains container folder names
Write-Host "`n=== 2. GENERATED NAMES CONTAINING FOLDER NAMES ===" -ForegroundColor Yellow
# Let's find examples where the proposed name contains a word from the parent path
# split parent path by '/' and clean segments, see if any segments (like 'jp' or 'Cuisine' or others) are in the ProposedName
$containFolder = $csv | Where-Object {
    if (-not $_.ProposedName) { return $false }
    $path = $_.ParentPath -replace "^/drive/root:", ""
    $segs = $path.Split("/") | Where-Object { $_ -and $_ -ne "jp" -and $_ -ne "JPM" -and $_ -ne "Images" -and $_ -ne "Videos" -and $_ -ne "Vidéos" }
    $matched = $false
    foreach ($seg in $segs) {
        if ($_.ProposedName -match [regex]::Escape($seg)) {
            $matched = $true
            break
        }
    }
    return $matched
}
Write-Host "Found $($containFolder.Count) files where the proposed name contains parent folder segments."
$containFolder | Select-Object Name, ParentPath, ProposedName -First 15 | Format-Table -AutoSize

# 3. Duplicates in the generated name
Write-Host "`n=== 3. GENERATED NAMES WITH INTERNAL DUPLICATE WORDS ===" -ForegroundColor Yellow
# Find names that contain the same word multiple times (excluding timestamp)
$nameDupes = $csv | Where-Object {
    if (-not $_.ProposedName) { return $false }
    $nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($_.ProposedName)
    $words = $nameNoExt -split "_" | Where-Object { $_ -and $_ -notmatch '^\d+$' } # skip timestamps
    $uniqueWords = $words | Select-Object -Unique
    return ($words.Count -ne $uniqueWords.Count)
}
Write-Host "Found $($nameDupes.Count) files with duplicate words in the proposed name."
$nameDupes | Select-Object Name, ProposedName -First 15 | Format-Table -AutoSize
