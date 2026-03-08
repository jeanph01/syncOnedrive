# apply_progress_direct.ps1
param(
    [string]$RepoPath = ".",
    [string]$TargetFile = "organizer_refactor.ps1",
    [string]$BackupSuffix = ".bak"
)

Set-Location $RepoPath

$targetPath = Join-Path (Get-Location) $TargetFile
if (-not (Test-Path $targetPath)) {
    Write-Host "Fichier introuvable: $targetPath" -ForegroundColor Red
    exit 1
}

# 1) Sauvegarde
$backupPath = "$targetPath$BackupSuffix"
Copy-Item -Path $targetPath -Destination $backupPath -Force
Write-Host "Backup created at: $backupPath" -ForegroundColor Green

# 2) Lire le contenu
$content = Get-Content -Raw -Path $targetPath

# 3) Définir le bloc original (début et fin) et le bloc de remplacement
$startMarker = 'Write-Host "[1/4] Analyse des fichiers..." -ForegroundColor Gray'
$endMarker   = 'Write-Host ("[Done] Analyse terminée : {0} fichiers traités en {1:hh\:mm\:ss}" -f $processedCount, $stopwatch.Elapsed) -ForegroundColor Green'

if ($content -notmatch [regex]::Escape($startMarker)) {
    Write-Host "Le marqueur de début n'a pas été trouvé. Le fichier peut avoir été modifié manuellement." -ForegroundColor Yellow
}

# Nouveau bloc (instrumentation). Assure-toi que l'indentation et les guillemets sont corrects.
$newBlock = @'
Write-Host "[1/4] Analyse des fichiers..." -ForegroundColor Gray
$PlannedActions = New-Object System.Collections.Generic.List[string]

# --- Instrumentation : progression et timing ---
$allFileIds = $Cache.Files.Keys
$totalFiles = $allFileIds.Count
$processedCount = 0
$lastReportTime = Get-Date
$reportIntervalSeconds = 3
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($fileId in $allFileIds) {
    $processedCount++
    $percent = if ($totalFiles -gt 0) { [int](($processedCount / $totalFiles) * 100) } else { 100 }
    Write-Progress -Activity "Analyse des fichiers" -Status "Fichier $processedCount / $totalFiles" -PercentComplete $percent

    if ((Get-Date) -gt $lastReportTime.AddSeconds($reportIntervalSeconds)) {
        $elapsed = $stopwatch.Elapsed
        $avgPerFile = if ($processedCount -gt 0) { [TimeSpan]::FromMilliseconds($elapsed.TotalMilliseconds / $processedCount) } else { [TimeSpan]::Zero }
        $remaining = if ($processedCount -gt 0) { [TimeSpan]::FromMilliseconds($avgPerFile.TotalMilliseconds * ($totalFiles - $processedCount)) } else { [TimeSpan]::Zero }
        Write-Host ("[Progress] {0}/{1} ({2}%) - Elapsed: {3:hh\:mm\:ss} - Avg/file: {4:hh\:mm\:ss} - Est. remaining: {5:hh\:mm\:ss}" -f $processedCount, $totalFiles, $percent, $elapsed, $avgPerFile, $remaining) -ForegroundColor Yellow
        $lastReportTime = Get-Date
    }

    $iterStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($ProcessedIds.ContainsKey($fileId)) { $iterStopwatch.Stop(); continue }
    $fileEntry = $Cache.Files[$fileId]
    if ($fileEntry.n -match $RenameMarker) { $iterStopwatch.Stop(); continue }
    $extension = [System.IO.Path]::GetExtension($fileEntry.n).ToLower()
    if ($extension -notmatch ".jpg|.jpeg|.png|.heic|.mp4|.mov") { $iterStopwatch.Stop(); continue }

    $timestampStr = ([DateTime]$fileEntry.d).ToString("yyyyMMdd_HHmmss")
    $videoTags = if ($fileEntry.dur -or $fileEntry.res) { (($fileEntry.dur, $fileEntry.res | Where-Object {$_}) -join "_") } else { "" }

    $pathParts = $fileEntry.p -split "/" | Where-Object { $_ -and $_ -notmatch "drive|root|Images|Videos|Pellicule" }
    $context = if ($pathParts.Length -gt 0) { ($pathParts[[Math]::Max(0, $pathParts.Length-3)..($pathParts.Length-1)]) -join "_" } else { "" }

    $originalNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fileEntry.n)
    $newName = Build-SmartFileName -timestampStr $timestampStr -contextStr $context -originalName $originalNameNoExt -marker $RenameMarker -extension $extension -videoTags $videoTags

    $subType = if ($extension -match "mp4|mov") { "Videos" } else { "Images" }
    $targetRoot = Determine-TargetRoot -SourcePath $fileEntry.p

    if ($targetRoot -like "Pour coffre fort*") {
        $rawDestination = "$targetRoot/$subType/$(([DateTime]$fileEntry.d).Year)/$(([DateTime]$fileEntry.d).ToString('MM'))"
    } else {
        $rawDestination = "$targetRoot/$(([DateTime]$fileEntry.d).Year)/$(([DateTime]$fileEntry.d).ToString('MM'))"
    }

    $cleanDestination = Normalize-ToAscii -text $rawDestination -isPath:$true
    $targetKey = "/$cleanDestination/$newName"

    $suffix = 1
    while ($FolderInventory.ContainsKey($targetKey)) {
        $newName = $newName -replace "$RenameMarker", "_$suffix$RenameMarker"
        $targetKey = "/$cleanDestination/$newName"
        $suffix++
    }
    $FolderInventory[$targetKey] = $true

    $PlannedActions.Add("ID:$fileId | SRC:$($fileEntry.p)/$($fileEntry.n) | DST:$targetKey")

    $iterStopwatch.Stop()
    if ($iterStopwatch.Elapsed.TotalSeconds -gt 2) {
        "$((Get-Date).ToString('s')) - Slow item: $fileId - Elapsed: $($iterStopwatch.Elapsed.TotalSeconds)s" | Add-Content ".\slow_items.log"
    }
}
$stopwatch.Stop()
Write-Host ("[Done] Analyse terminée : {0} fichiers traités en {1:hh\:mm\:ss}" -f $processedCount, $stopwatch.Elapsed) -ForegroundColor Green
'@

# 4) Remplacement : on tente de remplacer la section entre startMarker et endMarker
# Utilise regex singleline pour capturer tout entre les deux marqueurs
$pattern = [regex]::Escape($startMarker) + '.*?' + [regex]::Escape($endMarker)
if ($content -match $pattern) {
    $newContent = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newBlock }, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    # Sauvegarde temporaire du nouveau contenu
    $tmpPath = "$targetPath.tmp"
    $newContent | Out-File -FilePath $tmpPath -Encoding utf8 -Force

    # Afficher un diff simple (ligne par ligne)
    Write-Host "Showing simple diff (old -> new) around the replaced block:" -ForegroundColor Cyan
    $oldLines = Get-Content $backupPath
    $newLines = Get-Content $tmpPath
    $diff = Compare-Object -ReferenceObject $oldLines -DifferenceObject $newLines -SyncWindow 5
    $diff | Select-Object -First 200 | ForEach-Object {
        if ($_.SideIndicator -eq "=>") { Write-Host "+ $($_.InputObject)" -ForegroundColor Green }
        elseif ($_.SideIndicator -eq "<=") { Write-Host "- $($_.InputObject)" -ForegroundColor Red }
        else { Write-Host "  $($_.InputObject)" }
    }

    # Remplacer le fichier cible par la nouvelle version
    Move-Item -Path $tmpPath -Destination $targetPath -Force
    Write-Host "Replacement done. File updated: $targetPath" -ForegroundColor Green

    Write-Host ""
    Write-Host "Next steps (git):" -ForegroundColor Cyan
    Write-Host "  git add $TargetFile"
    Write-Host "  git commit -m 'Add progress instrumentation and slow-item logging to analysis loop'"
    Write-Host "  git push -u origin feat/add-progress"
} else {
    Write-Host "Pattern not found: unable to auto-replace. Open the file manually and apply the new block." -ForegroundColor Yellow
    Write-Host "Backup is at: $backupPath"
    exit 2
}