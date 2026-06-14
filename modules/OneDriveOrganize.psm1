
param(
    [string]$ClientId,
    [string]$TokenFile,
    [string]$LogFile
)

# Prevent multiple imports
if ($script:ModuleLoaded) {
    return
}
$script:ModuleLoaded = $true

# Check OneDriveTools dependency
if (-not (Get-Command Get-GraphToken -ErrorAction SilentlyContinue)) {
    throw "ERROR: OneDriveTools functions are not available. Check the import in the main script."
}

# =====================================================================
# METADATA EXTRACTION
# =====================================================================

function Read-AzureFileInfo {
    param($item)

    try {
        if (-not ($item.file -and $item.file.hashes.sha1Hash)) {
            return $null
        }

        # GPS
        $GPS = $null
        if ($item.photo -and $item.photo.GPS) {
            $GPS = "$($item.photo.GPS.latitude),$($item.photo.GPS.longitude)"
        }
        elseif ($item.location -and $item.location.latitude) {
            $GPS = "$($item.location.latitude),$($item.location.longitude)"
        }

        # Camera
        $camera = $null
        if ($item.photo) {
            $camera = "$($item.photo.cameraMake) $($item.photo.cameraModel)".Trim()
        }

        # Image
        $imgInfo = $null
        if ($item.image) {
            $imgInfo = @{
                width  = $item.image.width
                height = $item.image.height
            }
        }

        # Video
        $videoInfo = $null
        if ($item.video) {
            $videoInfo = @{
                duration = $item.video.duration
                width    = $item.video.width
                height   = $item.video.height
            }
        }

        # Audio
        $audioInfo = $null
        if ($item.audio) {
            $audioInfo = @{
                title  = $item.audio.title
                album  = $item.audio.album
                artist = $item.audio.artist
            }
        }

        # EXIF date or fallback
        $refDate = $null
        if ($item.photo -and $item.photo.takenDateTime) {
            $refDate = [DateTime]$item.photo.takenDateTime
        }
        if (-not $refDate) {
            $refDate = [DateTime]$item.fileSystemInfo.lastModifiedDateTime
        }

        return @{
            n   = $item.name
            s   = $item.size
            h   = $item.file.hashes.sha1Hash.ToLower()
            d   = $refDate
            p   = $item.parentReference.path
            GPS = $GPS
            cam = $camera
            img = $imgInfo
            vid = $videoInfo
            aud = $audioInfo
        }
    }
    catch {
        Write-Log "Read-AzureFileInfo failure: $_" "ERROR"
    }
}

function Get-PathTags($fullPath) {
    try {
        $parts = $fullPath -replace "^/drive/root:/?", "" -split "/"
        return ($parts -join "_")
    }
    catch {
        Write-Log "Get-PathTags failure: $_" "ERROR"
    }
}

function Get-MediaType {
    param([string]$Extension)

    $ext = $Extension.ToLower()
    if ($Global:Config.ExtensionMap.ContainsKey($ext)) {
        return $Global:Config.ExtensionMap[$ext]
    }

    return $null
}


# =====================================================================
# NAMING HELPERS (RULES-BASED)
# =====================================================================

function Normalize-AsciiString {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    try {
        $normalized = $Text.Normalize([System.Text.NormalizationForm]::FormD)
        $clean = ($normalized.ToCharArray() | Where-Object {
                [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne
                [System.Globalization.UnicodeCategory]::NonSpacingMark
            }) -join ""

        $clean = [Regex]::Replace($clean, "[^a-zA-Z0-9_\-]", "_")
        $clean = $clean -replace "_+", "_"
        $clean = $clean -replace "-+", "-"
        return $clean.Trim("_", "-")
    }
    catch {
        Write-Log "Normalize-AsciiString failure: $_" "ERROR"
        return $Text
    }
}

function Split-Words {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $clean = Normalize-AsciiString $Text
    return ($clean -split "[ _\-]" | Where-Object { $_ -and $_.Trim() -ne "" })
}

function Remove-StopWordsFromList {
    param(
        [string[]]$Words,
        [string[]]$StopWords
    )

    if (-not $Words) { return @() }
    if (-not $StopWords) { return $Words }

    $stop = $StopWords | ForEach-Object { $_.ToLower() }
    return $Words | Where-Object { $stop -notcontains $_.ToLower() }
}

function Remove-DuplicatesFromList {
    param([string[]]$Words)

    if (-not $Words) { return @() }

    $seen = @{}
    $result = @()
    foreach ($w in $Words) {
        $key = $w.ToLower()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $result += $w
        }
    }
    return $result
}

function Remove-DateWordsFromList {
    param(
        [string[]]$Words,
        [datetime]$DateRef
    )

    if (-not $Words) { return @() }

    $year = $DateRef.ToString("yyyy")
    $yearMonth = $DateRef.ToString("yyyyMM")
    $dateRaw = $DateRef.ToString("yyyyMMdd")
    $timestamp = $DateRef.ToString("yyyyMMdd_HHmmss")

    $toRemove = @($year, $yearMonth, $dateRaw, $timestamp) | ForEach-Object { $_.ToLower() }

    return $Words | Where-Object { $toRemove -notcontains $_.ToLower() }
}

function Extract-GPSWords {
    param([string]$GPSLocation)

    if (-not $GPSLocation) { return @() }
    return Split-Words $GPSLocation
}

function Extract-TagWords {
    param(
        [string]$PathTags,
        [string[]]$StopWords,
        [datetime]$DateRef,
        [string[]]$GpsWords
    )

    if (-not $PathTags) { return @() }

    $words = Split-Words $PathTags
    $words = Remove-StopWordsFromList -Words $words -StopWords $StopWords
    $words = Remove-DateWordsFromList -Words $words -DateRef $DateRef

    if ($GpsWords) {
        $gpsSet = $GpsWords | ForEach-Object { $_.ToLower() }
        $words = $words | Where-Object { $gpsSet -notcontains $_.ToLower() }
    }

    return Remove-DuplicatesFromList $words
}

function Extract-OrigWords {
    param(
        [string]$OriginalName,
        [string[]]$StopWords,
        [datetime]$DateRef,
        [string[]]$ExistingWords
    )

    $name = $OriginalName
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = "unnamed"
    }

    $words = Split-Words $name
    $words = Remove-StopWordsFromList -Words $words -StopWords $StopWords
    $words = Remove-DateWordsFromList -Words $words -DateRef $DateRef

    if ($ExistingWords) {
        $existingSet = $ExistingWords | ForEach-Object { $_.ToLower() }
        $words = $words | Where-Object { $existingSet -notcontains $_.ToLower() }
    }

    return Remove-DuplicatesFromList $words
}

function Extract-MediaWords {
    param(
        [string]$Camera,
        [hashtable]$VideoInfo,
        [string[]]$StopWords,
        [string[]]$ExistingWords
    )

    $all = ""

    if ($Camera) {
        $all += "$Camera "
    }

    if ($VideoInfo -and $VideoInfo.duration) {
        # Normaliser la durée en secondes
        $seconds = [int]([double]$VideoInfo.duration / 1000)
        $all += "duration_${seconds}s"
    }

    if (-not $all) { return @() }

    $words = Split-Words $all
    $words = Remove-StopWordsFromList -Words $words -StopWords $StopWords

    if ($ExistingWords) {
        $existingSet = $ExistingWords | ForEach-Object { $_.ToLower() }
        $words = $words | Where-Object { $existingSet -notcontains $_.ToLower() }
    }

    return Remove-DuplicatesFromList $words
}

function Apply-TruncationToBaseName {
    param(
        [string]$BaseName,
        [string]$Extension,
        [int]$MaxLenWithoutExt
    )

    if (-not $BaseName) { return "" }
    if ($BaseName.Length -le $MaxLenWithoutExt) {
        return $BaseName
    }

    return $BaseName.Substring(0, $MaxLenWithoutExt)
}

function Build-FinalNameFromPattern {
    param(
        [datetime]$DateRef,
        [string[]]$GpsWords,
        [string[]]$TagWords,
        [string[]]$OrigWords,
        [string[]]$MediaWords,
        [string]$Extension,
        [hashtable]$NamingRules
    )

    $timestamp = $DateRef.ToString("yyyyMMdd_HHmmss")
    $renameMarker = $NamingRules.renameMarker
    $maxLen = $NamingRules.maxNameLength
    $pattern = $NamingRules.finalPattern

    $gps = ($GpsWords -join "_")
    $tags = ($TagWords -join "_")
    $orig = ($OrigWords -join "_")
    $media = ($MediaWords -join "_")

    $base = $pattern
    $base = $base.Replace("<timestamp>", $timestamp)
    $base = $base.Replace("<gps>", $gps)
    $base = $base.Replace("<tags>", $tags)
    $base = $base.Replace("<original>", $orig)
    $base = $base.Replace("<media>", $media)
    $base = $base.Replace("<dup>", "")

    $base = $base -replace "_+", "_"
    $base = $base.Trim("_")

    $maxLenWithoutExt = $maxLen - $renameMarker.Length - $Extension.Length
    if ($maxLenWithoutExt -lt 10) { $maxLenWithoutExt = 10 }

    $base = Apply-TruncationToBaseName -BaseName $base -Extension $Extension -MaxLenWithoutExt $maxLenWithoutExt

    return "$base$renameMarker$Extension"
}

function Resolve-FinalName {
    param(
        [hashtable]$FileMeta,
        [string]$Extension,
        [string]$GPSLocation,
        [string]$PathTags,
        [string]$Camera
    )

    $rules = $Global:Rules.namingRules
    $stopWords = $rules.stopWords
    $dateRef = [datetime]$FileMeta.d

    $originalNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($FileMeta.n)
    if ([string]::IsNullOrWhiteSpace($originalNameNoExt)) {
        $originalNameNoExt = "unnamed"
    }

    $gpsWords = Extract-GPSWords -GPSLocation $GPSLocation

    $tagWords = Extract-TagWords `
        -PathTags $PathTags `
        -StopWords $stopWords `
        -DateRef $dateRef `
        -GpsWords $gpsWords

    $existing = @()
    $existing += $gpsWords
    $existing += $tagWords

    $origWords = Extract-OrigWords `
        -OriginalName $originalNameNoExt `
        -StopWords $stopWords `
        -DateRef $dateRef `
        -ExistingWords $existing

    $existing2 = @()
    $existing2 += $gpsWords
    $existing2 += $tagWords
    $existing2 += $origWords

    $mediaWords = Extract-MediaWords `
        -Camera $Camera `
        -VideoInfo $FileMeta.vid `
        -StopWords $stopWords `
        -ExistingWords $existing2

    return Build-FinalNameFromPattern `
        -DateRef    $dateRef `
        -GpsWords   $gpsWords `
        -TagWords   $tagWords `
        -OrigWords  $origWords `
        -MediaWords $mediaWords `
        -Extension  $Extension `
        -NamingRules $rules
}

# =====================================================================
# ROUTING (RULES-BASED)
# =====================================================================

function Get-RoutingAction {
    param(
        [string]$Path,
        [string]$Extension
    )

    $rules = $Global:Rules.routingRules
    $folderRules = $Global:Rules.folderRules

    $candidates = @()

    # 1) Règles "confidential" par regex sur le path complet
    foreach ($regex in $rules.confidentialRegexList) {
        if ($Path -match $regex) {
            $candidates += 'confidential'
            break
        }
    }

    # 2) Règles basées sur les dossiers (folderRules)
    $relativePath = $Path -replace '^/drive/root:', ''
    $segments = $relativePath.Trim('/') -split '/'
    foreach ($seg in $segments) {
        if ([string]::IsNullOrWhiteSpace($seg)) { continue }
        if ($folderRules.ContainsKey($seg)) {
            $candidates += $folderRules[$seg]
        }
    }

    # 3) Règle globale "*.*" si rien trouvé
    if (-not $candidates -and $folderRules.ContainsKey('*.*')) {
        $candidates += $folderRules['*.*']
    }

    # 4) Si toujours rien, fallback "default"
    if (-not $candidates) {
        $candidates += 'default'
    }

    # 5) Appliquer la priorité définie dans rules.json
    foreach ($prio in $rules.actionPriority) {
        if ($candidates -contains $prio) {
            return $prio
        }
    }

    return 'default'
}

function Resolve-RoutingTemplate {
    param(
        [string]$Template,
        [hashtable]$Values
    )

    if ([string]::IsNullOrWhiteSpace($Template)) {
        return $null
    }

    $result = $Template

    # 1) Gérer les blocs optionnels [ ... ] — REGEX CORRIGÉE
    $result = [regex]::Replace($result, '

\[(.*?)\]

', {
            param($m)
            $block = $m.Groups[1].Value
            $blockResolved = $block

            foreach ($key in $Values.Keys) {
                $blockResolved = $blockResolved -replace [regex]::Escape($key), [string]$Values[$key]
            }

            # Si un token reste non résolu → on supprime le bloc
            if ($blockResolved -match '<[^>]+>') {
                return ''
            }

            return $blockResolved
        })

    # 2) Remplacer les tokens simples
    foreach ($key in $Values.Keys) {
        $result = $result -replace [regex]::Escape($key), [string]$Values[$key]
    }

    # 3) Nettoyage des tokens restants et des doubles slash
    $result = $result -replace '<[^>]+>', ''
    $result = $result -replace '//+', '/'

    return $result.Trim('/')
}

function Get-DestinationPath {
    param(
        [hashtable]$FileMeta,
        [string]$Extension,
        [string]$NewName,
        [datetime]$FileDate
    )

    $rules = $Global:Rules.routingRules
    $extMap = $Global:Config.ExtensionMap

    # 1) Catégorie media
    $media = if ($extMap.ContainsKey($Extension)) { $extMap[$Extension] } else { "Other" }

    # 2) Analyse du path source
    $srcPath = $FileMeta.p
    $relativePath = $srcPath -replace '^/drive/root:', ''
    $segments = @()
    if (-not [string]::IsNullOrWhiteSpace($relativePath)) {
        $segments = $relativePath.Trim('/') -split '/'
    }

    # 3) Déterminer l'action
    $actionName = Get-RoutingAction -Path $srcPath -Extension $Extension
    if (-not $rules.actions.ContainsKey($actionName)) {
        $actionName = 'default'
    }

    $action = $rules.actions[$actionName]

    # 4) Cas no_action
    if ($actionName -eq 'no_action' -or -not $action.destination) {
        return $null
    }

    # 5) keepLevels — CORRIGÉ
    if ($action.ContainsKey("keepLevels")) {
        $keep = [int]$action.keepLevels
        if ($keep -gt 0 -and $segments.Count -gt $keep) {
            $segments = $segments[0..($keep - 1)]
        }
    }

    # Recalcul des niveaux
    $level1 = if ($segments.Count -ge 1) { $segments[0] } else { "" }
    $level2 = if ($segments.Count -ge 2) { $segments[1] } else { "" }
    $level3 = if ($segments.Count -ge 3) { $segments[2] } else { "" }

    # 6) Préparation des valeurs
    $values = @{
        '<media>'          = $media
        '<year>'           = $FileDate.ToString('yyyy')
        '<month>'          = $FileDate.ToString('MM')
        '<level1>'         = $level1
        '<level2>'         = $level2
        '<level3>'         = $level3
        '<same_directory>' = $relativePath.Trim('/')
    }

    $template = $action.destination

    # 7) Cas spécial only_rename — CORRIGÉ POUR <same_directory>
    if ($actionName -eq 'only_rename' -or $template -like '<same_directory*') {
        $cleanDest = $relativePath.Trim('/')
        $fullDest = "/$($cleanDest.Trim('/'))/$NewName"
        return [PSCustomObject]@{
            Action           = $actionName
            CleanDestination = $cleanDest
            FullDestination  = $fullDest
        }
    }

    # 8) Résolution du template
    $resolvedPath = Resolve-RoutingTemplate -Template $template -Values $values
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        $resolvedPath = "$media/$($FileDate.ToString('yyyy'))/$($FileDate.ToString('MM'))"
    }

    $cleanDestination = $resolvedPath.Trim('/')
    $fullDestination = "/$($cleanDestination.Trim('/'))/$NewName"

    return [PSCustomObject]@{
        Action           = $actionName
        CleanDestination = $cleanDestination
        FullDestination  = $fullDestination
    }
}

function Get-SmartCategory {
    param(
        [string]$Path,
        [string]$Extension
    )

    return (Get-RoutingAction -Path $Path -Extension $Extension)
}

# =====================================================================
# PLAN GENERATION
# =====================================================================

function Get-FilteredFileIds {
    param([string]$Range, [array]$AllIds)

    if ([string]::IsNullOrWhiteSpace($Range)) {
        return $AllIds
    }

    $total = $AllIds.Count

    if ($Range -match '^(\d+)$') {
        $index = [int]$Matches[1] - 1
        if ($index -ge 0 -and $index -lt $total) {
            return @($AllIds[$index])
        }
        elseif ($total -eq 0) { return @() }
    }
    elseif ($Range -match '^(\d+)\.\.(\d+)$') {
        $start = [int]$Matches[1] - 1
        $end = [int]$Matches[2] - 1
        if ($start -le $end -and $start -ge 0 -and $end -lt $total) {
            return $AllIds[$start..$end]
        }
        elseif ($total -eq 0) { return @() }
    }
    elseif ($Range -match '^(\d+)\+$') {
        $start = [int]$Matches[1] - 1
        if ($start -ge 0 -and $start -lt $total) {
            return $AllIds[$start..($total - 1)]
        }
        elseif ($total -eq 0) { return @() }
    }

    if ($total -gt 0) {
        Write-Log "Invalid ProcessRange '$Range', processing all files" "WARN"
    }
    return $AllIds
}

function New-Plan {
    Write-Log "Scanning files (merged pipeline)..." "INFO"

    try {
        $FileIds = $Global:State.FilesToProcess.Keys

        if ($global:ProcessRange) {
            $FileIds = Get-FilteredFileIds -Range $global:ProcessRange -AllIds $FileIds
            Write-Log "Range filter applied: $($global:ProcessRange) -> processing $($FileIds.Count) files" "INFO"
        }

        $FilteredTotal = $FileIds.Count
        $StartTime = Get-Date
        $count = 0

        $log2 = Join-Path (Split-Path $IndexFile -Parent) "log2.txt"
        if (Test-Path $log2) { Remove-Item $log2 -Force }

        foreach ($fileId in $FileIds) {

            $count++
            $fileMeta = $Global:State.Cache.Files[$fileId]
            $extension = [System.IO.Path]::GetExtension($fileMeta.n).ToLower()

            $elapsed = (Get-Date) - $StartTime
            $avgTime = $elapsed.TotalSeconds / [math]::Max($count, 1)
            $remainingStr = "{0:hh\:mm\:ss}" -f [TimeSpan]::FromSeconds($avgTime * ($FilteredTotal - $count))

            Write-Progress -Activity "Analyse OneDrive" `
                -Status "$count / $FilteredTotal | Restant: $remainingStr" `
                -PercentComplete (($count / $FilteredTotal) * 100)

            Write-Log "----------------------------------------------" "DEBUG"
            Write-Log "Analyzing file" "DEBUG"
            Write-Log "ID             : $fileId" "DEBUG"
            Write-Log "Original name  : $($fileMeta.n)" "DEBUG"
            Write-Log "Source path    : $($fileMeta.p)" "DEBUG"
            Write-Log "Extension      : $extension" "DEBUG"
            Write-Log "File date      : $($fileMeta.d)" "DEBUG"
            Write-Log "GPS            : $($fileMeta.GPS)" "DEBUG"

            $category = Get-SmartCategory -Path $fileMeta.p -Extension $extension
            Write-Log "Smart classification = ($category)" "DEBUG"

            #
            # 1) EXTENSION NON SUPPORTEE → marquer comme traité
            #
            if (-not $Config.ExtensionMap.ContainsKey($extension)) {
                Write-Log "Ignored: unsupported extension ($extension)" "DEBUG"

                $Global:State.ProcessedIds[$fileId] = $true
                Save-ProcessedIds -Id $fileId

                continue
            }

            $fileDate = [DateTime]$fileMeta.d

            # GPS
            $GPSLocation = $null
            if ($fileMeta.GPS) {
                $GPSLocation = Get-LocationName $fileMeta.GPS
                Write-Log "GPS location : $GPSLocation" "DEBUG"
            }

            # Tags
            $pathTags = Get-PathTags $fileMeta.p
            Write-Log "Tags de Path : $pathTags" "DEBUG"

            # Camera
            $camera = $fileMeta.cam

            # Nouveau nom
            $originalNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fileMeta.n)
            if ([string]::IsNullOrWhiteSpace($originalNameNoExt)) {
                Write-Log "Empty filename, skipping file: $($fileMeta.p)/$($fileMeta.n)" "WARN"
                continue
            }

            $newName = Resolve-FinalName `
                -FileMeta   $fileMeta `
                -Extension  $extension `
                -GPSLocation $GPSLocation `
                -PathTags   $pathTags `
                -Camera     $camera

            Write-Log "Generated new name: $newName" "DEBUG"

            $dest = Get-DestinationPath `
                -FileMeta  $fileMeta `
                -Extension $extension `
                -NewName   $newName `
                -FileDate  $fileDate

            $logFile = Join-Path (Split-Path $IndexFile -Parent) "log2.txt"
            "[$category] $($fileMeta.p)/$($fileMeta.n) --> $($dest.FullDestination)" | Add-Content -Path $logFile

            #
            # 2) CAS no_action → marquer comme traité
            #
            if ($null -eq $dest) {
                Write-Log "File ignored (no_action category): $($fileMeta.n)" "DEBUG"

                $Global:State.ProcessedIds[$fileId] = $true
                Save-ProcessedIds -Id $fileId

                continue
            }

            Write-Log "Destination path = ($($dest.CleanDestination))" "DEBUG"
            $cleanDestination = $dest.CleanDestination
            $fullDestination = $dest.FullDestination

            $srcDirClean = $fileMeta.p -replace "^/drive/root:", ""
            $currentPath = "$($srcDirClean.Trim('/'))/$($fileMeta.n)"

            #
            # 3) Déjà à la bonne place → marquer comme traité
            #
            if ($currentPath -eq $fullDestination.Trim('/')) {
                Write-Log "Already in correct place: $($fileMeta.n)" "DEBUG"

                $Global:State.ProcessedIds[$fileId] = $true
                Save-ProcessedIds -Id $fileId

                continue
            }

            #
            # 4) Sinon → ajouter au plan
            #
            $Global:State.PlannedActions.Add([PSCustomObject]@{
                    Id       = $fileId
                    SrcPath  = $fileMeta.p
                    SrcName  = $fileMeta.n
                    DstDir   = "/$($cleanDestination.Trim('/'))"
                    DstName  = $newName
                    FullDst  = $fullDestination
                    Category = $category
                })
        }

        if (Test-Path $logFile) {
            Get-Content $logFile | Sort-Object | Set-Content $logFile
        }

        Write-Progress -Activity "Analyse OneDrive" -Completed

        Write-Log "Plan generated: $($Global:State.PlannedActions.Count) files." "SUCCESS"

        try {
            $cacheFolder = Split-Path $IndexFile -Parent
            $planFile = Join-Path $cacheFolder "plan.json"
            $Global:State.PlannedActions | ConvertTo-Json -Depth 10 | Set-Content $planFile
            Write-Log "Plan saved to $planFile" "SUCCESS"
        }
        catch {
            Write-Log "Error saving plan : $($_.Exception.Message)" "ERROR"
        }
    }
    catch {
        Write-Log "New-Plan error : $($_.Exception.Message)" "ERROR"
        throw
    }
}

function Save-ProcessedIds {
    param([string]$Id)
    try {
        # Use the global path defined in the main script
        $processedFile = $Global:ProcessedLog
        if (-not $processedFile) {
            $processedFile = Join-Path (Split-Path $Global:IndexFile -Parent) "processed_ids.log"
        }

        if ($Id) {
            # Performance optimization: Append only the new ID
            $Id | Add-Content -Path $processedFile -Encoding UTF8
        }
        else {
            # Fallback: rewrite full list as flat text if no specific ID provided
            $Global:State.ProcessedIds.Keys | Set-Content -Path $processedFile -Encoding UTF8
        }
    }
    catch {
        Write-Log "Error saving processed IDs: $($_.Exception.Message)" "ERROR"
    }
}

function Test-Plan {
    try {
        $plan = $Global:State.PlannedActions

        if (-not $plan -or $plan.Count -eq 0) {
            Write-Log "No plan loaded for analysis." "WARN"
            return
        }

        Write-Log "=== PLAN ANALYSIS ===" "INFO"
        Write-Log "Total actions : $($plan.Count)" "INFO"

        $duplicates = $plan.FullDst | Group-Object | Where-Object { $_.Count -gt 1 }
        if ($duplicates) {
            Write-Log "Collisions detected:" "ERROR"
            foreach ($d in $duplicates) {
                Write-Log " - $($d.Name) ($($d.Count) occurrences)" "ERROR"
            }
        }
        else {
            Write-Log "No collisions detected." "SUCCESS"
        }

        $tooLong = $plan | Where-Object { $_.FullDst.Length -gt 250 }
        if ($tooLong) {
            Write-Log "Paths > 250 characters: $($tooLong.Count)" "INFO"
        }

        Write-Log "Analysis complete." "SUCCESS"
    }
    catch {
        Write-Log "Test-Plan error : $($_.Exception.Message)" "ERROR"
    }
}

# =====================================================================
# EXPORT
# =====================================================================

Export-ModuleMember -Function *
